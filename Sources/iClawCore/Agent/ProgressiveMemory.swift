import Foundation

/// Three-tier progressive memory manager for the 4K token context window.
///
/// Replaces the old approach (2 truncated tool result summaries @ ~300 tokens)
/// with structured facts + incremental summary + vector archival:
///
/// Tier 1: Working Facts (5 slots, ~50-60 tokens)
///         Evicted by recency + entity overlap scoring.
/// Tier 2: Running Summary (~80 tokens)
///         Incremental fold: each evicted fact is merged in.
/// Tier 3: Vector Archive (NLEmbedding cosine similarity, 0 working tokens)
///         Evicted facts are embedded + stored for future recall.
///
/// Token budget: ~140 tokens total (was ~300), saving ~160 tokens for agent headroom.
public actor ProgressiveMemoryManager {

    /// Maximum facts in working memory (Tier 1).
    private let maxFacts: Int

    /// Maximum token estimate for the running summary (Tier 2).
    private let maxSummaryTokens: Int

    /// Current working facts (Tier 1).
    private(set) public var workingFacts: [Fact] = []

    /// Incremental running summary of evicted facts (Tier 2).
    private(set) public var runningSummary: String = ""

    /// LLM responder for summary folding (injectable for tests).
    public typealias SummaryFolder = @Sendable (String, Fact) async throws -> String
    private let summaryFolder: SummaryFolder?

    /// Callback for archiving evicted facts to the vector store (Tier 3).
    public typealias ArchiveHandler = @Sendable (Fact) async -> Void
    private let archiveHandler: ArchiveHandler?

    public init(
        maxFacts: Int = 5,
        maxSummaryTokens: Int = 80,
        summaryFolder: SummaryFolder? = nil,
        archiveHandler: ArchiveHandler? = nil
    ) {
        self.maxFacts = maxFacts
        self.maxSummaryTokens = maxSummaryTokens
        self.summaryFolder = summaryFolder
        self.archiveHandler = archiveHandler
    }

    /// Records new facts from a tool execution, evicting old ones as needed.
    /// Contradiction detection: if a new fact has the same tool + overlapping key
    /// as an existing fact but a different value, the old fact is replaced in-place
    /// rather than appended. Prevents stale data accumulation (e.g., two different
    /// weather readings for the same city).
    public func recordFacts(_ newFacts: [Fact], activeEntities: [String]) async {
        for newFact in newFacts {
            if let existingIndex = workingFacts.firstIndex(where: { newFact.contradicts($0) }) {
                workingFacts[existingIndex] = newFact
            } else {
                workingFacts.append(newFact)
            }
        }
        await evict(activeEntities: activeEntities)
    }

    /// Returns facts matching the given entities, checking Tier 1 first.
    /// If no Tier 1 match, returns nil (caller should check vector store).
    public func factsMatching(entities: [String]) -> [Fact]? {
        let matches = workingFacts.filter { fact in
            entities.contains(where: { fact.matches(entity: $0) })
        }
        return matches.isEmpty ? nil : matches
    }

    /// Formats the current memory state for LLM context injection.
    /// Targets ~140 tokens total.
    public func asPromptContext() -> String {
        var parts: [String] = []

        if !runningSummary.isEmpty {
            parts.append("Prior: \(runningSummary)")
        }

        if !workingFacts.isEmpty {
            let factLines = workingFacts.map { $0.compact() }
            parts.append("Recent: \(factLines.joined(separator: " | "))")
        }

        return parts.joined(separator: "\n")
    }

    /// Estimated token cost of the current memory state.
    public var estimatedTokens: Int {
        AppConfig.estimateTokens(for: asPromptContext())
    }

    /// Resets all memory tiers.
    public func reset() {
        workingFacts = []
        runningSummary = ""
    }

    // MARK: - Eviction

    /// Evicts lowest-relevance facts when over capacity.
    /// Evicted facts are folded into the running summary and archived.
    private func evict(activeEntities: [String]) async {
        guard workingFacts.count > maxFacts else { return }

        // Score all facts
        let scored = workingFacts.map { ($0, $0.relevanceScore(activeEntities: activeEntities)) }
            .sorted { $0.1 > $1.1 }

        // Keep the top N
        let kept = scored.prefix(maxFacts).map(\.0)
        let evicted = scored.dropFirst(maxFacts).map(\.0)

        workingFacts = Array(kept)

        // Fold evicted facts into running summary (Tier 2)
        for fact in evicted {
            await foldIntoSummary(fact)
            // Archive to vector store (Tier 3)
            await archiveHandler?(fact)
        }
    }

    /// Folds a single evicted fact into the running summary.
    private func foldIntoSummary(_ fact: Fact) async {
        if let folder = summaryFolder {
            // LLM-based incremental fold
            do {
                let updated = try await folder(runningSummary, fact)
                // Ensure summary stays within budget
                let tokens = AppConfig.estimateTokens(for: updated)
                if tokens <= maxSummaryTokens {
                    runningSummary = updated
                } else {
                    // Truncate to budget
                    let charLimit = maxSummaryTokens * 4
                    runningSummary = String(updated.prefix(charLimit))
                }
            } catch {
                Log.engine.debug("Summary fold failed: \(error). Using compact append.")
                appendToSummary(fact)
            }
        } else {
            // Deterministic fold (no LLM): append compact representation
            appendToSummary(fact)
        }
    }

    /// Simple deterministic summary append (no LLM call).
    /// When over budget, drops the oldest entries (semicolon-delimited) rather than
    /// cutting mid-sentence. This preserves complete facts instead of truncating.
    private func appendToSummary(_ fact: Fact) {
        let entry = fact.compact()
        if runningSummary.isEmpty {
            runningSummary = entry
        } else {
            runningSummary += "; \(entry)"
        }
        // Trim to budget by dropping oldest entries (front of string)
        while AppConfig.estimateTokens(for: runningSummary) > maxSummaryTokens {
            if let semicolonRange = runningSummary.range(of: "; ") {
                runningSummary = String(runningSummary[semicolonRange.upperBound...])
            } else {
                // Single entry exceeds budget — truncate it
                let charLimit = maxSummaryTokens * 4
                runningSummary = String(runningSummary.prefix(charLimit))
                break
            }
        }
    }
}
