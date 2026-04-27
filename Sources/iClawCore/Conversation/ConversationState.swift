import Foundation

/// Engine-managed structured conversation state.
///
/// Uses structured `Fact` objects for tool result memory (replacing truncated string
/// summaries) and progressive memory for long-term context. Token budget target: ~280
/// tokens typical, ~400 max.
public struct ConversationState: Codable, Sendable, Equatable {

    /// The last 3 discussion topics (extracted from user inputs).
    public var topics: [String]

    /// Active entities (people, places, orgs) still relevant to the conversation.
    public var activeEntities: [String]

    /// Structured facts from recent tool executions (replaces truncated summaries).
    /// Capped at 5 facts, ~10 tokens each = ~50 tokens total.
    public var recentFacts: [Fact]

    /// Legacy: truncated tool result summaries. Kept for backward compatibility
    /// with existing consumers during migration. New code should use `recentFacts`.
    public var recentToolResults: [ToolResultSummary]

    /// User preferences detected during the conversation (e.g., "unit_system": "metric").
    public var userPreferences: [String: String]

    /// Number of successful turns in this conversation.
    public var turnCount: Int

    /// Number of failed turns (errors, permission denials). Tracked separately
    /// so the LLM sees an accurate "Turn N" that reflects actual conversation depth,
    /// not noise from repeated failures.
    public var errorTurnCount: Int

    /// The last few (user input, assistant reply) exchanges, truncated.
    /// This is what lets the LLM answer follow-ups like "expand on the second
    /// paragraph" or "back to the recipe — oven temp?" — topic/entity/fact
    /// summaries alone don't carry enough context for those pivots.
    /// Capped to 3 exchanges × 240 chars each ≈ 360 tokens worst case.
    public var recentExchanges: [Exchange]

    /// Durable life facts declared by the user (name, age, dietary, family,
    /// location, work, preference). Populated by `UserFactClassifier` when
    /// Phase 5 wiring is ON and the classifier hits high confidence.
    /// Keyed by category so each fact has a single current value per kind.
    /// The value is the raw user statement, capped to 120 chars.
    public var userFacts: [UserFactEntry]

    /// A single recorded life fact. `category` mirrors `UserFactClassifier.Label`
    /// raw values — storing as String avoids a cross-module dependency from
    /// the state struct to the Classification layer.
    public struct UserFactEntry: Codable, Sendable, Equatable {
        public let category: String
        public let value: String
        public let recordedAt: Date
        public init(category: String, value: String, recordedAt: Date = Date()) {
            self.category = category
            self.value = value
            self.recordedAt = recordedAt
        }
    }

    /// A truncated (user, assistant) pair. Kept small so the `<ctx>` block
    /// stays within its token budget even at cap.
    public struct Exchange: Codable, Sendable, Equatable {
        public let user: String
        public let assistant: String
        public init(user: String, assistant: String) {
            self.user = user
            self.assistant = assistant
        }
    }

    public init(
        topics: [String] = [],
        activeEntities: [String] = [],
        recentFacts: [Fact] = [],
        recentToolResults: [ToolResultSummary] = [],
        userPreferences: [String: String] = [:],
        turnCount: Int = 0,
        errorTurnCount: Int = 0,
        recentExchanges: [Exchange] = [],
        userFacts: [UserFactEntry] = []
    ) {
        self.topics = topics
        self.activeEntities = activeEntities
        self.recentFacts = recentFacts
        self.recentToolResults = recentToolResults
        self.userPreferences = userPreferences
        self.turnCount = turnCount
        self.errorTurnCount = errorTurnCount
        self.userFacts = userFacts
        self.recentExchanges = recentExchanges
    }

    /// A compact summary of a tool execution result (legacy format).
    public struct ToolResultSummary: Codable, Sendable, Equatable {
        public let toolName: String
        public let summary: String

        public init(toolName: String, summary: String) {
            self.toolName = toolName
            self.summary = summary
        }
    }

    // MARK: - Mutation

    /// Records a new turn, updating topics, entities, facts, and legacy summaries.
    public mutating func recordTurn(
        userInput: String,
        entities: ExtractedEntities?,
        toolResults: [(toolName: String, summary: String)]
    ) {
        turnCount += 1

        // Extract topic from user input (first 60 chars, trimmed to last word boundary)
        let topic = extractTopic(from: userInput)
        if !topic.isEmpty {
            topics.append(topic)
            if topics.count > 3 { topics.removeFirst() }
        }

        // Merge new entities, dedup, and cap at 10.
        // New entities are prepended so prefix(10) favors recent ones.
        var newEntities: [String] = []
        if let ent = entities {
            newEntities.append(contentsOf: ent.places)
            newEntities.append(contentsOf: ent.names)
            newEntities.append(contentsOf: ent.organizations)
        }
        // Deduplicate while preserving recency order (newest first)
        var seen = Set<String>()
        var merged: [String] = []
        for entity in newEntities + activeEntities {
            let lower = entity.lowercased()
            if !seen.contains(lower) {
                seen.insert(lower)
                merged.append(entity)
            }
        }
        activeEntities = Array(merged.prefix(10))

        // Legacy: keep last 2 truncated summaries for backward compatibility
        let newSummaries = toolResults.map { ToolResultSummary(toolName: $0.toolName, summary: String($0.summary.prefix(200))) }
        recentToolResults.append(contentsOf: newSummaries)
        if recentToolResults.count > 2 {
            recentToolResults = Array(recentToolResults.suffix(2))
        }
    }

