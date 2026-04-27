import SwiftUI

/// A Liquid Glass styled First-Time User Experience (FTUE) tutorial.
@MainActor
public struct FTUETutorialView: View {
    @AppStorage(AppConfig.hasSeenTutorialKey) private var hasSeenTutorial = false

    /// Optional callback invoked when the panel is dismissed (e.g. to close a standalone window).
    var onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Animation state for the Liquid Glass mesh effect
    @State private var t: Float = 0.0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        if !hasSeenTutorial || onDismiss != nil {
            ZStack {
                // Dimming background
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)

                // Liquid Glass Modal
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 48)) // SF Symbol sizing — hero onboarding icon
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.blue, .purple, .pink],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 10)

                        Text("Welcome to iClaw", bundle: .iClawCore)
                            .font(.title.bold())
                            .fontDesign(.rounded)
                            .foregroundStyle(.primary)

                        Text("Your private, local AI companion.", bundle: .iClawCore)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Core Values
                    VStack(alignment: .leading, spacing: 20) {
                        ValueRow(
                            icon: "apple.intelligence",
                            title: String(localized: "Private", bundle: .iClawCore),
                            description: String(localized: "Local AI, so your data never leaves your Mac.", bundle: .iClawCore)
                        )
                        ValueRow(
                            icon: "gift",
                            title: String(localized: "Free", bundle: .iClawCore),
                            description: String(localized: "No trials, subscriptions, credits, or rate limits.", bundle: .iClawCore)
                        )
                        ValueRow(
                            icon: "bolt.fill",
                            title: String(localized: "Powerful", bundle: .iClawCore),
                            description: String(localized: "Built-in tools and skills help iClaw get results and take action.", bundle: .iClawCore)
                        )
                        ValueRow(
                            icon: "shield.checkered",
                            title: String(localized: "Secure", bundle: .iClawCore),
                            description: String(localized: "iClaw only uses the permissions you give it, and confirms before taking action.", bundle: .iClawCore)
                        )
                    }
                    .padding(.horizontal)

                    // Tool Chips Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tool Chips", bundle: .iClawCore)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text("Type # to use a specific tool. For example: type #weather to skip the thinking and go straight to the forecast.", bundle: .iClawCore)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("#weather")
                            Text("#math")
                            Text("#search")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Capsule().fill(.secondary.opacity(0.2)))
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))

                    // Action Button
                    Button(action: {
                        withAnimation(reduceMotion ? nil : .spring()) {
                            hasSeenTutorial = true
                        }
                        onDismiss?()
                    }) {
                        Text("Get Started", bundle: .iClawCore)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor)
                                    .shadow(color: Color.accentColor.opacity(0.5), radius: 10, x: 0, y: 5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(32)
                .frame(width: 360)
                .background {
                    ZStack {
                        // Liquid Glass: Ultra Thin Material
                        RoundedRectangle(cornerRadius: 24)
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
                                    .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1),
                                    .indigo.opacity(0.1), .clear, .indigo.opacity(0.1),
                                    .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1)
                                ]
                            )
                            .onReceive(timer) { _ in
                                if !reduceMotion { t += 0.1 }
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 40, x: 0, y: 20)
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) {
                    hasSeenTutorial = true
                    onDismiss?()
                }
            }
        }
    }
}

private struct ValueRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2) // SF Symbol sizing
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - Standalone Window Launcher

@MainActor
enum FTUEWindowController {
    private static var window: NSWindow?

    static func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        let view = FTUETutorialView(onDismiss: {
            panel.close()
            FTUEWindowController.window = nil
        })

        panel.contentView = NSHostingView(rootView: view)
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}
#endif

// MARK: - Memberwise init for onDismiss

extension FTUETutorialView {
    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }
}

#Preview {
    FTUETutorialView()
}
