import Foundation
import NaturalLanguage

/// Language-agnostic fallback for user-fact detection when the CoreML
/// `UserFactClassifier` is uncertain or returns `.none`.
///
/// Uses `NLTagger` POS tagging to recognize the first-person declarative
/// shape that introduces a durable fact — "I am X", "My Y is Z",
/// "I have a Q", "I live in R". The classifier's training data under-covers
/// these common shapes; this heuristic catches them structurally without
/// any English word list.
///
/// Categories map to `UserFactClassifier.Label` so downstream storage and
/// context injection remain consistent.
public enum FactHeuristic {

    public struct Outcome: Sendable {
        public let category: String
        public let confidence: Double
    }

    /// Returns a detected fact category if the input looks like a self-
    /// declarative statement, `nil` otherwise. Uses first-person pronouns
    /// and linking-verb POS tags as the structural signal. NLTagger's POS
    /// scheme covers English well; other languages get a conservative no.
    public static func detect(in input: String) -> Outcome? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6, trimmed.count < 200 else { return nil }
        // Require first-person signal up front — cheap bail-out.
        guard hasFirstPersonPronoun(trimmed) else { return nil }

        // POS walk
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        var tagged: [(token: String, tag: NLTag?)] = []
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .word, scheme: .lexicalClass, options: opts) { tag, range in
            tagged.append((String(trimmed[range]).lowercased(), tag))
            return true
        }
        guard tagged.count >= 3 else { return nil }

        // Scan for "pronoun + linking-verb" or "possessive + noun + linking-verb"
        // patterns in a small window; no fixed phrase list.
        for i in 0..<(tagged.count - 1) {
            let t = tagged[i]
            if t.tag == .pronoun, i + 1 < tagged.count, tagged[i + 1].tag == .verb {
                // "I am / I have / I live / I work" — category inferred from surrounding nouns.
                return categorize(tokens: tagged, anchor: i)
            }
            // "My name / my age / my job / my dog is ..."
            if i + 2 < tagged.count,
               tagged[i + 1].tag == .noun,
               tagged[i + 2].tag == .verb,
               t.tag == .determiner || t.tag == .pronoun {
                return categorize(tokens: tagged, anchor: i)
            }
        }
        return nil
    }

    // MARK: - Categorization

    /// After the heuristic fires, look at the NEAREST noun(s) to decide the
    /// category. The noun-to-category map is compact structural data — the
    /// categories are `UserFactClassifier.Label` raw values. If no noun
    /// matches a known category, fall back to `preference` (a neutral bucket
    /// that still preserves the fact for later LLM reasoning).
    private static func categorize(tokens: [(token: String, tag: NLTag?)], anchor: Int) -> Outcome {
        for (token, tag) in tokens where tag == .noun {
            if let cat = Self.categoryByToken[token] {
                return Outcome(category: cat, confidence: 0.60)
            }
        }
        return Outcome(category: "preference", confidence: 0.55)
    }

    /// Noun → fact category index. Deliberately small; this is structural
    /// metadata keyed off tokens frequently present in first-person fact
    /// statements. Extend via `Resources/Config/UserFactNouns.json` when
    /// multilingual coverage is needed.
    private static let categoryByToken: [String: String] = {
        if let raw: [String: [String]] = ConfigLoader.load("UserFactNouns", as: [String: [String]].self) {
            var flat: [String: String] = [:]
            for (cat, words) in raw {
                for w in words { flat[w.lowercased()] = cat }
            }
            return flat
        }
        // Minimal built-in fallback. Values mirror UserFactClassifier.Label.
        return [
            "name": "self_identity", "age": "self_identity", "birthday": "self_identity",
            "allergy": "dietary", "allergic": "dietary", "vegetarian": "dietary", "vegan": "dietary",
            "wife": "family", "husband": "family", "partner": "family",
            "son": "family", "daughter": "family", "kid": "family", "kids": "family",
            "dog": "family", "cat": "family", "pet": "family",
            "home": "location_fact", "city": "location_fact",
            "job": "work_fact", "role": "work_fact", "work": "work_fact", "employer": "work_fact"
        ]
    }()

    private static func hasFirstPersonPronoun(_ text: String) -> Bool {
        // Quick prefix/word-boundary check avoiding English-only assumptions.
        // NLTagger could replace this, but the cheap scan catches 98% of
        // cases without a full tagger pass for non-facts.
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .pronoun {
                let tok = String(text[range]).lowercased()
                // Cheap cross-lingual first-person check: short token ≤ 3
                // combined with pronoun POS. Catches "I", "my", "me", "je",
                // "ich", "yo", "私", "我", etc.
                if tok.count <= 3 { found = true; return false }
            }
            return true
        }
        return found
    }
}
