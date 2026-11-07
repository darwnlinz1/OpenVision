// OpenVision - GeminiSettingsView.swift
// Gemini Live API key configuration

import SwiftUI

struct GeminiSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var apiKey: String = ""
    @State private var videoFPS: Int = 1

    // MARK: - Body

    var body: some View {
        Form {
            // API Key
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("AQ.… hoặc AIza…  (nhiều key: cách nhau bằng dấu phẩy)", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Xác thực")
            } footer: {
                let count = GeminiLiveService.parseKeys(apiKey).count
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: count > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(count > 0 ? Theme.success : Theme.warning)
                        Text(count > 0 ? "\(count) key — lưu trong Keychain của máy, không nằm trong mã nguồn" : "Chưa có key: app không thể gọi Gemini")
                            .foregroundColor(count > 0 ? Theme.success : Theme.warning)
                    }
                    Text("Quota tính theo PROJECT và theo model, không theo key: chỉ thêm key từ các project Google Cloud khác nhau mới tăng quota. Khi model chính hết quota, app tự chuyển sang \(GeminiLiveService.modelChain.dropFirst().joined(separator: ", ")).")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }

            // Video Settings
            Section {
                Picker("Video Frame Rate", selection: $videoFPS) {
                    Text("1 FPS (Recommended)").tag(1)
                    Text("2 FPS").tag(2)
                    Text("5 FPS").tag(5)
                }
            } header: {
                Text("Video Streaming")
            } footer: {
                Text("Higher frame rates use more bandwidth and API quota. 1 FPS is recommended for most use cases.")
            }

            // Help
            Section {
                Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                    HStack {
                        Text("Get API Key")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

                Link(destination: URL(string: "https://ai.google.dev/gemini-api/docs/live-api")!) {
                    HStack {
                        Text("Gemini Live Documentation")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Gemini Live provides real-time voice and vision AI with native audio responses.")
            }

            // Info
            Section {
                HStack {
                    Text("Input Audio")
                    Spacer()
                    Text("16kHz PCM")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Output Audio")
                    Spacer()
                    Text("24kHz PCM")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Video Format")
                    Spacer()
                    Text("JPEG @ \(videoFPS) FPS")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Technical Details")
            }
        }
        .navigationTitle("Gemini Live")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settingsManager.settings.geminiAPIKey
            videoFPS = settingsManager.settings.geminiVideoFPS
        }
        .onDisappear {
            saveSettings()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveSettings()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Methods

    private func saveSettings() {
        // Normalised to "key1, key2" — GeminiLiveService.parseKeys reads any separator.
        settingsManager.settings.geminiAPIKey = GeminiLiveService.parseKeys(apiKey).joined(separator: ", ")
        settingsManager.settings.geminiVideoFPS = videoFPS
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        GeminiSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
