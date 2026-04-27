import Foundation

/// Loads per-tool help content from `ToolHelp.json` and provides
/// tool name matching for natural language help queries.
public enum ToolHelpProvider: Sendable {

    private struct HelpEntry: Decodable, Sendable {
        let description: String
        let examples: [String]
    }

    private static let entries: [String: HelpEntry] = {
        ConfigLoader.load("ToolHelp", as: [String: HelpEntry].self) ?? [:]
    }()

    /// Returns the help content for a tool by name (case-insensitive).
    public static func help(for toolName: String) -> (description: String, examples: [String])? {
        let entry = entries[toolName]
            ?? entries.first(where: { $0.key.lowercased() == toolName.lowercased() })?.value
        guard let entry else { return nil }
        return (entry.description, entry.examples)
    }

    /// Scans the input for a known tool name or chip name.
    /// Returns the canonical tool name if found, nil otherwise.
    /// Matches are case-insensitive and prefer longer matches to avoid
    /// partial hits (e.g., "maps" inside "remaps").
    public static func toolName(matchingInput input: String) -> String? {
        let lower = input.lowercased()
        let words = lower.wordTokenSet

        // Build a lookup of chip names → tool names and tool names → tool names
        var candidates: [(name: String, matchWord: String)] = []

        for (toolName, manifestEntry) in ToolManifest.entries {
            // Match by chip name (e.g., "weather", "stocks", "wiki")
            if let chip = manifestEntry.chipName {
                candidates.append((toolName, chip.lowercased()))
            }
            // Match by tool name (e.g., "Weather", "Calculator")
            candidates.append((toolName, toolName.lowercased()))
        }

        // Sort by match word length descending to prefer longer matches
        candidates.sort { $0.matchWord.count > $1.matchWord.count }

        for candidate in candidates {
            if words.contains(candidate.matchWord) {
                return candidate.name
            }
        }

        return nil
    }
}
