import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Shared glass material styling modifier extracted from 16 widget files.
/// Replaces duplicated `.background(.ultraThinMaterial).cornerRadius(...).shadow(...)` chains.
///
/// Falls back to an opaque window-background color when the user has
/// "Reduce Transparency" enabled in System Settings > Accessibility > Display,
/// per Apple HIG guidance on blur materials.
struct GlassContainer: ViewModifier {
    var cornerRadius: CGFloat = 16
    var hasShadow: Bool = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    #if canImport(AppKit)
                    Color(nsColor: .windowBackgroundColor)
                    #else
                    Color(.systemBackground)
                    #endif
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .shadow(
                color: .black.opacity(hasShadow ? 0.1 : 0),
                radius: hasShadow ? 10 : 0,
                x: 0,
                y: hasShadow ? 5 : 0
            )
    }
}

extension View {
    /// Apply the standard iClaw glass container styling.
    func glassContainer(cornerRadius: CGFloat = 16, hasShadow: Bool = true) -> some View {
        modifier(GlassContainer(cornerRadius: cornerRadius, hasShadow: hasShadow))
    }
}
