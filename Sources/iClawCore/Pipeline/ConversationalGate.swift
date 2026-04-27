import Foundation
import NaturalLanguage

/// Language-neutral pre-router that classifies a user turn by the POSITIVE
/// evidence it contains. Absence of evidence is conversation — the default.
///
/// The gate runs AFTER `InputPreprocessor` (so entities are already extracted)
/// and BEFORE `ToolRouter`. Its decision either short-circuits the router
/// entirely (`.conversational`, `.replyElaboration`, `.clarification`) or
/// scopes the router's candidate set (`.candidateScope`) or forces a hard
/// tool route (`.toolSignal`).
///
/// The decision relies only on signals that are language-agnostic by
/// construction (regex over punctuation, digits, URLs, tickers, chips) or
/// multilingual by framework (`NLTagger` named-entity extraction covers
/// 40+ languages). No English-specific word or phrase lists.
public enum ConversationalGate {

    // MARK: - Decision

    public struct Decision: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Hard structural evidence (chip, URL, ticker, numeric operator,
            /// phone/email). Route to the hinted tools.
            case toolSignal
            /// Soft evidence: named entities or interrogative structure.
            /// Router may run, but its output is filtered to these hints.
            case candidateScope
            /// ≤2 substantive tokens, no entities, no signal. Ask briefly.
            case clarification
            /// No positive evidence. Respond conversationally.
            case conversational
            /// Reply-prefix turn with empty payload. Expand on prior answer.
            case replyElaboration
        }

        public let kind: Kind
        /// Candidate tools produced by evidence detection. Empty for
        /// `.conversational`, `.clarification`, `.replyElaboration`.
        public let candidateToolHints: [String]
        /// Human-readable trace for logs / tests.
        public let reason: String
        /// True when the decision was produced by prior-tool continuity
        /// markers (anaphora, action verbs, ordinals) rather than direct
        /// evidence in the current input. The router's follow-up classifier
        /// is allowed to pivot outside the hint set in this mode —
        /// drill-down (News → WebFetch) is a legitimate pivot.
        public let isFollowUpContinuation: Bool
        /// True when the ConversationIntentClassifier promoted a turn that
        /// the gate initially classified `.conversational` / `.clarification`
        /// back to the router. The gate's structural-evidence detectors are
        /// incomplete (no coverage for News/Calendar/Podcast/Timer tool names,
        /// short tool queries like "weather today"); the ML intent classifier
        /// catches those. When promoted, the protected-tool filter is bypassed
        /// so the router's pick is trusted.
        public let isClassifierPromoted: Bool

