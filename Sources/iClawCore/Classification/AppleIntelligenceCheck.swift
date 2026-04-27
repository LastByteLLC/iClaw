import SwiftUI
import Observation
import FoundationModels

/// Manages the state and availability of Apple Intelligence features.
@MainActor
@Observable
public final class AppleIntelligenceState {
    /// Whether Apple Intelligence is available on this device.
    public var isAppleIntelligenceEnabled: Bool

    /// Shared singleton instance.
    public static let shared = AppleIntelligenceState()

    private init() {
        isAppleIntelligenceEnabled = SystemLanguageModel.default.availability == .available
    }

    /// Re-checks availability (e.g. after returning from System Settings).
    public func refreshStatus() {
        isAppleIntelligenceEnabled = SystemLanguageModel.default.availability == .available
    }

    #if DEBUG
    /// Toggles the status for testing UI transitions.
    public func toggleStatus() {
        isAppleIntelligenceEnabled.toggle()
    }
    #endif
}

/// A "Liquid Glass" stylized view that informs the user that Apple Intelligence is required.
public struct AppleIntelligenceRequirementView: View {
    @Environment(\.openURL) private var openURL
    var state = AppleIntelligenceState.shared
    
    // Animation state for the Liquid Glass mesh effect
    @State private var t: Float = 0.0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            // Stylized Apple Intelligence / Sparkle Icon
            Image(systemName: "sparkles")
                .font(.system(size: 64)) // SF Symbol sizing — hero display icon
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue, .purple, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .blue.opacity(0.3), radius: 10)

            VStack(spacing: 8) {
                Text("Apple Intelligence Required")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("iClaw Local utilizes on-device foundation models. Please enable Apple Intelligence in System Settings to continue.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            // Action button to open System Settings
            Button(action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence") {
                    openURL(url)
                }
            }) {
                Text("Open System Settings")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.8))
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(0.3), lineWidth: 1)
                            )
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            #if DEBUG
            // Debug toggle to test UI transitions
            Button("Toggle Status (Debug Only)") {
                state.toggleStatus()
            }
            .buttonStyle(.link)
            .padding(.top, 8)
            #endif
        }
        .padding(40)
        .frame(width: 400)
        .background {
            ZStack {
                // Liquid Glass: Ultra Thin Material
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                
                // Liquid Glass: Animated Mesh Gradient
                if #available(macOS 15.0, *) {
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            [0, 0], [0.5, 0], [1, 0],
                            [0, 0.5], [0.5 + 0.1 * sin(t), 0.5 + 0.1 * cos(t)], [1, 0.5],
                            [0, 1], [0.5, 1], [1, 1]
                        ],
                        colors: [
                            .blue.opacity(0.15), .purple.opacity(0.15), .blue.opacity(0.15),
                            .indigo.opacity(0.15), .clear, .indigo.opacity(0.15),
                            .blue.opacity(0.15), .purple.opacity(0.15), .blue.opacity(0.15)
                        ]
                    )
                    .onReceive(timer) { _ in
                        t += 0.1
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 20))
        .overlay(
            // Thin white border for the Liquid Glass look
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 15)
    }
}

#Preview {
    ZStack {
        // Dark background to showcase Liquid Glass transparency
        Color.black.ignoresSafeArea()
        AppleIntelligenceRequirementView()
    }
}
