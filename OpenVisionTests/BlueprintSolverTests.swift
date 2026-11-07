// OpenVision - BlueprintSolverTests.swift
// Pure-logic layer of the MASTER_HANDOVER_BLUEPRINT.md end-to-end suite: everything between
// "the wearer said something" and "the glasses speak / the phone shows LaTeX" that can be
// checked without a network or audio device. Each test names the blueprint lesson (§3) or
// checklist item (§7) it protects. See docs/testing/E2E_TEST_PLAN.md for the full matrix.

import XCTest
import UIKit
import AVFoundation
@testable import OpenVision

@MainActor
final class BlueprintSolverTests: XCTestCase {

    // MARK: - Lesson 5: dual-channel parsing (SPOKEN for the glasses, DISPLAY for the phone)

    func testPlainSpokenAndDisplayAreSplit() {
        let reply = "SPOKEN:\nPhương trình 2x cộng 3 bằng 7 nên x bằng 2. Lời giải chi tiết ở trên điện thoại.\n\nDISPLAY:\nTa có $2x + 3 = 7$\n$$x = \\frac{7-3}{2} = 2$$\nĐáp án: $x = 2$"
        let (spoken, display) = GeminiLiveService.parseDualChannel(reply)
        XCTAssertEqual(spoken, "Phương trình 2x cộng 3 bằng 7 nên x bằng 2. Lời giải chi tiết ở trên điện thoại.")
        XCTAssertEqual(display, "Ta có $2x + 3 = 7$\n$$x = \\frac{7-3}{2} = 2$$\nĐáp án: $x = 2$")
    }

    func testTagVariantsTheModelActuallyEmits() {
        let variants: [(String, String, String)] = [
            ("[SPOKEN] Đáp án là B vì đạo hàm dương.\n[DISPLAY] $f'(x) = 3x^2 > 0$ nên chọn **B**.",
             "Đáp án là B vì đạo hàm dương.", "$f'(x) = 3x^2 > 0$ nên chọn **B**."),
            ("**SPOKEN:** Đáp án là C.\n**DISPLAY:** Chọn C vì $\\sqrt{9} = 3$.",
             "Đáp án là C.", "Chọn C vì $\\sqrt{9} = 3$."),
            ("## SPOKEN\nKết quả là 5.\n## DISPLAY\n$2 + 3 = 5$", "Kết quả là 5.", "$2 + 3 = 5$"),
            ("- SPOKEN: Đáp án A.\n- DISPLAY: Chọn A.", "Đáp án A.", "Chọn A."),
            ("spoken: đáp án là d.\ndisplay: chọn $d$.", "đáp án là d.", "chọn $d$."),
            ("DISPLAY:\n$x^2 = 4$\nSPOKEN:\nx bằng 2 hoặc âm 2.", "x bằng 2 hoặc âm 2.", "$x^2 = 4$"),
        ]
        for (reply, spoken, display) in variants {
            let parsed = GeminiLiveService.parseDualChannel(reply)
            XCTAssertEqual(parsed.spoken, spoken, reply)
            XCTAssertEqual(parsed.display, display, reply)
        }
    }

    /// The bug behind lesson 5: the word "display" or `\displaystyle` inside the spoken text
    /// used to cut everything after it.
    func testWordDisplayInsideSpokenDoesNotTruncate() {
        let reply = "SPOKEN:\nBạn nhìn display của máy tính, kết quả là 12. Công thức dùng \\displaystyle cũng không sao. Câu cuối vẫn phải được đọc.\nDISPLAY:\n$$\\displaystyle \\sum_{k=1}^{3} k \\cdot 2 = 12$$"
        let (spoken, display) = GeminiLiveService.parseDualChannel(reply)
        XCTAssertTrue(spoken.hasSuffix("Câu cuối vẫn phải được đọc."), spoken)
        XCTAssertTrue(display.hasPrefix("$$\\displaystyle"), display)
    }

