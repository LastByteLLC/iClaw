import Foundation

/// Centralizes tool name normalization, replacing 14+ repetitions of
/// `name.lowercased().replacingOccurrences(of: " ", with: "_")`.
enum ToolNameNormalizer {
    /// Lowercase with spaces replaced by underscores: "Web Fetch" → "web_fetch"
    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    /// Lowercase with all separators removed: "Web Fetch" → "webfetch"
    static func normalizeStripped(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    /// Returns true if either normalized form matches.
    static func matches(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b) || normalizeStripped(a) == normalizeStripped(b)
    }
}
