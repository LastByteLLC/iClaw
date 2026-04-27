import Foundation
import NaturalLanguage

public actor EmbeddingManager {
    public static let shared = EmbeddingManager()

    private init() {}

    /// Generates an embedding vector for `text`. Auto-detects language via
    /// `LocalizedEmbedding` so non-English inputs no longer silently use the
    /// English embedding (which produced garbage vectors for them).
    public func generateEmbedding(for text: String) async -> [Double]? {
        guard let loaded = await LocalizedEmbedding.shared.sentence(detectedFrom: text) else {
            return nil
        }
        return loaded.embedding.vector(for: text)
    }
}