    func testDisplayOnlyReplyGetsASpokenSummary() {
        let reply = "DISPLAY:\nBước 1: Chuyển vế $2x = 4$\nBước 2: Chia hai vế cho 2\nĐáp số: $x = 2$"
        let (spoken, display) = GeminiLiveService.parseDualChannel(reply)
        XCTAssertEqual(spoken, "Đáp số: $x = 2$. Các bước giải chi tiết đã hiển thị trên màn hình điện thoại.")
        XCTAssertEqual(TTSService.cleanSpokenAudio(spoken), "Đáp số: x = 2. Các bước giải chi tiết đã hiển thị trên màn hình điện thoại.")
        XCTAssertTrue(display.hasSuffix("Đáp số: $x = 2$"))
    }

    func testUntaggedOrHalfTaggedRepliesStillSpeak() {
        XCTAssertEqual(GeminiLiveService.parseDualChannel("Just a plain answer without tags.").spoken,
                       "Just a plain answer without tags.")
        let spokenOnly = GeminiLiveService.parseDualChannel("SPOKEN: Xin chào, tôi có thể giúp gì?")
        XCTAssertEqual(spokenOnly.spoken, "Xin chào, tôi có thể giúp gì?")
        XCTAssertEqual(spokenOnly.display, spokenOnly.spoken)
        let emptySpoken = GeminiLiveService.parseDualChannel("SPOKEN:\n\nDISPLAY:\nĐáp án: 42")
        XCTAssertEqual(emptySpoken.spoken, "Đáp án: 42", "an empty SPOKEN falls back to DISPLAY instead of silence")
    }

    // MARK: - Lesson 5: what reaches the speech synthesizer

    func testCleanSpokenAudioStripsLatexAndMarkdownButKeepsVietnamese() {
        XCTAssertEqual(TTSService.cleanSpokenAudio("Ta có $\\frac{1}{2}$ cộng $\\sqrt{4}$ bằng **2,5** và `code` ## Hết"),
                       "Ta có 12 cộng 4 bằng 2,5 và Hết")
        XCTAssertEqual(TTSService.cleanSpokenAudio("SPOKEN: x bằng 2"), "x bằng 2")
        XCTAssertEqual(TTSService.cleanSpokenAudio("   "), "")
        for sample in ["Tích phân $\\int_0^1 x\\,dx$ bằng một phần hai.", "Đáp án $\\boxed{B}$", "\\[ x = 2 \\]"] {
            let cleaned = TTSService.cleanSpokenAudio(sample)
            XCTAssertFalse(cleaned.contains("$") || cleaned.contains("\\") || cleaned.contains("{"), cleaned)
        }
    }

    // MARK: - Bilingual: the voice follows the answer's language

    func testLanguageDetection() {
        XCTAssertTrue(TTSService.containsVietnamese("Giải câu này"))
        XCTAssertTrue(TTSService.containsVietnamese("giai bai nay giup minh"))
        XCTAssertFalse(TTSService.containsVietnamese("solve this"))
        // Substring matching used to read these English answers in the Vietnamese voice.
        XCTAssertFalse(TTSService.containsVietnamese("That statement is true for every structure."))
        XCTAssertFalse(TTSService.containsVietnamese("Tap the congress button"))
    }

    func testVoiceFollowsAnswerLanguage() {
        let english = TTSService.voice(forText: "The answer is B because the derivative is positive.")
        XCTAssertTrue(english?.language.hasPrefix("en") ?? false, "English answer → English voice, got \(String(describing: english?.language))")
        if AVSpeechSynthesisVoice(language: "vi-VN") != nil {
            let vietnamese = TTSService.voice(forText: "Đáp án là B vì đạo hàm dương.")
            XCTAssertEqual(vietnamese?.language, "vi-VN")
            let chosenEnglish = AVSpeechSynthesisVoice(language: "en-GB")
            XCTAssertEqual(TTSService.voice(forText: "x bằng 2", english: chosenEnglish)?.language, "vi-VN",
                           "a Vietnamese answer is never read by an English voice")
        }
    }

