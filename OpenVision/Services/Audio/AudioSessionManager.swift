// OpenVision - AudioSessionManager.swift
// Manages AVAudioSession configuration for different modes

import AVFoundation

/// Manages audio session configuration
@MainActor
final class AudioSessionManager {
    // MARK: - Singleton

    static let shared = AudioSessionManager()

    // MARK: - Properties

    private let audioSession = AVAudioSession.sharedInstance()

    /// Current audio mode
    private(set) var currentMode: AudioMode = .inactive

    // MARK: - Audio Modes

    enum AudioMode {
        /// No audio session active
        case inactive

        /// Voice chat mode (aggressive echo cancellation for iPhone mic)
        case voiceChat

        /// Video chat mode (mild echo cancellation for glasses mic)
        case videoChat

        /// Measurement mode (for wake word detection)
        case measurement
    }

    /// Callback invoked when audio route changes (device connected/disconnected)
    var onRouteChange: (() -> Void)?

    private var routeChangeWorkItem: DispatchWorkItem?
    private var lastInputPortUID: String?

    // MARK: - Initialization

    private init() {
        lastInputPortUID = audioSession.currentRoute.inputs.first?.uid
        setupRouteChangeObserver()
    }

    private func setupRouteChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification)
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        print("[AudioSession] Route changed: reason=\(reason.rawValue), route: \(currentRouteDescription)")

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            // IGNORE .categoryChange and .routeConfigurationChange to prevent infinite ping-pong loops!
            // DO NOT call audioSession.setPreferredInput(hfp) inside handleAudioRouteChange!
            // Debounce onRouteChange?() by 0.5s and check if input actually changed to prevent hardware bursts.
            routeChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let currentInputUID = self.audioSession.currentRoute.inputs.first?.uid
                if currentInputUID != self.lastInputPortUID {
                    self.lastInputPortUID = currentInputUID
                    print("[AudioSession] Debounced route change fired, active input changed to: \(self.currentRouteDescription)")
                    self.onRouteChange?()
                } else {
                    print("[AudioSession] Route change debounced: input port UID unchanged (\(currentInputUID ?? "none"))")
                }
            }
            routeChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        default:
            break
        }
    }

    // MARK: - Configuration

    /// Configure audio session for specified mode
    func configure(for mode: AudioMode) throws {
        guard mode != currentMode else { return }

        switch mode {
        case .inactive:
            try deactivate()

        case .voiceChat:
            try configureVoiceChat()

        case .videoChat:
            try configureVideoChat()

        case .measurement:
            try configureMeasurement()
        }

        currentMode = mode
        print("[AudioSession] Configured for \(mode)")
    }

    /// Deactivate audio session
    func deactivate() throws {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        currentMode = .inactive
    }

    // MARK: - Mode Configurations

    /// Configure for voice chat (iPhone mic, aggressive AEC)
    private func configureVoiceChat() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ]
        )
        try audioSession.setActive(true)
    }

    /// Configure for video chat (glasses mic, mild AEC)
    private func configureVideoChat() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers
            ]
        )
        try audioSession.setActive(true)
    }

    /// Configure for measurement (wake word detection)
    private func configureMeasurement() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .duckOthers
            ]
        )
        try audioSession.setActive(true)
    }

    // MARK: - Bluetooth HFP Routing

    /// Configures audio session category allowing Bluetooth HFP & A2DP without locking preferredInput to phone.
    func configureCategoryAllowingBluetooth() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        if let hfp = findBluetoothHFPInput() {
            try? audioSession.setPreferredInput(hfp)
            lastInputPortUID = hfp.uid
            currentMode = .voiceChat
            print("[AudioSession] ✓ Auto-selected Bluetooth HFP: \(hfp.portName)")
        }
    }

    /// Configure the audio session for the glasses' Bluetooth HFP mic + speaker.
    /// Returns `true` only if an HFP input was actually found and selected (i.e. the glasses are
    /// connected as an audio device); `false` means no glasses audio is present and the caller
    /// should fall back to the phone. NOTE: we must set the category with `.allowBluetoothHFP` and
    /// activate the session *first* — only then does iOS expose the HFP input in `availableInputs`
    /// (this is what previously made the glasses mic undetectable: the phone route disallows HFP).
    @discardableResult
    func configureForGlasses() throws -> Bool {
        // Match OpenGlasses: `.default` mode + `.mixWithOthers` so the recognizer's session COEXISTS
        // with the glasses camera's Bluetooth stream instead of taking exclusive HFP control. With
        // `.voiceChat` + `.duckOthers` the camera stream killed the HFP mic (and iOS wouldn't revive
        // it); `.mixWithOthers` keeps the glasses mic alive through photo capture.
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Now that HFP is allowed + the session is active, the glasses mic should be listed.
        guard let hfpInput = findBluetoothHFPInput() else {
            print("[AudioSession] No Bluetooth HFP input — glasses not connected as an audio device. Inputs: \(availableInputsDescription)")
            return false
        }
        try audioSession.setPreferredInput(hfpInput)
        lastInputPortUID = hfpInput.uid
        currentMode = .voiceChat
        print("[AudioSession] ✓ Configured for glasses (Bluetooth HFP): \(hfpInput.portName) — route: \(currentRouteDescription)")
        return true
    }

    /// Names + types of every input iOS currently reports — for diagnosing mic routing.
    var availableInputsDescription: String {
        (audioSession.availableInputs ?? []).map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ")
    }

    /// Configure audio for phone-only use (no glasses): record from the built-in mic and play
    /// spoken responses out of the LOUD speaker. Without `.defaultToSpeaker`, `.playAndRecord`
    /// routes output to the quiet earpiece — which is why phone-only audio was inaudible.
    /// `.allowBluetoothA2DP` and `.allowBluetoothHFP` still let Bluetooth audio / mics work when present.
    func configureForPhone() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP]
        )
        try audioSession.setActive(true)
        try? audioSession.setPreferredInput(nil)
        lastInputPortUID = audioSession.currentRoute.inputs.first?.uid
        // If still routed to the quiet earpiece (carried over from a glasses/voiceChat config),
        // force the loud speaker — but leave AirPods / headphones alone if they're connected.
        if audioSession.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            try? audioSession.overrideOutputAudioPort(.speaker)
        }
        currentMode = .voiceChat
        print("[AudioSession] Configured for phone (built-in mic + loud speaker)")
    }

    /// Find Bluetooth HFP input port (prioritizing Ray-Ban Meta devices)
    private func findBluetoothHFPInput() -> AVAudioSessionPortDescription? {
        let available = audioSession.availableInputs ?? []
        // Priority 1: standard Bluetooth HFP port
        if let hfp = available.first(where: { $0.portType == .bluetoothHFP }) {
            return hfp
        }
        // Priority 2: device explicitly identified as Ray-Ban or Meta
        if let metaInput = available.first(where: { input in
            let name = input.portName.lowercased()
            return name.contains("ray-ban") || name.contains("meta") || name.contains("rb") || name.contains("stories")
        }) {
            return metaInput
        }
        // Priority 3: standard Bluetooth LE input port
        return available.first(where: { $0.portType == .bluetoothLE })
    }

    /// Check if Bluetooth HFP / glasses microphone is currently the active input route
    var isBluetoothHFPInputActive: Bool {
        let inputs = audioSession.currentRoute.inputs
        return inputs.contains { input in
            if input.portType == .bluetoothHFP || input.portType == .bluetoothLE { return true }
            let name = input.portName.lowercased()
            return name.contains("ray-ban") || name.contains("meta") || name.contains("rb meta")
        }
    }

    /// Check if Bluetooth HFP is currently active (input or output)
    var isBluetoothHFPActive: Bool {
        let inputs = audioSession.currentRoute.inputs
        let outputs = audioSession.currentRoute.outputs

        let hasHFPInput = inputs.contains { input in
            if input.portType == .bluetoothHFP || input.portType == .bluetoothLE { return true }
            let name = input.portName.lowercased()
            return name.contains("ray-ban") || name.contains("meta") || name.contains("rb meta")
        }
        let hasHFPOutput = outputs.contains { output in
            if output.portType == .bluetoothHFP { return true }
            let name = output.portName.lowercased()
            return output.portType == .bluetoothA2DP && (name.contains("ray-ban") || name.contains("meta") || name.contains("rb meta"))
        }

        return hasHFPInput || hasHFPOutput
    }

    /// Get current audio route description
    var currentRouteDescription: String {
        let inputs = audioSession.currentRoute.inputs.map { $0.portName }.joined(separator: ", ")
        let outputs = audioSession.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        return "Input: \(inputs.isEmpty ? "none" : inputs), Output: \(outputs.isEmpty ? "none" : outputs)"
    }

    // MARK: - Utilities

    /// Get current input sample rate
    var inputSampleRate: Double {
        audioSession.sampleRate
    }

    /// Get current output sample rate
    var outputSampleRate: Double {
        audioSession.sampleRate
    }

    /// Check if Bluetooth audio is available
    var isBluetoothAvailable: Bool {
        audioSession.availableInputs?.contains { port in
            port.portType == .bluetoothHFP || port.portType == .bluetoothA2DP
        } ?? false
    }

    /// Check if using built-in mic
    var isUsingBuiltInMic: Bool {
        audioSession.currentRoute.inputs.contains { port in
            port.portType == .builtInMic
        }
    }
}
