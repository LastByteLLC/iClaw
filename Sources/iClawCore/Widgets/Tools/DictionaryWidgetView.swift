import SwiftUI

struct DictionaryWidgetView: View {
    let data: DictionaryWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: word + phonetic + open in Dictionary
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    openInDictionary(word: data.word)
                } label: {
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Look up in Dictionary", bundle: .iClawCore))
                .accessibilityLabel(String(localized: "Look up in Dictionary", bundle: .iClawCore))

                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        openInDictionary(word: data.word)
                    } label: {
                        Text(data.word.capitalized)
                            .font(.system(.title2, design: .serif, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Look up in Dictionary", bundle: .iClawCore))
                    .accessibilityLabel(String(localized: "Look up in Dictionary", bundle: .iClawCore))

                    if !data.phonetic.isEmpty {
                        Text(data.phonetic)
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Spell correction notice
            if let original = data.correctedFrom {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Corrected from '\(original)'", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            // Definition text
            Text(cleanDefinition(data.definition))
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(minWidth: 220, maxWidth: 340, alignment: .leading)
        .glassContainer()
        .copyable("\(data.word): \(data.definition)")
    }

    private func openInDictionary(word: String) {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        if let url = URL(string: "dict://\(encoded)") {
            URLOpener.open(url)
        }
    }

    /// Cleans up the raw DCS definition for display.
    /// Removes the leading "word pho·net·ic | ... |" prefix since we show those separately.
    private func cleanDefinition(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "|")
        if parts.count >= 3 {
            // Everything after the second pipe is the definition body
            let body = parts.dropFirst(2).joined(separator: "|")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body }
        }
        // Fallback: strip the word prefix if present
        let word = data.word.lowercased()
        if raw.lowercased().hasPrefix(word) {
            let stripped = String(raw.dropFirst(word.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return stripped }
        }
        return raw
    }
}
