import Photos
import UIKit
import ImageIO
// OpenVision - VoiceAgentViewModel.swift
// MVVM: all voice-session orchestration for the main screen lives here — session lifecycle,
// command routing, live video, face intents, photo capture, TTS streaming, and history.
// VoiceAgentView renders this state and forwards user interactions; it holds no logic.
//
// The services are app-wide singletons; this ViewModel is their single orchestrator. Service
// callbacks capture self weakly — the services outlive any owner, so strong captures would pin
// the ViewModel forever.

import SwiftUI
import Speech

/// Pre-captured photo context for Visor "Capture First, Ask Later" workflow
struct CapturedPhotoContext {
    /// How long a captured photo stays attached to follow-up questions (Blueprint §2.1 step 7).
    static let ttl: TimeInterval = 120.0
    /// How many questions may reuse one photo before a fresh capture is required.
    static let maxUses = 5

    let id: UUID = UUID()
    let data: Data
    let timestamp: Date
    var useCount: Int

    init(data: Data, timestamp: Date = Date(), useCount: Int = 0) {
        self.data = data
        self.timestamp = timestamp
        self.useCount = useCount
    }

    var isFresh: Bool { isFresh(at: Date()) }

    /// Freshness at an explicit instant — lets tests check the TTL boundary without sleeping.
    func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(timestamp) < Self.ttl && useCount < Self.maxUses
    }
}

// MARK: - Solver intent (pure, unit-testable)

/// Pure command classification for the solver flow. Kept free of state so the Blueprint
/// end-to-end suite can pin the routing rules that protect against the "fatal pitfalls"
/// (MASTER_HANDOVER_BLUEPRINT.md §3 and checklist §7).
enum SolverIntent {
    /// Window in which a photo synced to Camera Roll by the temple shutter counts as "the
    /// photo the user is asking about" (Visor `hasRecentShutterPhoto`, Blueprint lesson 6).
    static let recentPhotoWindow: TimeInterval = 120.0

    /// Delay after the last TTS utterance before the mic may barge in again, so the temple
    /// speaker's echo is not heard as a new command (Blueprint lesson 4).
    static let ttsEchoSettleNanoseconds: UInt64 = 350_000_000

    /// "Stop" detection. Matched on WORDS, not substrings: `.contains("stop")` treated
    /// "what's on the desktop" as a stop command and killed the session mid-question.
    /// Phrases mentioning video/stream are left to the live-video stop handling.
    static func isStopCommand(_ command: String) -> Bool {
        let lowerCommand = command.lowercased()
        let commandWords = Set(lowerCommand.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let stopSingleWords: Set<String> = ["stop", "quiet", "silence", "enough"]
        let stopExact: Set<String> = ["stop", "quiet", "silence", "enough", "dừng", "thôi", "ngừng"]
        let stopPhrases = [
            "be quiet", "shut up", "ok stop", "okay stop", "stop talking", "stop it",
            "dừng lại", "dừng đi", "thôi đi", "ngừng lại", "ngừng đi"
        ]
        let isExactStop = stopExact.contains(lowerCommand.trimmingCharacters(in: .whitespacesAndNewlines))
        return (isExactStop
                || !commandWords.isDisjoint(with: stopSingleWords)
                || stopPhrases.contains { lowerCommand.contains($0) })
                && !lowerCommand.contains("video") && !lowerCommand.contains("stream")
    }

    /// What the glasses say when no Gemini API key is set (keys are never compiled into the app).
    @MainActor
    static func missingKeyMessage(for prompt: String) -> String {
        TTSService.containsVietnamese(prompt)
            ? "Chưa có API key Gemini. Bạn mở Cài đặt, chọn Gemini và dán key vào nhé."
            : "There is no Gemini API key yet. Open Settings, Gemini, and paste your key."
    }

    /// What the glasses say when the AI could not be reached even after retries.
    @MainActor
    static func networkFailureMessage(for prompt: String) -> String {
        TTSService.containsVietnamese(prompt)
            ? "Mạng đang chậm nên mình chưa nhận được câu trả lời. Bạn hỏi lại giúp mình nhé."
            : "The connection is slow and I didn't get an answer. Please ask again."
    }

    /// Language for what the app says on its own, when there is no question to answer in kind
    /// (a capture-button press): the listening-language setting, or the iPhone's language on "auto".
    @MainActor
    static var speaksVietnamese: Bool {
        switch SettingsManager.shared.settings.recognitionLanguage {
        case "vi-VN": return true
        case "en-US": return false
        default: return Locale.preferredLanguages.first?.lowercased().hasPrefix("vi") ?? false
        }
    }

    /// The question sent for "capture and solve" (hold on the glasses' capture button).
    @MainActor
    static var solvePhotoQuestion: String {
        speaksVietnamese ? "Giải bài trong ảnh này." : "Solve the problem in this photo."
    }

    /// Spoken after a capture-button photo, so the wearer knows it is ready for a question.
    @MainActor
    static var photoReadyMessage: String {
        speaksVietnamese ? "Đã chụp. Bạn hỏi đi." : "Got the photo. Go ahead."
    }

    /// Spoken when the glasses' photo could not be taken or transferred.
    @MainActor
    static var photoFailedMessage: String {
        speaksVietnamese
            ? "Chưa lấy được ảnh từ kính. Bạn bấm nút chụp lại giúp mình nhé."
            : "I couldn't get the photo from the glasses. Please press the capture button again."
    }

    /// Spoken for "repeat the answer" when nothing has been answered yet.
    @MainActor
    static var nothingToRepeatMessage: String {
        speaksVietnamese ? "Chưa có câu trả lời nào để đọc lại." : "There's no answer to repeat yet."
    }

    /// What the glasses say when a visual question arrives and no photo can be found
    /// (checklist test 5) — in the language the question was asked in.
    @MainActor
    static func missingPhotoMessage(for prompt: String) -> String {
        TTSService.containsVietnamese(prompt)
            ? "Không tìm thấy ảnh chụp bài tập từ kính Ray-Ban. Bạn hãy bấm nút chụp trên gọng kính rồi hỏi lại nhé."
            : "No photo found from Ray-Ban glasses. Please press the temple capture button and ask again."
    }
}

// MARK: - Recent Photo Scanner (Visor Parity)

/// Fallback for when the capture button is not linked to the app: finds a glasses photo that
/// the Meta AI app imported into Camera Roll. That import is NOT real-time (it typically happens
/// when the glasses are folded or charging), which is why the direct DAT capture is tried first;
/// when a photo does land, it is prefetched so its bytes are ready when the question comes.
///
/// Everything heavy (PhotoKit fetch, image decode/encode) runs OFF the main thread — the previous
/// synchronous 2048 px decode on the main actor stalled the UI on every library change.
@MainActor
final class RecentPhotoScanner: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = RecentPhotoScanner()