    // MARK: - Streaming: the glasses start talking before DISPLAY is generated

    func testStreamingSpokenPrefixIsAlwaysAPrefixOfTheFinalSpokenText() {
        let replies = [
            "SPOKEN:\nPhương trình 2x cộng 3 bằng 7 nên x bằng 2. Lời giải chi tiết ở trên điện thoại.\n\nDISPLAY:\nTa có $2x + 3 = 7$\nĐáp án: $x = 2$",
            "**SPOKEN:** The answer is B. Because the derivative is positive.\n**DISPLAY:** $f'(x)>0$",
            "## SPOKEN\nKết quả là 5.\n## DISPLAY\n$2 + 3 = 5$",
            "[SPOKEN] Câu 3 chọn D.\nDo đó đáp án là D.\n[DISPLAY] Chọn D",
        ]
        for reply in replies {
            let finalSpoken = GeminiLiveService.parseDualChannel(reply).spoken
            var sawSpoken = false
            for end in 1...reply.count {
                let partial = String(reply.prefix(end))
                guard let spoken = GeminiLiveService.streamingSpokenPrefix(from: partial) else { continue }
                sawSpoken = true
                XCTAssertTrue(finalSpoken.hasPrefix(spoken), "streamed \"\(spoken)\" is not a prefix of \"\(finalSpoken)\"")
            }
            XCTAssertTrue(sawSpoken)
            XCTAssertEqual(GeminiLiveService.streamingSpokenPrefix(from: reply), finalSpoken)
        }
        XCTAssertNil(GeminiLiveService.streamingSpokenPrefix(from: "SPOK"), "nothing is spoken before the tag arrives")
    }

