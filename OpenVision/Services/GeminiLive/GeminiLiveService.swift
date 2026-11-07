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

    // MARK: - Endpoint

    static let apiHost = "generativelanguage.googleapis.com"
    static let modelName = "gemini-3.5-flash-lite"

    // MARK: - Multi-turn Conversation History

    /// Entries kept for follow-up questions: 3 user/model exchanges (Blueprint lesson 7).
    static let maxHistoryEntries = 6

    private var conversationHistory: [[String: Any]] = []

    /// Number of stored history entries (user + model turns) — read-only view for diagnostics/tests.
    var conversationHistoryCount: Int { conversationHistory.count }

    public func clearConversationHistory() {
        conversationHistory.removeAll()
        imageFingerprintInHistory = nil
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
        requestGeneration += 1   // an in-flight stream drops its result and stops feeding speech
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

    /// Primary solver entrypoint: send the wearer's words (+ optional glasses photo) to Gemini.
    ///
    /// Built to never leave the wearer stuck on "thinking":
    /// - Streams (SSE): the SPOKEN channel is handed to `onPartialSpoken` sentence by sentence,
    ///   so the glasses start talking long before the step-by-step DISPLAY channel is finished,
    ///   and bytes keep flowing, so long answers never hit an idle timeout.
    /// - Retries by failure type: 429 → next key now; dead/blocked key (400/401/403) → drop it
    ///   for an hour and use the next; 5xx → exponential backoff with jitter; network drop →
    ///   retry, or keep what already streamed. One overall deadline bounds the whole turn.
    /// - The photo goes at full resolution once. History keeps a 2048 px copy, and a follow-up
    ///   on the same photo does not upload it again.
    func sendRESTMessage(_ text: String, imageData: Data?) async throws {
        requestGeneration += 1
        let generation = requestGeneration
        isProcessing = true
        processingChangedCallback?(true)
        lastError = nil

        defer {
            // A newer request (or interrupt) owns the processing state now — don't clobber it.
            if generation == requestGeneration {
                isProcessing = false
                processingChangedCallback?(false)
            }
        }

        let allKeys = getAvailableKeyList()
        guard !allKeys.isEmpty else {
            throw AIBackendError.notConfigured
        }

        // Same photo as one the model already has in this conversation? Don't upload it again.
        var imageToSend = imageData
        if let data = imageData, historyContainsImage,
           imageFingerprintInHistory == PhotoPayload.fingerprint(data) {
            imageToSend = nil
            NSLog("[GeminiLive] Photo already in conversation history — not re-uploading")
        }
        if let data = imageToSend {
            NSLog("[GeminiLive] Attached image payload: %d bytes (%@)", data.count, PhotoPayload.mimeType(for: data))
        }
        // Prepare the lighter history copy off the main actor while the upload runs.
        let historyCopyTask: Task<Data, Never>? = imageToSend.map { data in
            Task.detached(priority: .utility) { PhotoPayload.historyCopy(of: data) }
        }

        // The wearer's words go through as spoken. Only an empty turn gets a default ask.
        let promptText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (imageToSend != nil || imageData != nil ? "Giải giúp tôi bài toán hoặc câu hỏi trong ảnh này" : "Xin chào")
            : text
        let contents = conversationHistory + [Self.userTurn(text: promptText, imageData: imageToSend)]

        let started = Date()
        let maxAttempts = allKeys.count + 2
        var attempt = 0
        var networkFailures = 0
        var lastErrorMessage = "No response from Gemini API"

        retryLoop: while attempt < maxAttempts && Date().timeIntervalSince(started) < Self.overallDeadline {
            guard generation == requestGeneration, !Task.isCancelled else { throw CancellationError() }
            attempt += 1
            let key = getNextAvailableKey(from: allKeys)
            let body = try makeRequestBody(contents: contents)
            NSLog("[GeminiLive] Sending request (attempt %d/%d, %d KB) using key %@...",
                  attempt, maxAttempts, body.count / 1024, String(key.prefix(8)))

            let outcome = await performStreamingRequest(body: body, key: key, generation: generation)
            switch outcome {
            case .success(let rawText):
                NSLog("[GeminiLive] Received response (%d chars) in %.1fs", rawText.count, Date().timeIntervalSince(started))
                deliver(rawText)
                await recordTurn(userText: promptText, sentImage: imageToSend, historyCopyTask: historyCopyTask, rawText: rawText)
                return

            case .cancelled:
                throw CancellationError()

            case .rateLimited(let retryAfter):
                NSLog("[GeminiLive] Key %@... returned 429 quota exhausted. Cooling down and rotating...", String(key.prefix(8)))
                coolDownKey(key, for: retryAfter ?? 60)
                lastErrorMessage = "Gemini quota exhausted (429)"

            case .badKey(let message):
                NSLog("[GeminiLive] Key %@... rejected (%@) — dropping it for an hour", String(key.prefix(8)), message)
                coolDownKey(key, for: 3600)
                lastErrorMessage = message

            case .unsupportedField(let message):
                guard mediaResolutionSupported else {
                    lastErrorMessage = message
                    break retryLoop
                }
                NSLog("[GeminiLive] Model rejected mediaResolution (%@) — retrying without it", message)
                mediaResolutionSupported = false
                attempt -= 1   // not the key's fault

            case .serverError(let message):
                lastErrorMessage = message
                await backoff(attempt: attempt)

            case .network(let message, let partial):
                if !partial.isEmpty {
                    // The connection dropped mid-answer: keep what arrived rather than make the
                    // wearer wait for a full retry (the spoken part streams first anyway).
                    NSLog("[GeminiLive] Stream dropped after %d chars (%@) — using partial answer", partial.count, message)
                    deliver(partial)
                    await recordTurn(userText: promptText, sentImage: imageToSend, historyCopyTask: historyCopyTask, rawText: partial)
                    return
                }
                lastErrorMessage = message
                networkFailures += 1
                if networkFailures > Self.maxNetworkRetries { break retryLoop }
                await backoff(attempt: networkFailures)

            case .fatal(let message):
                lastErrorMessage = message
                break retryLoop
            }
        }

        historyCopyTask?.cancel()
        NSLog("[GeminiLive] Giving up after %d attempt(s), %.1fs: %@", attempt, Date().timeIntervalSince(started), lastErrorMessage)
        self.lastError = lastErrorMessage
        throw AIBackendError.requestFailed(lastErrorMessage)
    }

    // MARK: - Request plumbing

    /// Hard cap on one turn, all retries included.
    nonisolated static let overallDeadline: TimeInterval = 120
    /// Longest silence tolerated between bytes (covers the model "thinking" before its first token).
    nonisolated static let idleTimeout: TimeInterval = 75
    nonisolated static let maxNetworkRetries = 2

    /// Streamed SPOKEN-channel text so far (cumulative, cleaned exactly like the final parse), so
    /// the glasses can start speaking at the first finished sentence. Main actor.
    var onPartialSpoken: ((String) -> Void)?

    /// Extra URLProtocol classes for the session (tests stub the network with these).
    var urlProtocolClasses: [AnyClass] = [] {
        didSet { session = Self.makeSession(protocolClasses: urlProtocolClasses) }
    }

    private var session: URLSession = GeminiLiveService.makeSession(protocolClasses: [])
    private var requestGeneration = 0
    private var imageFingerprintInHistory: Int?
    private var mediaResolutionSupported = true

    private nonisolated static func makeSession(protocolClasses: [AnyClass]) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = overallDeadline + 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty {
            config.protocolClasses = protocolClasses + (config.protocolClasses ?? [])
        }
        return URLSession(configuration: config)
    }

    /// Outcome of one HTTP attempt, classified for the retry policy.
    enum AttemptOutcome: Equatable {
        case success(String)
        case cancelled
        case rateLimited(retryAfter: TimeInterval?)
        case badKey(String)
        case unsupportedField(String)
        case serverError(String)
        case network(String, partial: String)
        case fatal(String)
    }

    var historyContainsImage: Bool {
        conversationHistory.contains { turn in
            (turn["parts"] as? [[String: Any]])?.contains { $0["inlineData"] != nil } ?? false
        }
    }

    static func userTurn(text: String, imageData: Data?) -> [String: Any] {
        var parts: [[String: Any]] = []
        if let imageData {
            parts.append([
                "inlineData": [
                    "mimeType": PhotoPayload.mimeType(for: imageData),
                    "data": imageData.base64EncodedString()
                ]
            ])
        }
        parts.append(["text": text])
        return ["role": "user", "parts": parts]
    }

    private func makeRequestBody(contents: [[String: Any]]) throws -> Data {
        var generationConfig: [String: Any] = [
            "temperature": 0.2,
            // Thinking tokens count against this budget; 2048 could leave a hard problem with
            // an empty, truncated answer.
            "maxOutputTokens": 8192
        ]
        if mediaResolutionSupported {
            // Read the glasses photo at the highest detail the model offers (small print, exams).
            generationConfig["mediaResolution"] = "MEDIA_RESOLUTION_HIGH"
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": buildSystemPrompt()]]],
            "contents": contents,
            "generationConfig": generationConfig
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private func performStreamingRequest(body: Data, key: String, generation: Int) async -> AttemptOutcome {
        let endpoint = "https://\(Self.apiHost)/v1beta/models/\(Self.modelName):streamGenerateContent?alt=sse&key=\(key)"
        guard let url = URL(string: endpoint) else { return .fatal("Invalid Gemini URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = Self.idleTimeout

        var accumulated = ""
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .network("No HTTP response", partial: "")
            }
            guard (200...299).contains(http.statusCode) else {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    if errorBody.count > 4000 { break }
                }
                NSLog("[GeminiLive] HTTP error %d: %@", http.statusCode, errorBody)
                return Self.classifyHTTPError(status: http.statusCode, body: errorBody,
                                              retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            for try await line in bytes.lines {
                guard generation == requestGeneration else { return .cancelled }
                guard let chunk = Self.parseSSELine(line) else { continue }
                if let reason = chunk.blockReason {
                    return .fatal("Gemini blocked the request (\(reason))")
                }
                guard !chunk.text.isEmpty else { continue }
                accumulated += chunk.text
                if let spoken = Self.streamingSpokenPrefix(from: accumulated), !spoken.isEmpty {
                    onPartialSpoken?(spoken)
                }
            }
            if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .serverError("Empty response from Gemini")
            }
            return .success(accumulated)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if (error as? URLError)?.code == .cancelled { return .cancelled }
            NSLog("[GeminiLive] Request error: %@", error.localizedDescription)
            return .network(error.localizedDescription, partial: accumulated)
        }
    }

    /// Hand a finished reply to the view model (dual-channel parsing happens there).
    private func deliver(_ rawText: String) {
        if let agentMessage = agentMessageCallback {
            agentMessage(rawText)
        } else {
            onOutputTranscription?(Self.parseDualChannel(rawText).spoken)
        }
        onTextReceived?(rawText)
        // Note: For REST calls, turn completion does NOT occur here; it occurs after TTS playback completes.
    }

    /// Append the finished exchange to history (photo as its lighter copy), keeping the last
    /// `maxHistoryEntries` entries.
    private func recordTurn(userText: String, sentImage: Data?, historyCopyTask: Task<Data, Never>?, rawText: String) async {
        var historyImage: Data?
        if let historyCopyTask {
            historyImage = await historyCopyTask.value
        }
        conversationHistory.append(Self.userTurn(text: userText, imageData: historyImage))
        conversationHistory.append(["role": "model", "parts": [["text": rawText]]])
        if conversationHistory.count > Self.maxHistoryEntries {
            conversationHistory.removeFirst(conversationHistory.count - Self.maxHistoryEntries)
        }
        if let sentImage {
            imageFingerprintInHistory = PhotoPayload.fingerprint(sentImage)
        }
        if !historyContainsImage {
            imageFingerprintInHistory = nil
        }
    }

    private func backoff(attempt: Int) async {
        let base = min(4.0, 0.5 * pow(2.0, Double(max(0, attempt - 1))))
        let delay = base + Double.random(in: 0...0.3)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // MARK: - Response parsing (pure, unit-testable)

    struct StreamChunk: Equatable {
        var text: String
        var finishReason: String?
        var blockReason: String?
    }

    /// One SSE line (`data: {json}`) → its text delta. Thought parts are skipped; every text part
    /// is joined (models that "think" can put a non-text part first).
    static func parseSSELine(_ line: String) -> StreamChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseResponseObject(json)
    }

    static func parseResponseObject(_ json: [String: Any]) -> StreamChunk {
        var text = ""
        var finishReason: String?
        if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
            finishReason = first["finishReason"] as? String
            if let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts where (part["thought"] as? Bool) != true {
                    if let t = part["text"] as? String { text += t }
                }
            }
        }
        let blockReason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
        return StreamChunk(text: text, finishReason: finishReason, blockReason: blockReason)
    }

    static func classifyHTTPError(status: Int, body: String, retryAfter: String?) -> AttemptOutcome {
        let lower = body.lowercased()
        let summary = "HTTP \(status): \(body.prefix(300))"
        switch status {
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0) })
        case 401, 403:
            return .badKey(summary)
        case 400:
            if lower.contains("api key") || lower.contains("api_key") {
                return .badKey(summary)
            }
            if lower.contains("mediaresolution") || lower.contains("media_resolution") || lower.contains("media resolution") {
                return .unsupportedField(summary)
            }
            return .fatal(summary)
        case 408, 500...599:
            return .serverError(summary)
        default:
            return .fatal(summary)
        }
    }

    private static let spokenTagRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[SPOKEN\]|\*{0,2}SPOKEN(?:\s*:|\*{0,2}\s*:?)|#+\s*SPOKEN)"#)
    private static let displayTagRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|\n)\s*[-*•]?\s*(?:\[DISPLAY\]|\*{0,2}DISPLAY(?:\s*:|\*{0,2}\s*:?)|#+\s*DISPLAY)"#)

    /// The SPOKEN channel of a reply that is still streaming in: nil until the SPOKEN tag has
    /// arrived, cut at the DISPLAY tag. Cleaned with the same rules as `parseDualChannel`, so it
    /// is always a prefix of the final spoken text (the sentence streamer relies on that).
    static func streamingSpokenPrefix(from raw: String) -> String? {
        guard let spokenRegex = spokenTagRegex else { return nil }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let tag = spokenRegex.firstMatch(in: raw, range: full) else { return nil }
        let start = tag.range.location + tag.range.length
        var end = ns.length
        if let displayRegex = displayTagRegex,
           let display = displayRegex.firstMatch(in: raw, range: NSRange(location: start, length: ns.length - start)) {
            end = display.range.location
        }
        guard end > start else { return "" }
        var body = ns.substring(with: NSRange(location: start, length: end - start))
        // A DISPLAY tag that has only half arrived ("\n**DISP") must not leak into speech:
        // hold back a trailing line that could still become the tag.
        if let newline = body.range(of: "\n", options: .backwards) {
            let lastLine = body[newline.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            let core = lastLine.trimmingCharacters(in: CharacterSet(charactersIn: "-*•#[ "))
            if !lastLine.isEmpty && "display".hasPrefix(core) {
                body = String(body[..<newline.lowerBound])
            }
        }
        return cleanChannelText(body)
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
        // Every key is cooling down: use the one whose cooldown ends first.
        let soonest = keys.min { (keyCooldowns[$0] ?? .distantPast) < (keyCooldowns[$1] ?? .distantPast) } ?? keys[0]
        return soonest
    }

    private func coolDownKey(_ key: String, for seconds: TimeInterval) {
        keyCooldowns[key] = Date().addingTimeInterval(max(1, seconds))
    }

    /// Forget rotation position and cooldowns (tests, or a fresh start).
    func resetKeyRotationState() {
        currentKeyIndex = 0
        keyCooldowns.removeAll()
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

    static func cleanChannelText(_ text: String) -> String {
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

    func buildSystemPrompt() -> String {
        let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var prompt = """
        You are an expert AI professor and STEM/math solver integrated directly into Ray-Ban Meta Gen 2 smart glasses and iPhone. You can see what the user sees through their camera (textbooks, math problems, exams, computer screens, code).

        HOW THE USER TALKS TO YOU:
        The user speaks freely, in Vietnamese or in English (sometimes mixed), with no fixed commands. Their words come from speech recognition, so expect missing diacritics, misheard words and small typos — infer what they mean.
        ALWAYS answer in the language the user used in their latest message: Vietnamese question -> Vietnamese answer (tiếng Việt có dấu đầy đủ, chuẩn xác); English question -> English answer.

        PHOTOS:
        Usually the user presses the capture button on the glasses frame first, then asks. An attached image is that photo. Use it whenever the question could be about it (e.g. "giải câu này", "what does this say", "câu 3 chọn gì").
        If the question is clearly unrelated to the photo (general knowledge, chit-chat, time, advice...), ignore the photo and answer normally.
        Follow-up questions may refer to a photo earlier in this conversation; keep using it.
        If the user is asking about something they are looking at but there is no image in this conversation, do not guess: say no photo was found and ask them to press the capture button on the glasses frame and ask again (in their language).

        When solving problems or answering questions, you MUST strictly follow the DUAL-CHANNEL RESPONSE FORMAT:

        SPOKEN:
        Provide a natural, comprehensive spoken explanation in 2 to 4 complete sentences for the Ray-Ban Meta smart glasses speaker, in the user's language. State the core method, key calculation steps, and the final answer clearly and confidently. For a problem with a worked solution, briefly mention that the complete derivation is shown on the phone screen.
        NEVER use raw LaTeX formulas, backslashes, or math symbols (no dollar signs, frac, sqrt, subscripts). Spell out math naturally (ví dụ: 'x bằng 2', 'tích phân từ 0 đến 1', 'đáp án là A'; e.g. 'x equals 2', 'the answer is A').
        For multiple choice questions, explicitly state the question number and the selected option with brief reasoning.

        DISPLAY:
        Complete step-by-step solution for the iPhone screen, in the user's language. Use standard LaTeX ($...$ inline, $$...$$ block display) for all formulas. Provide clear derivations, explanations, and final answer. If multiple choice, clearly state the selected option and rationale. For a simple non-math question, DISPLAY can just repeat the answer with any useful detail.

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
