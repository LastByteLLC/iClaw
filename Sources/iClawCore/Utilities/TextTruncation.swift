import Foundation

/// Reusable truncation strategies for the 4K token budget.
///
/// Consolidates the three truncation approaches used across the codebase:
/// - Head+tail (ContentCompactor): preserves beginning and end
/// - Oldest-entry drop (ProgressiveMemory): removes oldest semicolon-delimited entries
/// - Token-bounded prefix (OutputFinalizer): cuts at token budget with ellipsis
public enum TextTruncation {

    /// Truncates text to fit a token budget by dropping the oldest semicolon-delimited
    /// entries from the front. Preserves complete entries rather than cutting mid-sentence.
    ///
    /// Used by ProgressiveMemory for running summary management.
    public static func dropOldestEntries(_ text: String, maxTokens: Int) -> String {
        var result = text
        while AppConfig.estimateTokens(for: result) > maxTokens {
            if let semicolonRange = result.range(of: "; ") {
                result = String(result[semicolonRange.upperBound...])
            } else {
                // Single entry exceeds budget — prefix truncate as last resort
                return prefixTruncate(result, maxTokens: maxTokens)
            }
        }
        return result
    }

    /// Truncates text to fit a token budget by taking a prefix and appending "…".
    /// Uses word-level token estimation for the budget check.
    public static func prefixTruncate(_ text: String, maxTokens: Int) -> String {
        guard AppConfig.estimateTokens(for: text) > maxTokens else { return text }
        // Approximate: 4 chars per token (conservative for prefix cut)
        let charLimit = maxTokens * 4
        let prefix = String(text.prefix(charLimit))
        // Cut at last word boundary
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

    /// Head+tail truncation preserving both the beginning and end of content.
    /// `headRatio` controls the split (default 0.75 = 75% head, 15% tail, 10% gap).
    public static func headTail(_ text: String, maxChars: Int, headRatio: Double = 0.75) -> String {
        guard text.count > maxChars else { return text }
        let headChars = Int(Double(maxChars) * headRatio)
        let tailChars = Int(Double(maxChars) * (1.0 - headRatio - 0.10))
        let head = String(text.prefix(headChars))
        let tail = String(text.suffix(tailChars))
        return "\(head)\n\n[…truncated…]\n\n\(tail)"
    }
}
