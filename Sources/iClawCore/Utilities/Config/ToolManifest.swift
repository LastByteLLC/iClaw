import Foundation

/// Configuration for a persistent Mode that takes over routing.
public struct ModeConfig: Codable, Sendable {
    public let displayName: String
    public let systemPrompt: String
    public let allowedTools: [String]
    public let exitPhrases: [String]
    public let entryPhrases: [String]
    /// CSS-style hex color for the mode's background tint (e.g. "#FFCC00").
    public let tintColor: String?
}

/// Per-tool metadata loaded from ToolManifest.json.
/// Consolidates identity data that was previously scattered across
/// ToolSlotRegistry, PrimaryEntityExtractor, FMToolDescriptors, etc.
public struct ToolManifestEntry: Sendable, Decodable {
    public let category: String
    public let chipName: String?
    public let icon: String
    public let slots: [SlotEntry]?
    public let entityPrefixes: [String]?
    public let extractionSchema: String?
    public let modeConfig: ModeConfig?
    public let showsInUI: Bool?
    /// User-facing name for the context pill and UI. Falls back to the tool's
    /// registry key (e.g. "WikipediaSearch") when absent.
    public let displayName: String?
    /// Maximum execution time in seconds before the engine cancels the tool.
    /// Defaults to `AppConfig.defaultToolTimeout` when absent.
    public let timeout: Int?

    public struct SlotEntry: Sendable, Decodable {
        public let name: String
        public let type: String
    }
}

/// Central registry of tool metadata.
public enum ToolManifest {
    private struct Root: Decodable {
        let tools: [String: ToolManifestEntry]
    }

    /// All tool manifest entries, keyed by tool name.
    public static let entries: [String: ToolManifestEntry] = {
        guard let root = ConfigLoader.load("ToolManifest", as: Root.self) else {
            Log.tools.error("Failed to load ToolManifest.json")
            return [:]
        }
        return root.tools
    }()

    /// Look up a tool's manifest entry by name (case-insensitive).
    public static func entry(for toolName: String) -> ToolManifestEntry? {
        entries[toolName] ?? entries.first(where: { $0.key.lowercased() == toolName.lowercased() })?.value
    }

    /// Get the SF Symbol icon for a tool, with fallback.
    public static func icon(for toolName: String) -> String {
        entry(for: toolName)?.icon ?? "sparkles"
    }

    /// User-facing display name for a tool (e.g. "Wikipedia" instead of "WikipediaSearch").
    /// Falls back to the tool's registry key when no explicit displayName is set.
    public static func displayName(for toolName: String) -> String {
        entry(for: toolName)?.displayName ?? toolName
    }

    /// Get entity extraction prefixes for a tool.
    public static func prefixes(for toolName: String) -> [String] {
        entry(for: toolName)?.entityPrefixes ?? []
    }

    /// Whether a tool should appear in user-facing UI (context pill, chip dropdown).
    /// Omitted = `true` (visible). Infrastructure/FM-only tools return `false`.
    public static func showsInUI(for toolName: String) -> Bool {
        entry(for: toolName)?.showsInUI ?? true
    }

    /// Per-tool execution timeout in seconds. Falls back to the global default.
    public static func timeout(for toolName: String) -> Int {
        entry(for: toolName)?.timeout ?? AppConfig.defaultToolTimeout
    }

    /// Look up a mode by chip name. Returns (toolName, config) if matched.
    public static func modeForChip(_ chipName: String) -> (name: String, config: ModeConfig)? {
        let lower = chipName.lowercased()
        for (name, entry) in entries {
            guard let config = entry.modeConfig else { continue }
            if entry.chipName?.lowercased() == lower {
                return (name, config)
            }
        }
        return nil
    }

    /// Look up a mode by natural language phrase (substring match on entryPhrases).
    public static func modeForPhrase(_ input: String) -> (name: String, config: ModeConfig)? {
        let lower = input.lowercased()
        for (name, entry) in entries {
            guard let config = entry.modeConfig else { continue }
            for phrase in config.entryPhrases {
                if lower.contains(phrase.lowercased()) {
                    return (name, config)
                }
            }
        }
        return nil
    }

    /// All chip names that correspond to modes.
    public static var allModeChipNames: [String] {
        entries.compactMap { (_, entry) in
            entry.modeConfig != nil ? entry.chipName : nil
        }
    }
}
