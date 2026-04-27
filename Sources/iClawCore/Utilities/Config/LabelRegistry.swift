import Foundation

/// Maps compound ML labels (e.g., "email.read") to tool names and metadata.
/// Loaded from `Resources/Config/LabelRegistry.json`.
///
/// Compound labels use `domain.action` format. Flat labels (single tool per domain)
/// have no dot separator. The registry supports:
/// - Direct label → tool lookup (replaces ToolNameNormalizer.matches in ML path)
/// - Domain extraction for fallback disambiguation
/// - Consent policy per label
public enum LabelRegistry {

    /// Metadata for a single label→tool mapping.
    public struct Entry: Codable, Sendable {
        public let tool: String
        public let type: String // "core" or "fm"
        public let requiresConsent: Bool
    }

    /// The loaded registry: label → entry.
    static let entries: [String: Entry] = {
        ConfigLoader.load("LabelRegistry", as: [String: Entry].self) ?? [:]
    }()

    /// Look up a label and return its entry, or nil if unknown.
    public static func lookup(_ label: String) -> Entry? {
        entries[label]
    }

    /// Extract the domain from a compound label.
    /// "email.read" → "email", "weather" → "weather"
    public static func domain(of label: String) -> String {
        if let dot = label.firstIndex(of: ".") {
            return String(label[label.startIndex..<dot])
        }
        return label
    }

    /// Extract the action from a compound label.
    /// "email.read" → "read", "weather" → nil
    public static func action(of label: String) -> String? {
        guard let dot = label.firstIndex(of: ".") else { return nil }
        let afterDot = label.index(after: dot)
        guard afterDot < label.endIndex else { return nil }
        return String(label[afterDot...])
    }

    /// All labels that share the same domain.
    /// "email" → ["email.read", "email.compose", "email.search"]
    public static func siblings(of label: String) -> [String] {
        let dom = domain(of: label)
        return entries.keys.filter { domain(of: $0) == dom && $0 != label }
    }

    /// Whether a domain has multiple actions (compound labels).
    public static func isCompoundDomain(_ domain: String) -> Bool {
        let count = entries.keys.filter { self.domain(of: $0) == domain }.count
        return count > 1
    }

    /// All known labels.
    public static var allLabels: [String] {
        Array(entries.keys)
    }
}
