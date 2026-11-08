# Architecture

OpenVision does one thing: a Ray-Ban Meta photo + a free-form question (Vietnamese or English) →
Gemini → a spoken answer on the glasses and a rendered step-by-step solution on the phone. Why it
is built this way: [ADR-001](architecture/ADR-001-solver-pipeline.md).

```
OpenVision/
├── App/                 App entry (OpenVisionApp): DAT SDK configure, URL callback
├── Config/              Constants (voice, storage)
├── Managers/            SettingsManager (+ SettingsSecrets: API key in the Keychain),
│                        GlassesManager (DAT session, capture button, full-res stills, stream),
│                        ConversationManager (History)
├── Models/              AppSettings, conversation models
├── Resources/           Info.plist, SolutionRenderer/ (offline KaTeX + marked page)
├── Services/
│   ├── GeminiLive/      GeminiLiveService — REST streaming solver, retries, agent loop, prompt
│   ├── TTS/             TTSService — Apple voices per language, SpokenMath
│   ├── Voice/           VoiceCommandService — wake word, recognition, barge-in
│   ├── Audio/           AudioSessionManager (HFP routing to the glasses), SoundService
│   ├── Recording/       SessionRecorder — POV demo recording
│   ├── Telemetry/       Local latency metrics (no network)
│   └── AIBackend/       Connection state / error types
└── Views/
    ├── VoiceAgent/      VoiceAgentView + VoiceAgentViewModel (all orchestration),
    │                    RecentPhotoScanner, PhotoPayload, SolverIntent, TextChunking
    ├── Components/      Theme, SolutionView (rendered DISPLAY), bubbles, onboarding
    ├── History/         Conversations, "Continue" (seeds Gemini's context)
    └── Settings/        Gemini keys, glasses (button, photo quality), voices
OpenVisionTests/         Pure logic + scripted-network E2E (see docs/testing)
```

## One question, end to end

1. **Photo.** The glasses' capture button reaches the app through DAT Inputs
   (`GlassesManager.onCaptureButton`). Short press = photo for the next question, hold = photo
   and solve now, double press = repeat the last answer (configurable). The photo is a
   standalone still at full sensor resolution (`Camera.photo`); fallbacks are the 720p stream
   still and a glasses photo already in Camera Roll (`VoiceAgentViewModel.acquireGlassesPhoto`).
   It stays the context for 120 s / 5 questions.
2. **Question.** "Ok Vision …" → `VoiceCommandService` (recognizer language from Settings) →
   `VoiceAgentViewModel.sendCommand`, which sends the words verbatim with the photo.
3. **Gemini.** `GeminiLiveService.sendRESTMessage` streams the reply, retrying by failure type
   inside a 120 s deadline. If the model must see and has no photo it answers `[[CAPTURE]]`
   and the app takes one (`onCaptureRequested`).
4. **Answer.** The `SPOKEN:` channel is spoken sentence by sentence while it streams
   (`onPartialSpoken` → `TTSService`), in the question's language; `DISPLAY:` opens in
   `SolutionSheet` (KaTeX, offline). Both go to History.

## Patterns

- **MVVM on the main screen.** `VoiceAgentView` renders; `VoiceAgentViewModel`
  (`@MainActor ObservableObject`) owns session lifecycle, routing, speech streaming and History.
  Service callbacks capture the view model weakly.
- **Singleton services** (`Service.shared`), orchestrated from the view model.
- **Pure logic in enums/static functions** (`SolverIntent`, `TextChunking`, `PhotoPayload`,
  `SpokenMath`, `GeminiLiveService.parseDualChannel` / `classifyHTTPError` / `parseSSELine`) so
  tests never need hardware or network.
- **Audio invariants** (do not regress): one shared mic tap, a stable audio session, HFP routing
  to the glasses, a 350 ms echo guard, barge-in paused *before* speech starts.

## Tests

```bash
xcodebuild test -project OpenVision.xcodeproj -scheme OpenVision -destination "platform=iOS Simulator,name=iPhone 16 Pro"
```

- `BlueprintSolverTests` — parsing, language, voices, keys, photo sizing, SpokenMath.
- `BlueprintGeminiE2ETests` — a scripted Gemini endpoint (URLProtocol): retries, model fallback,
  media-resolution step-down, agent loop, stale signatures, streamed speech.
- `GeminiLiveSmokeTests` — one real call when `OPENVISION_GEMINI_API_KEYS` is set (CI secret).
- `scripts/blueprint/verify_blueprint.py` — static guard run before every IPA build, including
  a check that no Gemini key is in the repository.

Glasses-only paths (capture button, full-resolution transfer) are verified on hardware.
