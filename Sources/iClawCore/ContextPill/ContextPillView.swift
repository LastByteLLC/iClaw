import SwiftUI

/// A capsule-shaped pill that appears above the input field after tool execution.
///
/// Shows the prior tool name + primary entity with a countdown bar that indicates
/// when the context will expire. Users can:
/// - **Tap** to anchor the context (follow-up confidence boosted to ~100%)
/// - **Tap again** to un-anchor (countdown resumes)
/// - **Let it expire** (30s) to signal a new topic
///
/// The countdown bar is a rounded capsule overlay that shrinks from right to left.
public struct ContextPillView: View {
    var state: ContextPillState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: ContextPillState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.toolIcon)
                .font(.caption2)
                .foregroundStyle(state.isAnchored ? .primary : .secondary)

            Text(state.displayText)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary.opacity(0.8))

            if state.isAnchored {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8)) // SF Symbol sizing — compact pill indicator
                    .foregroundStyle(.primary.opacity(0.6))
            }

            Button {
                withAnimation(reduceMotion ? nil : .quick) {
                    state.dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold)) // SF Symbol sizing — compact pill dismiss
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss context", bundle: .iClawCore))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .leading) {
                    // Countdown bar — rounded capsule that shrinks from right
                    GeometryReader { geo in
                        Capsule()
                            .fill(state.isAnchored
                                ? Color.accentColor.opacity(0.15)
                                : Color.primary.opacity(0.08))
                            .frame(width: geo.size.width * state.progress)
                            .animation(.linear(duration: 0.5), value: state.progress)
                    }
                }
                .clipShape(Capsule())
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    state.isAnchored
                        ? Color.accentColor.opacity(0.3)
                        : Color.primary.opacity(0.1),
                    lineWidth: 0.5
                )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state.isAnchored
            ? String(localized: "Unpin context", bundle: .iClawCore)
            : String(localized: "Pin context", bundle: .iClawCore))
        .onTapGesture {
            withAnimation(.snappy) {
                state.toggleAnchor()
            }
        }
        .transition(reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        )
    }
}
