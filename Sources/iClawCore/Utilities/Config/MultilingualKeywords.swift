import Foundation
import NaturalLanguage

/// Loads per-language keyword lists from `Resources/Config/*.json` for tool-
/// internal intent detection. Replaces the scattered English `contains(...)`
/// gates across tool files (Maps, Podcast, Calendar, Random, etc.) that
/// silently bypass non-English inputs.
///
/// JSON shape:
/// ```
/// {
///   "intent_key_1": {
///     "en": ["keyword1", "keyword 2", ...],
///     "es": ["palabra1", ...],
///     "ja": ["キーワード1", ...]
///   },
///   "intent_key_2": { ... }
/// }
/// ```
///
/// Lookups detect the input's language via `NLLanguageRecognizer` and match
/// against that language's list, falling back to English when the detected
/// language isn't present in the JSON. Matching is case-insensitive
/// substring containment — callers that need word-boundary matching should
/// preprocess via `NLTokenizer` upstream.
public struct MultilingualKeywords: Sendable {

    public typealias Table = [String: [String: [String]]]

    private let table: Table
    private let configName: String

    /// Loads a config file from `Resources/Config/<name>.json`. Returns `nil`
    /// when the file is missing or can't be decoded.
    public static func load(_ name: String) -> MultilingualKeywords? {
        guard let table = ConfigLoader.load(name, as: Table.self) else {
            return nil
        }
        return MultilingualKeywords(table: table, configName: name)
    }

    private init(table: Table, configName: String) {
        self.table = table
        self.configName = configName
    }

    /// True iff `input` contains any keyword for the given intent in the
    /// input's detected language (fallback: English).
    public func matches(intent: String, in input: String) -> Bool {
        let keywords = keywordsFor(intent: intent, text: input)
        let lowered = input.lowercased()
        return keywords.contains { lowered.contains($0.lowercased()) }
    }

    /// Returns the first keyword that matches, or nil. Useful for span
    /// extraction when the caller wants to know WHICH keyword fired.
    public func firstMatch(intent: String, in input: String) -> String? {
        let keywords = keywordsFor(intent: intent, text: input)
        let lowered = input.lowercased()
        return keywords.first { lowered.contains($0.lowercased()) }
    }

    /// Returns every intent key that matched at least one of its keywords.
    public func matchingIntents(in input: String) -> Set<String> {
        var result: Set<String> = []
        for intent in table.keys where matches(intent: intent, in: input) {
            result.insert(intent)
        }
        return result
    }

    /// Word-exact containment for cases where substring matching is unsafe
    /// (e.g. "that" as a standalone anaphora marker — substring matching
    /// would false-positive on "thatch"). Tokenizes `input` using
    /// `NLTokenizer(unit: .word)` for proper multilingual word splitting.
    ///
    /// Keywords containing whitespace (e.g. "mensaje a", "message à") are
    /// treated as phrases and matched via substring containment, since the
    /// word-boundary check would split them across tokens.
    public func containsAnyAsWord(intent: String, in input: String) -> Bool {
        guard let langMap = table[intent] else { return false }
        let detected = detectLanguage(from: input)?.rawValue ?? "en"
        let keywords = langMap[detected] ?? langMap["en"] ?? []
        guard !keywords.isEmpty else { return false }

        let lowered = input.lowercased()
        var singleWord: Set<String> = []
        var phrases: [String] = []
        for keyword in keywords {
            let lower = keyword.lowercased()
            if lower.contains(" ") {
                phrases.append(lower)
            } else {
                singleWord.insert(lower)
            }
        }

        for phrase in phrases where lowered.contains(phrase) { return true }
        guard !singleWord.isEmpty else { return false }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = input
        var hit = false
        tokenizer.enumerateTokens(in: input.startIndex..<input.endIndex) { range, _ in
            let token = String(input[range]).lowercased()
            if singleWord.contains(token) {
                hit = true
                return false
            }
            return true
        }
        return hit
    }

    /// Returns all keyword strings registered under `intent` for the
    /// language detected from `text`, with English fallback. Callers that
    /// need the full list (e.g. to compute ordinal index) use this.
    public func keywords(for intent: String, in text: String) -> [String] {
        keywordsFor(intent: intent, text: text)
    }

    // MARK: - Private

    private func keywordsFor(intent: String, text: String) -> [String] {
        guard let langMap = table[intent] else { return [] }
        let detected = detectLanguage(from: text)?.rawValue ?? "en"
        if let list = langMap[detected], !list.isEmpty {
            return list
        }
        // Fallback chain: detected → English → any-available.
        if let list = langMap["en"], !list.isEmpty { return list }
        return langMap.values.flatMap { $0 }
    }

    private func detectLanguage(from text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        // Short English phrases with Spanish-looking tokens ("roll dice", "flip a coin")
        // regularly get mis-detected as Spanish or Italian at low confidence.
        // Require a dominant-language probability ≥0.7 before trusting detection;
        // below that, fall back to English. This keeps strong-signal multilingual
        // routing intact (Spanish "lanza un dado" at ~0.95, Japanese at ~0.99) while
        // stopping the 2026-04 "roll dice" regression (es @ 0.45, en @ 0.14).
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let score = hypotheses[dominant] ?? 0
        if score < 0.7 {
            return nil
        }
        return dominant
    }
}
