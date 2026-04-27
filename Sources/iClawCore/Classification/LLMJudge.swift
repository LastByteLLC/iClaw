import Foundation

/// Slow-path classification fallback used when a MaxEnt classifier's
/// confidence lands in the `.medium` tier (0.60–0.85). Asks the on-device
/// LLM a classifier-shaped question with a one-word answer.
///
/// Budget:
///   • 20–40 output tokens per judge call.
///   • Result cached by input hash so repeat calls are O(1).
///
/// The judge does NOT replace the MaxEnt classifier — it supplements it.
/// Callers pick an answer in priority order:
///   1. Classifier `.high` confidence → act on classifier label.
///   2. Classifier `.medium` confidence → ask judge; act on judge label.
///   3. Classifier `.low` or nil → fall through to legacy heuristics.
///
/// Dependency-injected `responder` allows tests to stub the LLM call. When
/// `responder` is `nil`, the real `LLMAdapter.shared` is used.
///
/// Feature-flag gated by `AppConfig.useLLMJudgeKey` at the caller level —
/// this actor itself is always safe to instantiate.
///
/// Cache scope: per-actor (in-memory). Cleared on app restart. That's fine
/// for judgments because they depend on on-device model state which doesn't
/// persist either.
public actor LLMJudge {

    public static let shared = LLMJudge()

    private var cache: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheCapacity: Int

    public init(cacheCapacity: Int = 256) {
        self.cacheCapacity = cacheCapacity
    }

    /// Returns the count of entries currently cached — visible so tests can
    /// assert cache behavior without reflection.
    public var cachedEntryCount: Int { cache.count }

    /// Clears the in-memory cache. Useful after switching LLM backends or
    /// when label taxonomies change mid-session.
    public func clearCache() {
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    // MARK: - Judge calls (one per classifier)

    /// Resolves a `ConversationIntentClassifier.Label` via LLM. Returns
    /// `nil` when the LLM response can't be parsed to a known label.
    public func judgeIntent(
        input: String,
        classifierHint: ConversationIntentClassifier.Result? = nil,
        responder: SimpleLLMResponder? = nil
    ) async -> ConversationIntentClassifier.Label? {
        let prompt = Self.buildIntentPrompt(input: input, hint: classifierHint)
        let key = CacheKey(kind: .intent, inputHash: prompt)
        if let cached = cache[key] {
            touch(key)
            return ConversationIntentClassifier.Label(rawValue: cached)
        }
        guard let raw = await generate(prompt: prompt, responder: responder),
              let label = Self.parseIntentLabel(raw) else {
            return nil
        }
        store(key: key, value: label.rawValue)
        return label
    }

    /// Resolves a `ResponsePathologyClassifier.Label` via LLM.
    public func judgePathology(
        response: String,
        classifierHint: ResponsePathologyClassifier.Result? = nil,
        responder: SimpleLLMResponder? = nil
    ) async -> ResponsePathologyClassifier.Label? {
        let prompt = Self.buildPathologyPrompt(response: response, hint: classifierHint)
        let key = CacheKey(kind: .pathology, inputHash: prompt)
        if let cached = cache[key] {
            touch(key)
            return ResponsePathologyClassifier.Label(rawValue: cached)
        }
        guard let raw = await generate(prompt: prompt, responder: responder),
              let label = Self.parsePathologyLabel(raw) else {
            return nil
        }
        store(key: key, value: label.rawValue)
        return label
    }

    /// Resolves a `UserFactClassifier.Label` via LLM.
    public func judgeUserFact(
        input: String,
        classifierHint: UserFactClassifier.Result? = nil,
        responder: SimpleLLMResponder? = nil
    ) async -> UserFactClassifier.Label? {
        let prompt = Self.buildUserFactPrompt(input: input, hint: classifierHint)
        let key = CacheKey(kind: .userFact, inputHash: prompt)
        if let cached = cache[key] {
            touch(key)
            return UserFactClassifier.Label(rawValue: cached)
        }
        guard let raw = await generate(prompt: prompt, responder: responder),
              let label = Self.parseUserFactLabel(raw) else {
            return nil
        }
        store(key: key, value: label.rawValue)
        return label
    }

    // MARK: - Generation

    private func generate(prompt: String, responder: SimpleLLMResponder?) async -> String? {
        do {
            if let responder {
                return try await responder(prompt)
            }
            // Live path: use shared LLMAdapter with a tight token cap + low
            // temperature for deterministic one-word answers.
            return try await LLMAdapter.shared.generateText(
                prompt, temperature: 0.0, maxTokens: 10, sampling: .greedy
            )
        } catch {
            Log.engine.debug("LLMJudge generate failed: \(error)")
            return nil
        }
    }

    // MARK: - Cache

    /// Key = (kind, exact prompt). Prompt is deterministic for a given input
    /// so identical inputs hit the cache.
    private struct CacheKey: Hashable {
        enum Kind: Hashable { case intent, pathology, userFact }
        let kind: Kind
        let inputHash: String
    }

    private func store(key: CacheKey, value: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        // LRU eviction by insertion order.
        while cacheOrder.count > cacheCapacity {
            let victim = cacheOrder.removeFirst()
            cache.removeValue(forKey: victim)
        }
    }

    private func touch(_ key: CacheKey) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(key)
        }
    }

    // MARK: - Prompt Templates

    /// Emits a compact prompt that asks the LLM for a single-word answer
    /// from the fixed label set. Each label is quoted so the LLM learns to
    /// match exactly one.
    static func buildIntentPrompt(
        input: String,
        hint: ConversationIntentClassifier.Result?
    ) -> String {
        var lines = [
            "Classify the user's message into exactly ONE of these categories:",
            "- tool_action: user wants a specific tool/action (weather, math, calendar, stocks, etc.)",
            "- knowledge: factual question the assistant can answer from general knowledge",
            "- conversation: chat, opinion, creative, emotional, advice",
            "- refinement: user is transforming the assistant's PREVIOUS reply",
            "- meta: user is asking about the assistant ITSELF",
            "",
        ]
        if let hint {
            let top3 = hint.hypotheses.prefix(3).map { "\($0.label.rawValue) (\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
            lines.append("Classifier hint: \(top3).")
        }
        lines.append("Message: \(input)")
        lines.append("")
        lines.append("Answer with one word only — one of: tool_action, knowledge, conversation, refinement, meta.")
        return lines.joined(separator: "\n")
    }

    static func buildPathologyPrompt(
        response: String,
        hint: ResponsePathologyClassifier.Result?
    ) -> String {
        var lines = [
            "Classify this LLM output into exactly ONE quality category:",
            "- ok: a usable response that answers the user",
            "- refusal: reflexively declines a benign request",
            "- meta_leak: leaks a template preamble or bracket tag",
            "- empty_stub: vague or one-word without substance",
            "- instruction_echo: regurgitates prompt structure",
            "- pure_ingredient_echo: dumps raw tool output without synthesis",
            "",
        ]
        if let hint {
            let top3 = hint.hypotheses.prefix(3).map { "\($0.label.rawValue) (\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
            lines.append("Classifier hint: \(top3).")
        }
        lines.append("LLM output: \(response)")
        lines.append("")
        lines.append("Answer with one word: ok, refusal, meta_leak, empty_stub, instruction_echo, or pure_ingredient_echo.")
        return lines.joined(separator: "\n")
    }

    static func buildUserFactPrompt(
        input: String,
        hint: UserFactClassifier.Result?
    ) -> String {
        var lines = [
            "Does the user's message declare a durable life fact about themselves? If so, which kind?",
            "- none: no life fact (default)",
            "- self_identity: name, age, pronouns, birthday",
            "- dietary: vegetarian, vegan, allergy, dietary restriction",
            "- family: kids, partner, pets, household",
            "- location_fact: where the user lives / is based",
            "- work_fact: job, profession, employer",
            "- preference: persistent interaction preference (units, language, style)",
            "",
        ]
        if let hint {
            let top3 = hint.hypotheses.prefix(3).map { "\($0.label.rawValue) (\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
            lines.append("Classifier hint: \(top3).")
        }
        lines.append("Message: \(input)")
        lines.append("")
        lines.append("Answer with one word: none, self_identity, dietary, family, location_fact, work_fact, or preference.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Label Parsing

    /// Parses a one-word LLM answer into an intent label. Tolerant of extra
    /// whitespace, trailing punctuation, quotes, and case. Returns `nil`
    /// when the answer doesn't map to a known label.
    static func parseIntentLabel(_ raw: String) -> ConversationIntentClassifier.Label? {
        let normalized = normalizeAnswer(raw)
        for label in ConversationIntentClassifier.Label.allCases {
            if normalized.contains(label.rawValue) { return label }
        }
        return nil
    }

    static func parsePathologyLabel(_ raw: String) -> ResponsePathologyClassifier.Label? {
        let normalized = normalizeAnswer(raw)
        // Check two-word labels first (meta_leak, empty_stub, etc.) so their
        // substrings don't falsely match a shorter label.
        let sorted = ResponsePathologyClassifier.Label.allCases
            .sorted { $0.rawValue.count > $1.rawValue.count }
        for label in sorted {
            if normalized.contains(label.rawValue) { return label }
        }
        return nil
    }

    static func parseUserFactLabel(_ raw: String) -> UserFactClassifier.Label? {
        let normalized = normalizeAnswer(raw)
        let sorted = UserFactClassifier.Label.allCases
            .sorted { $0.rawValue.count > $1.rawValue.count }
        for label in sorted {
            if normalized.contains(label.rawValue) { return label }
        }
        return nil
    }

    /// Normalizes an LLM answer for label matching.
    static func normalizeAnswer(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:\"'`*"))
    }
}
