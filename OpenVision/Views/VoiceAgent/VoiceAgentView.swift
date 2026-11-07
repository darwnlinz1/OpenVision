// OpenVision - VoiceAgentView.swift
// Beautiful main voice conversation UI with glassmorphism design.
//
// MVVM: this view only renders state and forwards interactions — every piece of orchestration
// (session lifecycle, command routing, live video, TTS streaming) lives in VoiceAgentViewModel.

import SwiftUI

struct VoiceAgentView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - ViewModel

    @StateObject private var viewModel = VoiceAgentViewModel()

    // MARK: - Observed services
    // Only the services whose @Published state the body reacts to directly. They are the same
    // singletons the ViewModel drives — observed here purely so onChange fires.

    @StateObject private var voiceCommandService = VoiceCommandService.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var kokoroTTS = KokoroTTSService.shared
    @StateObject private var grokTTS = CloudTTSService.grok
    @StateObject private var openAITTS = CloudTTSService.openAI
    @StateObject private var documentFocus = DocumentFocus.shared
    @StateObject private var photoScanner = RecentPhotoScanner.shared

    /// The solution open in the sheet — frozen when opened, so a new question doesn't blank it.
    @State private var openSolution: SolutionItem?

    // MARK: - Body

    var body: some View {
        ZStack {
            // Beautiful animated background
            AnimatedBackground()

            // Particle effects
            ParticleEffect(particleCount: 30)
                .opacity(0.5)

            // Main content — the orb stays vertically centered and STABLE. The transcript is a
            // separate overlay (below) so it can never push the orb around.
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                // Document-focus pill: visible whenever a document is "open" so the mode is never
                // silently steering answers. Tap to release focus.
                if let doc = documentFocus.activeDocument {
                    HStack(spacing: 6) {
                        Image(systemName: "book.fill").font(.caption2)
                        Text(doc.title).font(.caption.bold()).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").font(.caption2).opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.indigo.opacity(0.8)))
                    .padding(.top, 8)
                    .onTapGesture { documentFocus.deactivate() }
                    .transition(.opacity)
                }
                Spacer()
                centerContent
                Spacer()
            }

            // Transcript floats over the bottom; growing text stays inside its own card and doesn't
            // move the orb.
            if settingsManager.settings.showTranscripts
                && (!viewModel.userTranscript.isEmpty || !viewModel.aiTranscript.isEmpty || viewModel.agentState == .thinking) {
                VStack {
                    Spacer()
                    transcriptArea
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Error overlay
            if let error = viewModel.errorMessage {
                errorOverlay(error)
            }
        }
        // Animate the state text and the transcript's appear/disappear only — NOT every streamed
        // token (the old .spring on userTranscript/aiTranscript sprang the whole view and jostled
        // the orb on every word).
        .animation(.easeInOut(duration: 0.3), value: viewModel.agentState)
        .animation(.easeInOut(duration: 0.35), value: viewModel.userTranscript.isEmpty)
        .animation(.easeInOut(duration: 0.35), value: viewModel.aiTranscript.isEmpty)
        // Attached to the root (not the transcript, which comes and goes) so the solution stays
        // open after the session ends.
        .sheet(item: $openSolution) { item in
            SolutionSheet(markdown: item.markdown)
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .task {
            await viewModel.requestSpeechAuthorization()
        }
        // Observe TTS state changes
        .onChange(of: ttsService.isSpeaking) { isSpeaking in
            viewModel.ttsSpeakingChanged(isSpeaking)
        }
        .onChange(of: kokoroTTS.isSpeaking) { speaking in
            viewModel.neuralSpeakingChanged(speaking)
        }
        .onChange(of: grokTTS.isSpeaking) { _, speaking in
            viewModel.neuralSpeakingChanged(speaking)
        }
        .onChange(of: openAITTS.isSpeaking) { _, speaking in
            viewModel.neuralSpeakingChanged(speaking)
        }
        // Control thinking sound based on agent state
        .onChange(of: viewModel.agentState) { newState in
            viewModel.agentStateChanged(newState)
        }
        // Observe VoiceCommandService state changes
        .onChange(of: voiceCommandService.state) { newState in
            viewModel.voiceStateChanged(newState)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // AI Backend status (or Live Video indicator)
            if viewModel.isLiveVideoMode {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                        )

                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundColor(.white)

                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.red.opacity(0.8))
                )
            } else {
                StatusPill(
                    status: settingsManager.settings.backendDisplayName,
                    color: viewModel.agentState == .idle ? .gray : .green,
                    isConnected: viewModel.agentState != .idle && viewModel.agentState != .connecting
                )
            }

            Spacer()

            // Transient "Saved to Photos" / failure status after a recording finishes.
            if let status = viewModel.recordingStatus {
                Text(status)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .transition(.opacity)
            }

            // POV recording toggle (glasses video + as-heard audio → Photos).
            if glassesManager.isRegistered {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title2)
                        .foregroundColor(viewModel.isRecording ? .red : .white)
                        .padding(.horizontal, 4)
                }
                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Record point of view")
            }

            // Photo readiness: the glasses photo the next question will use (temple shutter →
            // Camera Roll, or the SDK camera). Tap to take one with the glasses camera.
            Button {
                Task { await viewModel.snapPhotoFromGlasses() }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    photoBadge(now: timeline.date)
                }
            }
            .accessibilityLabel("Chụp ảnh bằng kính")

            // Glasses status
            HStack(spacing: 8) {
                Image(systemName: "eyeglasses")
                    .foregroundColor(glassesManager.isRegistered ? Theme.success : Theme.inactive)

                if glassesManager.isStreaming {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Center Content

    /// Map the agent state to the orb's visual mode.
    private var orbMode: SwirlOrb.Mode {
        switch viewModel.agentState {
        case .listening: return .listening
        case .speaking: return .speaking
        case .thinking, .toolRunning, .connecting: return .thinking
        case .idle, .liveVideo: return .idle
        }
    }

    private var centerContent: some View {
        VStack(spacing: 28) {
            // Heading / status prompt
            Group {
                if viewModel.agentState == .liveVideo {
                    VStack(spacing: 6) {
                        Text(settingsManager.settings.backendDisplayName)
                            .font(.headline)
                            .foregroundColor(Theme.heading)
                        Text("Nói \"stop video\" để thoát")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                } else if viewModel.agentState == .idle && settingsManager.settings.wakeWordEnabled {
                    VStack(spacing: 8) {
                        Text("Hỏi gì cũng được")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.heading)
                        if viewModel.isVoiceReady {
                            Text("Bấm nút chụp trên kính, rồi nói \"\(settingsManager.settings.wakeWord)\" + câu hỏi")
                                .font(.subheadline)
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().tint(Theme.accent).scaleEffect(0.8)
                                Text("Đang khởi động giọng nói…")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .transition(.opacity)

            // The assistant identity: swirling emerald orb (tap to start/stop a session)
            SwirlOrb(mode: orbMode, size: 250)
                .onTapGesture { viewModel.toggleSession() }

            // Status text
            Text(viewModel.agentState.displayText)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(Theme.textPrimary)

            // Tool status
            if let tool = viewModel.currentToolName, viewModel.agentState == .toolRunning {
                ToolStatusView(toolName: tool, isRunning: true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Transcript Area

    // Bubbles float directly over the background (no outer card box — the old GlassCard wrapper
    // was a mostly-empty gray slab).
    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptView(
                userText: viewModel.userTranscript,
                aiText: viewModel.aiTranscript,
                isAIStreaming: viewModel.agentState == .speaking
            )
            if let solution = viewModel.latestSolution {
                SolutionButton { openSolution = SolutionItem(markdown: solution) }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.25), value: viewModel.latestSolution == nil)
    }

    // MARK: - Photo badge

    /// The photo the next question will use: a thumbnail and how long ago it was taken, or a plain
    /// camera when there is none. Green while it is still within the 120 s window.
    @ViewBuilder
    private func photoBadge(now: Date) -> some View {
        let contextAge = viewModel.activePhotoContext.map { now.timeIntervalSince($0.timestamp) }
        let libraryAge = photoScanner.latestPhotoDate.map { now.timeIntervalSince($0) }
        let age = [contextAge, libraryAge].compactMap { $0 }.filter { $0 >= 0 }.min()
        let ready = (age ?? .infinity) < SolverIntent.recentPhotoWindow
            && (viewModel.activePhotoContext?.isFresh(at: now) ?? true)
        HStack(spacing: 6) {
            if ready, let thumbnail = photoScanner.latestThumbnail, libraryAge == age {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: ready ? "camera.fill" : "camera")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(ready ? Theme.success : Theme.textPrimary)
            }
            if ready, let age {
                Text("\(Int(age))s")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundColor(Theme.success)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(ready ? Theme.success.opacity(0.6) : Theme.bgElevatedStroke, lineWidth: 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ready ? "Có ảnh từ kính, chụp \(Int(age ?? 0)) giây trước" : "Chưa có ảnh")
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    VoiceAgentView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .preferredColorScheme(.dark)
}
