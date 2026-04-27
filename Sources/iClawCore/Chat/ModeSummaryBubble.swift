import SwiftUI

/// A collapsed summary bubble for a completed Mode thread.
/// Tap to expand/collapse the thread. Context menu offers deletion.
struct ModeSummaryBubble: View {
    let message: Message
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(.yellow.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: message.modeIcon ?? "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.modeName ?? String(localized: "Mode", bundle: .iClawCore))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(message.modeSummary ?? String(localized: "Session", bundle: .iClawCore))
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded
            ? String(localized: "Collapse thread", bundle: .iClawCore)
            : String(localized: "Expand thread", bundle: .iClawCore))
        .accessibilityHint(String(localized: "Double-tap to toggle", bundle: .iClawCore))
        .onTapGesture { onToggle() }
        .contextMenu {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(String(localized: "Delete Thread", bundle: .iClawCore), systemImage: "trash")
            }
        }
        .confirmationDialog(String(localized: "Delete this mode thread?", bundle: .iClawCore), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete", bundle: .iClawCore), role: .destructive) { onDelete() }
        }
    }
}
