import SwiftUI

/// Widget displaying research summary text and scrollable source chips with favicons.
/// Each chip opens the source URL in the user's browser.
struct ResearchWidgetView: View {
    let data: ResearchWidgetData
    /// Finalized LLM summary text passed from the message content.
    var messageContent: String?

    var body: some View {
        if data.sources.isEmpty {
            Text("No sources found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .glassContainer(hasShadow: false)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Summary text from LLM finalization
                if let content = messageContent,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(markdownAttributed(content))
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }

                // Source chips header
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.caption) // SF Symbol sizing
                        .foregroundStyle(.secondary)
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "source_count", bundle: .iClawCore), data.sources.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, messageContent == nil ? 12 : 0)

                // Scrollable source chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(data.sources.enumerated()), id: \.offset) { index, source in
                            SourceChipView(source: source, index: index + 1)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 12)
            }
            .glassContainer(hasShadow: false)
            .frame(minWidth: 280, maxWidth: 380)
        }
    }

    private func markdownAttributed(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }
}

// MARK: - Source Chip

private struct SourceChipView: View {
    let source: ResearchSource
    let index: Int

    var body: some View {
        Button {
            if let url = URL(string: source.url) {
                URLOpener.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                // Citation number
                Text("[\(index)]")
                    .font(.caption2.weight(.bold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)

                // Favicon
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    default:
                        Image(systemName: "globe")
                            .font(.caption2) // SF Symbol sizing
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                    }
                }

                // Domain name
                Text(source.domain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(source.title)
        .accessibilityLabel(Text("[\(index)] \(source.title), \(source.domain)"))
    }

    private var faviconURL: URL? {
        guard !source.domain.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(source.domain).ico")
    }
}

#Preview("Research Widget") {
    ResearchWidgetView(
        data: ResearchWidgetData(
            topic: "quantum computing",
            sources: [
                ResearchSource(title: "Wikipedia: Quantum computing", url: "https://en.wikipedia.org/wiki/Quantum_computing", domain: "wikipedia.org", snippet: "Quantum computing is a type of computation..."),
                ResearchSource(title: "What Is Quantum Computing? - IBM", url: "https://www.ibm.com/topics/quantum-computing", domain: "ibm.com", snippet: "Quantum computing is a rapidly-emerging technology..."),
                ResearchSource(title: "Quantum Computing - MIT Technology Review", url: "https://www.technologyreview.com/quantum-computing", domain: "technologyreview.com", snippet: "The latest advances in quantum computing..."),
                ResearchSource(title: "Introduction to Quantum Computing - Nature", url: "https://www.nature.com/articles/quantum", domain: "nature.com", snippet: "A comprehensive introduction to quantum..."),
            ],
            iterationCount: 1
        ),
        messageContent: "Quantum computing leverages **quantum mechanics** to process information in fundamentally different ways than classical computers. Instead of bits (0 or 1), quantum computers use *qubits* that can exist in superposition — representing both states simultaneously."
    )
    .padding()
    .frame(width: 360)
}