    /// Records structured facts from tool execution.
    /// Capped at 5 — excess facts are simply dropped here (FIFO).
    /// The authoritative eviction (with relevance scoring and summary folding)
    /// happens in ProgressiveMemoryManager, which is the single eviction authority.
    /// This avoids dual eviction strategies producing inconsistent state.
    public mutating func recordFacts(_ facts: [Fact]) {
        recentFacts.append(contentsOf: facts)
        if recentFacts.count > 5 {
            recentFacts = Array(recentFacts.suffix(5))
        }
    }

    /// Returns facts matching the given entity, or nil if no match.
    public func factsMatching(entity: String) -> [Fact] {
        let matches = recentFacts.filter { $0.matches(entity: entity) }
        return matches.isEmpty ? [] : matches
    }

    /// Updates preferences from a key-value pair.
    public mutating func setPreference(key: String, value: String) {
        userPreferences[key] = value
    }

    /// Records a (user input, assistant reply) exchange. Truncates each side
    /// to keep token usage bounded. Cap at 3 exchanges — more than that
    /// pushes the full conversation-context block over its budget.
    public mutating func recordExchange(user: String, assistant: String) {
        let userTrimmed = String(user.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let assistantTrimmed = String(assistant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !userTrimmed.isEmpty, !assistantTrimmed.isEmpty else { return }
        recentExchanges.append(Exchange(user: userTrimmed, assistant: assistantTrimmed))
        if recentExchanges.count > 3 {
            recentExchanges = Array(recentExchanges.suffix(3))
        }
    }

    /// Records a durable life fact. Each category holds a single current
    /// entry — a new declaration replaces the prior value (e.g. user
    /// corrects their age). Value is truncated to 120 chars.
    public mutating func recordUserFact(category: String, value: String) {
        let trimmed = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !trimmed.isEmpty else { return }
        // Remove any existing entry for this category so the new one wins.
        userFacts.removeAll { $0.category == category }
        userFacts.append(UserFactEntry(category: category, value: trimmed))
        // Cap total fact count to keep the <ctx> block bounded.
        if userFacts.count > 8 {
            userFacts = Array(userFacts.suffix(8))
        }
    }

    // MARK: - Serialization

    /// Serializes to compact JSON for injection into the system prompt.
    public func serialize() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Estimated token count of the serialized state.
    public var estimatedTokens: Int {
        AppConfig.estimateTokens(for: asPromptContext())
    }

    /// Formats the state as a human-readable context block for the LLM.
    public func asPromptContext() -> String {
        guard turnCount > 0 else { return "" }

        var parts: [String] = []

        if !recentExchanges.isEmpty {
            // Chronological order so the most-recent exchange is last.
            let lines = recentExchanges.map { "User: \($0.user)\nAssistant: \($0.assistant)" }
            parts.append("Recent exchange:\n" + lines.joined(separator: "\n"))
        }

        if !topics.isEmpty {
            parts.append("Recent topics: \(topics.joined(separator: ", "))")
        }
        if !activeEntities.isEmpty {
            parts.append("Active entities: \(activeEntities.joined(separator: ", "))")
        }

        // Use structured facts (preferred) or legacy summaries (fallback)
        if !recentFacts.isEmpty {
            let factLines = recentFacts.map { $0.compact() }
            parts.append("Recent data: \(factLines.joined(separator: " | "))")
        } else {
            for result in recentToolResults {
                parts.append("[\(result.toolName)] \(result.summary)")
            }
        }

        if !userPreferences.isEmpty {
            let prefs = userPreferences.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("Preferences: \(prefs)")
        }
        if !userFacts.isEmpty {
            let facts = userFacts.map { "\($0.category): \($0.value)" }.joined(separator: " | ")
            parts.append("About user: \(facts)")
        }
        parts.append("Turn: \(turnCount)")

        return parts.joined(separator: "\n")
    }

    // MARK: - Private

    private func extractTopic(from input: String) -> String {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 60 { return cleaned }
        let prefix = String(cleaned.prefix(60))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return prefix
    }
}