    @Published private(set) var lastScannedPhotoData: Data?
    @Published private(set) var lastScannedTimestamp: Date?
    /// True when the user granted "Selected Photos" only: new glasses photos are then invisible
    /// to the app and the shutter workflow cannot work. Surfaced to the UI as a warning.
    @Published private(set) var isLimitedAccess = false
    /// When the newest glasses photo was TAKEN (asset creation date) and a small preview, for the
    /// "photo ready" indicator. Also shows on a real device how long Camera Roll import takes.
    @Published private(set) var latestPhotoDate: Date?
    @Published private(set) var latestThumbnail: UIImage?

    /// Full-resolution bytes of the newest asset we loaded, keyed by its local identifier.
    private var cache: (assetID: String, created: Date, data: Data)?
    private var prefetchTask: Task<Void, Never>?
    /// A load already running (usually the prefetch), so a question asked meanwhile joins it
    /// instead of decoding the same photo twice.
    private var inFlight: (assetID: String, task: Task<Data?, Never>)?

    private override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        isLimitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        isLimitedAccess = status == .limited
        if status == .limited {
            NSLog("[RecentPhotoScanner] Limited photo access — new glasses photos will NOT be visible. Ask for Full Access.")
        }
        return status == .authorized || status == .limited
    }

    /// The newest photo created within `seconds`, prepared for upload (see
    /// `PhotoPayload.uploadJPEG`), or nil when there is none / no permission.
    func fetchMostRecentPhoto(withinSeconds seconds: TimeInterval = SolverIntent.recentPhotoWindow) async -> Data? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            NSLog("[RecentPhotoScanner] Photo library not authorized (%d)", status.rawValue)
            return nil
        }

        let cutoffDate = Date().addingTimeInterval(-seconds)
        guard let newest = await Self.newestImageAsset(since: cutoffDate) else {
            NSLog("[RecentPhotoScanner] No photos found created after %@", cutoffDate.description)
            return nil
        }

        if let cached = cache, cached.assetID == newest.id {
            NSLog("[RecentPhotoScanner] Using prefetched photo (%d bytes)", cached.data.count)
            return cached.data
        }

        let load: Task<Data?, Never>
        if let running = inFlight, running.assetID == newest.id {
            load = running.task
        } else {
            NSLog("[RecentPhotoScanner] Found asset created at: %@", newest.created.description)
            let assetID = newest.id
            load = Task.detached(priority: .userInitiated) { await Self.loadFullResolution(assetID: assetID) }
            inFlight = (assetID: assetID, task: load)
        }
        let loaded = await load.value
        if inFlight?.assetID == newest.id { inFlight = nil }
        guard let data = loaded else {
            NSLog("[RecentPhotoScanner] Could not load image data for newest asset")
            return nil
        }
        NSLog("[RecentPhotoScanner] Loaded photo (%ld bytes), taken %.1fs ago", data.count, Date().timeIntervalSince(newest.created))
        cache = (assetID: newest.id, created: newest.created, data: data)
        lastScannedPhotoData = data
        lastScannedTimestamp = Date()
        latestPhotoDate = newest.created
        let thumbnail = await Task.detached(priority: .utility) {
            PhotoPayload.renderJPEG(from: data, maxPixelSize: 180, quality: 0.7)
        }.value
        if cache?.assetID == newest.id {
            latestThumbnail = thumbnail.flatMap { UIImage(data: $0) }
        }
        return data
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // Coalesce bursts of change notifications (iCloud, Meta View writing metadata).
            self.prefetchTask?.cancel()
            self.prefetchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                _ = await self.fetchMostRecentPhoto(withinSeconds: 60.0)
            }
        }
    }

    // MARK: - Background PhotoKit work

    /// Newest image asset created at/after `cutoff` — (localIdentifier, creationDate).
    private nonisolated static func newestImageAsset(since cutoff: Date) async -> (id: String, created: Date)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(id: String, created: Date)?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fetchOptions = PHFetchOptions()
                fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@",
                                                     PHAssetMediaType.image.rawValue, cutoff as NSDate)
                fetchOptions.fetchLimit = 1
                let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
                if let asset = assets.firstObject {
                    continuation.resume(returning: (id: asset.localIdentifier, created: asset.creationDate ?? Date()))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The asset's original image (12 MP on Ray-Ban Meta Gen 2), prepared for upload once, in the
    /// background: upright, long edge <= 3072 px (see `PhotoPayload`).
    private nonisolated static func loadFullResolution(assetID: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                guard let asset = assets.firstObject else {
                    continuation.resume(returning: nil)
                    return
                }
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.version = .current
                // Synchronous request: the handler runs before this returns. A box (not a captured
                // var) carries the result out, which is safe in any concurrency-checking mode.
                let box = DataBox()
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    box.value = data
                }
                continuation.resume(returning: box.value.flatMap { PhotoPayload.uploadJPEG(from: $0) })
            }
        }
    }
}

/// Result carrier for synchronous PhotoKit callbacks on a background queue.
private final class DataBox: @unchecked Sendable {
    var value: Data?
}

// MARK: - Photo payload (pure, unit-testable)

/// Image bytes sent to the AI.
///
/// Gemini 3 gives each image a FIXED token budget (HIGH ~1120, ULTRA_HIGH ~2240 tokens) whatever
/// its pixel count, so a 12 MP upload carries no more detail than ~3000 px — it only costs
/// 4-5x the bytes (seconds on mobile uplink). Detail is requested with media resolution instead
/// (GeminiLiveService), and the photo is sent upright, long edge <= `uploadMaxDimension`.
enum PhotoPayload {
    /// Long edge of the uploaded photo.
    static let uploadMaxDimension = 3072
    static let uploadQuality: CGFloat = 0.85

    /// Long edge of the copy kept in conversation history: follow-up questions re-send the
    /// whole history, so they carry this lighter copy.
    static let historyMaxDimension: CGFloat = 1536

    static func isJPEG(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        return bytes.count == 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    }

