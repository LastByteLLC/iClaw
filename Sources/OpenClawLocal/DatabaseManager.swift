import Foundation
import GRDB

@MainActor
class DatabaseManager {
    static let shared = DatabaseManager()
    
    let dbQueue: DatabaseQueue
    
    private init() {
        do {
            let fileManager = FileManager.default
            let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbFolderURL = appSupportURL.appendingPathComponent("OpenClawLocal", isDirectory: true)
            try fileManager.createDirectory(at: dbFolderURL, withIntermediateDirectories: true)
            let dbURL = dbFolderURL.appendingPathComponent("db.sqlite")
            
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try migrator.migrate(dbQueue)
        } catch {
            fatalError("Could not initialize database: \(error)")
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
        
        return migrator
    }

    func saveMemory(_ memory: Memory) async throws -> Memory {
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

    func searchMemories(query: String, limit: Int = 5) async throws -> [Memory] {
        guard let queryVector = EmbeddingManager.shared.generateEmbedding(for: query) else { return [] }
        
        let allMemories = try await dbQueue.read { db in
            try Memory.fetchAll(db)
        }
        
        // Manual cosine similarity
        let scored = allMemories.compactMap { memory -> (Memory, Double)? in
            guard let embeddingData = memory.embedding,
                  let vector = try? JSONDecoder().decode([Double].self, from: embeddingData) else {
                return nil
            }
            let score = cosineSimilarity(queryVector, vector)
            return (memory, score)
        }
        
        return scored.sorted { $0.1 > $1.1 }
                     .prefix(limit)
                     .map { $0.0 }
    }

    func compactMemoriesIfNeeded() async throws {
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

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        let dotProduct = zip(a, b).map(*).reduce(0, +)
        let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        return dotProduct / (normA * normB)
    }
}

struct Memory: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var role: String
    var content: String
    var embedding: Data?
    var created_at: Date
    var is_important: Bool
    
    enum CodingKeys: String, CodingKey {
        case id, role, content, embedding, created_at, is_important
    }
}