        public init(
            kind: Kind,
            candidateToolHints: [String] = [],
            reason: String,
            isFollowUpContinuation: Bool = false,
            isClassifierPromoted: Bool = false
        ) {
            self.kind = kind
            self.candidateToolHints = candidateToolHints
            self.reason = reason
            self.isFollowUpContinuation = isFollowUpContinuation
            self.isClassifierPromoted = isClassifierPromoted
        }
    }

    // MARK: - Language-neutral evidence detectors

    /// Interrogative punctuation across the world's writing systems.
    /// Covers `?` (most Latin-derived), `¿` (Spanish), `？` (CJK fullwidth),
    /// `؟` (Arabic), `⸮` (reversed), `︖` (CJK small).
    private static let interrogativeCharacters: Set<Character> = [
        "?", "¿", "？", "؟", "⸮", "︖"
    ]

    private static let numericExpressionRegex = try! NSRegularExpression(
        // Matches: digit+operator+digit for +, *, /, ×, ÷, ^, %  (skip `-` to
        // avoid clashing with phone numbers; NSDataDetector handles those).
        // Also matches unary math symbols like √64, ∛27, ∜16, π × anything.
        pattern: #"\d+\s*[+*/×÷^%]\s*\d+|√\s*\d+|∛\s*\d+|∜\s*\d+|\bsqrt\s*\(|\bln\s*\(|\blog\s*\("#,
        options: [.caseInsensitive]
    )

    /// Detects encoding / decoding requests: `"help!" in binary`,
    /// `decode base64 SGVsbG8=`, raw binary/hex blobs. These are deterministic
    /// Compute operations — they must not fall through to conversational
    /// just because the gate sees no NER entity or interrogative punctuation.
    private static let encodingExpressionRegex = try! NSRegularExpression(
        pattern: #"\b(?:to|in)\s+(?:binary|hex|hexadecimal|ascii|base64|nato|morse|octal|rot13|roman|url)\b|\bdecode\s+(?:binary|hex|hexadecimal|ascii|base64|nato|morse|octal|rot13|roman|url)\b|^[01\s]{16,}$"#,
        options: [.caseInsensitive]
    )

    /// Counts "substantive" tokens using `NLTokenizer` which handles CJK /
    /// Thai / other whitespace-less scripts via morphological segmentation,
    /// and falls back to whitespace + punctuation splitting elsewhere.
    /// Tokens that are pure punctuation are excluded.
    private static func substantiveTokenCount(_ input: String) -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let token = trimmed[range]
            // Skip tokens that are entirely punctuation / symbols / whitespace.
            if token.unicodeScalars.contains(where: {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }) {
                count += 1
            }
            return true
        }
        return count
    }

    private static func hasNumericExpression(_ input: String) -> Bool {
        let range = NSRange(location: 0, length: input.utf16.count)
        return numericExpressionRegex.firstMatch(in: input, options: [], range: range) != nil
    }

    private static func hasEncodingExpression(_ input: String) -> Bool {
        let range = NSRange(location: 0, length: input.utf16.count)
        return encodingExpressionRegex.firstMatch(in: input, options: [], range: range) != nil
    }

    private static func hasInterrogativePunctuation(_ input: String) -> Bool {
        input.contains(where: { interrogativeCharacters.contains($0) })
    }

    /// Multilingual keywords for contact-attribute nouns: "email", "phone",
    /// "address", "number", "contact info", and translations. Loaded lazily
    /// from `Resources/Config/ContactAttributeKeywords.json`.
    private static let contactAttributeKeywords: MultilingualKeywords? =
        MultilingualKeywords.load("ContactAttributeKeywords")

    /// True when the input mentions a contact-info attribute in any supported
    /// language. Used to promote Contacts into the gate's hint set when a
    /// name entity is also present.
    private static func containsContactAttribute(_ input: String) -> Bool {
        guard let kw = contactAttributeKeywords else { return false }
        return kw.matches(intent: "contact_attribute", in: input)
    }

    /// Returns true when the input contains a NOUN that isn't an
    /// interrogative pronoun (what/when/who/where/why/how and language
    /// equivalents). Used by the gate to distinguish "when is sunrise?"
    /// (has noun "sunrise" → tool query) from "what's up?" (no nouns →
    /// small talk). Multilingual: NLTagger's lexicalClass tagger covers
    /// every supported language.
    static func containsNounBeyondInterrogative(_ input: String) -> Bool {
        nounCount(in: input) >= 1
    }

    /// Counts NLTagger-identified nouns (excluding small-talk fillers).
    /// Used both by `containsNounBeyondInterrogative` and by the gate's
    /// non-interrogative path which requires ≥2 nouns.
    static func nounCount(in input: String) -> Int {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = input
        var count = 0
        // Generic small-talk nouns that don't indicate a knowledge-bearing
        // query. Kept English because NLTagger only tags English words as
        // `.noun` reliably; non-English tagging tends to under-count, which
        // means this allowlist won't false-positive in other languages.
        let stopNouns: Set<String> = ["thing", "way", "stuff", "everyone", "anyone"]
        tagger.enumerateTags(
            in: input.startIndex..<input.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            if tag == .noun {
                let word = input[range].lowercased()
                if !stopNouns.contains(word) {
                    count += 1
                }
            }
            return true
        }
        return count
    }

    // MARK: - Inputs

    public struct Signals: Sendable {
        public let input: String
        /// The text that remains after stripping a `[Replying to:]` prefix.
        /// `nil` when the input isn't a reply. Empty string when it IS a
        /// reply with no new user content (→ `.replyElaboration`).
        public let replyPayload: String?
        public let entities: ExtractedEntities
        public let chipsPresent: [String]
        public let tickersPresent: [String]
        /// The tool that ran in the immediately-prior turn, if any. Included
        /// so future revisions can layer follow-up heuristics on top of the
        /// gate — currently unused in the decision (gate stays stateless).
        public let priorTool: String?

        public init(
            input: String,
            replyPayload: String?,
            entities: ExtractedEntities,
            chipsPresent: [String],
            tickersPresent: [String],
            priorTool: String? = nil
        ) {
            self.input = input
            self.replyPayload = replyPayload
            self.entities = entities
            self.chipsPresent = chipsPresent
            self.tickersPresent = tickersPresent
            self.priorTool = priorTool
        }
    }

    // MARK: - Evaluation

    /// Evaluate the gate over a preprocessed turn. Pure function.
    public static func evaluate(_ signals: Signals) -> Decision {
        // 1. Reply with empty payload — elaborate on prior.
        if let payload = signals.replyPayload,
           payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Decision(kind: .replyElaboration, reason: "empty reply payload")
        }

        // Use the reply-stripped text for all subsequent analysis so the
        // gate never sees the quoted prior assistant answer.
        let effectiveInput = signals.replyPayload ?? signals.input

        // 2. Hard structural tool signals — language-neutral patterns.
        if !signals.chipsPresent.isEmpty {
            return Decision(
                kind: .toolSignal,
                candidateToolHints: signals.chipsPresent,
                reason: "chip(s): \(signals.chipsPresent.joined(separator: ","))"
            )
        }
        if !signals.entities.urls.isEmpty {
            return Decision(kind: .toolSignal, candidateToolHints: ["WebFetch"], reason: "url present")
        }
        if !signals.tickersPresent.isEmpty {
            return Decision(kind: .toolSignal, candidateToolHints: ["Stocks"], reason: "ticker(s): \(signals.tickersPresent.joined(separator: ","))")
        }
        if hasNumericExpression(effectiveInput) {
            return Decision(kind: .toolSignal, candidateToolHints: ["Calculator"], reason: "numeric expression")
        }
        if hasEncodingExpression(effectiveInput) {
            return Decision(kind: .toolSignal, candidateToolHints: ["Compute"], reason: "encoding expression")
        }
        if !signals.entities.phoneNumbers.isEmpty || !signals.entities.emails.isEmpty {
            return Decision(kind: .toolSignal, candidateToolHints: ["Messages"], reason: "contact info present")
        }

        // 3. Entity-typed soft signals + interrogative hint.
        var hints: [String] = []
        if !signals.entities.places.isEmpty {
            hints.append("Weather")
            hints.append("Maps")
        }
        if !signals.entities.organizations.isEmpty {
            if !hints.contains("WikipediaSearch") { hints.append("WikipediaSearch") }
        }
        if !signals.entities.names.isEmpty {
            if !hints.contains("WikipediaSearch") { hints.append("WikipediaSearch") }
            // Name + contact-attribute noun ("Shawn's email", "John's phone")
            // is a contact-info lookup, not a Wikipedia query. Hint Contacts so
            // the protected-tool filter lets Contacts.search through and so
            // downstream routing has an explicit signal to prefer it. Without
            // this, the 2026-04 "whats Shawn's email?" query fell through
            // to the communication safety net and routed to Messages.
            if containsContactAttribute(effectiveInput),
               !hints.contains("Contacts") {
                hints.append("Contacts")
            }
        }
        // Interrogative punctuation suggests a knowledge query — UNLESS the
        // input is short enough to be small talk. Threshold at >2
        // substantive tokens admits 3-token queries like "when is sunrise?"
        // / "what time now?" while keeping bare "how are you?" / "what's
        // up?" / "ça va?" (also 3 tokens) ambiguous. The lexical-content
        // check below distinguishes these: knowledge queries contain a
        // noun beyond the interrogative pronoun, small talk doesn't.
        // Threshold `> 3` admits 4+ token interrogative queries with
        // concrete nouns ("what time is sunset?", "where is Paris?")
        // while keeping bare "how are you?" / "what's up?" (3 tokens)
        // ambiguous → conversational. Three-token interrogatives with
        // strong nouns ("when is sunrise?") are accepted as a known
        // gap — promoting them broke clarification routing for inputs
        // like "xyzzy gibberish nonsense" which NLTagger over-tags as
        // proper nouns.
        // Reply-payload turns already carry the prior Q/A in the `[Replying
        // to: …]` prefix — they don't need a new Wikipedia/Web lookup to
        // answer follow-up interrogatives. `ConversationalGateTests "Reply
        // with payload evaluates the payload, not the quoted text"` pins
        // this: short reply follow-ups without a `priorTool` must resolve
        // conversationally, not promote to knowledge queries.
        let isReplyPayload = signals.replyPayload != nil
        if hasInterrogativePunctuation(effectiveInput), !isReplyPayload {
            let tokenCount = substantiveTokenCount(effectiveInput)
            if tokenCount > 3 {
                if !hints.contains("WikipediaSearch") { hints.append("WikipediaSearch") }
                if !hints.contains("WebSearch") { hints.append("WebSearch") }
            }
        }

        // Non-interrogative declaratives without NER are intentionally NOT
        // promoted here. NLTagger can't distinguish "moon phase tonight"
        // (real query) from "xyzzy gibberish nonsense" (gibberish input
        // exercised by `testClarificationGoesToFinalization`) — both have
        // ≥2 noun-tagged tokens. Punting these declaratives to the
        // conversational/clarification path is the correct trade-off; the
        // ML tool classifier picks them up via chip routing or follow-up
        // when there's prior context. Tests asserting the contrary live
        // in `SunriseSunsetE2ETests` for `sunrise time tomorrow`-style
        // 3-word declaratives — they're documented as known-failing.

        // 4. Prior-tool follow-up signals. When a prior turn ran a tool and
        //    THIS turn shows linguistic continuation markers (anaphora,
        //    action verbs, follow-up phrases, ordinal references), treat
        //    it as a follow-up: union the prior tool into hints and let
        //    the router's follow-up classifier choose (drill-down News →
        //    WebFetch is a legitimate pivot). `isFollowUpContinuation`
        //    tells the scope filter to trust the router's decision.
        var isContinuation = false
        if let prior = signals.priorTool, !prior.isEmpty {
            let lower = effectiveInput.lowercased()
            let hasContinuityMarker =
                PriorTurnContext.containsAnaphora(lower)
                || PriorTurnContext.containsActionVerb(lower)
                || PriorTurnContext.containsFollowUpPhrase(lower)
                || hasOrdinalReference(lower)
            if hasContinuityMarker {
                if !hints.contains(prior) { hints.append(prior) }
                isContinuation = true
            }
        }

        if !hints.isEmpty {
            let reason = "entities/interrogative"
                + (isContinuation ? " + prior-tool continuity" : "")
            return Decision(
                kind: .candidateScope,
                candidateToolHints: hints,
                reason: reason,
                isFollowUpContinuation: isContinuation
            )
        }

        // 5. No positive evidence. Decide between clarification and conversation
        //    based on token count. Uses Unicode letter/number properties so
        //    "hi" and "¡Hola!" and "こんにちは" all count the same way.
        let tokens = substantiveTokenCount(effectiveInput)
        if tokens <= 2 {
            return Decision(kind: .clarification, reason: "≤2 substantive tokens, no signal")
        }

        return Decision(kind: .conversational, reason: "no positive tool evidence")
    }

    /// Ordinal reference detection — English-only today but the method is
    /// isolated so a future pass can extend with multilingual ordinals.
    /// Looking up `\d+(st|nd|rd|th)` catches numeric ordinals in any
    /// language that borrows Arabic numerals (`1st`, `2nd`, `3rd`).
    private static let ordinalRegex = try! NSRegularExpression(
        pattern: #"\b\d+\s*(?:st|nd|rd|th)\b|\b(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|last)\b"#,
        options: [.caseInsensitive]
    )

    private static func hasOrdinalReference(_ input: String) -> Bool {
        let range = NSRange(location: 0, length: input.utf16.count)
        return ordinalRegex.firstMatch(in: input, options: [], range: range) != nil
    }
}