    /// MIME type from the magic bytes (Gemini accepts JPEG, PNG, WEBP, HEIC, HEIF).
    static func mimeType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "image/jpeg" }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "image/png" }
        if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 { return "image/webp" }
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {   // "ftyp"
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            return brand.hasPrefix("hei") || brand.hasPrefix("hev") ? "image/heic" : "image/heif"
        }
        return "image/jpeg"
    }

    /// Pixel size and EXIF orientation (1 = upright) read from the header, without decoding.
    static func imageInfo(_ data: Data) -> (width: Int, height: Int, orientation: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (width, height, orientation)
    }

    /// Upload JPEG: an upright JPEG already within `uploadMaxDimension` passes through
    /// byte-for-byte; anything else (12 MP originals, HEIC, EXIF-rotated) is decoded once with
    /// the rotation applied — the model may ignore EXIF orientation — and re-encoded.
    static func uploadJPEG(from original: Data) -> Data? {
        guard let info = imageInfo(original) else { return nil }
        if isJPEG(original), info.orientation == 1, max(info.width, info.height) <= uploadMaxDimension {
            return original
        }
        let target = min(max(info.width, info.height), uploadMaxDimension)
        return renderJPEG(from: original, maxPixelSize: target, quality: uploadQuality)
    }

    /// Lighter copy for conversation history (longest edge `historyMaxDimension`, JPEG 0.8).
    /// Returns the input unchanged if it is already that small or cannot be decoded.
    static func historyCopy(of data: Data) -> Data {
        guard let info = imageInfo(data), max(info.width, info.height) > Int(historyMaxDimension) else { return data }
        return renderJPEG(from: data, maxPixelSize: Int(historyMaxDimension), quality: 0.8) ?? data
    }

    /// Decode (EXIF rotation applied, longest edge `maxPixelSize`) and encode as JPEG with ImageIO —
    /// thread-safe and memory-light, so it runs on background queues.
    static func renderJPEG(from data: Data, maxPixelSize: Int, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Cheap identity for "is this the same photo the model already has?" checks.
    static func fingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(256))
        hasher.combine(data.suffix(256))
        return hasher.finalize()
    }
}

@MainActor
final class VoiceAgentViewModel: ObservableObject {

    // MARK: - Dependencies

    let settingsManager = SettingsManager.shared
    let glassesManager = GlassesManager.shared
    let voiceCommandService = VoiceCommandService.shared
    let gemini = GeminiLiveService.shared
    let ttsService = TTSService.shared
    let soundService = SoundService.shared
    let sessionRecorder = SessionRecorder.shared

    // MARK: - Published UI state

    @Published var isSessionActive = false
    @Published var agentState: AgentState = .idle
    @Published var userTranscript = ""
    @Published var aiTranscript = ""
    @Published var errorMessage: String?
    /// True when voice recognition is ready (audio engine running)
    @Published var isVoiceReady = false
    /// True while a POV demo recording (glasses video + mic audio) is in progress.
    @Published var isRecording = false
    /// Transient status shown after a recording finishes ("Saved to Photos" / a failure). Auto-clears.
    @Published var recordingStatus: String?
    /// The photo the next question uses (120 s / 5 questions; "Capture First, Ask Later").
    @Published var activePhotoContext: CapturedPhotoContext?
    /// The DISPLAY channel of the latest answer (Markdown + LaTeX), rendered by SolutionSheet.
    /// The transcript bubble shows the SPOKEN text; this is the step-by-step derivation.
    @Published var latestSolution: String?

    // MARK: - Internal state

    // De-dup: the last command we processed and when (drops duplicate recognizer emissions).
    private var lastProcessedCommand = ""
    private var lastProcessedAt = Date.distantPast
    private var hasRequestedSpeechAuth = false

    /// Sentence-streaming TTS: how many characters of the streamed reply have already been handed
    /// to the speech queue, and whether a streamed utterance is open.
    private var ttsStreamSpokenChars = 0
    private var ttsStreaming = false

    /// History: true after a user command was recorded, until its reply is recorded. Keeps
    /// system utterances (error prompts) out of the History tab.
    private var historyAwaitingReply = false

    /// The SPOKEN channel of the last answer, for "read it again" (double press on the glasses).
    private var lastSpokenAnswer = ""

    /// True while a capture-button photo is being taken (extra presses are ignored meanwhile).
    @Published private(set) var isCapturingFromButton = false

    // MARK: - Agent State

    enum AgentState: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking

