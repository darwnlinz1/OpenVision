// OpenVision - SettingsView.swift
// Settings: one brain (Gemini), the glasses, and the voice — nothing else.

import SwiftUI

struct SettingsView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // AI
                Section {
                    NavigationLink {
                        GeminiSettingsView()
                    } label: {
                        HStack {
                            Label("Gemini", systemImage: "sparkles")
                            Spacer()
                            if settingsManager.settings.isGeminiConfigured {
                                Text("\(GeminiLiveService.parseKeys(settingsManager.settings.geminiAPIKey).count) key")
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Chưa có key")
                                    .foregroundColor(Theme.warning)
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(Theme.warning)
                            }
                        }
                    }

                    NavigationLink {
                        AdditionalInstructionsView()
                    } label: {
                        Label("Hướng dẫn riêng", systemImage: "text.quote")
                    }

                    NavigationLink {
                        MemoriesView()
                    } label: {
                        HStack {
                            Label("Ghi nhớ", systemImage: "brain")
                            Spacer()
                            Text("\(settingsManager.settings.memories.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("AI")
                }

                // Glasses
                Section {
                    NavigationLink {
                        GlassesSettingsView()
                    } label: {
                        HStack {
                            Label("Kính Ray-Ban Meta", systemImage: "eyeglasses")
                            Spacer()
                            Image(systemName: glassesManager.isRegistered ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(glassesManager.isRegistered ? Theme.success : Theme.warning)
                        }
                    }
                } header: {
                    Text("Phần cứng")
                }

                // Voice
                Section {
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        HStack {
                            Label("Giọng nói", systemImage: "mic.fill")
                            Spacer()
                            Text(settingsManager.settings.wakeWordEnabled ? settingsManager.settings.wakeWord : "Tắt")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Giọng nói")
                }

                // Display
                Section {
                    Toggle(isOn: $settingsManager.settings.showTranscripts) {
                        Label("Hiện hội thoại trên màn hình", systemImage: "text.bubble")
                    }
                } header: {
                    Text("Hiển thị")
                }

                // About
                Section {
                    HStack {
                        Label("Phiên bản", systemImage: "info.circle")
                        Spacer()
                        Text("\(Config.appVersion) (\(Config.buildNumber))")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/darwnlinz1/OpenVision")!) {
                        Label("Mã nguồn trên GitHub", systemImage: "link")
                    }
                } header: {
                    Text("Giới thiệu")
                } footer: {
                    Text("OpenVision là phần mềm mã nguồn mở (MIT).")
                }
            }
            .navigationTitle("Cài đặt")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
}
