import Foundation
import NaturalLanguage

/// RetrievalManager handles document chunking and semantic retrieval of relevant context.
/// Implemented as a Swift 6 actor to ensure strict concurrency and thread-safe data access.
public actor RetrievalManager {

    /// Shared instance for app-wide retrieval operations.
    public static let shared = RetrievalManager()

    private init() {}

    /// Maximum characters per chunk. Paragraphs exceeding this are split at sentence
    /// boundaries to prevent a single chunk from consuming the entire retrieval budget.
    private let maxChunkChars = 2000

    /// Splits a document into chunks at paragraph boundaries using NaturalLanguage.
    /// Oversized paragraphs are sub-split at sentence boundaries with a hard cap
    /// of `maxChunkChars` to prevent budget exhaustion.
    /// - Parameter text: The raw document text to be chunked.
    /// - Returns: An array of strings, each representing a semantic chunk.
    public func chunkDocument(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .paragraph)
        tokenizer.string = text

        var chunks: [String] = []
        let fullRange = text.startIndex..<text.endIndex

        tokenizer.enumerateTokens(in: fullRange) { range, _ in
            let chunk = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if chunk.isEmpty { return true }

            if chunk.count <= maxChunkChars {
                chunks.append(chunk)
            } else {
                // Sub-split oversized paragraphs at sentence boundaries
                let sentenceTokenizer = NLTokenizer(unit: .sentence)
                sentenceTokenizer.string = chunk
                var buffer = ""
                let sentenceRange = chunk.startIndex..<chunk.endIndex
                sentenceTokenizer.enumerateTokens(in: sentenceRange) { sRange, _ in
                    let sentence = String(chunk[sRange])
                    if buffer.count + sentence.count > self.maxChunkChars && !buffer.isEmpty {
                        chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                        buffer = sentence
                    } else {
                        buffer += sentence
                    }
                    return true
                }
                if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return true
        }

        return chunks
    }

    /// Retrieves relevant chunks from the memory store using vector similarity search.
    /// Returns 1-3 relevant chunks that fit within the retrievedDataChunks budget defined in AppConfig.
    /// - Parameters:
    ///   - query: The user's query or search term.
    ///   - documentID: The unique identifier for the document to search within (currently unused, reserved for future per-document filtering).
    /// - Returns: An array of relevant text chunks.
    /// - Throws: An error if retrieval fails.
    public func retrieveRelevantChunks(for query: String, from documentID: String) async throws -> [String] {
        let memories = try await DatabaseManager.shared.searchMemories(query: query, limit: 3)

        let maxTokens = AppConfig.retrievedDataChunks
        var selectedChunks: [String] = []
        var currentTokenCount = 0

        for memory in memories {
            let tokens = AppConfig.estimateTokens(for: memory.content)
            if currentTokenCount + tokens <= maxTokens {
                selectedChunks.append(memory.content)
                currentTokenCount += tokens
            } else {
                break
            }
        }

        return selectedChunks
    }

}
