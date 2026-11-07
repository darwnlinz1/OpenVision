// OpenVision - AIBackendConformances.swift
// AIBackend conformances for the seven services, in one place so the adapters are easy to audit.
//
// Five services (OpenClaw, OpenAI, Grok, Hermes, Gemma) already match the protocol surface and conform for
// free; Apple Intelligence and Gemini Live get thin adapters where their native APIs differ.

import Foundation

// MARK: - OpenClaw

extension OpenClawService: AIBackend {
    var backendType: AIBackendType { .openClaw }
    var supportsImageInput: Bool { true }
}

// MARK: - OpenAI

extension OpenAIService: AIBackend {
    var backendType: AIBackendType { .openAI }
    var supportsImageInput: Bool { true }
}

// MARK: - Grok

extension GrokService: AIBackend {
    var backendType: AIBackendType { .grok }
    var supportsImageInput: Bool { true }
}

// MARK: - Hermes

extension HermesService: AIBackend {
    var backendType: AIBackendType { .hermes }
    var supportsImageInput: Bool { true }
}

// MARK: - Local Gemma (MLX)

extension GemmaLocalService: AIBackend {
    var backendType: AIBackendType { .localGemma }
    var supportsImageInput: Bool { true }
    var localLLM: LocalTextLLM? { self }
}

// MARK: - Apple Intelligence

extension AppleFoundationService: AIBackend {
    var backendType: AIBackendType { .appleFoundation }
    var localLLM: LocalTextLLM? { self }

    /// Text-only backend — sends the prompt and ignores the image (supportsImageInput is false,
    /// so callers route photo commands elsewhere).
    func sendMessage(_ text: String, imageData: Data?) async throws {
        await sendMessage(text)
    }
}

// MARK: - Gemini Live

extension GeminiLiveService: AIBackend {
    var backendType: AIBackendType { .geminiLive }
    var supportsImageInput: Bool { true }

    var onAgentMessage: ((String) -> Void)? {
        get { agentMessageCallback }
        set { agentMessageCallback = newValue }
    }
    var onProcessingChanged: ((Bool) -> Void)? {
        get { processingChangedCallback }
        set { processingChangedCallback = newValue }
    }

    /// Route message and optional photo payload directly to Gemini REST service.
    func sendMessage(_ text: String, imageData: Data?) async throws {
        try await sendRESTMessage(text, imageData: imageData)
    }
}
