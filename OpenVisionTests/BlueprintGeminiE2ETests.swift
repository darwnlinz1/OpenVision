// OpenVision - BlueprintGeminiE2ETests.swift
// End-to-end through the REAL GeminiLiveService (request building, SSE streaming, retry policy,
// conversation history) and the REAL TTSService, with only the network replaced by a scripted
// URLProtocol. Mirrors the wearer's workflow from MASTER_HANDOVER_BLUEPRINT.md §2.1:
// temple-shutter photo → "Ok Vision" + a free-form question (Vietnamese or English) → spoken
// answer on the glasses + LaTeX on the phone → follow-up questions on the same photo.

import XCTest
@testable import OpenVision

@MainActor
final class BlueprintGeminiE2ETests: XCTestCase {

    private var service: GeminiLiveService { GeminiLiveService.shared }

    // The host app wires these to the view model; park them so only this test listens.
    private var savedText: ((String) -> Void)?
    private var savedPartial: ((String) -> Void)?
    private var savedAgent: ((String) -> Void)?
    private var savedOutput: ((String) -> Void)?
    private var savedProcessing: ((Bool) -> Void)?
    private var savedCapture: ((String) async -> Data?)?

    private let answer = "SPOKEN:\nPhương trình 2x cộng 3 bằng 7, chuyển vế được 2x bằng 4 nên x bằng 2. Lời giải chi tiết ở trên điện thoại.\n\nDISPLAY:\nTa có $2x + 3 = 7$\n$$2x = 4 \\Rightarrow x = 2$$\nĐáp án: $x = 2$"

    override func setUp() async throws {
        savedText = service.onTextReceived
        savedPartial = service.onPartialSpoken
        savedAgent = service.agentMessageCallback
        savedOutput = service.onOutputTranscription
        savedProcessing = service.processingChangedCallback
        savedCapture = service.onCaptureRequested
        service.onCaptureRequested = nil
        service.apiKeysOverride = ["AQ.test-key-A", "AQ.test-key-B", "AQ.test-key-C"]
        service.onTextReceived = nil
        service.onPartialSpoken = nil
        service.agentMessageCallback = nil
        service.onOutputTranscription = nil
        service.processingChangedCallback = nil
        service.urlProtocolClasses = [GeminiStub.self]
        service.clearConversationHistory()
        service.resetNetworkState()
        GeminiStub.reset()
    }

    override func tearDown() async throws {
        service.urlProtocolClasses = []
        service.apiKeysOverride = nil
        service.onCaptureRequested = savedCapture
        service.clearConversationHistory()
        service.resetNetworkState()
        service.onTextReceived = savedText
        service.onPartialSpoken = savedPartial
        service.agentMessageCallback = savedAgent
        service.onOutputTranscription = savedOutput
        service.processingChangedCallback = savedProcessing
        GeminiStub.reset()
    }

    // MARK: - Checklist test 1: shutter photo + question → full-resolution photo reaches Gemini

