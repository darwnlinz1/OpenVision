// OpenVision - GeminiLiveSmokeTests.swift
// OPT-IN smoke test against the REAL Gemini API: checks that the live model honours the
// contract the rest of the app depends on (dual-channel format, answer in the wearer's
// language, photo used only when relevant). Skipped unless OPENVISION_LIVE_GEMINI=1 is set for
// the test runner (CI: the "live Gemini" option of the E2E workflow; locally:
// `TEST_RUNNER_OPENVISION_LIVE_GEMINI=1 scripts/e2e/run-simulator-tests.sh`).
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
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENVISION_LIVE_GEMINI"] == "1",
                          "live Gemini smoke test is opt-in (OPENVISION_LIVE_GEMINI=1)")
        savedText = service.onTextReceived
        savedAgent = service.agentMessageCallback
        savedPartial = service.onPartialSpoken
        service.agentMessageCallback = nil
        service.onPartialSpoken = nil
        service.urlProtocolClasses = []
        service.clearConversationHistory()
        service.resetNetworkState()
    }

    override func tearDown() async throws {
        service.onTextReceived = savedText
        service.agentMessageCallback = savedAgent
        service.onPartialSpoken = savedPartial
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
