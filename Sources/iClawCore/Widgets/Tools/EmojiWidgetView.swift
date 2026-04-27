import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Data model for the emoji skill widget.
public struct EmojiWidgetData: Sendable {
    public let emoji: String
    public let name: String
    public let relatedEmoji: [(emoji: String, name: String)]

    public init(emoji: String, name: String, relatedEmoji: [(emoji: String, name: String)]) {
        self.emoji = emoji
        self.name = name
        self.relatedEmoji = relatedEmoji
    }
}

/// Widget displaying a prominently rendered emoji with related emoji.
/// Tapping any emoji copies it to the clipboard.
struct EmojiWidgetView: View {
    let data: EmojiWidgetData

    var body: some View {
        VStack(spacing: 12) {
            // Large emoji — tap to copy
            Button {
                copyToClipboard(data.emoji)
            } label: {
                Text(data.emoji)
                    .font(.system(size: 60)) // Intentional fixed size — hero emoji display element
            }
            .buttonStyle(.plain)
            .help(String(format: String(localized: "Copy %@", bundle: .iClawCore), data.emoji))
            .accessibilityLabel(String(localized: "Copy emoji to clipboard", bundle: .iClawCore))

            // Name
            Text(data.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            // Related emoji — tap to copy
            if !data.relatedEmoji.isEmpty {
                Divider()
                    .opacity(0.2)

                HStack(spacing: 16) {
                    ForEach(Array(data.relatedEmoji.prefix(3).enumerated()), id: \.offset) { _, related in
                        Button {
                            copyToClipboard(related.emoji)
                        } label: {
                            VStack(spacing: 4) {
                                Text(related.emoji)
                                    .font(.title) // Emoji display element
                                Text(related.name)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(String(format: String(localized: "Copy %@", bundle: .iClawCore), related.emoji))
                        .accessibilityLabel(String(format: String(localized: "Copy %@", bundle: .iClawCore), related.emoji))
                    }
                }
            }
        }
        .padding(16)
        .glassContainer()
    }

    private func copyToClipboard(_ text: String) {
        ClipboardHelper.copy(text)
    }
}
