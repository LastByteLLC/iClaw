import Foundation
import OSLog

/// Manages conversational memory using structured state and progressive fact compression.
///
/// Three-tier memory model:
/// - Tier 1: Working facts (5 slots, ~50 tokens) — entity-anchored, scored by relevance
/// - Tier 2: Running summary (~80 tokens) — incremental fold of evicted facts
/// - Tier 3: Vector archive (NLEmbedding cosine similarity, 0 working tokens) — evicted facts embedded for recall
///
/// This replaces the old approach of 2 truncated 200-char summaries (~300 tokens)
/// with structured facts + summary (~130 tokens), saving ~170 tokens for agent headroom.
public actor ConversationManager {
    private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "ConversationManager")

    /// The structured conversation state, updated deterministically by the engine.
    private(set) public var state: ConversationState = ConversationState()

    /// Progressive memory manager (Tier 1 + Tier 2).
    private let memory: ProgressiveMemoryManager

    /// LLM responder for testing — if nil, uses LLMAdapter.shared.
    private let llmResponder: ((String) async throws -> String)?

    public init(
        initialState: String = "",
        llmResponder: ((String) async throws -> String)? = nil,
        memory: ProgressiveMemoryManager? = nil
    ) {
        self.llmResponder = llmResponder
        self.memory = memory ?? ProgressiveMemoryManager(
            summaryFolder: { existing, fact in
                // LLM-based incremental fold: merge fact into running summary
                let prompt = """
                Current summary: "\(existing)"
                New fact to incorporate: "\(fact.compact())"
                Merge the new fact into the summary. Preserve all numbers, prices, \
                measurements, and names. Keep it under 30 words. Output only the merged summary.
                """
                // Fact folding — stable greedy summarization under 60 tokens.
                return try await LLMAdapter.shared.generateText(prompt, profile: .summarization)
            },
            archiveHandler: { fact in
                // Archive to vector store for future recall
                let content = "\(fact.tool): \(fact.compact())"
                let memory = Memory(role: "fact", content: content, created_at: fact.timestamp, is_important: false)
                do {
                    _ = try await DatabaseManager.shared.saveMemory(memory)
                } catch {
                    Log.engine.debug("Failed to archive fact: \(error)")
                }
            }
        )
    }

    // MARK: - Structured State API

    /// Records a completed turn into the structured state, with fact compression.
    public func recordTurn(
        userInput: String,
        entities: ExtractedEntities?,
        toolResults: [(toolName: String, summary: String)]
    ) {
        state.recordTurn(userInput: userInput, entities: entities, toolResults: toolResults)
    }

    /// Records a (user, assistant) exchange for verbatim recall on the next
    /// turn. Called after the engine has produced the final user-facing text
    /// so the assistant side reflects what the user actually saw.
    public func recordExchange(userInput: String, assistantReply: String) {
        state.recordExchange(user: userInput, assistant: assistantReply)
    }

    /// Records a durable user fact detected by `UserFactClassifier`.
    /// Replaces any existing fact in the same category so corrections win.
    public func recordUserFact(category: String, value: String) {
        state.recordUserFact(category: category, value: value)
    }

    /// Records structured facts from tool execution into progressive memory.
    public func recordFacts(_ facts: [Fact]) async {
        state.recordFacts(facts)
        await memory.recordFacts(facts, activeEntities: state.activeEntities)
    }

    /// Updates a user preference (key-value).
    public func setPreference(key: String, value: String) {
        state.setPreference(key: key, value: value)
    }

    /// Returns the structured state's estimated token cost for adaptive budgeting.
    public var stateTokenCost: Int {
        get async {
            state.estimatedTokens + (await memory.estimatedTokens)
        }
    }

    /// Returns facts matching the given entities from working memory (Tier 1).
    /// Returns nil if no match — caller should fall back to vector search (Tier 3).
    public func factsMatching(entities: [String]) -> [Fact]? {
        let stateFacts = state.recentFacts.filter { fact in
            entities.contains(where: { fact.matches(entity: $0) })
        }
        return stateFacts.isEmpty ? nil : stateFacts
    }

    // MARK: - Prompt Assembly

    /// Assembles the context including structured state, progressive memory, and retrieved data.
    public func preparePrompt(userInput: String, retrievedChunks: [String]) async -> String {
        var components: [String] = []

        // 1. Structured conversation state
        let stateContext = state.asPromptContext()
        if !stateContext.isEmpty {
            components.append("## CONVERSATION_STATE\n\(stateContext)")
        }

        // 2. Progressive memory context (Tier 2 running summary)
        let memoryContext = await memory.asPromptContext()
        if !memoryContext.isEmpty {
            components.append("## MEMORY\n\(memoryContext)")
        }

        // 3. Retrieved Context
        if !retrievedChunks.isEmpty {
            components.append("## RETRIEVED_CONTEXT\n" + retrievedChunks.joined(separator: "\n---\n"))
        }

        // 4. User Input
        components.append("## USER_INPUT\n\(userInput)")

        return components.joined(separator: "\n\n")
    }

    /// Legacy: no-op since state is engine-managed.
    public func appendStateGenerationInstruction(to originalPrompt: String) -> String {
        return originalPrompt
    }

    /// Returns the full conversation context for injection into the next prompt.
    public func conversationContext() async -> String? {
        var parts: [String] = []

        let stateContext = state.asPromptContext()
        if !stateContext.isEmpty {
            parts.append(stateContext)
        }

        let memoryContext = await memory.asPromptContext()
        if !memoryContext.isEmpty {
            parts.append(memoryContext)
        }

        if let profileCtx = await profileContext() {
            parts.append(profileCtx)
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Returns minimal context for pivot turns (different tool, no follow-up).
    /// Strips prior topics, data, and facts to prevent context poisoning.
    /// Retains turn count, user preferences, and profile for baseline coherence.
    public func minimalContext() async -> String? {
        var parts: [String] = []

        if state.turnCount > 0 {
            parts.append("Turn: \(state.turnCount)")
        }

        // Preserve user preferences across pivots (unit system, language, etc.)
        if !state.userPreferences.isEmpty {
            let prefs = state.userPreferences.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("Preferences: \(prefs)")
        }

        if let profileCtx = await profileContext() {
            parts.append(profileCtx)
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Increments the error turn count without recording topics or data.
    /// Used for failed turns to avoid polluting state with stale topics.
    /// Error turns are tracked separately so the LLM sees accurate conversation depth.
    public func incrementTurnCount() {
        state.errorTurnCount += 1
    }

    /// Cached profile context with TTL. Refreshed per-turn and invalidated after 5 minutes
    /// to pick up mid-conversation profile changes.
    private var cachedProfileContext: String?
    private var profileCacheTimestamp: Date = .distantPast
    private static let profileCacheTTL: TimeInterval = 300 // 5 minutes

    /// Refreshes the cached profile context from UserProfileManager.
    public func refreshProfileContext() async {
        cachedProfileContext = await UserProfileManager.shared.profileContext()
        profileCacheTimestamp = Date()
    }

    /// Returns the cached profile context, refreshing if stale.
    private func profileContext() async -> String? {
        if Date().timeIntervalSince(profileCacheTimestamp) > Self.profileCacheTTL {
            await refreshProfileContext()
        }
        return cachedProfileContext
    }

    /// Resets the conversation memory, including progressive memory tiers
    /// and the vector archive. Prevents stale Tier 3 memories from surfacing
    /// in a fresh conversation.
    public func reset() async {
        self.state = ConversationState()
        await memory.reset()
        // Clear archived facts from the vector store so stale memories
        // don't leak into the new conversation.
        do {
            try await DatabaseManager.shared.clearFactMemories()
        } catch {
            Log.engine.debug("Failed to clear fact memories on reset: \(error)")
        }
    }
}
