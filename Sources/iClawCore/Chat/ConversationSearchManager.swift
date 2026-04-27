import Foundation

/// Search result pairing a user message with its agent response.
public struct ConversationSearchResult: Identifiable, Sendable {
    public let id: Int64
    public let userMessage: Memory
    public let agentMessage: Memory?
    public let matchedRole: String
    public let timestamp: Date
    public let snippet: String?
}

/// Manages conversation search state: debounced FTS5 keyword search with semantic fallback and pagination.
@MainActor @Observable
public final class ConversationSearchManager {
    public var searchQuery: String = "" {
        didSet { queryDidChange() }
    }
    public private(set) var searchResults: [ConversationSearchResult] = []
    public private(set) var isSearching = false
    public private(set) var hasMoreResults = true

    private let pageSize = 20
    private var currentOffset = 0
    private var searchTask: Task<Void, Never>?
    private var seenIDs: Set<Int64> = []

    private let db: DatabaseManager
    private let debounceInterval: Duration

    public init(db: DatabaseManager = .shared, debounceInterval: Duration = .milliseconds(300)) {
        self.db = db
        self.debounceInterval = debounceInterval
    }

    private func queryDidChange() {
        searchTask?.cancel()
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            isSearching = false
            hasMoreResults = true
            currentOffset = 0
            seenIDs = []
            return
        }

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }

            self.isSearching = true
            self.searchResults = []
            self.currentOffset = 0
            self.seenIDs = []
            self.hasMoreResults = true

            await self.performSearch()
            self.isSearching = false
        }
    }

    /// Load the next page of results.
    public func loadMore() {
        guard hasMoreResults, !isSearching else { return }
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSearching = true
            await self.performSearch()
            self.isSearching = false
        }
    }

    private func performSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // FTS5 keyword search
        do {
            let hits = try await db.searchMemoriesText(query: query, limit: pageSize, offset: currentOffset)
            if hits.count < pageSize {
                hasMoreResults = false
            }
            currentOffset += hits.count

            var newResults: [ConversationSearchResult] = []
            for hit in hits {
                guard let memId = hit.memory.id, !seenIDs.contains(memId) else { continue }
                seenIDs.insert(memId)

                let pair = try? await db.fetchMemoryPair(for: hit.memory)

                let userMsg: Memory
                let agentMsg: Memory?
                let matchedRole = hit.memory.role

                if hit.memory.role == "user" {
                    userMsg = hit.memory
                    agentMsg = pair
                } else if hit.memory.role == "agent", let partner = pair {
                    userMsg = partner
                    agentMsg = hit.memory
                } else {
                    // system/compacted memory — show as-is
                    userMsg = hit.memory
                    agentMsg = nil
                }

                // Deduplicate by user message ID
                let resultId = userMsg.id ?? memId
                guard !seenIDs.contains(resultId) || resultId == memId else { continue }
                seenIDs.insert(resultId)
                if let agentId = agentMsg?.id { seenIDs.insert(agentId) }

                newResults.append(ConversationSearchResult(
                    id: resultId,
                    userMessage: userMsg,
                    agentMessage: agentMsg,
                    matchedRole: matchedRole,
                    timestamp: hit.memory.created_at,
                    snippet: hit.snippet
                ))
            }

            searchResults.append(contentsOf: newResults)

            // If few keyword results on first page, try semantic search
            if currentOffset <= pageSize, searchResults.count < 10 {
                await appendSemanticResults(query: query)
            }
        } catch {
            Log.ui.debug("Search failed: \(error)")
            hasMoreResults = false
        }
    }

    private func appendSemanticResults(query: String) async {
        do {
            let semanticHits = try await db.searchMemories(query: query, limit: 10)
            for memory in semanticHits {
                guard let memId = memory.id, !seenIDs.contains(memId) else { continue }
                seenIDs.insert(memId)

                let pair = try? await db.fetchMemoryPair(for: memory)
                let userMsg: Memory
                let agentMsg: Memory?

                if memory.role == "user" {
                    userMsg = memory
                    agentMsg = pair
                } else if memory.role == "agent", let partner = pair {
                    userMsg = partner
                    agentMsg = memory
                } else {
                    userMsg = memory
                    agentMsg = nil
                }

                let resultId = userMsg.id ?? memId
                guard !seenIDs.contains(resultId) || resultId == memId else { continue }
                seenIDs.insert(resultId)
                if let agentId = agentMsg?.id { seenIDs.insert(agentId) }

                searchResults.append(ConversationSearchResult(
                    id: resultId,
                    userMessage: userMsg,
                    agentMessage: agentMsg,
                    matchedRole: memory.role,
                    timestamp: memory.created_at,
                    snippet: nil
                ))
            }
        } catch {
            Log.ui.debug("Semantic search failed: \(error)")
        }
    }
}
