// OpenVision - VoiceSelectionView.swift
// Apple voice picker for one language (Vietnamese or English answers).

import SwiftUI
import AVFoundation

struct VoiceSelectionView: View {
    /// "vi" or "en".
    let languagePrefix: String
    let title: String
    let sample: String
    @Binding var selection: String?

    // MARK: - State

    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var testingVoiceId: String?
    /// Held for the duration of a preview: a synthesizer created inside a function is released as
    /// soon as it returns and speaks nothing (why "test voice" used to be silent).
    @State private var previewSynthesizer = AVSpeechSynthesizer()

    // MARK: - Body

    var body: some View {
        List {
            Section {
                voiceRow(name: "Tự động (giọng tốt nhất đã cài)", quality: nil, identifier: nil)
            } footer: {
                Text("Tự chọn giọng chất lượng cao nhất (Premium › Enhanced › Default) có trên máy.")
            }

            ForEach([AVSpeechSynthesisVoiceQuality.premium, .enhanced, .default], id: \.rawValue) { quality in
                let group = voices.filter { $0.quality == quality }
                if !group.isEmpty {
                    Section {
                        ForEach(group, id: \.identifier) { voice in
                            voiceRow(name: voice.name, quality: voice.quality, identifier: voice.identifier)
                        }
                    } header: {
                        Text(TTSService.qualityDisplayName(quality))
                    }
                }
            }

            Section {
                Link(destination: URL(string: "App-prefs:ACCESSIBILITY&path=SPEECH")!) {
                    HStack {
                        Label("Tải thêm giọng", systemImage: "square.and.arrow.down")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("Giọng Enhanced/Premium phát âm tự nhiên hơn nhiều. Tải trong Cài đặt iOS → Trợ năng → Nội dung được đọc → Giọng nói.")
            }
        }
        .navigationTitle(title)
        .onAppear {
            voices = TTSService.availableVoices(for: languagePrefix)
        }
    }

    // MARK: - Voice Row

    @ViewBuilder
    private func voiceRow(name: String, quality: AVSpeechSynthesisVoiceQuality?, identifier: String?) -> some View {
        Button {
            selection = identifier
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .foregroundColor(.primary)
                    if let quality {
                        Text(TTSService.qualityDisplayName(quality))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    preview(identifier: identifier)
                } label: {
                    Image(systemName: testingVoiceId == identifier ? "speaker.wave.2.fill" : "play.circle")
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nghe thử \(name)")

                if selection == identifier {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.accent)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func preview(identifier: String?) {
        previewSynthesizer.stopSpeaking(at: .immediate)
        testingVoiceId = identifier
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? TTSService.bestVoice(for: languagePrefix == "vi" ? "vi-VN" : "en-US")
        utterance.rate = SettingsManager.shared.settings.speechRate
        previewSynthesizer.speak(utterance)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if testingVoiceId == identifier { testingVoiceId = nil }
        }
    }
}

#Preview {
    NavigationStack {
        VoiceSelectionView(languagePrefix: "vi", title: "Giọng tiếng Việt",
                           sample: "Xin chào, đáp án là x bằng 2.", selection: .constant(nil))
    }
}
