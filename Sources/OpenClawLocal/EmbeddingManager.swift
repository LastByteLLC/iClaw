import Foundation
import NaturalLanguage

@MainActor
class EmbeddingManager {
    static let shared = EmbeddingManager()
    
    private let embeddingModel: NLEmbedding?
    
    private init() {
        self.embeddingModel = NLEmbedding.sentenceEmbedding(for: .english)
    }
    
    func generateEmbedding(for text: String) -> [Double]? {
        guard let embeddingModel = embeddingModel else { return nil }
        return embeddingModel.vector(for: text)
    }
}
