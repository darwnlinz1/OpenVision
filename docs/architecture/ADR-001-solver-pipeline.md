# ADR-001: Glasses solver pipeline — one brain, direct photos, dual channel

**Status:** Accepted
**Date:** 2026-11-07
**Deciders:** repository owner

## Context

OpenVision turns Ray-Ban Meta Gen 2 glasses + an iPhone 15 Pro Max (iOS 18+) into a hands-free
homework solver: the wearer presses the capture button, says "Ok Vision" and a free-form question
(Vietnamese or English), hears the answer on the glasses and sees the full derivation on the phone.

The fork had grown to ~20k lines with eight AI backends (Gemini Live, OpenAI, Realtime, Grok,
Hermes, OpenClaw, Apple Intelligence, on-device MLX Gemma/SmolVLM), three TTS engines (Apple,
Kokoro on MLX, cloud voices), telemetry, and API keys hidden in source. The manifesto and the
blueprint describe one workflow; the code supported a dozen. Forces:

- **Latency & reliability over choice.** The wearer can't see the phone; a stuck "thinking" or
  a wrong voice is the whole experience.
- **Public repository.** No key may ever be compiled in.
- **Photo freshness.** The Meta AI app imports glasses photos into Camera Roll when the glasses
  are folded or charging — not in real time — so "press, then ask" could not rely on it.
- **Gemini 3 image cost** is a fixed token budget per image (HIGH ≈1120, ULTRA_HIGH ≈2240
  tokens); pixels beyond what that budget resolves only add upload time.
- **iOS speech** recognizes one language per recognizer; there is no mixed vi/en model.
- Apple Foundation Models are text-only on iOS 26, so they can't read a photo of a problem.

## Decision

1. **One brain: Gemini REST streaming** (`streamGenerateContent?alt=sse`), model chain
   `gemini-3.5-flash-lite` → `gemini-3.1-flash-lite`, `thinkingLevel: LOW`, key in the
   `x-goog-api-key` header. Keys only from Settings (Keychain), several allowed (quota is per
   project *and* per model). Every other backend, MLX, Kokoro, telemetry and Apple Intelligence
   are removed.
2. **Retry by failure type inside one deadline** (120 s overall, 75 s idle): 429 rotates key,
   401/403/"api key" cools the key 1 h, 404 falls to the next model, unsupported fields step
   down (ULTRA_HIGH per part → HIGH in config → none; thinking off), stale thought signature
   resets history once (re-attaching the photo), 5xx backs off 1-2-4-8 s with jitter, a dropped
   stream keeps a usable partial answer.
3. **Agent loop:** if the model must see something and no photo is in the conversation it
   answers `[[CAPTURE]]`; the app takes a photo and asks again.
4. **Photos straight from the glasses** (Meta DAT 1.0.1): the capture button is routed to the
   app (MWDATInputs) and the photo is a standalone still at full sensor resolution
   (`Camera.photo`, `.full/.high`). Order everywhere: full-res still → 720p stream still →
   Camera Roll. Uploads are upright JPEG ≤ 3072 px q0.85 with `MEDIA_RESOLUTION_ULTRA_HIGH`;
   history keeps a 1536 px copy and the same photo is not re-uploaded.
5. **Dual channel:** the model writes `SPOKEN:` (2-4 sentences, answer first, no symbols) and
   `DISPLAY:` (Markdown + LaTeX). SPOKEN is spoken sentence by sentence while it streams;
   DISPLAY is rendered offline on the phone (bundled KaTeX + marked in a WKWebView).
6. **Language follows the question.** The prompt says so; TTS picks the Vietnamese or English
   Apple voice per reply (language-neutral sentences follow the reply), and reads leftover math
   symbols as words in that language (`SpokenMath`). The recognizer language is a setting
   (auto / vi-VN / en-US) because iOS can't mix.
7. **Keep the blueprint's audio fixes verbatim:** shared mic tap, stable audio session, HFP
   routing to the glasses, 350 ms echo guard, barge-in paused before speech starts.

## Options Considered

### A: Keep the multi-backend app
| Dimension | Assessment |
|-----------|------------|
| Complexity | High — 8 backends, 3 TTS engines, MLX packages |
| Cost | Large binary, memory entitlement, long CI builds |
| Reliability | Many untested paths reachable from Settings |
| Fit | The workflow uses one path |

**Pros:** offline fallback in theory, choice. **Cons:** on-device VLMs can't read a homework
photo well on an A17 Pro within the latency budget; Apple Intelligence can't see images; every
path is a place for the wearer to get stuck.

### B: Gemini Live (WebSocket audio)
**Pros:** native speech in/out. **Cons:** no LaTeX channel, Vietnamese voice quality and
interruptions are harder to control, a live session per question costs more and fails harder on
a weak link than one streamed REST call.

### C: Gemini REST + direct DAT photos (chosen)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Low — one service, one view model |
| Cost | Flash-Lite pricing; one image budget per question |
| Reliability | Typed retries, model fallback, deadline; three photo sources |
| Fit | Exactly the press → ask → hear + see workflow |

## Trade-off Analysis

Dropping offline modes means no answer without a network; for a homework solver whose
quality bar is "correct derivation", a weak offline model answering wrongly is worse than a
clear spoken "network is slow, ask again". Full-resolution stills cost 1-several seconds of
transfer; 1080p is offered as a setting. DAT Inputs and `Camera.photo` are experimental
(Developer Mode); the Camera Roll path stays as the fallback so the app never depends on them.

## Consequences

- Easier: one place to tune prompts, retries and voices; CI builds in minutes; the static
  guard (`scripts/blueprint/verify_blueprint.py`) can assert the whole workflow.
- Harder: nothing works offline; experimental Meta APIs may change in a minor SDK release.
- Revisit: when DAT Inputs/Photo leave experimental status; if Gemini model names change
  (only `modelChain` needs editing); if iOS ships a mixed-language recognizer.

## Action Items

1. [x] Remove backends, MLX, Kokoro, telemetry, embedded keys.
2. [x] Streaming REST with typed retries and model chain.
3. [x] DAT 1.0.1: capture button + full-resolution still, with fallbacks.
4. [x] Offline KaTeX solution view; per-language voices; SpokenMath.
5. [ ] Measure on hardware: capture-button delivery, full-res transfer time, whether the
       glasses still save their own copy when the button is routed to the app.
6. [ ] Owner: revoke the six keys that were in git history (Google AI Studio).
