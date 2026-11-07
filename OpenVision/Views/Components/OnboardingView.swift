// OpenVision - OnboardingView.swift
// First-run walkthrough, in the app's emerald theme.

import SwiftUI

struct OnboardingView: View {
    // MARK: - State

    @State private var currentPage = 0
    @Binding var hasCompletedOnboarding: Bool

    // MARK: - Body

    var body: some View {
        ZStack {
            // Animated background
            AnimatedBackground()

            // Content
            VStack(spacing: 0) {
                // Pages
                TabView(selection: $currentPage) {
                    WelcomePage()
                        .tag(0)

                    FeaturesPage()
                        .tag(1)

                    SetupPage()
                        .tag(2)

                    GetStartedPage(hasCompletedOnboarding: $hasCompletedOnboarding)
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)

                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(currentPage == index ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(currentPage == index ? 1.2 : 1.0)
                            .animation(.spring(response: 0.3), value: currentPage)
                    }
                }
                .padding(.bottom, 20)

                // Navigation buttons
                HStack {
                    if currentPage > 0 {
                        Button("Quay lại") {
                            withAnimation {
                                currentPage -= 1
                            }
                        }
                        .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()

                    if currentPage < 3 {
                        Button {
                            withAnimation {
                                currentPage += 1
                            }
                        } label: {
                            HStack {
                                Text("Tiếp")
                                Image(systemName: "arrow.right")
                            }
                            .foregroundColor(.black.opacity(0.9))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(Theme.buttonGradient)
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Welcome Page

private struct WelcomePage: View {
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: CGFloat = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated logo
            ZStack {
                // Outer glow rings
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Theme.accentBright.opacity(0.3), Theme.accentDeep.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: CGFloat(120 + i * 40), height: CGFloat(120 + i * 40))
                        .opacity(logoOpacity * (1 - Double(i) * 0.3))
                }

                // Main logo circle
                Circle()
                    .fill(Theme.buttonGradient)
                    .frame(width: 100, height: 100)
                    .shadow(color: Theme.glow.opacity(0.5), radius: 20)

                // Glasses icon
                Image(systemName: "eyeglasses")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
            .scaleEffect(logoScale)
            .opacity(logoOpacity)

            // Title
            VStack(spacing: 8) {
                Text("OpenVision")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)

                Text("Chụp bài, hỏi, nghe đáp án ngay trên kính.")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
            .opacity(logoOpacity)

            Spacer()
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
        }
    }
}

// MARK: - Features Page

private struct FeaturesPage: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Làm được gì")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(spacing: 24) {
                FeatureRow(
                    icon: "camera.shutter.button",
                    title: "Ảnh thẳng từ kính",
                    description: "Bấm nút chụp: ảnh nét gửi ngay cho Gemini, không chờ Thư viện."
                )

                FeatureRow(
                    icon: "mic.fill",
                    title: "Hỏi tự do, Việt hoặc Anh",
                    description: "Nói \"Ok Vision\" rồi hỏi gì cũng được. Hỏi tiếng nào, đáp tiếng đó."
                )

                FeatureRow(
                    icon: "function",
                    title: "Lời giải có công thức",
                    description: "Kính đọc đáp án; iPhone hiện từng bước với công thức toán."
                )

                FeatureRow(
                    icon: "lock.shield.fill",
                    title: "Key của riêng bạn",
                    description: "API key nằm trong Keychain của máy, không bao giờ trong mã nguồn."
                )
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(Theme.accent)
            }

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Setup Page

private struct SetupPage: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Thiết lập nhanh")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(spacing: 20) {
                SetupStep(
                    number: 1,
                    title: "Dán API key Gemini",
                    description: "Cài đặt → Gemini. Lấy key miễn phí ở Google AI Studio"
                )

                SetupStep(
                    number: 2,
                    title: "Kết nối kính",
                    description: "Đăng ký kính Ray-Ban Meta qua ứng dụng Meta AI"
                )

                SetupStep(
                    number: 3,
                    title: "Chụp và hỏi",
                    description: "Bấm nút chụp trên gọng kính, rồi nói \"Ok Vision\" + câu hỏi"
                )

                SetupStep(
                    number: 4,
                    title: "Nghe và xem",
                    description: "Kính đọc đáp án; iPhone hiện lời giải chi tiết có công thức"
                )
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            // Number badge
            ZStack {
                Circle()
                    .fill(Theme.buttonGradient)
                    .frame(width: 36, height: 36)

                Text("\(number)")
                    .font(.headline)
                    .foregroundColor(.black.opacity(0.9))
            }

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
    }
}

// MARK: - Get Started Page

private struct GetStartedPage: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var buttonScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Success animation
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.glow.opacity(0.3), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)

                Circle()
                    .fill(Theme.buttonGradient)
                    .frame(width: 100, height: 100)
                    .shadow(color: Theme.glow.opacity(0.5), radius: 20)

                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("Sẵn sàng!")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Dán API key Gemini trong Cài đặt, đăng ký kính, rồi nói \"Ok Vision\".")
                .font(.body)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            // Get started button
            Button {
                withAnimation {
                    hasCompletedOnboarding = true
                }
            } label: {
                Text("Bắt đầu")
                    .font(.headline)
                    .foregroundColor(.black.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(Theme.buttonGradient))
                    .shadow(color: Theme.glow.opacity(0.3), radius: 10)
            }
            .scaleEffect(buttonScale)
            .padding(.horizontal, 32)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: true)
                ) {
                    buttonScale = 1.05
                }
            }

            Spacer()
        }
    }
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
