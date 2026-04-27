import Foundation

extension String {
    /// Splits into word tokens by non-alphanumeric characters, removing empty strings.
    /// Equivalent to `.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }`.
    var wordTokens: [String] {
        components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Splits into whitespace-separated tokens, removing empty strings.
    var whitespaceTokens: [String] {
        components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    /// Set of lowercased word tokens for overlap/intersection checks.
    var wordTokenSet: Set<String> {
        Set(wordTokens.map { $0.lowercased() })
    }
}