    func testSSEParsingJoinsTextPartsAndSkipsThoughts() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"SPOKEN: x "},{"text":"bằng 2."}]},"finishReason":"STOP"}]}"#
        let chunk = GeminiLiveService.parseSSELine(line)
        XCTAssertEqual(chunk?.text, "SPOKEN: x bằng 2.")
        XCTAssertEqual(chunk?.finishReason, "STOP")
        XCTAssertNil(GeminiLiveService.parseSSELine(": keep-alive"))
        XCTAssertNil(GeminiLiveService.parseSSELine(""))
        let blocked = GeminiLiveService.parseSSELine(#"data: {"promptFeedback":{"blockReason":"SAFETY"}}"#)
        XCTAssertEqual(blocked?.blockReason, "SAFETY")
        // Gemini 3 ends a stream with an empty-text part that only carries the thought signature.
        let last = GeminiLiveService.parseSSELine(#"data: {"candidates":[{"content":{"parts":[{"text":"","thoughtSignature":"c2lnbmF0dXJl"}]},"finishReason":"STOP"}]}"#)
        XCTAssertEqual(last?.text, "")
        XCTAssertEqual(last?.thoughtSignature, "c2lnbmF0dXJl")
    }

    func testModelTurnKeepsTheThoughtSignature() {
        let turn = GeminiLiveService.modelTurn(text: "SPOKEN: x bằng 2", signature: "c2ln")
        let parts = turn["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?.last?["thoughtSignature"] as? String, "c2ln")
        XCTAssertEqual((GeminiLiveService.modelTurn(text: "ok", signature: nil)["parts"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Keys: from Settings only, several allowed

    func testKeysAreParsedFromSettingsText() {
        XCTAssertEqual(GeminiLiveService.parseKeys(" AQ.aaa, AIzabbb\nAQ.ccc;AQ.aaa "), ["AQ.aaa", "AIzabbb", "AQ.ccc"])
        XCTAssertEqual(GeminiLiveService.parseKeys(""), [])
    }

    func testAgentCaptureToken() {
        XCTAssertTrue(GeminiLiveService.isCaptureRequest("[[CAPTURE]]"))
        XCTAssertTrue(GeminiLiveService.isCaptureRequest("  [[capture]]\n"))
        XCTAssertFalse(GeminiLiveService.isCaptureRequest("SPOKEN: Đáp án là A"))
    }

    // MARK: - No-timeout networking: every failure has a defined next step

    func testHTTPFailuresAreClassifiedForTheRetryPolicy() {
        typealias G = GeminiLiveService
        XCTAssertEqual(G.classifyHTTPError(status: 429, body: "", retryAfter: "7"), .rateLimited(retryAfter: 7))
        XCTAssertEqual(G.classifyHTTPError(status: 429, body: "", retryAfter: nil), .rateLimited(retryAfter: nil))
        guard case .badKey = G.classifyHTTPError(status: 403, body: "PERMISSION_DENIED", retryAfter: nil) else {
            return XCTFail("a revoked key must rotate, not fail the turn")
        }
        guard case .badKey = G.classifyHTTPError(status: 400, body: "API key not valid. Please pass a valid API key.", retryAfter: nil) else {
            return XCTFail("an invalid key must rotate, not fail the turn")
        }
        XCTAssertEqual(G.classifyHTTPError(status: 400, body: "Invalid JSON payload received. Unknown name \"mediaResolution\"", retryAfter: nil),
                       .unsupportedField(.mediaResolution, "HTTP 400: Invalid JSON payload received. Unknown name \"mediaResolution\""))
        guard case .unsupportedField(.thinking, _) = G.classifyHTTPError(status: 400, body: "thinking_level is not supported for this model", retryAfter: nil) else {
            return XCTFail("an unsupported thinking level must trigger a retry without it")
        }
        guard case .staleSignature = G.classifyHTTPError(status: 400, body: "Thought signature is not valid", retryAfter: nil) else {
            return XCTFail("a rejected thought signature must reset the history, not fail every follow-up")
        }
        guard case .modelUnavailable = G.classifyHTTPError(status: 404, body: "models/x is not found", retryAfter: nil) else {
            return XCTFail("a retired model must fall back to the next model")
        }
        guard case .serverError = G.classifyHTTPError(status: 503, body: "overloaded", retryAfter: nil) else {
            return XCTFail("5xx must back off and retry")
        }
        guard case .fatal = G.classifyHTTPError(status: 400, body: "Request contains an invalid argument.", retryAfter: nil) else {
            return XCTFail("a genuinely bad request must not loop")
        }
        XCTAssertLessThanOrEqual(G.overallDeadline, 180, "a turn must never leave the wearer waiting for minutes")
        XCTAssertGreaterThanOrEqual(G.idleTimeout, 45, "the model may think before its first token")
    }

    // MARK: - Lesson 7 + Ray-Ban Meta full resolution

    func testSmallUprightJPEGPassesThroughUntouched() throws {
        let original = try XCTUnwrap(Self.jpeg(width: 3072, height: 2304))
        XCTAssertEqual(PhotoPayload.uploadJPEG(from: original), original, "already upload-sized: no re-encode")
        XCTAssertEqual(PhotoPayload.mimeType(for: original), "image/jpeg")
    }

    /// Gemini 3 has a fixed token budget per image, so 12 MP is downscaled to 3072 px before upload:
    /// same detail for the model, a quarter of the upload time.
    func testTwelveMegapixelPhotoIsSentAt3072px() throws {
        let original = try XCTUnwrap(Self.jpeg(width: 4032, height: 3024))
        let payload = try XCTUnwrap(PhotoPayload.uploadJPEG(from: original))
        let info = try XCTUnwrap(PhotoPayload.imageInfo(payload))
        XCTAssertEqual(max(info.width, info.height), PhotoPayload.uploadMaxDimension)
        XCTAssertEqual(info.orientation, 1)
        XCTAssertLessThan(payload.count, original.count)
    }

    func testNonJPEGIsReencodedAsJPEG() throws {
        let png = try XCTUnwrap(Self.image(width: 2000, height: 1500).pngData())
        XCTAssertEqual(PhotoPayload.mimeType(for: png), "image/png")
        let payload = try XCTUnwrap(PhotoPayload.uploadJPEG(from: png))
        XCTAssertEqual(PhotoPayload.mimeType(for: payload), "image/jpeg")
        XCTAssertEqual(PhotoPayload.imageInfo(payload)?.width, 2000, "smaller than the cap: size kept")
    }

    func testHistoryCopyIsLighterButReadable() throws {
        let original = try XCTUnwrap(Self.jpeg(width: 3072, height: 2304))
        let copy = PhotoPayload.historyCopy(of: original)
        let info = try XCTUnwrap(PhotoPayload.imageInfo(copy))
        XCTAssertEqual(max(info.width, info.height), Int(PhotoPayload.historyMaxDimension))
        XCTAssertLessThan(copy.count, original.count)
        let small = try XCTUnwrap(Self.jpeg(width: 800, height: 600))
        XCTAssertEqual(PhotoPayload.historyCopy(of: small), small, "small images are kept as-is")
        XCTAssertNotEqual(PhotoPayload.fingerprint(original), PhotoPayload.fingerprint(small))
    }

    func testSolutionIsOfferedOnlyWhenItAddsSomething() {
        XCTAssertNil(VoiceAgentViewModel.solutionWorthShowing(spoken: "Paris.", display: "Paris."))
        XCTAssertEqual(VoiceAgentViewModel.solutionWorthShowing(spoken: "x bằng 2.", display: "$2x = 4$\n$x = 2$"), "$2x = 4$\n$x = 2$")
    }

    // MARK: - Workflow: shutter photo → "Ok Vision" + anything, in Vietnamese or English

    /// Math that slipped into SPOKEN is read as words, in the answer's language.
    func testSpokenMathReadsSymbolsAsWords() {
        XCTAssertEqual(SpokenMath.normalize("x^2 = 4 nên x = 2 hoặc x = -2.", vietnamese: true),
                       "x bình phương bằng 4 nên x bằng 2 hoặc x bằng âm 2.")
        XCTAssertEqual(SpokenMath.normalize("Đáp án: 3/4 + 1/4 = 1", vietnamese: true),
                       "Đáp án: 3 phần 4 cộng 1 phần 4 bằng 1")
        XCTAssertEqual(SpokenMath.normalize("The answer is x^2 = 9, so x = -3 or x = 3.", vietnamese: false),
                       "The answer is x squared equals 9, so x equals negative 3 or x equals 3.")
        XCTAssertEqual(SpokenMath.normalize("e^(x+1) là đạo hàm", vietnamese: true), "e mũ x cộng 1 là đạo hàm")
        XCTAssertEqual(SpokenMath.normalize("x² ≥ 0, √16 = 4, giảm 20%", vietnamese: true),
                       "x bình phương lớn hơn hoặc bằng 0, căn 16 bằng 4, giảm 20 phần trăm")
        // Not math: ranges and names are left alone.
        XCTAssertEqual(SpokenMath.normalize("câu 1-5 của Ray-Ban", vietnamese: true), "câu 1-5 của Ray-Ban")
    }

    func testRecognizerLanguageSetting() {
        XCTAssertEqual(VoiceCommandService.recognitionLocaleIdentifier("vi-VN"), "vi-VN")
        XCTAssertEqual(VoiceCommandService.recognitionLocaleIdentifier("en-US"), "en-US")
        XCTAssertFalse(VoiceCommandService.recognitionLocaleIdentifier("auto").contains("_"))
    }

    func testPhotoContextLivesFor120SecondsAndFiveQuestions() {
        let shot = Date()
        var context = CapturedPhotoContext(data: Data([0xFF, 0xD8, 0xFF]), timestamp: shot)
        XCTAssertTrue(context.isFresh(at: shot.addingTimeInterval(119)))
        XCTAssertFalse(context.isFresh(at: shot.addingTimeInterval(120)))
        context.useCount = CapturedPhotoContext.maxUses
        XCTAssertFalse(context.isFresh(at: shot.addingTimeInterval(1)))
        XCTAssertEqual(SolverIntent.recentPhotoWindow, 120, "Visor hasRecentShutterPhoto window")
    }

    func testStopIsMatchedOnWordsInBothLanguages() {
        for stop in ["stop", "dừng lại", "thôi", "Okay stop", "be quiet", "ngừng đi"] {
            XCTAssertTrue(SolverIntent.isStopCommand(stop), stop)
        }
        // "desktop" contains "stop" but is not the word; "stop video" belongs to live-video handling.
        for question in ["what's on the desktop", "giải câu này", "stop video", "Tại sao ra x bằng 2?"] {
            XCTAssertFalse(SolverIntent.isStopCommand(question), question)
        }
    }

    func testMessagesAreSpokenInTheWearersLanguage() {
        XCTAssertTrue(SolverIntent.missingPhotoMessage(for: "giải câu này").contains("Không tìm thấy ảnh"))
        XCTAssertTrue(SolverIntent.missingPhotoMessage(for: "solve this").contains("No photo found"))
        XCTAssertTrue(TTSService.containsVietnamese(SolverIntent.networkFailureMessage(for: "câu 2 thì sao")))
        XCTAssertTrue(SolverIntent.missingKeyMessage(for: "giải câu này").contains("API key"))
        XCTAssertFalse(TTSService.containsVietnamese(SolverIntent.networkFailureMessage(for: "and question two?")))
    }

    // MARK: - Lesson 3: wake word heard through the Vietnamese recognizer

    func testWakeWordIsStrippedInEitherLanguage() {
        XCTAssertEqual(VoiceCommandService.stripWakeWord(from: "ô kê vi dơn giải câu này", defaultWakeWord: "ok vision"), "giải câu này")
        XCTAssertEqual(VoiceCommandService.stripWakeWord(from: "Ok Vision what does this say", defaultWakeWord: "ok vision"), "what does this say")
        XCTAssertEqual(VoiceCommandService.stripWakeWord(from: "vi dơn câu 2 thì sao", defaultWakeWord: "ok vision"), "câu 2 thì sao")
        for variant in ["ô kê vi dơn", "ok vi dơn", "vi dơn", "vision"] {
            XCTAssertTrue(VoiceCommandService.wakeWordVariations.contains { $0.contains(variant) }, variant)
        }
    }

    // MARK: - §5: system prompt contract

    func testSystemPromptKeepsTheDualChannelContractAndIsBilingual() {
        let prompt = GeminiLiveService.shared.buildSystemPrompt()
        XCTAssertTrue(prompt.contains("SPOKEN:"))
        XCTAssertTrue(prompt.contains("DISPLAY:"))
        XCTAssertTrue(prompt.contains("2 to 4 complete sentences"), "lesson 5: no ultra-short spoken answers")
        XCTAssertFalse(prompt.lowercased().contains("under 250 characters"), "lesson 5 regression")
        XCTAssertTrue(prompt.contains("ALWAYS answer in the language the user used"))
        XCTAssertTrue(prompt.contains("clearly unrelated to the photo"), "unrelated questions are answered normally")
        XCTAssertTrue(prompt.contains(GeminiLiveService.captureToken), "the model asks the app for a photo instead of guessing")
        XCTAssertTrue(prompt.contains("FIRST sentence states the final answer"), "answer-first: heard within seconds")
    }

    // MARK: - Helpers

    static func image(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let text = "2x + 3 = 7. Tìm x." as NSString
            text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: CGFloat(height) / 12)])
        }
    }

    static func jpeg(width: Int, height: Int) -> Data? {
        image(width: width, height: height).jpegData(compressionQuality: 0.9)
    }
}
