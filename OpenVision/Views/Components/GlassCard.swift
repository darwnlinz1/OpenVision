// OpenVision - GlassCard.swift
// Beautiful glassmorphic card component for dark mode

import SwiftUI

/// A glassmorphic card with frosted blur effect
struct GlassCard<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 20
    var opacity: CGFloat = 0.15
    var blurRadius: CGFloat = 10

    init(
        cornerRadius: CGFloat = 20,
        opacity: CGFloat = 0.15,
        blurRadius: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.blurRadius = blurRadius
    }

    var body: some View {
        content
            .background(
                ZStack {
                    // Blur background
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)

                    // Subtle gradient overlay
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(opacity),
                                    Color.white.opacity(opacity * 0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Border glow
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Status pill showing connection state
struct StatusPill: View {
    let status: String
    let color: Color
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isConnected ? 1.5 : 1)
                        .opacity(isConnected ? 0 : 1)
                        .animation(
                            isConnected ?
                                .easeOut(duration: 1).repeatForever(autoreverses: false) :
                                .none,
                            value: isConnected
                        )
                )

            Text(status)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

#Preview {
    ZStack {
        Theme.bg.ignoresSafeArea()
        VStack(spacing: 30) {
            StatusPill(status: "Gemini", color: Theme.success, isConnected: true)
            GlassCard {
                VStack(spacing: 12) {
                    Text("Glassmorphic Card")
                        .font(.headline)
                    Text("Frosted glass surface")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
