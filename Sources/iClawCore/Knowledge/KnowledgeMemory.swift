import Foundation
import GRDB
import NaturalLanguage

// MARK: - Model

/// Category of knowledge entry, affecting retrieval weight.
public enum KnowledgeCategory: String, Codable, Sendable, CaseIterable {
    case personal      // "vegetarian", "lives in Austin" — uniquely user-known
    case preference    // "prefers Celsius", "likes concise answers"
    case relationship  // "Sarah = wife", "Dave = boss"
    case fact          // "AAPL was $286 Mar 24" — data from tools
    case context       // "researching Tokyo trip" — transient context

    /// Retrieval weight: higher = more likely to be injected.
    var weight: Double {
        switch self {
        case .personal:     1.0
        case .preference:   0.9
        case .relationship: 0.8
        case .context:      0.5
        case .fact:         0.3
        }
    }
}

/// How the knowledge was acquired.
public enum KnowledgeSource: String, Codable, Sendable {
    case userStated   // User explicitly said it
    case toolResult   // Derived from a tool result
    case inferred     // Inferred from patterns
}

/// A single knowledge entry: entity-anchored, categorized, scored.
public struct KnowledgeEntry: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "knowledge_memory"

    public var id: Int64?
    public var category: String           // KnowledgeCategory raw value
    public var key: String                // Entity anchor: "vegetarian", "Sarah"
    public var value: String              // Compressed fact: "wife, prefers texts"
    public var source: String             // KnowledgeSource raw value
    public var confidence: Double         // 0.0–1.0
    public var createdAt: Date
    public var lastAccessedAt: Date
    public var accessCount: Int
    public var embedding: Data?           // JSON-encoded [Double]

    public init(
        id: Int64? = nil,
        category: KnowledgeCategory,
        key: String,
        value: String,
        source: KnowledgeSource,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        accessCount: Int = 0,
        embedding: Data? = nil
    ) {
        self.id = id
        self.category = category.rawValue
        self.key = key
        self.value = value
        self.source = source.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.embedding = embedding
    }

    public var knowledgeCategory: KnowledgeCategory {
        KnowledgeCategory(rawValue: category) ?? .fact
    }

    public var knowledgeSource: KnowledgeSource {
        KnowledgeSource(rawValue: source) ?? .inferred
    }

    /// Decode the stored embedding vector.
    public var embeddingVector: [Double]? {
        guard let data = embedding else { return nil }
        return try? JSONDecoder().decode([Double].self, from: data)
    }
}

// MARK: - Database Migration

extension KnowledgeEntry {
    public static func registerMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createKnowledgeMemory") { db in
            try db.create(table: "knowledge_memory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("category", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.column("source", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("createdAt", .datetime).notNull()
                t.column("lastAccessedAt", .datetime).notNull()
                t.column("accessCount", .integer).notNull().defaults(to: 0)
                t.column("embedding", .blob)
                t.uniqueKey(["category", "key"])
            }
        }
    }
}

// MARK: - Manager

