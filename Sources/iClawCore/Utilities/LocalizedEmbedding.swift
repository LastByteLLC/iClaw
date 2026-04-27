import Foundation
import NaturalLanguage

/// Language-aware wrapper over `NLEmbedding.sentenceEmbedding` /
/// `.wordEmbedding` calls. Replaces the scattered unconditional
/// `NLEmbedding.sentenceEmbedding(for: .english)` sites audited in Phase 0.
///
/// Why this matters: non-English inputs fed through English embeddings
/// produce bad vectors. Meta-query detection, help-topic dispatch, prior-turn
/// reference matching, and extractive summarization all previously loaded
/// `.english` unconditionally, silently bypassing their purpose for Spanish,
/// French, Japanese, etc.
///
/// Strategy:
/// 1. Caller supplies a language OR omits and we detect/default.
/// 2. We attempt the exact language.
/// 3. If unsupported (NLEmbedding has a smaller coverage set than NLTagger),
///    we fall back to English — but the caller knows via `languageUsed` so
///    they can decide whether the match is trustworthy.
/// 4. Loaded embeddings are cached per-language (they're ~200 MB on first
///    load; re-loading per call would be catastrophic).
///
/// Thread-safe via actor.
public actor LocalizedEmbedding {

    public static let shared = LocalizedEmbedding()

    /// A sentence or word embedding plus the language it was actually built
    /// for. `requestedLanguage` may differ from `languageUsed` when the
    /// requested language isn't supported by `NLEmbedding` — callers can then
    /// decide whether to degrade similarity thresholds or skip the path.
    public struct Loaded: @unchecked Sendable {
        public let embedding: NLEmbedding
        public let requestedLanguage: NLLanguage
        public let languageUsed: NLLanguage
        public var isFallback: Bool { requestedLanguage != languageUsed }
    }

    /// Languages Apple's `NLEmbedding.sentenceEmbedding(for:)` supports on
    /// macOS 26. This list is *probed* — we try to load each once at first
    /// use; missing languages fall through to English automatically.
    private var sentenceCache: [NLLanguage: NLEmbedding] = [:]
    private var wordCache: [NLLanguage: NLEmbedding] = [:]

    /// Languages we've confirmed are unavailable via `NLEmbedding`. Cached so
    /// we don't re-probe on every call.
    private var sentenceUnavailable: Set<NLLanguage> = []
    private var wordUnavailable: Set<NLLanguage> = []

    private init() {}

    // MARK: - Public API

    /// Returns a sentence embedding for the given language. When `nil`, uses
    /// the system language, falling back to English if that's unsupported.
    /// Returns `nil` only when English itself fails to load (extremely rare).
    public func sentence(for language: NLLanguage? = nil) -> Loaded? {
        let requested = language ?? Self.systemLanguage()
        return loadSentence(requested: requested)
    }

    /// Returns a word embedding for the given language. Same fallback chain.
    public func word(for language: NLLanguage? = nil) -> Loaded? {
        let requested = language ?? Self.systemLanguage()
        return loadWord(requested: requested)
    }

    /// Returns the system language as an `NLLanguage`, defaulting to English
    /// when the locale's language code isn't representable.
    public nonisolated static func systemLanguage() -> NLLanguage {
        guard let code = Locale.current.language.languageCode?.identifier else {
            return .english
        }
        return NLLanguage(rawValue: code)
    }

    /// Synchronous, non-caching variant for call sites that can't cross the
    /// actor boundary (sync static helpers in the summarizer, help-topic
    /// seed loading, tool-internal intent detection). Detects language and
    /// loads the matching `NLEmbedding`, falling back to English on any
    /// miss. Does NOT participate in the shared actor's per-language cache
    /// — callers that hit this repeatedly should migrate to the async
    /// `sentence(for:)` to get caching benefits.
    public nonisolated static func sentenceEmbeddingSync(for text: String) -> NLEmbedding? {
        let lang = detectLanguage(from: text) ?? systemLanguage()
        return NLEmbedding.sentenceEmbedding(for: lang)
            ?? NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// Same as `sentenceEmbeddingSync(for:)` but for an explicit language.
    public nonisolated static func sentenceEmbeddingSync(forLanguage language: NLLanguage) -> NLEmbedding? {
        NLEmbedding.sentenceEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// Convenience helper: detect the language of `text` (via
    /// `NLLanguageRecognizer`) and return the matching embedding. Falls back
    /// to the system language when detection confidence is too low.
    public func sentence(detectedFrom text: String) -> Loaded? {
        let language = Self.detectLanguage(from: text) ?? Self.systemLanguage()
        return sentence(for: language)
    }

    public func word(detectedFrom text: String) -> Loaded? {
        let language = Self.detectLanguage(from: text) ?? Self.systemLanguage()
        return word(for: language)
    }

    // MARK: - Language Detection

    /// Returns the dominant language of `text` when the recognizer reports
    /// hypothesis probability ≥ 0.5. Returns `nil` otherwise (caller should
    /// fall back to a session-sticky or system-locale default).
    public nonisolated static func detectLanguage(from text: String, minConfidence: Double = 0.5) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (lang, prob) = hypotheses.first, prob >= minConfidence else {
            return nil
        }
        return lang
    }

    // MARK: - Loader

    private func loadSentence(requested: NLLanguage) -> Loaded? {
        // Probe the exact language first.
        if let cached = sentenceCache[requested] {
            return Loaded(embedding: cached, requestedLanguage: requested, languageUsed: requested)
        }
        if !sentenceUnavailable.contains(requested),
           let model = NLEmbedding.sentenceEmbedding(for: requested) {
            sentenceCache[requested] = model
            return Loaded(embedding: model, requestedLanguage: requested, languageUsed: requested)
        }
        sentenceUnavailable.insert(requested)
        // Fall back to English.
        if requested != .english {
            if let cached = sentenceCache[.english] {
                return Loaded(embedding: cached, requestedLanguage: requested, languageUsed: .english)
            }
            if let fallback = NLEmbedding.sentenceEmbedding(for: .english) {
                sentenceCache[.english] = fallback
                return Loaded(embedding: fallback, requestedLanguage: requested, languageUsed: .english)
            }
        }
        return nil
    }

    private func loadWord(requested: NLLanguage) -> Loaded? {
        if let cached = wordCache[requested] {
            return Loaded(embedding: cached, requestedLanguage: requested, languageUsed: requested)
        }
        if !wordUnavailable.contains(requested),
           let model = NLEmbedding.wordEmbedding(for: requested) {
            wordCache[requested] = model
            return Loaded(embedding: model, requestedLanguage: requested, languageUsed: requested)
        }
        wordUnavailable.insert(requested)
        if requested != .english {
            if let cached = wordCache[.english] {
                return Loaded(embedding: cached, requestedLanguage: requested, languageUsed: .english)
            }
            if let fallback = NLEmbedding.wordEmbedding(for: .english) {
                wordCache[.english] = fallback
                return Loaded(embedding: fallback, requestedLanguage: requested, languageUsed: .english)
            }
        }
        return nil
    }
}
