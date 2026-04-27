import Foundation

/// Extracts the primary entity from a tool execution result for display
/// in the context pill. Maps tool name + entities + input to a short
/// display string (e.g., "Paris", "AAPL", "John").
public enum PrimaryEntityExtractor {

    /// Extracts the most relevant entity to display for a given tool.
    public static func extract(
        toolName: String,
        entities: ExtractedEntities?,
        input: String
    ) -> String? {
        switch toolName {
        // Location-centric tools
        case "Weather", "Time", "Maps":
            return entities?.places.first

        // Stock tools
        case "Stocks":
            // Try ticker from input
            if let ticker = InputParsingUtilities.extractTickerSymbols(from: input).first {
                return ticker
            }
            return entities?.organizations.first

        // People-centric tools
        case "ReadEmail", "Email", "contacts", "messages":
            return entities?.names.first

        // Topic-centric tools
        case "News":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "News"))

        case "Podcast":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "Podcast"))

        case "Research":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "Research"))

        case "web_search":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "web_search"))

        case "wikipedia":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "wikipedia"))

        // Definition tools
        case "Dictionary":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "Dictionary"))

        // Translation
        case "Translate":
            let languages = ["spanish", "french", "german", "japanese", "korean",
                             "mandarin", "chinese", "italian", "arabic", "english"]
            let lower = input.lowercased()
            return languages.first { lower.contains($0) }?.capitalized

        // Timer
        case "Timer":
            let pattern = try? NSRegularExpression(pattern: "(\\d+\\s*(?:min|sec|hour|hr)\\w*)")
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            if let match = pattern?.firstMatch(in: input, options: [], range: range) {
                return (input as NSString).substring(with: match.range)
            }
            return nil

        // Convert
        case "Convert":
            let pattern = try? NSRegularExpression(pattern: "(\\d+\\s*\\w+)")
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            if let match = pattern?.firstMatch(in: input, options: [], range: range) {
                return (input as NSString).substring(with: match.range)
            }
            return nil

        // System control (app management)
        case "system_control":
            return extractTopic(from: input, prefixes: ToolManifest.prefixes(for: "system_control"))?
                .replacingOccurrences(of: " app", with: "")

        default:
            // Fall back to first place, then first person, then nil
            return entities?.places.first ?? entities?.names.first
        }
    }

    /// Maps tool names to SF Symbol icons.
    public static func icon(for toolName: String) -> String {
        ToolManifest.icon(for: toolName)
    }

    // MARK: - Private

    private static func extractTopic(from input: String, prefixes: [String]) -> String? {
        let lower = input.lowercased()
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                let remainder = String(input.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    // Cap at 30 chars for pill display
                    return String(remainder.prefix(30))
                }
            }
        }
        return nil
    }
}
