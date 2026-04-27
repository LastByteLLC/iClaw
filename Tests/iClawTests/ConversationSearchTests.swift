import XCTest
@testable import iClawCore

@MainActor
final class ConversationSearchTests: XCTestCase {

    // MARK: - DatabaseManager FTS5 Tests

    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true)
    }

    private func insertPair(db: DatabaseManager, user: String, agent: String) async throws {
        let userMem = Memory(id: nil, role: "user", content: user, embedding: nil, created_at: Date(), is_important: false)
        let agentMem = Memory(id: nil, role: "agent", content: agent, embedding: nil, created_at: Date(), is_important: false)
        _ = try await db.saveMemory(userMem)
        _ = try await db.saveMemory(agentMem)
    }

    func testFTSSearchReturnsMatches() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "What's the weather in London", agent: "It's cloudy and 12°C in London")
        try await insertPair(db: db, user: "Play some jazz music", agent: "Here's a jazz playlist")

        let results = try await db.searchMemoriesText(query: "weather")
        XCTAssertFalse(results.isEmpty, "Should find weather-related memories")
        XCTAssertTrue(results.allSatisfy { $0.memory.content.lowercased().contains("weather") || $0.memory.content.lowercased().contains("london") })
    }

    func testFTSSearchPrefixMatching() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "Calculate 2+2", agent: "4")

        let results = try await db.searchMemoriesText(query: "calc")
        XCTAssertFalse(results.isEmpty, "Prefix matching should find 'Calculate' from 'calc'")
    }

    func testFTSSearchEmptyQuery() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "Hello", agent: "Hi there")

        let results = try await db.searchMemoriesText(query: "")
        XCTAssertTrue(results.isEmpty, "Empty query should return no results")
    }

    func testFTSSearchSanitizesSpecialCharacters() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "test query", agent: "response")

        // Should not crash with FTS5 special chars
        let results = try await db.searchMemoriesText(query: "test\" OR *:^()")
        // May or may not match, but should not throw
        _ = results
    }

    func testFTSSearchPagination() async throws {
        let db = try makeDB()
        for i in 0..<5 {
            try await insertPair(db: db, user: "weather query \(i)", agent: "weather response \(i)")
        }

        let page1 = try await db.searchMemoriesText(query: "weather", limit: 3, offset: 0)
        let page2 = try await db.searchMemoriesText(query: "weather", limit: 3, offset: 3)

        XCTAssertEqual(page1.count, 3)
        XCTAssertTrue(page2.count <= 3)
        // No overlap
        let ids1 = Set(page1.map { $0.memory.id })
        let ids2 = Set(page2.map { $0.memory.id })
        XCTAssertTrue(ids1.isDisjoint(with: ids2))
    }

    func testFTSSearchSnippet() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "The weather in San Francisco is usually foggy", agent: "Indeed")

        let results = try await db.searchMemoriesText(query: "weather")
        XCTAssertFalse(results.isEmpty)
        if let snippet = results.first?.snippet {
            XCTAssertTrue(snippet.contains("[[") && snippet.contains("]]"), "Snippet should contain highlight markers")
        }
    }

    // MARK: - Pair Fetching Tests

    func testFetchMemoryPairUserToAgent() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "Hello world", agent: "Hi there!")

        let allMemories = try await db.dbQueue.read { db in
            try Memory.fetchAll(db)
        }
        let userMem = allMemories.first { $0.role == "user" }!

        let pair = try await db.fetchMemoryPair(for: userMem)
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.role, "agent")
        XCTAssertEqual(pair?.content, "Hi there!")
    }

    func testFetchMemoryPairAgentToUser() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "Hello world", agent: "Hi there!")

        let allMemories = try await db.dbQueue.read { db in
            try Memory.fetchAll(db)
        }
        let agentMem = allMemories.first { $0.role == "agent" }!

        let pair = try await db.fetchMemoryPair(for: agentMem)
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.role, "user")
        XCTAssertEqual(pair?.content, "Hello world")
    }

    // MARK: - FTS5 Trigger Sync Tests

    func testFTSTriggerOnInsert() async throws {
        let db = try makeDB()
        // Insert after migration — trigger should add to FTS
        let mem = Memory(id: nil, role: "user", content: "unique searchable term xylophone", embedding: nil, created_at: Date(), is_important: false)
        _ = try await db.saveMemory(mem)

        let results = try await db.searchMemoriesText(query: "xylophone")
        XCTAssertEqual(results.count, 1)
    }

    func testFTSTriggerOnDelete() async throws {
        let db = try makeDB()
        let mem = Memory(id: nil, role: "user", content: "deletable content zebra", embedding: nil, created_at: Date(), is_important: false)
        let saved = try await db.saveMemory(mem)
        let savedId = try XCTUnwrap(saved.id, "saveMemory should return a memory with an id")

        // Verify it's searchable
        let before = try await db.searchMemoriesText(query: "zebra")
        XCTAssertEqual(before.count, 1)

        // Delete it
        try await db.deleteMemory(id: savedId)

        // Should no longer be searchable
        let after = try await db.searchMemoriesText(query: "zebra")
        XCTAssertEqual(after.count, 0)
    }

    // MARK: - ConversationSearchManager Tests

    func testSearchManagerDebounce() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "weather forecast", agent: "sunny")

        let manager = ConversationSearchManager(db: db, debounceInterval: .milliseconds(10))
        manager.searchQuery = "wea"
        manager.searchQuery = "weat"
        manager.searchQuery = "weather"

        // Wait for debounce (10ms) + search
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(manager.searchResults.isEmpty, "Should have results after debounce")
    }

    func testSearchManagerClearOnEmptyQuery() async throws {
        let db = try makeDB()
        try await insertPair(db: db, user: "test content", agent: "response")

        let manager = ConversationSearchManager(db: db, debounceInterval: .milliseconds(10))
        manager.searchQuery = "test"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(manager.searchResults.isEmpty)

        manager.searchQuery = ""
        // Should clear immediately (no debounce needed)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(manager.searchResults.isEmpty)
    }

    func testSearchManagerDeduplication() async throws {
        let db = try makeDB()
        // Insert a pair where both user and agent contain the keyword
        try await insertPair(db: db, user: "weather in Tokyo", agent: "The weather is warm in Tokyo")

        let manager = ConversationSearchManager(db: db, debounceInterval: .milliseconds(10))
        manager.searchQuery = "weather Tokyo"
        try await Task.sleep(for: .milliseconds(100))

        // Both messages match but should be deduplicated into one result
        let uniqueUserIDs = Set(manager.searchResults.map { $0.userMessage.id })
        XCTAssertEqual(uniqueUserIDs.count, manager.searchResults.count, "Results should be deduplicated by conversation pair")
    }
}