        var displayText: String {
            switch self {
            case .idle: return "Chạm để bắt đầu"
            case .connecting: return "Đang kết nối…"
            case .listening: return "Đang nghe…"
            case .thinking: return "Đang suy nghĩ…"
            case .speaking: return "Đang trả lời…"
            }
        }
    }

    // MARK: - View lifecycle

    func onAppear() {
        setupVoiceCommandService()
        setupGlassesCallbacks()
        applyButtonLinkSetting()
        // The temple-shutter workflow reads glasses photos from Camera Roll: ask for Photos access
        // up front (it was never requested before, so the scanner silently found nothing), and
        // warn when only "Selected Photos" is granted — new glasses photos are invisible then.
        Task { @MainActor in
            let granted = await RecentPhotoScanner.shared.requestAuthorizationIfNeeded()
            if !granted {
                errorMessage = "OpenVision cần quyền Ảnh (Toàn bộ ảnh) để đọc ảnh chụp từ kính Ray-Ban. Vào Cài đặt → OpenVision → Ảnh."
            } else if RecentPhotoScanner.shared.isLimitedAccess {
                errorMessage = "Quyền Ảnh đang ở chế độ Giới hạn nên app không thấy ảnh mới từ kính. Vào Cài đặt → OpenVision → Ảnh → chọn Toàn bộ ảnh."
            }
        }
        // Resume wake-word listening when returning to this screen. onDisappear stops it
        // (e.g. when navigating to Settings), and the one-time .task doesn't re-run on return —
        // so without this, the wake word stayed dead until you tapped the mic button.
        if voiceCommandService.authorizationStatus == .authorized && !voiceCommandService.isListening {
            startWakeWordListening()
        }
    }

    func onDisappear() {
        voiceCommandService.stopListening()
    }

    // MARK: - Observed state changes (forwarded from the view's onChange hooks)

    func ttsSpeakingChanged(_ isSpeaking: Bool) {
        if isSpeaking {
            agentState = .speaking
            // Pause barge-in detection while TTS is playing
            // (prevents microphone picking up TTS and triggering interruption)
            voiceCommandService.isBargeInPaused = true
        } else {
            // Playback finished — closes the turn and publishes it to the metrics sinks.
            MetricsCollector.shared.markSpokeDone()

            // Resume barge-in detection
            voiceCommandService.isBargeInPaused = false

            if isSessionActive {
                agentState = .listening
                resumeListeningAfterSpeaking()
            } else {
                agentState = .idle
            }
        }
    }

    /// Control thinking sound based on agent state.
    func agentStateChanged(_ newState: AgentState) {
        if newState == .thinking {
            soundService.startThinkingSound()
        } else {
            soundService.stopThinkingSound()
        }
    }

    func voiceStateChanged(_ newState: VoiceCommandService.ListeningState) {
        print("[VoiceAgent] VoiceCommandService state changed to: \(newState)")
        switch newState {
        case .idle:
            // A real conversation end is the recognizer going idle *while we were listening*
            // for the user (silence timeout). An .idle in any other state (.connecting startup,
            // .thinking command processing, .speaking a reply) is a transient from our own
            // stop/restart — e.g. the camera capture restarts the recognizer mid-command — and
            // must NOT tear the session down.
            if isSessionActive && agentState == .listening {
                print("[VoiceAgent] Voice service idle, stopping session")
                isSessionActive = false
                agentState = .idle
                Task { await gemini.disconnect() }
            }
        case .listening, .conversationMode:
            if ttsService.isSpeaking {
                // The recognizer restarts (→ conversation mode) mid-reply for barge-in; don't
                // let that flip the UI to "Listening" while the assistant is still speaking.
                agentState = .speaking
            } else if isSessionActive {
                agentState = .listening
            }
        case .processing:
            agentState = .thinking
        }
    }

    // MARK: - Session lifecycle

    func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    func startSession() {
        isSessionActive = true
        agentState = .connecting

        // Configure audio routing for glasses if registered
        configureAudioForGlasses()

        Task {
            do {
                // No camera stream here: the glasses camera only runs for the moment a photo is
                // taken ("Click & Go"). A stream per session drained the glasses' battery and
                // heated them for nothing — the REST solver never reads video frames.
                try await gemini.connect()

                agentState = .listening
                userTranscript = ""
                aiTranscript = ""

                // Start voice command listening for speech capture
                if voiceCommandService.authorizationStatus == .authorized {
                    if !voiceCommandService.isListening {
                        try? voiceCommandService.startListening()
                    }
                    // Put in listening mode (not waiting for wake word)
                    voiceCommandService.enterConversationMode()
                } else {
                    errorMessage = "Chưa được cấp quyền nhận dạng giọng nói."
                }
            } catch {
                // No key yet: still listen, so the glasses can SAY what is missing.
                if case AIBackendError.notConfigured = error {
                    agentState = .listening
                    if voiceCommandService.authorizationStatus == .authorized {
                        if !voiceCommandService.isListening { try? voiceCommandService.startListening() }
                        voiceCommandService.enterConversationMode()
                    }
                    errorMessage = "Chưa có API key Gemini — vào Cài đặt → Gemini để dán key."
                    return
                }
                errorMessage = "Không kết nối được: \(error.localizedDescription)"
                isSessionActive = false
                agentState = .idle
            }
        }
    }

    /// Resume listening after a spoken response ends — camera and text commands end identically:
    /// the persistent audio engine keeps running through a capture (never torn down — a rebuild
    /// would force a fresh Bluetooth HFP negotiation the glasses can't service right after
    /// streaming, leaving the mic deaf). Conversation mode's silence timeout then returns to idle.
    private func resumeListeningAfterSpeaking() {
        voiceCommandService.enterConversationMode()
    }

    /// Apply the preferred audio route: the glasses' Bluetooth mic + speaker when the user wants it
    /// and they're the connected audio device, otherwise the phone's built-in mic + loud speaker.
    /// Attempting glasses is what makes iOS expose the HFP mic — so we try it directly rather than
    /// pre-checking availability (which can't see HFP until it's allowed). Returns true on glasses.
    @discardableResult
    private func applyPreferredAudioRoute() -> Bool {
        // "Click & Go" architecture shuts down camera stream after photo capture anyway, so glasses mic can be used.
        if settingsManager.settings.preferGlassesMic,
           (try? AudioSessionManager.shared.configureForGlasses()) == true {
            return true
        }
        // Glasses mic off, glasses not connected as audio, or no HFP input available → phone.
        // Loud speaker so spoken replies are audible (not the quiet earpiece).
        print("[VoiceAgent] Using iPhone mic + speaker (glasses mic off or unavailable)")
        try? AudioSessionManager.shared.configureForPhone()
        return false
    }

    private func configureAudioForGlasses(forceRestart: Bool = false) {
        // If voiceCommandService is already listening and the current route is acceptable,
        // do NOT stop and restart AVAudioEngine. That prevents Mach IPC deadlock and audio churn.
        let wantsGlasses = settingsManager.settings.preferGlassesMic
        let isHFPActive = AudioSessionManager.shared.isBluetoothHFPInputActive
        let routeAcceptable = (wantsGlasses && isHFPActive) || (!wantsGlasses && !isHFPActive)

        if !forceRestart && voiceCommandService.isListening && routeAcceptable {
            return
        }
        let wasListening = voiceCommandService.isListening
        if wasListening { voiceCommandService.stopListening() }
        applyPreferredAudioRoute()
        if wasListening {
            try? voiceCommandService.startListening()
        }
    }

    func stopSession() {
        Task {
            await gemini.disconnect()
            // Stop glasses streaming (turns off LED) — e.g. one left running by a capture.
            if glassesManager.isStreaming && !isRecording {
                print("[VoiceAgent] Stopping glasses stream...")
                await glassesManager.stopStreaming()
            }
        }

        // Stop any ongoing TTS
        ttsService.stop()
        ttsStreaming = false

        // Set session inactive FIRST to prevent callbacks from processing
        isSessionActive = false
        agentState = .idle

        // Handle voice command service based on wake word setting
        if settingsManager.settings.wakeWordEnabled {
            // Exit conversation mode but keep listening for wake word
            voiceCommandService.exitConversationMode()
        } else {
            // Wake word disabled - stop listening entirely to prevent
            // processing speech after session ends
            voiceCommandService.stopListening()
        }
        userTranscript = ""
        aiTranscript = ""
    }

    /// Full stop for "Ok Vision stop": silence all output, cancel any in-flight generation, and go
    /// quiet back to wake-word listening. The recognizer buffer is already reset by
    /// VoiceCommandService (so the stale transcript can't re-fire); here we just halt + end the turn.
    private func performFullStop() {
        // "Ok Vision stop" is an interruption too: the user cut the reply off. Close the turn
        // deterministically before stopping the engines.
        MetricsCollector.shared.markInterrupted()
        MetricsCollector.shared.markSpokeDone()
        ttsService.stop()
        ttsStreaming = false
        Task { await gemini.interrupt() }

        // Go quiet: end the turn, return to wake-word idle. Say "Ok Vision" to start again.
        userTranscript = ""
        aiTranscript = ""
        isSessionActive = false
        agentState = .idle
    }

    // MARK: - Voice Command Setup

    /// Request speech recognition authorization
    func requestSpeechAuthorization() async {
        guard !hasRequestedSpeechAuth else { return }
        hasRequestedSpeechAuth = true

        let authorized = await voiceCommandService.requestAuthorization()
        if authorized {
            print("[VoiceAgent] Speech recognition authorized")
            startWakeWordListening()
        } else {
            print("[VoiceAgent] Speech recognition not authorized")
            errorMessage = "Chưa được cấp quyền nhận dạng giọng nói. Hãy bật trong Cài đặt."
        }
    }

    /// Setup voice command service callbacks
    private func setupVoiceCommandService() {
        print("[VoiceAgent] Setting up voice command callbacks")

        // Interruptible whenever the assistant holds the floor. This gate exists to stop the
        // reply's own audio (heard through the mic) from false-triggering the wake word — so it
        // must be true exactly when the assistant is producing output, or still thinking (no reply
        // audio exists yet, so a wake word then is genuinely the user — the only way to cancel a
        // long generation by voice).
        voiceCommandService.shouldAllowInterrupt = { [weak self] in
            guard let self else { return false }
            return self.ttsService.isSpeaking || self.agentState == .thinking
        }

        // Wake word detected
        voiceCommandService.onWakeWordDetected = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Wake word detected!")
            HapticFeedback.medium()
            self.soundService.playWakeWordSound()

            // If TTS is speaking, stop it immediately (interrupt)
            if self.ttsService.isSpeaking {
                print("[VoiceAgent] Stopping TTS due to wake word interrupt")
                MetricsCollector.shared.markInterrupted()
                // Close the turn NOW, deterministically, rather than racing the engine's async
                // speaking-changed callback against the next turn's speechEnd.
                MetricsCollector.shared.markSpokeDone()
                self.ttsService.stop()
                self.ttsStreaming = false   // keep flag in sync with the cleared stream
                self.agentState = .listening
            }

            // Auto-start session if not already active (use Task to avoid blocking)
            Task { @MainActor in
                if !self.isSessionActive {
                    print("[VoiceAgent] Starting session from wake word...")
                    self.startSession()
                }
            }
        }

        // "Ok Vision stop" during a reply → full stop, go quiet (the recognizer is already reset
        // to wake-word idle by VoiceCommandService; here we just halt output + end the turn).
        voiceCommandService.onStopCommand = { [weak self] in
            print("[VoiceAgent] Full stop requested")
            self?.performFullStop()
        }

        // Command captured
        voiceCommandService.onCommandCaptured = { [weak self] (command: String) in
            guard let self else { return }
            print("[VoiceAgent] Command captured: \(command)")

            // IMPORTANT: Only process commands when session is active
            // This prevents processing stale commands after session ends
            guard self.isSessionActive else {
                print("[VoiceAgent] Ignoring command - session not active")
                return
            }

            self.userTranscript = command
            self.latestSolution = nil

            // Telemetry: the turn is now the backend's problem — everything after this is
            // think time, and everything before it was endpointing.
            MetricsCollector.shared.markCommit(backend: "gemini", model: GeminiLiveService.modelName, ttsEngine: "apple")

            // History: every captured command is a user message.
            ConversationManager.shared.addUserMessage(command)
            self.historyAwaitingReply = true

            Task {
                await self.sendCommand(command)
            }
        }

        // Barge-in (user interrupts AI)
        voiceCommandService.onInterruption = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Barge-in detected")
            // Interruption rate is a satisfaction signal: users talk over an agent that is slow,
            // wrong, or too verbose. Recorded on the turn being interrupted.
            MetricsCollector.shared.markInterrupted()
            self.ttsService.stop()
            Task { await self.gemini.interrupt() }
        }

        // Conversation timeout (user didn't speak after AI response)
        voiceCommandService.onConversationTimeout = { [weak self] in
            guard let self else { return }
            print("[VoiceAgent] Conversation timeout - returning to idle")
            self.stopSession()
        }

        // Auto-reconfigure audio route when Bluetooth / Ray-Ban Meta connects or disconnects
        AudioSessionManager.shared.onRouteChange = { [weak self] in
            Task { @MainActor in
                print("[VoiceAgent] Audio route changed - reapplying preferred audio route without restart")
                self?.configureAudioForGlasses(forceRestart: false)
            }
        }

        // Setup AI service callbacks for responses
        setupAIServiceCallbacks()

        print("[VoiceAgent] Voice command callbacks setup complete")
    }

    /// Setup AI service callbacks for receiving responses
    private func setupAIServiceCallbacks() {
        // Wire TTS completion with 350ms echo settling delay (prevents temple speaker echo from triggering false barge-in)
        ttsService.onSpeechEnded = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: SolverIntent.ttsEchoSettleNanoseconds)
                if !self.ttsService.isSpeaking && self.ttsService.pendingUtterances == 0 {
                    self.voiceCommandService.isBargeInPaused = false
                    if self.agentState == .speaking {
                        self.agentState = self.isSessionActive ? .listening : .idle
                    }
                }
            }
        }

        // The finished reply (dual channel): SPOKEN to the glasses, DISPLAY to the phone.
        gemini.agentMessageCallback = { [weak self] (message: String) in
            guard let self else { return }
            guard self.isSessionActive else { return }

            let (spoken, display) = self.parseDualChannelResponse(message)
            self.aiTranscript = spoken.isEmpty ? display : spoken
            if !spoken.isEmpty { self.lastSpokenAnswer = spoken }
            self.latestSolution = Self.solutionWorthShowing(spoken: spoken, display: display)

            // Reply text is final. markFirstToken is first-wins, so streaming kept it accurate.
            MetricsCollector.shared.markFirstToken()
            MetricsCollector.shared.markGenerationDone()
            if self.ttsStreaming {
                // A streamed utterance is open: flush the unspoken tail and close it.
                self.feedStreamingSpeech(spoken, isFinal: true, historyText: display)
            } else {
                self.speakResponse(spoken, historyText: display)
            }
        }

        gemini.processingChangedCallback = { [weak self] (isProcessing: Bool) in
            guard let self else { return }
            if isProcessing {
                self.agentState = .thinking
                // New reply: reset the sentence-streaming cursor for a clean start.
                self.ttsStreaming = false
                self.ttsStreamSpokenChars = 0
            } else {
                // Generation ended (always fires via defer, even when interrupted/superseded).
                // If a streamed utterance is still open, the reply callback never fired to close
                // it — close it here so isSpeaking can't stick true and freeze the wake word.
                if self.ttsStreaming {
                    self.ttsService.endStreaming()
                    self.ttsStreaming = false
                }
                if self.agentState == .thinking
                    && !self.ttsService.isSpeaking && self.ttsService.pendingUtterances == 0 {
                    self.agentState = self.isSessionActive ? .listening : .idle
                }
            }
        }

        // Agent loop: Gemini asked to SEE and no photo was in the conversation — take one.
        gemini.onCaptureRequested = { [weak self] (_: String) async -> Data? in
            guard let self else { return nil }
            return await self.captureForAgent()
        }

        // Gemini streams its reply: start speaking the SPOKEN channel at the first finished sentence
        // instead of waiting for the long step-by-step DISPLAY channel to be generated.
        gemini.onPartialSpoken = { [weak self] (spoken: String) in
            guard let self else { return }
            guard self.isSessionActive else { return }
            if !self.ttsStreaming {
                // Blueprint lesson 4: be "speaking" with barge-in paused BEFORE the first sentence is
                // queued, so the temple speaker's echo can never be taken for a new command.
                self.agentState = .speaking
                self.voiceCommandService.isBargeInPaused = true
            }
            self.aiTranscript = spoken
            MetricsCollector.shared.markFirstToken()
            self.feedStreamingSpeech(spoken, isFinal: false)
        }
    }

    /// The DISPLAY text when it adds something to what was spoken (a derivation, formulas, a
    /// table) — nil for a plain one-liner, so the phone doesn't offer an empty "solution".
    static func solutionWorthShowing(spoken: String, display: String) -> String? {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != spoken.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed
    }

    /// Parse Gemini Solver Dual-Channel Response (SPOKEN: and DISPLAY:)
    private func parseDualChannelResponse(_ text: String) -> (spoken: String, display: String) {
        GeminiLiveService.parseDualChannel(text)
    }

    /// Start listening for wake word
    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }

        // Configure audio for glasses before starting to listen without unnecessary engine churn
        configureAudioForGlasses(forceRestart: false)

        do {
            try voiceCommandService.startListening()
            isVoiceReady = true
            print("[VoiceAgent] Started wake word listening - READY")
        } catch {
            print("[VoiceAgent] Failed to start listening: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Command routing

    /// Send the wearer's words — verbatim, any language — to Gemini, with the current glasses
    /// photo when there is one. Gemini decides whether the photo matters, and asks for one
    /// ([[CAPTURE]]) when it must see something and has none.
    private func sendCommand(_ command: String, allowRepeat: Bool = false) async {
        // "Stop" — stops speech and waits for the next command (word-matched, see SolverIntent).
        if SolverIntent.isStopCommand(command) {
            print("[VoiceAgent] Stop command detected - full stop")
            performFullStop()
            return
        }

        // Drop only EXACT-duplicate commands fired within a few seconds. The speech recognizer
        // can emit the same phrase twice (partial + final). A *different* follow-up question must
        // still go through, even while the previous answer is generating/speaking.
        let now = Date()
        if !allowRepeat, command == lastProcessedCommand, now.timeIntervalSince(lastProcessedAt) < 4 {
            print("[VoiceAgent] Ignoring duplicate command within 4s: \(command)")
            return
        }
        lastProcessedCommand = command
        lastProcessedAt = now

        agentState = .thinking

        // Visor parity: the photo taken with the glasses just before asking.
        if activePhotoContext?.isFresh != true {
            if let recentPhoto = await RecentPhotoScanner.shared.fetchMostRecentPhoto(withinSeconds: SolverIntent.recentPhotoWindow) {
                print("[VoiceAgent] ✓ Fetched recent glasses photo from library (\(recentPhoto.count) bytes)")
                activePhotoContext = CapturedPhotoContext(data: recentPhoto)
            }
        }

        var photo: Data?
        if let context = activePhotoContext, context.isFresh {
            activePhotoContext?.useCount += 1
            photo = context.data
            print("[VoiceAgent] ✓ Fusing photo context (\(context.data.count) bytes, use #\(context.useCount + 1)) with: \(command)")
        }

        do {
            try await gemini.sendRESTMessage(command, imageData: photo)
        } catch {
            handleSendFailure(error, command: command)
        }
    }

    /// A turn failed after the service's own retries. Hands-free: the wearer is not looking at
    /// the phone, so SAY it (in their language) instead of only setting a banner. A cancellation
    /// (the wearer said "stop" or asked something new) stays silent.
    private func handleSendFailure(_ error: Error, command: String) {
        if error is CancellationError { return }
        print("[VoiceAgent] Send failed: \(error)")
        errorMessage = "Gửi câu hỏi thất bại: \(error.localizedDescription)"
        if isSessionActive, !ttsService.isSpeaking {
            if case AIBackendError.notConfigured = error {
                speakResponse(SolverIntent.missingKeyMessage(for: command))
                return
            }
            speakResponse(SolverIntent.networkFailureMessage(for: command))
        } else {
            agentState = isSessionActive ? .listening : .idle
        }
    }

    // MARK: - POV Recording

    /// Toggle a demo recording of the glasses point-of-view (video) plus the phone mic (audio,
    /// which captures the scene sound and the assistant's spoken reply played out the speaker).
    /// The result is saved to Photos for sharing.
    func toggleRecording() {
        if isRecording {
            sessionRecorder.stop()   // finishes async; `onFinished` resets state + reports the save
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard glassesManager.isRegistered else {
            errorMessage = "Hãy kết nối kính trước khi ghi hình."
            return
        }
        // Recording needs a live frame stream.
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        guard glassesManager.isStreaming else {
            errorMessage = "Không bật được camera kính để ghi hình."
            return
        }

        glassesManager.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.sessionRecorder.appendVideoSampleBuffer(sampleBuffer)
        }

        sessionRecorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.isRecording = false
            self.glassesManager.onVideoSampleBuffer = nil
            self.showRecordingStatus(url != nil ? "Đã lưu vào Ảnh" : "Không lưu được bản ghi")
            if self.glassesManager.isStreaming {
                Task { await self.glassesManager.stopStreaming() }
            }
        }

        if !voiceCommandService.isListening {
            try? voiceCommandService.startListening()
        }
        do {
            try sessionRecorder.start()
            isRecording = true
        } catch {
            glassesManager.onVideoSampleBuffer = nil
            errorMessage = "Không bắt đầu ghi được: \(error.localizedDescription)"
        }
    }

    /// Show a brief status message after a recording finishes, then clear it.
    private func showRecordingStatus(_ text: String) {
        recordingStatus = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.recordingStatus == text { self?.recordingStatus = nil }
        }
    }

    // MARK: - Photo capture

    /// Capture photo from glasses and return the data
    private func capturePhotoFromGlasses() async -> Data? {
        guard glassesManager.isRegistered else {
            NSLog("[OV] capturePhotoFromGlasses: glasses not registered")
            return nil
        }
        // Clear any stale photo before requesting a fresh capture.
        glassesManager.lastPhotoData = nil
        NSLog("[OV] capturePhotoFromGlasses: requesting capture (streaming=%@)", glassesManager.isStreaming ? "yes" : "no")
        await glassesManager.capturePhoto()

        // Wait for photo data to appear (poll for up to 1.5 seconds / 15 iterations of 100ms)
        for _ in 0..<15 {
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                NSLog("[OV] Photo captured: %ld bytes", photoData.count)
                return photoData
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        NSLog("[OV] Photo capture timed out after 1.5s — falling back")
        return nil
    }

    /// Force a fresh live video frame, restarting the stream if it has stalled.
    /// More reliable than the one-shot photo capture for repeated requests in a session.
    private func freshLiveFrame() async -> Data? {
        guard glassesManager.isRegistered else { return nil }
        if !glassesManager.isStreaming {
            await glassesManager.startStreaming()
        }
        // Wait for a NEW frame (clear first so we don't reuse a stale one).
        glassesManager.lastFrame = nil
        for _ in 0..<25 { // up to ~2.5s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired")
                return f.jpegData(compressionQuality: 0.95)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Stream appears stalled — restart it once and retry.
        NSLog("[OV] live frame stalled — restarting stream")
        await glassesManager.stopStreaming()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await glassesManager.startStreaming()
        glassesManager.lastFrame = nil
        for _ in 0..<30 { // up to ~3s
            if let f = glassesManager.lastFrame {
                NSLog("[OV] fresh live frame acquired after restart")
                return f.jpegData(compressionQuality: 0.95)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[OV] freshLiveFrame: STILL no frame after restart")
        return nil
    }

    /// One photo from the glasses camera, "Click & Go": the camera stream runs only for the
    /// capture and is stopped right after (unless a recording is using it).
    private func takeGlassesPhoto() async -> Data? {
        guard glassesManager.isRegistered else { return nil }
        let startedStreaming = !glassesManager.isStreaming
        if startedStreaming { await glassesManager.startStreaming() }
        var data = await capturePhotoFromGlasses()
        if data == nil { data = await freshLiveFrame() }
        if startedStreaming && glassesManager.isStreaming && !isRecording {
            await glassesManager.stopStreaming()
        }
        return data
    }

    /// The best photo the glasses can give right now, straight to the app — never waiting for the
    /// Meta AI app's Camera Roll import: (1) a standalone still at full sensor resolution
    /// (DAT 1.0 Camera.photo), (2) a 720p still from the video stream, (3) a glasses photo that
    /// already reached Camera Roll.
    private func acquireGlassesPhoto() async -> Data? {
        // Another capture (button press, the agent, Settings' test) is already crossing: wait for
        // it and share its photo instead of starting the stream under it.
        if glassesManager.isTakingPhoto {
            let requestedAt = Date()
            while glassesManager.isTakingPhoto, Date().timeIntervalSince(requestedAt) < 45 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if let context = activePhotoContext, context.timestamp >= requestedAt.addingTimeInterval(-45) {
                return context.data
            }
        }
        if glassesManager.isRegistered, !isRecording,
           let full = await glassesManager.captureFullResolutionPhoto(
               fullResolution: settingsManager.settings.fullResolutionPhotos) {
            return full
        }
        if let streamStill = await takeGlassesPhoto() { return streamStill }
        return await RecentPhotoScanner.shared.fetchMostRecentPhoto(withinSeconds: SolverIntent.recentPhotoWindow)
    }

    /// The model needs to see and no photo is in the conversation: take one. The new photo also
    /// becomes the context for follow-up questions.
    private func captureForAgent() async -> Data? {
        HapticFeedback.light()
        let data = await acquireGlassesPhoto()
        if let data {
            activePhotoContext = CapturedPhotoContext(data: data)
            HapticFeedback.success()
            NSLog("[OV] Agent capture: got photo (%ld bytes)", data.count)
        } else {
            HapticFeedback.error()
            NSLog("[OV] Agent capture: no photo available")
        }
        return data
    }

    /// Manually trigger a photo capture from glasses to cache in activePhotoContext (Capture First, Ask Later)
    func snapPhotoFromGlasses() async {
        HapticFeedback.light()
        print("[VoiceAgent] Manual photo snap requested from glasses...")
        let data = await acquireGlassesPhoto()

        if let data {
            activePhotoContext = CapturedPhotoContext(data: data)
            HapticFeedback.success()
            print("[VoiceAgent] ✓ Manual photo context cached (\(data.count) bytes)")
        } else {
            HapticFeedback.error()
            let message = SolverIntent.missingPhotoMessage(for: lastProcessedCommand.isEmpty ? "chụp ảnh" : lastProcessedCommand)
            errorMessage = message
            speakResponse(message)
        }
    }

    // MARK: - Glasses callbacks

    private func setupGlassesCallbacks() {
        // A photo delivered by the glasses SDK becomes the context for the next questions.
        glassesManager.onPhotoCaptured = { [weak self] data in
            Task { @MainActor in
                self?.activePhotoContext = CapturedPhotoContext(data: data)
                print("[VoiceAgent] ✓ Active photo context cached (\(data.count) bytes)")
            }
        }
        // The glasses' own capture button, routed to the app (DAT 1.0 Inputs).
        glassesManager.onCaptureButton = { [weak self] press in
            self?.handleCaptureButton(press)
        }
    }

    /// Route (or release) the glasses' capture button according to Settings.
    func applyButtonLinkSetting() {
        let settings = settingsManager.settings
        Task { await glassesManager.applySettings(settings) }
    }

    // MARK: - Capture button

    private func handleCaptureButton(_ press: GlassesButtonPress) {
        let settings = settingsManager.settings
        let action: GlassesButtonAction
        switch press {
        case .shortPress: action = settings.shortPressAction
        case .hold: action = settings.holdAction
        case .doublePress: action = settings.doublePressAction
        }
        print("[VoiceAgent] Capture button \(press.rawValue) → \(action.rawValue)")
        switch action {
        case .capture:
            Task { await takeButtonPhoto(thenSolve: false) }
        case .captureAndSolve:
            Task { await takeButtonPhoto(thenSolve: true) }
        case .repeatAnswer:
            repeatLastAnswer()
        case .none:
            break
        }
    }

    /// Shutter pressed on the glasses: the photo goes straight to the app at full resolution and
    /// becomes the context for the next question — or, for "capture and solve", is solved at once.
    private func takeButtonPhoto(thenSolve: Bool) async {
        guard !isCapturingFromButton else { return }
        isCapturingFromButton = true
        defer { isCapturingFromButton = false }
        HapticFeedback.light()

        if thenSolve {
            // A new problem replaces whatever is being said or generated.
            if ttsService.isSpeaking {
                ttsService.stop()
                ttsStreaming = false
            }
            await gemini.interrupt()
        }

        guard let data = await acquireGlassesPhoto() else {
            HapticFeedback.error()
            errorMessage = SolverIntent.photoFailedMessage
            speakNotice(SolverIntent.photoFailedMessage)
            return
        }
        activePhotoContext = CapturedPhotoContext(data: data)
        HapticFeedback.success()
        print("[VoiceAgent] ✓ Capture-button photo ready (\(data.count) bytes)")

        if !isSessionActive {
            startSession()
            // Let the session finish its (instant) connect before the question is shown/sent,
            // so its start-up reset of the transcript can't wipe it.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if thenSolve {
            let question = SolverIntent.solvePhotoQuestion
            userTranscript = question
            latestSolution = nil
            ConversationManager.shared.addUserMessage(question)
            historyAwaitingReply = true
            await sendCommand(question, allowRepeat: true)
        } else if !ttsService.isSpeaking && agentState != .thinking {
            speakNotice(SolverIntent.photoReadyMessage)
        }
    }

    /// Double press: read the last answer again.
    private func repeatLastAnswer() {
        if ttsService.isSpeaking {
            ttsService.stop()
            ttsStreaming = false
        }
        speakNotice(lastSpokenAnswer.isEmpty ? SolverIntent.nothingToRepeatMessage : lastSpokenAnswer)
    }

    /// Say something that is not an answer (kept out of History).
    private func speakNotice(_ text: String) {
        let awaiting = historyAwaitingReply
        historyAwaitingReply = false
        speakResponse(text)
        historyAwaitingReply = awaiting
    }

    // MARK: - Speech output (Apple voices; the language is picked per sentence by TTSService)

    /// Feed the streamed reply to the speech queue sentence-by-sentence. `cumulative` is the full
    /// SPOKEN text so far. On non-final calls we speak only the sentences that have fully completed;
    /// on the final call we flush whatever remains.
    private func feedStreamingSpeech(_ cumulative: String, isFinal: Bool, historyText: String? = nil) {
        // Open a streamed utterance session on first content.
        if !ttsStreaming {
            guard !cumulative.isEmpty else { return }
            ttsStreaming = true
            ttsStreamSpokenChars = 0
            ttsService.beginStreaming()
        }

        // The portion not yet handed to the speech queue.
        let spokenClamped = min(ttsStreamSpokenChars, cumulative.count)
        let start = cumulative.index(cumulative.startIndex, offsetBy: spokenClamped)
        let pending = cumulative[start...]

        if isFinal {
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { speakStreamedChunk(tail) }
            ttsStreamSpokenChars = cumulative.count
            ttsService.endStreaming()
            ttsStreaming = false
            recordAssistantReply(historyText ?? cumulative)   // history: streamed reply is complete
            return
        }

        // Speak everything up to the last completed sentence boundary in the pending text.
        guard let boundary = TextChunking.lastSentenceBoundary(in: String(pending)) else { return }
        let pendingStr = String(pending)
        let sentence = String(pendingStr[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count >= 2 else { return }   // don't voice a stray "." or "?"
        speakStreamedChunk(sentence)
        ttsStreamSpokenChars += pendingStr.distance(from: pendingStr.startIndex, to: boundary)
    }

    /// Speak one completed sentence.
    private func speakStreamedChunk(_ sentence: String) {
        // First-wins: the first sentence handed over starts the TTS TTFB clock.
        MetricsCollector.shared.markTTSRequested()
        ttsService.speakChunk(sentence)
    }

    /// Speak AI response via TTS (optionally recording different text like LaTeX DISPLAY into History)
    private func speakResponse(_ text: String, historyText: String? = nil) {
        guard !text.isEmpty else { return }
        recordAssistantReply(historyText ?? text)
        // Blueprint lesson 4: speaking + barge-in paused BEFORE the OS starts the audio.
        agentState = .speaking
        voiceCommandService.isBargeInPaused = true
        MetricsCollector.shared.markTTSRequested()
        ttsService.speak(text)
    }

    // MARK: - History

    /// History: persist the assistant's reply, but only when it answers a recorded user command —
    /// system utterances (connection errors) stay out of History.
    private func recordAssistantReply(_ text: String) {
        guard historyAwaitingReply else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        ConversationManager.shared.addAssistantMessage(clean)
        historyAwaitingReply = false
    }
}

// MARK: - Text chunking (pure, unit-testable)

/// Pure text helpers for sentence-streamed TTS.
enum TextChunking {
    /// Index just past the last sentence terminator (. ! ? or newline) in `s`, or nil if none.
    /// A `.`/`!`/`?` only counts when followed by whitespace or end-of-text, so decimals like
    /// "2.5" and abbreviations don't get split mid-number.
    static func lastSentenceBoundary(in s: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var boundary: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\n" {
                boundary = next
            } else if terminators.contains(c) {
                let followedByBreak = next == s.endIndex || s[next] == " " || s[next] == "\n"
                if followedByBreak { boundary = next }
            }
            i = next
        }
        return boundary
    }

    /// Split `s` into speakable sentence chunks using the same boundary rules as
    /// `lastSentenceBoundary` (terminator followed by a break, or newline). Chunks are trimmed;
    /// empties dropped; text after the last terminator is included as a final chunk.
    /// Used to queue a reply one sentence at a time, each in its own language's voice.
    static func sentences(_ s: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?"]
        var result: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            current.append(c)
            let next = s.index(after: i)
            let isBoundary = c == "\n"
                || (terminators.contains(c) && (next == s.endIndex || s[next] == " " || s[next] == "\n"))
            if isBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
            i = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
