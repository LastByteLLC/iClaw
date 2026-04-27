import Foundation
import GRDB

public final class DatabaseManager: Sendable {
    public static let shared: DatabaseManager = {
        do {
            return try DatabaseManager()
        } catch {
            Log.engine.debug("Failed to initialize: \(error). Using in-memory fallback.")
            do {
                return try DatabaseManager(inMemory: true)
            } catch {
                Log.engine.debug("In-memory DB also failed: \(error). This should never happen.")
                fatalError("Cannot create even an in-memory database: \(error)")
            }
        }
    }()

    public let dbQueue: DatabaseQueue

    public init(inMemory: Bool = false) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL mode for crash recovery and concurrent reads.
            // Enable foreign key enforcement for referential integrity.
            // These must run outside a transaction (prepareDatabase runs before
            // any implicit transaction), otherwise SQLite errors with
            // "cannot change into wal mode from within a transaction".
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        if inMemory {
            dbQueue = try DatabaseQueue(configuration: config)
        } else {
            let fileManager = FileManager.default
            guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw NSError(domain: "DatabaseManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory not found."])
            }
            let dbFolderURL = appSupportURL.appendingPathComponent("iClaw", isDirectory: true)
            try fileManager.createDirectory(at: dbFolderURL, withIntermediateDirectories: true)
            let dbURL = dbFolderURL.appendingPathComponent("db.sqlite")
            dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
            // Restrict database file to owner-only access
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
        }

        try migrator.migrate(dbQueue)

        // Quick integrity check — catches corruption early.
        // Uses quick_check (O(1) per page vs full integrity_check) to avoid
        // blocking startup on large databases.
        try dbQueue.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA quick_check")
            if result != "ok" {
                Log.engine.error("Database integrity check failed: \(result ?? "unknown")")
            }
        }
    }
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("createMemories") { db in
            try db.create(table: "memories") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("embedding", .blob)
                t.column("created_at", .datetime).notNull().defaults(to: Date())
                t.column("is_important", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("addSearchIndexes") { db in
            // FTS5 virtual table for keyword search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memories_fts USING fts5(
                    content,
                    content='memories',
                    content_rowid='id'
                )
                """)
            try db.execute(sql: "INSERT INTO memories_fts(rowid, content) SELECT id, content FROM memories")

            // Keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
                    INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
                    INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.id, old.content);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
                    INSERT INTO memories_fts(memories_fts, rowid, content) VALUES('delete', old.id, old.content);
                    INSERT INTO memories_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)

            // Index for pair-fetching and chronological queries
            try db.execute(sql: "CREATE INDEX idx_memories_role_created ON memories(role, created_at DESC)")
        }

        UserProfileManager.registerMigration(in: &migrator)
        ScheduledQueryStore.registerMigration(in: &migrator)
        KnowledgeEntry.registerMigration(in: &migrator)
        GeneratedPhrase.registerMigration(in: &migrator)

        return migrator
    }

    public func saveMemory(_ memory: Memory) async throws -> Memory {
        var memoryWithEmbedding = memory
        // Automatically generate embedding
        if let vector = await EmbeddingManager.shared.generateEmbedding(for: memory.content) {
            memoryWithEmbedding.embedding = try JSONEncoder().encode(vector)
        }
        
        let memoryToPersist = memoryWithEmbedding
        return try await dbQueue.write { db in
            var mutableMemory = memoryToPersist
            try mutableMemory.save(db)
            return mutableMemory
        }
    }

    func deleteMemory(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
        }
    }

    /// Clears all fact-type memories archived by ProgressiveMemoryManager.
    /// Called during conversation reset to prevent stale Tier 3 data from
    /// surfacing in a fresh session.
    func clearFactMemories() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memories WHERE role = 'fact'")
        }
    }

    func searchMemories(query: String, limit: Int = 5) async throws -> [Memory] {
        guard let queryVector = await EmbeddingManager.shared.generateEmbedding(for: query) else { return [] }
        
        let allMemories = try await dbQueue.read { db in
            try Memory.order(Column("created_at").desc).limit(200).fetchAll(db)
        }

        // Manual cosine similarity
        let scored = allMemories.compactMap { memory -> (Memory, Double)? in
            guard let embeddingData = memory.embedding,
                  let vector = try? JSONDecoder().decode([Double].self, from: embeddingData) else {
                return nil
            }
            let score = VectorMath.cosineSimilarity(queryVector, vector)
            return (memory, score)
        }
        
        return scored.sorted { $0.1 > $1.1 }
                     .prefix(limit)
                     .map { $0.0 }
    }

    public func compactMemoriesIfNeeded() async throws {
        let allMemories = try await dbQueue.read { db in
            try Memory.fetchAll(db)
        }
        
        let totalChars = allMemories.map { $0.content.count }.reduce(0, +)
        let tokenEstimate = totalChars / 4
        
        if tokenEstimate > 3500 { // Leave some room
            // Summarize oldest non-important memories
            let toSummarize = allMemories.filter { !$0.is_important }
                                         .sorted { $0.created_at < $1.created_at }
                                         .prefix(10)
            
            if !toSummarize.isEmpty {
                let combinedText = toSummarize.map { $0.content }.joined(separator: "\n")
                let summary = await SummarizationManager.shared.summarize(text: combinedText)
                
                try await dbQueue.write { db in
                    // Delete the old ones
                    for memory in toSummarize {
                        if let id = memory.id {
                            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                        }
                    }
                }
                
                // Save the summary as a new system memory
                let newMemory = Memory(id: nil, role: "system", content: "Summary of past interactions: \(summary)", embedding: nil, created_at: Date(), is_important: true)
                _ = try await saveMemory(newMemory)
            }
        }
    }

    /// Returns the most recent user inputs from the memory store.
    func recentUserInputs(limit: Int = 5) async -> [String] {
        do {
            return try await dbQueue.read { db in
                let rows = try Memory
                    .filter(Column("role") == "user")
                    .order(Column("created_at").desc)
                    .limit(limit)
                    .fetchAll(db)
                return rows.map { $0.content }
            }
        } catch {
            Log.engine.debug("recentUserInputs failed: \(error)")
            return []
        }
    }

    // MARK: - Conversation Search

    /// FTS5 keyword search with prefix matching. Returns memories ordered by recency.
    public func searchMemoriesText(query: String, limit: Int = 20, offset: Int = 0) async throws -> [(memory: Memory, snippet: String?)] {
        // Sanitize query: strip FTS5 special operators to prevent syntax errors
        let sanitized = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else { return [] }

        // Split into words, drop FTS5 boolean operators, keep only alphanumeric words
        let reserved: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let words = sanitized.split(separator: " ")
            .map { String($0) }
            .filter { word in
                let upper = word.uppercased()
                return !reserved.contains(upper) && word.rangeOfCharacter(from: .alphanumerics) != nil
            }
        guard !words.isEmpty else { return [] }
        let terms = words.map { "\($0)*" }.joined(separator: " ")

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.*, snippet(memories_fts, 0, '[[', ']]', '...', 32) AS snippet
                FROM memories m
                JOIN memories_fts ON memories_fts.rowid = m.id
                WHERE memories_fts MATCH ?
                ORDER BY m.created_at DESC
                LIMIT ? OFFSET ?
                """, arguments: [terms, limit, offset])

            return rows.map { row in
                let memory = Memory(
                    id: row["id"],
                    role: row["role"],
                    content: row["content"],
                    embedding: row["embedding"],
                    created_at: row["created_at"],
                    is_important: row["is_important"]
                )
                let snippet: String? = row["snippet"]
                return (memory: memory, snippet: snippet)
            }
        }
    }

    /// Given a memory, fetch its conversation partner (user↔agent pair).
    public func fetchMemoryPair(for memory: Memory) async throws -> Memory? {
        guard let memoryId = memory.id else { return nil }

        return try await dbQueue.read { db in
            if memory.role == "user" {
                // Look for the next agent memory by ID
                return try Memory
                    .filter(Column("id") > memoryId)
                    .filter(Column("role") == "agent")
                    .order(Column("id").asc)
                    .limit(1)
                    .fetchOne(db)
            } else {
                // Look for the previous user memory by ID
                return try Memory
                    .filter(Column("id") < memoryId)
                    .filter(Column("role") == "user")
                    .order(Column("id").desc)
                    .limit(1)
                    .fetchOne(db)
            }
        }
    }

    /// Fetches recent conversation pairs (user + agent) ordered by recency.
    /// Returns messages oldest-first within each chunk so they display in chronological order.
    /// Result of a paginated conversation history fetch.
    public struct ConversationPage: Sendable {
        /// Matched user–agent pairs in chronological order.
        public let pairs: [(user: Memory, agent: Memory)]
        /// Smallest user-message ID that was scanned (use as `beforeID` for the next page).
        /// `nil` when no user messages were found at all.
        public let cursorID: Int64?
        /// Number of raw user messages scanned (may exceed `pairs.count` when some lack an agent reply).
        public let scannedCount: Int
    }

    public func recentConversationPairs(limit: Int = 5, beforeID: Int64? = nil) async -> ConversationPage {
        do {
            return try await dbQueue.read { db in
                // Fetch recent user messages
                var query = Memory
                    .filter(Column("role") == "user")
                    .order(Column("id").desc)
                    .limit(limit)

                if let beforeID {
                    query = Memory
                        .filter(Column("role") == "user")
                        .filter(Column("id") < beforeID)
                        .order(Column("id").desc)
                        .limit(limit)
                }

                let userMessages = try query.fetchAll(db)

                // The cursor is the oldest user message ID we scanned, not the oldest paired one.
                // This ensures unpaired user messages don't block pagination.
                let cursorID = userMessages.last?.id

                var pairs: [(user: Memory, agent: Memory)] = []
                for userMsg in userMessages {
                    guard let uid = userMsg.id else { continue }
                    // Find the next agent message after this user message
                    if let agentMsg = try Memory
                        .filter(Column("id") > uid)
                        .filter(Column("role") == "agent")
                        .order(Column("id").asc)
                        .limit(1)
                        .fetchOne(db) {
                        pairs.append((user: userMsg, agent: agentMsg))
                    }
                }
                // Reverse to chronological order (oldest first)
                return ConversationPage(
                    pairs: pairs.reversed(),
                    cursorID: cursorID,
                    scannedCount: userMessages.count
                )
            }
        } catch {
            Log.engine.debug("recentConversationPairs failed: \(error)")
            return ConversationPage(pairs: [], cursorID: nil, scannedCount: 0)
        }
    }

    // MARK: - Auto-Memory Retrieval

    /// Searches memories by semantic similarity and returns results with their scores.
    /// Only returns results above the given similarity threshold.
    func searchMemoriesScored(query: String, limit: Int = 2, threshold: Double = 0.85) async throws -> [(memory: Memory, score: Double)] {
        guard let queryVector = await EmbeddingManager.shared.generateEmbedding(for: query) else { return [] }

        let allMemories = try await dbQueue.read { db in
            try Memory
                .filter(Column("role") == "agent" || Column("role") == "system")
                .order(Column("created_at").desc)
                .limit(200)
                .fetchAll(db)
        }

        let scored = allMemories.compactMap { memory -> (Memory, Double)? in
            guard let embeddingData = memory.embedding,
                  let vector = try? JSONDecoder().decode([Double].self, from: embeddingData) else {
                return nil
            }
            let score = VectorMath.cosineSimilarity(queryVector, vector)
            guard score >= threshold else { return nil }
            return (memory, score)
        }

        return scored.sorted { $0.1 > $1.1 }
                     .prefix(limit)
                     .map { (memory: $0.0, score: $0.1) }
    }

}

public struct Memory: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "memories"

    public var id: Int64?
    public var role: String
    public var content: String
    public var embedding: Data?
    public var created_at: Date
    public var is_important: Bool

    public init(id: Int64? = nil, role: String, content: String, embedding: Data? = nil, created_at: Date, is_important: Bool) {
        self.id = id
        self.role = role
        self.content = content
        self.embedding = embedding
        self.created_at = created_at
        self.is_important = is_important
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, embedding, created_at, is_important
    }
}
