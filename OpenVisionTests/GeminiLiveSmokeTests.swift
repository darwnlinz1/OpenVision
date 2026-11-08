// OpenVision - GeminiLiveSmokeTests.swift
// OPT-IN smoke test against the REAL Gemini API: checks that the live model honours the
// contract the rest of the app depends on (dual-channel format, answer in the wearer's
// language, photo used only when relevant). Skipped unless OPENVISION_LIVE_GEMINI=1 and
// OPENVISION_GEMINI_API_KEYS (comma-separated) are set for the test runner. Keys are NEVER in the
// source: CI passes the `GEMINI_API_KEYS` repository secret; locally:
// `TEST_RUNNER_OPENVISION_LIVE_GEMINI=1 TEST_RUNNER_OPENVISION_GEMINI_API_KEYS=AQ.… make e2e-live`.
// Assertions are deliberately loose: the model is not deterministic.

import XCTest
@testable import OpenVision

@MainActor
final class GeminiLiveSmokeTests: XCTestCase {

    private var service: GeminiLiveService { GeminiLiveService.shared }
    private var savedText: ((String) -> Void)?
    private var savedAgent: ((String) -> Void)?
    private var savedPartial: ((String) -> Void)?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPENVISION_LIVE_GEMINI"] == "1",
                          "live Gemini smoke test is opt-in (OPENVISION_LIVE_GEMINI=1)")
        let keys = GeminiLiveService.parseKeys(env["OPENVISION_GEMINI_API_KEYS"] ?? "")
        try XCTSkipIf(keys.isEmpty, "set OPENVISION_GEMINI_API_KEYS for the live smoke test")
        savedText = service.onTextReceived
        savedAgent = service.agentMessageCallback
        savedPartial = service.onPartialSpoken
        service.agentMessageCallback = nil
        service.onPartialSpoken = nil
        service.urlProtocolClasses = []
        service.apiKeysOverride = keys
        service.clearConversationHistory()
        service.resetNetworkState()
    }

    override func tearDown() async throws {
        service.onTextReceived = savedText
        service.agentMessageCallback = savedAgent
        service.onPartialSpoken = savedPartial
        service.apiKeysOverride = nil
        service.clearConversationHistory()
    }

    func testVietnameseQuestionAboutAPhotoGetsAVietnameseDualChannelAnswer() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 2400, height: 1200))
        let reply = try await ask("giải câu này", photo: photo)
        let (spoken, display) = GeminiLiveService.parseDualChannel(reply)
        let voiced = TTSService.cleanSpokenAudio(spoken)
        XCTAssertTrue(TTSService.containsVietnamese(voiced), "Vietnamese question → Vietnamese answer: \(voiced)")
        XCTAssertTrue(voiced.contains("2"), "2x + 3 = 7 → x = 2: \(voiced)")
        XCTAssertFalse(spoken.contains("\\frac") || spoken.contains("$$"), "no LaTeX on the speaker: \(spoken)")
        XCTAssertFalse(display.isEmpty)
    }

    func testEnglishQuestionGetsAnEnglishAnswer() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 2400, height: 1200))
        let reply = try await ask("what is x in this equation?", photo: photo)
        let voiced = TTSService.cleanSpokenAudio(GeminiLiveService.parseDualChannel(reply).spoken)
        XCTAssertFalse(TTSService.containsVietnamese(voiced), "English question → English answer: \(voiced)")
        XCTAssertTrue(voiced.contains("2"), voiced)
    }

    func testUnrelatedQuestionIsAnsweredNormallyDespiteThePhoto() async throws {
        let photo = try XCTUnwrap(BlueprintSolverTests.jpeg(width: 2400, height: 1200))
        let reply = try await ask("Thủ đô của nước Pháp là gì?", photo: photo)
        XCTAssertTrue(reply.contains("Paris"), reply)
    }

    private func ask(_ question: String, photo: Data?) async throws -> String {
        var reply: String?
        service.onTextReceived = { reply = $0 }
        try await service.sendRESTMessage(question, imageData: photo)
        return try XCTUnwrap(reply)
    }
}
