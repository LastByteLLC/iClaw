import SwiftUI

/// Animated gradient border glow effect inspired by Apple Intelligence.
/// Renders 4 stacked `RoundedRectangle` strokes with `AngularGradient`
/// whose color stop positions are randomized on a timer, creating an
/// organic shimmer. Each layer has increasing line width and blur to
/// produce a sharp edge fading into a soft halo.
struct ThinkingGlowView: View {
    let cornerRadius: CGFloat
    let isActive: Bool

    /// Apple Intelligence–inspired gradient palette.
    static let glowColors: [Color] = [
        Color(red: 0.74, green: 0.51, blue: 0.95),  // #BC82F3 Purple
        Color(red: 0.96, green: 0.73, blue: 0.92),  // #F5B9EA Pink
        Color(red: 0.55, green: 0.62, blue: 1.00),  // #8D9FFF Periwinkle
        Color(red: 1.00, green: 0.40, blue: 0.47),  // #FF6778 Coral
        Color(red: 1.00, green: 0.73, blue: 0.44),  // #FFBA71 Orange
        Color(red: 0.78, green: 0.53, blue: 1.00),  // #C686FF Violet
    ]

    var body: some View {
        if isActive {
            ZStack {
                GlowLayer(cornerRadius: cornerRadius, lineWidth: 3, blurRadius: 0,  interval: 0.4, duration: 0.5)
                GlowLayer(cornerRadius: cornerRadius, lineWidth: 5, blurRadius: 4,  interval: 0.4, duration: 0.6)
                GlowLayer(cornerRadius: cornerRadius, lineWidth: 7, blurRadius: 10, interval: 0.4, duration: 0.8)
                GlowLayer(cornerRadius: cornerRadius, lineWidth: 10, blurRadius: 14, interval: 0.5, duration: 1.0)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .transition(.opacity.animation(.easeInOut(duration: 0.4)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Single Glow Layer

/// One layer of the glow effect: an AngularGradient stroke whose stop
/// positions animate randomly, producing smooth organic color movement.
private struct GlowLayer: View {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let blurRadius: CGFloat
    let interval: TimeInterval
    let duration: TimeInterval

    @State private var stops: [Gradient.Stop] = Self.randomStops()

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: stops,
                    center: .center
                ),
                lineWidth: lineWidth
            )
            .blur(radius: blurRadius)
            .onAppear {
                startAnimation()
            }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func startAnimation() {
        guard !reduceMotion else { return }
        // Use a recurring task instead of Timer for structured concurrency
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                withAnimation(.easeInOut(duration: duration)) {
                    stops = Self.randomStops()
                }
            }
        }
    }

    /// Generate gradient stops with fixed colors but randomized positions.
    private static func randomStops() -> [Gradient.Stop] {
        ThinkingGlowView.glowColors
            .map { Gradient.Stop(color: $0, location: Double.random(in: 0...1)) }
            .sorted { $0.location < $1.location }
    }
}

// MARK: - View Modifier

extension View {
    /// Adds the Apple Intelligence–style animated glow border when active.
    func thinkingGlow(isActive: Bool, cornerRadius: CGFloat = 32) -> some View {
        self.overlay {
            ThinkingGlowView(cornerRadius: cornerRadius, isActive: isActive)
        }
    }
}
