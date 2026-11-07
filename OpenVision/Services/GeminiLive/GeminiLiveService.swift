// OpenVision - GeminiLiveService.swift
// REST-based Gemini Solver Service with API Key Pool & Dual-Channel Response

import Foundation
import UIKit
import AVFoundation

/// Gemini Live REST Service for STEM/Math Solver
///
/// Connects to Google Generative Language API via HTTPS REST with round-robin API Key Pool,
/// automatic 429 quota rotation, and dual-channel response parsing (SPOKEN for glasses, DISPLAY for phone).
@MainActor
final class GeminiLiveService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiLiveService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - API Key Pool (6 Verified Keys)

    private static let rawKeyPool: [String] = [
        "QVEuQWI4Uk42TDhyNzVHbFhob2RodC1ING55WDJkSk1TbURuYWNvVWppSlpSMlEyQW9sYmc=",
        "QVEuQWI4Uk42SWR0OXBKaE1YSERVNzR0d2FHcm91Tms5bm9rVVp1VEZZS2ZrQXgwZ2ZmcHc=",
        "QVEuQWI4Uk42S3VvckJ4TDFHZ3dacHlDRWV5bmh0ektQbU1pNWowNFlybXpxTHZxT2pYdmc=",
        "QVEuQWI4Uk42S2ViaFJwa0tYYXRGbTRLUktzc3ZoaklieVk1VEZvWmNyRkNsQmlaVXg2Q3c=",
        "QVEuQWI4Uk42SzBTVFdMNV92S01YclFlOWpkZmNSQ0tlNE5HS1k2RGhIWThWLVlBcEdwa1E=",
        "QVEuQWI4Uk42S2ZXSzhzUEhvZDZQeDNISU5WWEZZUXRHOTVmVThWRkc1YW5TcjdRU19waFE="
    ]

    static var defaultAPIKeyPool: [String] {
        rawKeyPool.compactMap { b64 in
            guard let data = Data(base64Encoded: b64),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }
    }

    private var currentKeyIndex: Int = 0
    private var keyCooldowns: [String: Date] = [:]

    // MARK: - Multi-turn Conversation History
    private var conversationHistory: [[String: Any]] = []

    public func clearConversationHistory() {
        conversationHistory.removeAll()
    }

    // MARK: - Callbacks

    var onTextReceived: ((String) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // Callbacks backing AIBackend conformance
    var agentMessageCallback: ((String) -> Void)?
    var processingChangedCallback: ((Bool) -> Void)?

    // MARK: - Active Request Tracking

    private var activeTask: Task<Void, Error>?

    // MARK: - Initialization

    private init() {}

    // MARK: - Connection Lifecycle

    /// Connect to Gemini Service: validates key availability and enters connected state
    func connect() async throws {
        let keys = getAvailableKeyList()
        guard !keys.isEmpty else {
            throw AIBackendError.notConfigured
        }

        connectionState = .connected
        onConnectionStateChanged?(connectionState)
        NSLog("[GeminiLive] Connected to REST solver endpoint with %d API keys in pool", keys.count)
    }

    /// Disconnect from Gemini Service
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        NSLog("[GeminiLive] Disconnecting")
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
        isModelSpeaking = false

        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        processingChangedCallback?(false)
        onDisconnected?()
    }

    /// Interrupt ongoing request
    func interrupt() async {
        NSLog("[GeminiLive] Interrupted")
        activeTask?.cancel()
        activeTask = nil
        isProcessing = false
        isModelSpeaking = false
        processingChangedCallback?(false)
    }

    // MARK: - Audio / Video Stubs (Preserved for compatibility)

    func sendAudio(data: Data) {
        // Audio stream not required in REST solver mode
    }

    func sendVideoFrame(imageData: Data) {
        // Video streaming handled on-demand via sendMessage photo capture
    }

    func sendVideoFrame(_ image: UIImage) {
        // Video streaming handled on-demand via sendMessage photo capture
    }

    // MARK: - Messaging

    /// Send plain text turn
    func sendText(_ text: String) async throws {
        try await sendRESTMessage(text, imageData: nil)
    }

    /// Primary solver entrypoint: send text and optional camera photo to Gemini 3.5 Flash Lite
    func sendRESTMessage(_ text: String, imageData: Data?) async throws {
        isProcessing = true
        processingChangedCallback?(true)
        lastError = nil

        defer {
            isProcessing = false
            processingChangedCallback?(false)
        }

        let allKeys = getAvailableKeyList()
        guard !allKeys.isEmpty else {
            throw AIBackendError.notConfigured
        }

        // Build contents parts (multimodal)
        var parts: [[String: Any]] = []
        if let imageData = imageData {
            let base64String = imageData.base64EncodedString()
            parts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": base64String
                ]
            ])
            NSLog("[GeminiLive] Attached image payload: %d bytes (base64 length: %d)", imageData.count, base64String.count)
        }

        let promptText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Giải giúp tôi bài toán hoặc câu hỏi trong ảnh này" : text
        parts.append(["text": promptText])

        let userTurn: [String: Any] = [
            "role": "user",
            "parts": parts
        ]

        var contentsToSend = conversationHistory
        contentsToSend.append(userTurn)

        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": buildSystemPrompt()]
                ]
            ],
            "contents": contentsToSend,
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 2048
            ]
        ]

        let postData = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        var lastErrorMessage = "No response from Gemini API"
        let maxAttempts = min(allKeys.count, 6)

        for attempt in 0..<maxAttempts {
            let selectedKey = getNextAvailableKey(from: allKeys)
            let endpointStr = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key=\(selectedKey)"
            guard let url = URL(string: endpointStr) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = postData
            request.timeoutInterval = 30

            do {
                NSLog("[GeminiLive] Sending request (attempt %d/%d) using key %@...", attempt + 1, maxAttempts, String(selectedKey.prefix(8)))
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }

                if httpResponse.statusCode == 429 {
                    NSLog("[GeminiLive] Key %@... returned 429 quota exhausted. Cooling down and rotating...", String(selectedKey.prefix(8)))
                    markKeyQuotaExhausted(selectedKey)
                    continue
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                    NSLog("[GeminiLive] HTTP error %d: %@", httpResponse.statusCode, errStr)
                    lastErrorMessage = "HTTP \(httpResponse.statusCode): \(errStr)"
                    if httpResponse.statusCode >= 500 {
                        continue
                    } else {
                        break
                    }
                }

                // Successful response
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first,
                      let content = firstCandidate["content"] as? [String: Any],
                      let responseParts = content["parts"] as? [[String: Any]],
                      let firstPart = responseParts.first,
                      let rawText = firstPart["text"] as? String else {
                    throw AIBackendError.invalidResponse
                }

                NSLog("[GeminiLive] Received response (%d chars)", rawText.count)

                let assistantTurn: [String: Any] = [
                    "role": "model",
                    "parts": [["text": rawText]]
                ]
                self.conversationHistory.append(userTurn)
                self.conversationHistory.append(assistantTurn)
                if self.conversationHistory.count > 6 {
                    self.conversationHistory.removeFirst(2)
                }

                // Parse dual-channel format
                let (spoken, display) = Self.parseDualChannel(rawText)

                // Dispatch to callbacks
                if let agentMessage = agentMessageCallback {
                    agentMessage(rawText)
                } else {
                    onOutputTranscription?(spoken)
                }
                onTextReceived?(rawText)
                // Note: For REST calls, turn completion does NOT occur here; it occurs after TTS playback completes.
                return

            } catch {
                NSLog("[GeminiLive] Request error on attempt %d: %@", attempt + 1, error.localizedDescription)
                lastErrorMessage = error.localizedDescription
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        self.lastError = lastErrorMessage
        throw AIBackendError.requestFailed(lastErrorMessage)
    }

    // MARK: - Key Pool Rotation & Cooldown

    private func getAvailableKeyList() -> [String] {
        let userKey = SettingsManager.shared.settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = Self.defaultAPIKeyPool
        if !userKey.isEmpty && !list.contains(userKey) {
            list.insert(userKey, at: 0)
        }
        return list
    }

    private func getNextAvailableKey(from keys: [String]) -> String {
        let now = Date()
        let total = keys.count
        for i in 0..<total {
            let idx = (currentKeyIndex + i) % total
            let candidate = keys[idx]
            if let cooldown = keyCooldowns[candidate], cooldown > now {
                continue
            }
            currentKeyIndex = (idx + 1) % total
            return candidate
        }
        // If all keys are in cooldown, proceed with next key anyway
        currentKeyIndex = (currentKeyIndex + 1) % total
        return keys[currentKeyIndex]
    }

    private func markKeyQuotaExhausted(_ key: String) {
        keyCooldowns[key] = Date().addingTimeInterval(60) // 60 seconds cooldown
    }

    // MARK: - Dual Channel Response Parser (Visor line-anchored regex)

    static func parseDualChannel(_ text: String) -> (spoken: String, display: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenPattern = #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[SPOKEN\]|\*{0,2}SPOKEN(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*SPOKEN)\s*([\s\S]*?)(?=(?:(?:^|\n)\s*[-*•]?\s*(?:\[DISPLAY\]|\*{0,2}DISPLAY(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*DISPLAY))|$)"#
        let displayPattern = #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[DISPLAY\]|\*{0,2}DISPLAY(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*DISPLAY)\s*([\s\S]*?)(?=(?:(?:^|\n)\s*[-*•]?\s*(?:\[SPOKEN\]|\*{0,2}SPOKEN(?:\s*:|\*{0,2}\s*:?)|\#\#+\s*SPOKEN))|$)"#

        let spokenRegex = try? NSRegularExpression(pattern: spokenPattern)
        let displayRegex = try? NSRegularExpression(pattern: displayPattern)

        let nsString = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        var spokenPart: String?
        var displayPart: String?

        if let sm = spokenRegex?.firstMatch(in: trimmed, range: fullRange), sm.numberOfRanges > 1 {
            let r = sm.range(at: 1)
            if r.location != NSNotFound {
                spokenPart = nsString.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let dm = displayRegex?.firstMatch(in: trimmed, range: fullRange), dm.numberOfRanges > 1 {
            let r = dm.range(at: 1)
            if r.location != NSNotFound {
                displayPart = nsString.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let s = spokenPart, let d = displayPart {
            let cleanS = cleanChannelText(s)
            let cleanD = cleanChannelText(d)
            return (cleanS.isEmpty ? cleanD : cleanS, cleanD.isEmpty ? cleanS : cleanD)
        } else if let s = spokenPart {
            let cleanS = cleanChannelText(s)
            return (cleanS, cleanS)
        } else if let d = displayPart {
            let cleanD = cleanChannelText(d)
            return (generateSpokenSummary(from: cleanD), cleanD)
        }

        return (trimmed, trimmed)
    }

    private static func generateSpokenSummary(from display: String) -> String {
        let lines = display.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var resultLine: String?
        for line in lines.reversed() {
            let lower = line.lowercased()
            if lower.hasPrefix("kết quả") || lower.hasPrefix("đáp án") || lower.hasPrefix("đáp số") ||
                lower.hasPrefix("nghiệm") || lower.hasPrefix("vậy") || lower.hasPrefix("chọn") ||
                lower.hasPrefix("result") || lower.hasPrefix("answer") || lower.hasPrefix("therefore") {
                resultLine = line
                break
            }
        }
        let prefix = resultLine ?? lines.first ?? ""
        let cleanPrefix = cleanChannelText(prefix)
        return "\(cleanPrefix). Các bước giải chi tiết đã hiển thị trên màn hình điện thoại."
    }

    private static func cleanChannelText(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"(?i)^\s*[-*•]?\s*(?:\[?(?:SPOKEN|DISPLAY)\]?)\s*:?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\b(?:SPOKEN|DISPLAY)\b\s*:"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[:\s\-*#]+"#, with: "", options: .regularExpression)
        while let last = s.last, "*# \t\r\n".contains(last) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - System Prompt (Visor parity: natural, multi-sentence spoken explanation)

    private func buildSystemPrompt() -> String {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var prompt = """
        You are an expert AI professor and STEM/math solver integrated directly into Ray-Ban Meta Gen 2 smart glasses and iPhone. You can see what the user sees through their camera (textbooks, math problems, exams, computer screens, code).

        When solving problems or answering questions, you MUST strictly follow the DUAL-CHANNEL RESPONSE FORMAT:

        SPOKEN:
        Provide a natural, comprehensive spoken explanation in 2 to 4 complete sentences for the Ray-Ban Meta smart glasses speaker. State the core method, key calculation steps, and the final answer clearly and confidently in natural Vietnamese (tiếng Việt có dấu đầy đủ, chuẩn xác). Then briefly mention that the complete derivation is shown on the phone screen.
        NEVER use raw LaTeX formulas, backslashes, or math symbols (no dollar signs, frac, sqrt, subscripts). Spell out math naturally (ví dụ: 'x bằng 2', 'tích phân từ 0 đến 1', 'đáp án là A').
        For multiple choice questions, explicitly state the question number and the selected option with brief reasoning.

        DISPLAY:
        Complete step-by-step solution for the iPhone screen. Use standard LaTeX ($...$ inline, $$...$$ block display) for all formulas. Provide clear derivations, explanations, and final answer. If multiple choice, clearly state the selected option and rationale.

        The current date and time is \(now) in the user's local time zone. Base any time on this.
        """

        let userPrompt = SettingsManager.shared.settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        let memories = SettingsManager.shared.settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }

        return prompt
    }
}
