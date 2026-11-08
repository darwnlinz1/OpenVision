// OpenVision - GeminiSettingsView.swift
// Gemini Live API key configuration

import SwiftUI

struct GeminiSettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var apiKey: String = ""

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

            // Help
            Section {
                Link(destination: URL(string: "https://aistudio.google.com/app/apikey")!) {
                    HStack {
                        Text("Lấy API key (Google AI Studio)")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                    }
                }

            } header: {
                Text("Trợ giúp")
            } footer: {
                Text("Model: \(GeminiLiveService.modelChain.joined(separator: " → ")). Câu trả lời được truyền dần (streaming): kính đọc câu đầu tiên ngay khi có.")
            }

        }
        .navigationTitle("Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKey = settingsManager.settings.geminiAPIKey
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
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        GeminiSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