    func testShutterPhotoQuestionSendsAnUprightPhotoAtUltraHighDetailAndStreamsTheSpokenAnswer() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 4032, height: 3024))
        GeminiStub.enqueue(.stream(answer))

        var partials: [String] = []
        var finalText: String?
        service.onPartialSpoken = { partials.append($0) }
        service.onTextReceived = { finalText = $0 }

        try await service.sendRESTMessage("giải câu này", imageData: photo)

        let request = try XCTUnwrap(GeminiStub.captured.first)
        XCTAssertEqual(GeminiStub.captured.count, 1)
        XCTAssertTrue(request.url.path.hasSuffix("/gemini-3.5-flash-lite:streamGenerateContent"), request.url.absoluteString)
        XCTAssertEqual(request.query("alt"), "sse")
        XCTAssertNil(request.query("key"), "the API key must not be in the URL")
        XCTAssertEqual(request.apiKey, "AQ.test-key-A")

        let turn = try XCTUnwrap(request.contents.last)
        let sent = try XCTUnwrap(turn.imageData)
        let info = try XCTUnwrap(PhotoPayload.imageInfo(sent))
        XCTAssertEqual(max(info.width, info.height), PhotoPayload.uploadMaxDimension, "12 MP is sent at 3072 px")
        XCTAssertEqual(info.orientation, 1)
        XCTAssertEqual(turn.imageMIMEType, "image/jpeg")
        XCTAssertEqual(turn.mediaResolution, "MEDIA_RESOLUTION_ULTRA_HIGH", "detail requested on the image itself")
        XCTAssertEqual(turn.text, "giải câu này", "the wearer's words go through verbatim")
        XCTAssertNil(request.generationConfig["mediaResolution"])
        XCTAssertEqual((request.generationConfig["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "LOW")
        XCTAssertEqual(request.generationConfig["maxOutputTokens"] as? Int, 8192)
        XCTAssertTrue(request.systemPrompt.contains("DISPLAY:"))

        XCTAssertEqual(finalText, answer)
        let finalSpoken = GeminiLiveService.parseDualChannel(answer).spoken
        XCTAssertFalse(partials.isEmpty, "the glasses must start speaking before the reply is complete")
        for partial in partials {
            XCTAssertTrue(finalSpoken.hasPrefix(partial), "streamed \"\(partial)\" is not a prefix of the final spoken text")
        }
        XCTAssertEqual(partials.last, finalSpoken)
        XCTAssertEqual(service.conversationHistoryCount, 2)
        XCTAssertTrue(service.historyContainsImage)
    }

    // MARK: - Checklist test 4 / lesson 7: follow-up on the same photo

    func testFollowUpOnTheSamePhotoKeepsContextWithoutReuploading() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 4032, height: 3024))
        GeminiStub.enqueue(.stream(answer, signature: "c2lnLTE="))
        GeminiStub.enqueue(.stream("SPOKEN: Vì ta chuyển 3 sang vế phải rồi chia hai vế cho 2.\nDISPLAY: $2x = 4$"))

        try await service.sendRESTMessage("giải câu này", imageData: photo)
        try await service.sendRESTMessage("Tại sao lại ra x bằng 2?", imageData: photo)

        let followUp = try XCTUnwrap(GeminiStub.captured.last)
        XCTAssertEqual(followUp.contents.count, 3, "history (question + answer) + the follow-up")
        XCTAssertNil(followUp.contents[2].imageData, "the photo is already in history — don't upload 12 MP again")
        XCTAssertEqual(followUp.contents[2].text, "Tại sao lại ra x bằng 2?")
        let historyPhoto = try XCTUnwrap(followUp.contents[0].imageData, "the model still sees the photo")
        let info = try XCTUnwrap(PhotoPayload.imageInfo(historyPhoto))
        XCTAssertEqual(max(info.width, info.height), Int(PhotoPayload.historyMaxDimension))
        XCTAssertEqual(followUp.contents[1].role, "model")
        XCTAssertEqual(followUp.contents[1].thoughtSignature, "c2lnLTE=", "Gemini 3 thought signatures go back with the history")
    }

    func testANewPhotoIsUploadedAgain() async throws {
        let first = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 4032, height: 3024))
        let second = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 3024, height: 4032))
        GeminiStub.enqueue(.stream(answer))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: first)
        try await service.sendRESTMessage("còn câu này?", imageData: second)
        let sent = try XCTUnwrap(GeminiStub.captured.last?.contents.last?.imageData)
        XCTAssertEqual(PhotoPayload.imageInfo(sent)?.height, PhotoPayload.uploadMaxDimension, "the second (portrait) photo was uploaded")
    }

    // MARK: - Free-form, bilingual, unrelated questions answered normally

    func testUnrelatedQuestionsGoVerbatimInEitherLanguage() async throws {
        for question in ["Thủ đô của Pháp là gì?", "What's the weather like for a picnic?"] {
            GeminiStub.enqueue(.stream("SPOKEN: ok\nDISPLAY: ok"))
            try await service.sendRESTMessage(question, imageData: nil)
            let turn = try XCTUnwrap(GeminiStub.captured.last?.contents.last)
            XCTAssertEqual(turn.text, question, "no rewriting into a solve-the-image prompt")
            XCTAssertNil(turn.imageData)
        }
    }

    func testHistoryKeepsTheLastThreeExchanges() async throws {
        for i in 1...4 {
            GeminiStub.enqueue(.stream("SPOKEN: trả lời \(i)\nDISPLAY: \(i)"))
            try await service.sendRESTMessage("câu hỏi \(i)", imageData: nil)
        }
        XCTAssertEqual(service.conversationHistoryCount, GeminiLiveService.maxHistoryEntries)
        XCTAssertEqual(GeminiStub.captured.last?.contents.count, 7, "6 history entries + the new question")
        XCTAssertEqual(GeminiStub.captured.last?.contents.first?.text, "câu hỏi 1")
    }

    // MARK: - No timeouts, no dead ends: the retry policy

    func testQuotaExhaustedKeyRotatesImmediately() async throws {
        GeminiStub.enqueue(.status(429, body: #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        XCTAssertEqual(GeminiStub.captured.count, 2)
        XCTAssertNotEqual(GeminiStub.captured[0].apiKey, GeminiStub.captured[1].apiKey)
    }

    /// Quota is per project AND per model: when the primary model is exhausted on every key, the
    /// fallback model still has its own quota.
    func testWhenEveryKeyIsExhaustedTheFallbackModelAnswers() async throws {
        for _ in 0..<3 {
            GeminiStub.enqueue(.status(429, body: #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#))
        }
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        XCTAssertEqual(GeminiStub.captured.count, 4)
        XCTAssertTrue(GeminiStub.captured[3].url.path.contains("/\(GeminiLiveService.modelChain[1]):"), GeminiStub.captured[3].url.path)
    }

    func testRetiredModelFallsBackInsteadOfFailing() async throws {
        GeminiStub.enqueue(.status(404, body: #"{"error":{"code":404,"message":"models/gemini-3.5-flash-lite is not found"}}"#))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        XCTAssertTrue(GeminiStub.captured[1].url.path.contains("/\(GeminiLiveService.modelChain[1]):"))
    }

    func testRevokedKeyIsSkippedInsteadOfFailingTheTurn() async throws {
        GeminiStub.enqueue(.status(403, body: #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#))
        GeminiStub.enqueue(.status(400, body: #"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        XCTAssertEqual(GeminiStub.captured.count, 3)
        XCTAssertEqual(Set(GeminiStub.captured.map { $0.apiKey }).count, 3, "each retry uses a different key")
    }

    /// ULTRA_HIGH on the image → HIGH in generationConfig → nothing: each rejection steps down.
    func testUnsupportedMediaResolutionStepsDownAndRetries() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 2048, height: 1536))
        let rejected = #"{"error":{"message":"Invalid JSON payload received. Unknown name \"mediaResolution\""}}"#
        GeminiStub.enqueue(.status(400, body: rejected))
        GeminiStub.enqueue(.status(400, body: rejected))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: photo)
        XCTAssertEqual(GeminiStub.captured.count, 3)
        XCTAssertEqual(GeminiStub.captured[0].contents.last?.mediaResolution, "MEDIA_RESOLUTION_ULTRA_HIGH")
        XCTAssertNil(GeminiStub.captured[1].contents.last?.mediaResolution)
        XCTAssertEqual(GeminiStub.captured[1].generationConfig["mediaResolution"] as? String, "MEDIA_RESOLUTION_HIGH")
        XCTAssertNil(GeminiStub.captured[2].generationConfig["mediaResolution"])
        XCTAssertNil(GeminiStub.captured[2].contents.last?.mediaResolution)
    }

    func testUnsupportedThinkingLevelIsDroppedAndRetried() async throws {
        GeminiStub.enqueue(.status(400, body: #"{"error":{"message":"thinking_level is not supported for this model"}}"#))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        XCTAssertNotNil(GeminiStub.captured[0].generationConfig["thinkingConfig"])
        XCTAssertNil(GeminiStub.captured[1].generationConfig["thinkingConfig"])
    }

    // MARK: - Agent loop: the model asks to see, the app takes the photo

    func testModelAsksToSeeAndTheAppCapturesThenAsksAgain() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 2048, height: 1536))
        GeminiStub.enqueue(.stream("[[CAPTURE]]"))
        GeminiStub.enqueue(.stream(answer))
        var captures = 0
        service.onCaptureRequested = { _ in
            captures += 1
            return photo
        }
        var partials: [String] = []
        var finalText: String?
        service.onPartialSpoken = { partials.append($0) }
        service.onTextReceived = { finalText = $0 }

        try await service.sendRESTMessage("câu 3 chọn gì", imageData: nil)

        XCTAssertEqual(captures, 1)
        XCTAssertEqual(GeminiStub.captured.count, 2)
        XCTAssertNil(GeminiStub.captured[0].contents.last?.imageData)
        XCTAssertNotNil(GeminiStub.captured[1].contents.last?.imageData, "the question is asked again with the photo")
        XCTAssertEqual(GeminiStub.captured[1].contents.last?.text, "câu 3 chọn gì")
        XCTAssertEqual(finalText, answer)
        XCTAssertFalse(partials.contains { $0.contains("CAPTURE") }, "the protocol token is never spoken")
        XCTAssertEqual(service.conversationHistoryCount, 2, "only the real exchange is remembered")
    }

    func testWhenNoPhotoCanBeTakenTheGlassesSaySo() async throws {
        GeminiStub.enqueue(.stream("[[CAPTURE]]"))
        service.onCaptureRequested = { _ in nil }
        var finalText: String?
        service.onTextReceived = { finalText = $0 }
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        let spoken = GeminiLiveService.parseDualChannel(try XCTUnwrap(finalText)).spoken
        XCTAssertEqual(spoken, SolverIntent.missingPhotoMessage(for: "giải câu này"))
        XCTAssertEqual(GeminiStub.captured.count, 1)
    }

    func testRejectedThoughtSignatureResetsTheHistoryOnce() async throws {
        GeminiStub.enqueue(.stream(answer, signature: "b2xk"))
        GeminiStub.enqueue(.status(400, body: #"{"error":{"message":"Thought signature is not valid"}}"#))
        GeminiStub.enqueue(.stream(answer))
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        try await service.sendRESTMessage("tại sao?", imageData: nil)
        XCTAssertEqual(GeminiStub.captured.count, 3)
        XCTAssertEqual(GeminiStub.captured[2].contents.count, 1, "retried with a fresh conversation")
    }

    func testServerOverloadBacksOffAndRetries() async throws {
        GeminiStub.enqueue(.status(503, body: #"{"error":{"code":503,"status":"UNAVAILABLE"}}"#))
        GeminiStub.enqueue(.stream(answer))
        var finalText: String?
        service.onTextReceived = { finalText = $0 }
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        XCTAssertEqual(finalText, answer)
    }

    func testABadRequestFailsFastInsteadOfLooping() async throws {
        GeminiStub.enqueue(.status(400, body: #"{"error":{"message":"Request contains an invalid argument."}}"#))
        do {
            try await service.sendRESTMessage("giải câu này", imageData: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(GeminiStub.captured.count, 1)
        }
    }

    func testDroppedStreamKeepsTheAnswerSoFar() async throws {
        let partialReply = "SPOKEN:\nĐáp án là B vì đạo hàm luôn dương.\nDISPLAY:\n$f'(x) = 3x^2"
        GeminiStub.enqueue(.stream(partialReply, dropAtEnd: true))
        var finalText: String?
        service.onTextReceived = { finalText = $0 }
        try await service.sendRESTMessage("câu 3 chọn gì", imageData: nil)
        XCTAssertEqual(GeminiStub.captured.count, 1, "no full retry when the spoken answer already arrived")
        XCTAssertEqual(GeminiLiveService.parseDualChannel(finalText ?? "").spoken, "Đáp án là B vì đạo hàm luôn dương.")
    }

    func testDeadNetworkIsRetriedThenReportedNotHung() async throws {
        for _ in 0...GeminiLiveService.maxNetworkRetries {
            GeminiStub.enqueue(.stream("", dropAtEnd: true))
        }
        let started = Date()
        do {
            try await service.sendRESTMessage("giải câu này", imageData: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(GeminiStub.captured.count, GeminiLiveService.maxNetworkRetries + 1)
            XCTAssertLessThan(Date().timeIntervalSince(started), 15, "fails in seconds, not minutes")
        }
    }

    // MARK: - Checklist test 2 / lessons 4-5: the spoken answer plays to the end

    func testSpokenAnswerPlaysCompletelyAndBargeInStaysClosedUntilTheEnd() async throws {
        GeminiStub.enqueue(.stream(answer))
        var finalText: String?
        service.onTextReceived = { finalText = $0 }
        try await service.sendRESTMessage("giải câu này", imageData: nil)
        let spoken = GeminiLiveService.parseDualChannel(try XCTUnwrap(finalText)).spoken
        let voiced = TTSService.cleanSpokenAudio(spoken)
        XCTAssertFalse(voiced.contains("$") || voiced.contains("\\"))
        XCTAssertGreaterThanOrEqual(voiced.split(separator: ".").count, 2, "2-4 sentences, not 'X bằng 2.'")

        let tts = TTSService.shared
        let savedEnded = tts.onSpeechEnded
        defer { tts.onSpeechEnded = savedEnded }
        let ended = expectation(description: "speech finished")
        ended.assertForOverFulfill = false
        tts.onSpeechEnded = { ended.fulfill() }

        tts.speak(spoken)
        // Lesson 4: "speaking" is set synchronously, BEFORE the OS starts audio, so the mic
        // can't hear the first syllables of the temple speaker as a new command.
        XCTAssertTrue(tts.isSpeaking)
        XCTAssertEqual(tts.pendingUtterances, 1)
        await fulfillment(of: [ended], timeout: 60)
        XCTAssertFalse(tts.isSpeaking)
        XCTAssertEqual(tts.pendingUtterances, 0, "every utterance finished — nothing was cut off")
        XCTAssertEqual(SolverIntent.ttsEchoSettleNanoseconds, 350_000_000, "lesson 4 echo guard")
    }
}

// MARK: - Scripted Gemini endpoint

/// Replaces generativelanguage.googleapis.com for the session GeminiLiveService uses.
final class GeminiStub: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        var chunks: [String]
        var dropAtEnd: Bool

        static func stream(_ text: String, dropAtEnd: Bool = false, signature: String? = nil) -> Reply {
            var chunks = GeminiStub.sseChunks(text)
            if let signature {
                // Like Gemini 3: a final chunk with an empty-text part carrying only the signature.
                let event: [String: Any] = ["candidates": [["content": ["role": "model", "parts": [["text": "", "thoughtSignature": signature]]], "finishReason": "STOP"]]]
                let json = (try? JSONSerialization.data(withJSONObject: event)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                chunks.append("data: \(json)\r\n\r\n")
            }
            return Reply(status: 200, body: "", chunks: chunks, dropAtEnd: dropAtEnd)
        }

        static func status(_ code: Int, body: String) -> Reply {
            Reply(status: code, body: body, chunks: [], dropAtEnd: false)
        }
    }

    struct Turn {
        let role: String
        let text: String?
        let imageData: Data?
        let imageMIMEType: String?
        let mediaResolution: String?
        let thoughtSignature: String?
    }

    struct Captured {
        let url: URL
        let apiKey: String?
        let json: [String: Any]

        func query(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }

        var generationConfig: [String: Any] { json["generationConfig"] as? [String: Any] ?? [:] }

        var systemPrompt: String {
            let parts = (json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined() ?? ""
        }

        var contents: [Turn] {
            (json["contents"] as? [[String: Any]] ?? []).map { turn in
                let parts = turn["parts"] as? [[String: Any]] ?? []
                let imagePart = parts.first { $0["inlineData"] != nil }
                let inline = imagePart?["inlineData"] as? [String: Any]
                return Turn(role: turn["role"] as? String ?? "",
                            text: parts.compactMap { $0["text"] as? String }.first,
                            imageData: (inline?["data"] as? String).flatMap { Data(base64Encoded: $0) },
                            imageMIMEType: inline?["mimeType"] as? String,
                            mediaResolution: (imagePart?["mediaResolution"] as? [String: Any])?["level"] as? String,
                            thoughtSignature: parts.compactMap { $0["thoughtSignature"] as? String }.first)
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var log: [Captured] = []

    static var captured: [Captured] { lock.withLock { log } }

    static func reset() {
        lock.withLock {
            replies = []
            log = []
        }
    }

    static func enqueue(_ reply: Reply) {
        lock.withLock { replies.append(reply) }
    }

    /// Splits a reply into several SSE events, the way Gemini streams it.
    static func sseChunks(_ text: String, pieces: Int = 5) -> [String] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        let size = max(1, characters.count / pieces)
        return stride(from: 0, to: characters.count, by: size).map { start in
            let piece = String(characters[start..<min(start + size, characters.count)])
            let event: [String: Any] = ["candidates": [["content": ["role": "model", "parts": [["text": piece]]]]]]
            let json = (try? JSONSerialization.data(withJSONObject: event)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "data: \(json)\r\n\r\n"
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "generativelanguage.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.readBody(request)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let reply: Reply = Self.lock.withLock {
            Self.log.append(Captured(url: url, apiKey: request.value(forHTTPHeaderField: "x-goog-api-key"), json: json))
            return Self.replies.isEmpty ? .status(500, body: "no scripted reply") : Self.replies.removeFirst()
        }
        let contentType = reply.status == 200 ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if reply.status != 200 {
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        }
        for chunk in reply.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        if reply.dropAtEnd {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession moves the body into a stream before a URLProtocol sees it.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