/// Actor managing persistent knowledge memory: acquisition, retrieval, and consolidation.
public actor KnowledgeMemoryManager {
    public static let shared = KnowledgeMemoryManager()

    private let dbQueue: DatabaseQueue?

    /// Timestamp of last consolidation run.
    private var lastConsolidation: Date?

    private init() {
        self.dbQueue = DatabaseManager.shared.dbQueue
    }

    /// Test-only initializer with injected database.
    init(dbQueue: DatabaseQueue?) {
        self.dbQueue = dbQueue
    }

    /// Loads a sentence embedding matching the text's detected language,
    /// falling back to English when NLEmbedding lacks coverage. Consolidated
    /// via `LocalizedEmbedding.shared` so the loader caches per-language.
    private func embeddingForText(_ text: String) async -> NLEmbedding? {
        await LocalizedEmbedding.shared.sentence(detectedFrom: text)?.embedding
    }

    // MARK: - CRUD

    /// Save or update a knowledge entry. Upserts on (category, key).
    public func upsert(_ entry: KnowledgeEntry) async throws {
        guard let dbQueue else { return }
        // Resolve the embedding first (crossing the LocalizedEmbedding actor)
        // so the DB write closure captures only Sendable values.
        var mutableEntry = entry
        if mutableEntry.embedding == nil {
            let combinedText = "\(entry.key) \(entry.value)"
            if let embedding = await embeddingForText(combinedText),
               let vector = embedding.vector(for: combinedText) {
                mutableEntry.embedding = try? JSONEncoder().encode(vector)
            }
        }
        let finalEntry = mutableEntry

        // GRDB 7 exposes both sync and async `write`; inside an async context
        // the compiler prefers the async overload, so the call must be
        // awaited. Keep using the synchronous closure body — only the outer
        // dispatch needs `await`.
        try await dbQueue.write { db in
            // Check for existing entry with same category+key
            if let existing = try KnowledgeEntry
                .filter(Column("category") == finalEntry.category && Column("key") == finalEntry.key)
                .fetchOne(db) {
                // Update: keep higher confidence, merge values if different
                var updated = finalEntry
                updated.id = existing.id
                updated.confidence = max(existing.confidence, finalEntry.confidence)
                updated.accessCount = existing.accessCount
                updated.createdAt = existing.createdAt
                try updated.update(db)
            } else {
                var inserted = finalEntry
                try inserted.insert(db)
            }
        }
    }

    /// Count of all knowledge entries.
    public func count() -> Int {
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in
            try KnowledgeEntry.fetchCount(db)
        }) ?? 0
    }

    /// Delete all knowledge entries.
    public func clearAll() throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            _ = try KnowledgeEntry.deleteAll(db)
        }
    }

    // MARK: - Retrieval (Multi-Signal Scoring)

    /// Retrieve relevant knowledge entries for a query, scored by the 4-signal formula.
    /// - Parameters:
    ///   - query: The user's input text
    ///   - routedToolNames: Names of tools that will execute (for redundancy penalty)
    ///   - limit: Maximum entries to return
    /// - Returns: Scored entries above the relevance threshold
    public func retrieve(
        for query: String,
        routedToolNames: Set<String> = [],
        limit: Int = AppConfig.knowledgeMemoryMaxPerTurn
    ) async -> [KnowledgeEntry] {
        guard let dbQueue,
              let embedding = await embeddingForText(query),
              let queryVector = embedding.vector(for: query) else { return [] }

        let candidates: [KnowledgeEntry]
        do {
            candidates = try await dbQueue.read { db in
                try KnowledgeEntry
                    .filter(Column("confidence") > AppConfig.knowledgeMemoryMinConfidence)
                    .order(Column("confidence").desc)
                    .limit(50)  // Fetch more than needed for scoring
                    .fetchAll(db)
            }
        } catch { return [] }

        let now = Date()
        var scored: [(entry: KnowledgeEntry, score: Double)] = []

        for candidate in candidates {
            guard let entryVector = candidate.embeddingVector else { continue }

            // Signal 1: Cosine similarity
            let cosineSim = VectorMath.cosineSimilarity(queryVector, entryVector)
            guard cosineSim >= MLThresholdsConfig.shared.knowledgeRetrieval.cosineSimilarityFloor else { continue }

            // Signal 2: Category weight
            let categoryWeight = candidate.knowledgeCategory.weight

            // Signal 3: Freshness (access frequency + recency)
            let daysSinceAccess = now.timeIntervalSince(candidate.lastAccessedAt) / 86400
            let recencyBoost: Double
            if daysSinceAccess < 1 { recencyBoost = 1.0 }
            else if daysSinceAccess < 7 { recencyBoost = 0.5 }
            else if daysSinceAccess < 30 { recencyBoost = 0.2 }
            else { recencyBoost = 0.0 }
            let freshness = min(1.5, 0.5 + Double(candidate.accessCount) / 10.0 + recencyBoost)

            // Signal 4: Tool redundancy penalty
            let toolRedundancy = toolRedundancyPenalty(for: candidate, routedTools: routedToolNames)

            // Combined score
            let finalScore = cosineSim * categoryWeight * freshness * (1.0 - toolRedundancy)
            if finalScore >= AppConfig.knowledgeMemoryRelevanceThreshold {
                scored.append((candidate, finalScore))
            }
        }

        // Sort by score descending, take top N
        let results = scored.sorted { $0.score > $1.score }.prefix(limit)

        // Boost access stats for retrieved entries
        for (entry, _) in results {
            boostAccess(entry)
        }

        return results.map(\.entry)
    }


    /// Check if a tool will provide fresher data than this memory.
    private func toolRedundancyPenalty(for entry: KnowledgeEntry, routedTools: Set<String>) -> Double {
        guard !routedTools.isEmpty else { return 0 }
        // Fact-category entries about tools that are routed get heavy penalty
        if entry.knowledgeCategory == .fact {
            let keyLower = entry.key.lowercased()
            for (tool, keywords) in Self.toolDomainKeywords where routedTools.contains(tool) {
                if keywords.contains(where: { keyLower.contains($0) }) {
                    return 0.8
                }
            }
        }
        return 0
    }

    /// Tool domain keywords loaded from ToolDomainKeywords.json config.
    private static let toolDomainKeywords: [String: [String]] = {
        ConfigLoader.load("ToolDomainKeywords", as: [String: [String]].self) ?? [:]
    }()

    /// Update access stats for a retrieved entry.
    private func boostAccess(_ entry: KnowledgeEntry) {
        guard let dbQueue, let id = entry.id else { return }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE knowledge_memory SET lastAccessedAt = ?, accessCount = accessCount + 1 WHERE id = ?",
                    arguments: [Date(), id]
                )
            }
        } catch {
            Log.engine.debug("Knowledge access boost failed for id \(id): \(error)")
        }
    }

    // MARK: - Consolidation

    /// Run consolidation if enough time has passed since the last run.
    public func consolidateIfNeeded() async {
        let minInterval: TimeInterval = 3600  // 1 hour
        if let last = lastConsolidation, Date().timeIntervalSince(last) < minInterval { return }
        await consolidate()
        lastConsolidation = Date()
    }

    /// Consolidate knowledge: decay confidence, prune low-confidence, cap entries.
    public func consolidate() async {
        guard let dbQueue else { return }

        do {
            // Step 1: Decay all confidence values
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE knowledge_memory SET confidence = confidence * ?",
                    arguments: [AppConfig.knowledgeMemoryConfidenceDecay]
                )
            }

            // Step 2: Delete entries below minimum confidence
            try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM knowledge_memory WHERE confidence < ?",
                    arguments: [AppConfig.knowledgeMemoryMinConfidence]
                )
            }

            // Step 3: Cap total entries
            let currentCount = count()
            if currentCount > AppConfig.knowledgeMemoryMaxEntries {
                let excess = currentCount - AppConfig.knowledgeMemoryMaxEntries
                try await dbQueue.write { db in
                    // Delete lowest-confidence entries
                    try db.execute(
                        sql: """
                            DELETE FROM knowledge_memory WHERE id IN (
                                SELECT id FROM knowledge_memory
                                ORDER BY confidence ASC, lastAccessedAt ASC
                                LIMIT ?
                            )
                            """,
                        arguments: [excess]
                    )
                }
            }

            Log.engine.debug("Knowledge consolidation complete. Entries: \(self.count())")
        } catch {
            Log.engine.error("Knowledge consolidation failed: \(error)")
        }
    }
}
