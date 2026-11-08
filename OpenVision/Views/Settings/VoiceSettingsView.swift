// OpenVision - VoiceSettingsView.swift
// Voice: wake word, microphone, listening language, answer voices (one per language), speed.

import SwiftUI
import AVFoundation

struct VoiceSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager

    // MARK: - Helpers

    private func voiceName(_ identifier: String?, language: String) -> String {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice.name
        }
        return TTSService.bestVoice(for: language).map { "Tự động · \($0.name)" } ?? "Tự động"
    }

    // MARK: - Body

    var body: some View {
        Form {
            // Wake word
            Section {
                Toggle(isOn: $settingsManager.settings.wakeWordEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Từ đánh thức")
                        Text("Chỉ nghe sau khi bạn gọi tên")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if settingsManager.settings.wakeWordEnabled {
                    TextField("Ok Vision", text: $settingsManager.settings.wakeWord)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Gọi trợ lý")
            } footer: {
                Text("Nói \"\(settingsManager.settings.wakeWord)\" rồi hỏi tự do, tiếng Việt hay tiếng Anh. Các cách đọc như \"ô kê vi dơn\" cũng được nhận.")
            }

            // Listening
            Section {
                Toggle(isOn: $settingsManager.settings.preferGlassesMic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dùng mic của kính")
                        Text("Rảnh tay hoàn toàn khi đang đeo kính")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Ngôn ngữ nghe", selection: $settingsManager.settings.recognitionLanguage) {
                    Text("Tự động (theo iPhone)").tag("auto")
                    Text("Tiếng Việt").tag("vi-VN")
                    Text("English").tag("en-US")
                }

                Picker("Tự kết thúc khi im lặng", selection: $settingsManager.settings.conversationTimeout) {
                    Text("15 giây").tag(TimeInterval(15))
                    Text("30 giây").tag(TimeInterval(30))
                    Text("1 phút").tag(TimeInterval(60))
                    Text("2 phút").tag(TimeInterval(120))
                }
            } header: {
                Text("Nghe")
            } footer: {
                Text("iOS chỉ nhận dạng một ngôn ngữ một lúc: chọn ngôn ngữ bạn hỏi nhiều nhất. Câu trả lời luôn theo ngôn ngữ của câu hỏi. Đổi ngôn ngữ nghe có hiệu lực ở lần gọi tiếp theo.")
            }

            // Answer voices
            Section {
                NavigationLink {
                    VoiceSelectionView(languagePrefix: "vi", title: "Giọng tiếng Việt",
                                       sample: "Xin chào, đáp án câu này là x bằng 2.",
                                       selection: $settingsManager.settings.selectedVietnameseVoiceIdentifier)
                } label: {
                    HStack {
                        Text("Giọng tiếng Việt")
                        Spacer()
                        Text(voiceName(settingsManager.settings.selectedVietnameseVoiceIdentifier, language: "vi-VN"))
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink {
                    VoiceSelectionView(languagePrefix: "en", title: "English voice",
                                       sample: "Hello! The answer to this question is x equals 2.",
                                       selection: $settingsManager.settings.selectedVoiceIdentifier)
                } label: {
                    HStack {
                        Text("Giọng tiếng Anh")
                        Spacer()
                        Text(voiceName(settingsManager.settings.selectedVoiceIdentifier, language: "en-US"))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tốc độ đọc")
                        Spacer()
                        Text(String(format: "%.0f%%", settingsManager.settings.speechRate / 0.5 * 100))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settingsManager.settings.speechRate, in: 0.35...0.6, step: 0.025)
                        .tint(Theme.accent)
                }
            } header: {
                Text("Giọng đọc câu trả lời")
            } footer: {
                Text("Mỗi câu được đọc bằng giọng đúng ngôn ngữ của nó. Công thức được đọc thành lời (\"x bình phương\", \"bằng\", \"phần\").")
            }

            // Feedback
            Section {
                Toggle(isOn: $settingsManager.settings.playActivationSound) {
                    Text("Âm báo khi gọi trợ lý")
                }
            } header: {
                Text("Phản hồi")
            }
        }
        .navigationTitle("Giọng nói")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
