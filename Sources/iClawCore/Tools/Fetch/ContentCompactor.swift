import Foundation

/// Cleans and truncates fetched web content to fit within the 4K token context window.
/// Target budget: ~2000 tokens ≈ 8000 characters for retrieved data chunks (per AppConfig).
public enum ContentCompactor {

    /// Default character limit for compacted content (~2000 tokens).
    public static let defaultLimit = 8000

    /// Clean and truncate text content for LLM consumption.
    /// - Parameters:
    ///   - text: Raw text from a fetch backend.
    ///   - limit: Maximum character count. Defaults to `defaultLimit`.
    /// - Returns: Cleaned, truncated text.
    public static func compact(_ text: String, limit: Int = defaultLimit) -> String {
        var result = text

        // 1. Remove zero-width and invisible Unicode characters
        result = stripInvisibleChars(result)

        // 2. Normalize whitespace
        result = normalizeWhitespace(result)

        // 3. Remove common web boilerplate lines
        result = stripBoilerplate(result)

        // 4. Truncate with head + tail preservation
        result = truncate(result, limit: limit)

        return result
    }

    /// Clean text without truncation (for search results that are already short).
    public static func clean(_ text: String) -> String {
        var result = stripInvisibleChars(text)
        result = normalizeWhitespace(result)
        return result
    }

    // MARK: - Processing stages

    /// Remove zero-width spaces, BOM, soft hyphens, and other invisible chars.
    /// Works at the Unicode scalar level since ZWJ and other combining chars
    /// merge into grapheme clusters at the Character level.
    static func stripInvisibleChars(_ text: String) -> String {
        let invisibles: Set<Unicode.Scalar> = [
            "\u{200B}", // Zero-width space
            "\u{200C}", // Zero-width non-joiner
            "\u{200D}", // Zero-width joiner
            "\u{FEFF}", // BOM / zero-width no-break space
            "\u{00AD}", // Soft hyphen
            "\u{200E}", // Left-to-right mark
            "\u{200F}", // Right-to-left mark
            "\u{202A}", // Left-to-right embedding
            "\u{202B}", // Right-to-left embedding
            "\u{202C}", // Pop directional formatting
            "\u{2060}", // Word joiner
            "\u{2061}", // Function application
            "\u{2062}", // Invisible times
            "\u{2063}", // Invisible separator
        ]
        var scalars = text.unicodeScalars
        scalars.removeAll(where: { invisibles.contains($0) })
        return String(scalars)
    }

    /// Collapse runs of whitespace and blank lines.
    static func normalizeWhitespace(_ text: String) -> String {
        var result = text

        // Replace tabs with spaces
        result = result.replacingOccurrences(of: "\t", with: " ")

        // Collapse multiple spaces to single space (single-pass regex)
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

        // Collapse 3+ consecutive newlines to 2
        let lines = result.components(separatedBy: "\n")
        var compacted: [String] = []
        var blankCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankCount += 1
                if blankCount <= 1 { compacted.append("") }
            } else {
                blankCount = 0
                compacted.append(trimmed)
            }
        }

        return compacted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let boilerplatePatterns: [String] = ConfigLoader.loadStringArray("BoilerplatePatterns")

    /// Remove common web boilerplate lines (cookie notices, nav text, etc.).
    static func stripBoilerplate(_ text: String) -> String {

        let lines = text.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            // Remove lines that are entirely boilerplate
            if lower.count < 80 {
                return !boilerplatePatterns.contains(where: { lower.contains($0) })
            }
            return true
        }
        return filtered.joined(separator: "\n")
    }

    /// Truncate to limit, preserving beginning and end of content.
    /// Keeps first 75% + last 15% of the budget with a separator.
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }

        let headSize = Int(Double(limit) * 0.75)
        let tailSize = Int(Double(limit) * 0.15)
        let separator = "\n\n[... content truncated ...]\n\n"

        let head = String(text.prefix(headSize))
        let tail = String(text.suffix(tailSize))
        return head + separator + tail
    }
}
