import SwiftUI

/// Compact card view for a single conversation search result.
struct SearchResultView: View {
    let result: ConversationSearchResult
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Timestamp and badge
            HStack {
                Text(result.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if result.userMessage.role == "system" {
                    Text("Summary", bundle: .iClawCore)
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                if result.matchedRole != "user" {
                    Text("matched in \(result.matchedRole)", bundle: .iClawCore)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // User message
            if result.userMessage.role != "system" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(result.userMessage.content)
                        .font(.callout)
                        .lineLimit(isExpanded ? nil : 2)
                        .foregroundStyle(.primary)
                }
            } else {
                // System/compacted memory
                Text(result.userMessage.content)
                    .font(.callout)
                    .italic()
                    .lineLimit(isExpanded ? nil : 2)
                    .foregroundStyle(.primary.opacity(0.8))
            }

            // Agent response
            if let agent = result.agentMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text(agent.content)
                        .font(.callout)
                        .lineLimit(isExpanded ? nil : 2)
                        .foregroundStyle(.secondary)
                }
            }

            // FTS5 snippet highlight (if different from displayed content)
            if let snippet = result.snippet, !isExpanded {
                Text(highlightedSnippet(snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .glassContainer(cornerRadius: 12, hasShadow: false)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(isExpanded
            ? String(localized: "Double-tap to collapse", bundle: .iClawCore)
            : String(localized: "Double-tap to expand", bundle: .iClawCore))
        .onTapGesture {
            withAnimation(.snappy) {
                isExpanded.toggle()
            }
        }
    }

    /// A meaningful one-line summary of the search hit for VoiceOver:
    /// "Search result: <user message snippet> — iClaw: <agent reply snippet>".
    private var accessibilitySummary: String {
        let userSnippet = String(result.userMessage.content.prefix(80))
        let agentSnippet = String((result.agentMessage?.content ?? "").prefix(80))
        return String(
            format: String(localized: "Search result: %@ — iClaw: %@", bundle: .iClawCore),
            userSnippet, agentSnippet
        )
    }

    /// Convert FTS5 `[[...]]` markers to an AttributedString with bold highlights.
    private func highlightedSnippet(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var remaining = snippet[...]

        while let openRange = remaining.range(of: "[[") {
            // Text before marker
            let before = remaining[remaining.startIndex..<openRange.lowerBound]
            result.append(AttributedString(before))

            remaining = remaining[openRange.upperBound...]

            if let closeRange = remaining.range(of: "]]") {
                var highlighted = AttributedString(remaining[remaining.startIndex..<closeRange.lowerBound])
                highlighted.font = .callout.bold()
                highlighted.foregroundColor = .primary
                result.append(highlighted)
                remaining = remaining[closeRange.upperBound...]
            }
        }
        // Append any trailing text
        result.append(AttributedString(remaining))
        return result
    }
}
