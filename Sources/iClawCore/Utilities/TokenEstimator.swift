import Foundation

/// Word-level token estimator for Apple Foundation Models.
///
/// Replaces the simple `char / 4` heuristic with a word-aware approach inspired by
/// BM25 tokenization (see ShellTalk's BM25.swift). Handles content-type differences:
/// - English prose: ~1.3 tokens per word (BPE splits long/rare words)
/// - CJK characters: ~1 token per character
/// - Punctuation/symbols: ~1 token per 2 marks
///
/// Conservative by design — overestimates slightly to prevent context overflow in
/// the 4K token budget. Accuracy target: ±30% (vs ±300% for char/4 on CJK).
public enum TokenEstimator {

    /// Estimates token count using word-level heuristics.
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        let scalars = text.unicodeScalars

        var wordCount = 0
        var inWord = false
        var cjkCount = 0
        var punctCount = 0

        for scalar in scalars {
            if isCJK(scalar) {
                cjkCount += 1
                inWord = false
            } else if scalar.properties.isWhitespace || scalar.value == 0x0A /* \n */ {
                inWord = false
            } else {
                if !inWord {
                    wordCount += 1
                    inWord = true
                }
                if isPunctuation(scalar) {
                    punctCount += 1
                }
            }
        }

        // English/Latin words: ~1.3 tokens per word (BPE splits long/rare words)
        // CJK characters: ~1 token per character
        // Punctuation: ~1 token per 2 punctuation marks (most are single-char tokens,
        // but some merge with adjacent content)
        let wordTokens = Int(Double(wordCount) * 1.3)
        let cjkTokens = cjkCount
        let punctTokens = max(0, punctCount / 2)
        let estimated = wordTokens + cjkTokens + punctTokens

        // Safety floor for single-word pathological blobs. A 15000-character
        // string with zero whitespace estimates at 1.3 tokens under the
        // word-count model, which defeats prompt-budget checks. The char/4
        // heuristic is a reasonable upper bound — use whichever is larger so
        // the token budget catches oversized inputs regardless of shape.
        let charBasedFallback = text.count / 4
        return max(1, max(estimated, charBasedFallback))
    }

    // MARK: - Character Classification

    /// CJK Unified Ideographs + Hiragana + Katakana + Hangul Syllables
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0x3040 && v <= 0x309F)     // Hiragana
            || (v >= 0x30A0 && v <= 0x30FF)     // Katakana
            || (v >= 0xAC00 && v <= 0xD7AF)     // Hangul Syllables
            || (v >= 0x3400 && v <= 0x4DBF)     // CJK Extension A
            || (v >= 0xF900 && v <= 0xFAFF)     // CJK Compatibility Ideographs
    }

    /// Punctuation and symbol characters that typically become individual tokens.
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation,
             .connectorPunctuation, .dashPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
