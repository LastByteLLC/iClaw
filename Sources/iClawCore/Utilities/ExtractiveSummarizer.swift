import Foundation
import NaturalLanguage

/// NLP-based extractive summarizer using sentence embeddings.
/// Selects the most representative sentences from a document by scoring them
/// against the document's semantic centroid. No LLM required.
///
/// Used as a fallback when Apple Foundation Models triggers safety guardrails,
/// providing real semantic summarization instead of naive truncation.
public enum ExtractiveSummarizer {

    /// Summarizes text by selecting the most representative sentences.
    /// - Parameters:
    ///   - text: The full document text to summarize.
    ///   - maxSentences: Maximum number of sentences to include (default 5).
    ///   - query: Optional query to bias selection toward relevant sentences.
    /// - Returns: An extractive summary preserving original sentence order.
    public static func summarize(_ text: String, maxSentences: Int = 5, query: String? = nil) -> String {
        let sentences = tokenizeSentences(text)

        // Too few sentences — return as-is
        guard sentences.count > maxSentences else {
            return sentences.map(\.text).joined(separator: " ")
        }

        let scored = scoreSentences(sentences, query: query)

        // Select top-k by score, then restore original order
        let selected = scored
            .sorted { $0.score > $1.score }
            .prefix(maxSentences)
            .sorted { $0.index < $1.index }

        return selected.map(\.text).joined(separator: " ")
    }

    // MARK: - Sentence Tokenization

    private struct IndexedSentence {
        let text: String
        let index: Int
    }

    private static func tokenizeSentences(_ text: String) -> [IndexedSentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [IndexedSentence] = []
        var index = 0

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip very short fragments (headers, labels, noise)
            if sentence.count >= 15 {
                sentences.append(IndexedSentence(text: sentence, index: index))
                index += 1
            }
            return true
        }

        return sentences
    }

    // MARK: - Sentence Scoring

    private struct ScoredSentence {
        let text: String
        let index: Int
        let score: Double
    }

    /// Scores sentences using a weighted combination of:
    /// 1. Embedding similarity to document centroid (semantic relevance)
    /// 2. Positional bias (leading sentences weighted higher)
    /// 3. Optional query relevance (if a query is provided)
    private static func scoreSentences(_ sentences: [IndexedSentence], query: String?) -> [ScoredSentence] {
        // Detect language from the longest sentence (most signal) to avoid
        // mislabeling short fragments. Falls back to English when the
        // detected language isn't in `NLEmbedding`'s supported set.
        let referenceText = sentences.max(by: { $0.text.count < $1.text.count })?.text ?? ""
        guard let embedding = LocalizedEmbedding.sentenceEmbeddingSync(for: referenceText) else {
            return positionalFallback(sentences)
        }

        // Get vectors for all sentences
        let vectors: [(index: Int, vector: [Double])] = sentences.compactMap { sentence in
            guard let vec = embedding.vector(for: sentence.text) else { return nil }
            return (sentence.index, vec)
        }

        guard !vectors.isEmpty else {
            return positionalFallback(sentences)
        }

        // Compute document centroid (mean of all sentence vectors)
        let dimension = vectors[0].vector.count
        var centroid = [Double](repeating: 0.0, count: dimension)
        for (_, vec) in vectors {
            for i in 0..<dimension {
                centroid[i] += vec[i]
            }
        }
        let n = Double(vectors.count)
        for i in 0..<dimension {
            centroid[i] /= n
        }

        // Get query vector if provided
        let queryVector = query.flatMap { embedding.vector(for: $0) }

        // Build a lookup from sentence index → vector
        var vectorLookup: [Int: [Double]] = [:]
        for (idx, vec) in vectors {
            vectorLookup[idx] = vec
        }

        let totalSentences = Double(sentences.count)

        return sentences.map { sentence in
            var score = 0.0

            if let vec = vectorLookup[sentence.index] {
                // Component 1: Centroid similarity (0.0–1.0) — weight 0.5
                let centroidSim = VectorMath.cosineSimilarity(vec, centroid)
                score += centroidSim * 0.5

                // Component 2: Query relevance (0.0–1.0) — weight 0.3 if query present
                if let qVec = queryVector {
                    let querySim = VectorMath.cosineSimilarity(vec, qVec)
                    score += querySim * 0.3
                } else {
                    // Redistribute query weight to centroid when no query
                    score += centroidSim * 0.15
                }
            }

            // Component 3: Positional bias — weight 0.2
            // First sentence gets full weight, decays linearly
            let positionScore = 1.0 - (Double(sentence.index) / totalSentences)
            score += positionScore * 0.2

            return ScoredSentence(text: sentence.text, index: sentence.index, score: score)
        }
    }

    /// Fallback when NLEmbedding isn't available — pure positional scoring.
    private static func positionalFallback(_ sentences: [IndexedSentence]) -> [ScoredSentence] {
        let total = Double(sentences.count)
        return sentences.map { sentence in
            let positionScore = 1.0 - (Double(sentence.index) / total)
            return ScoredSentence(text: sentence.text, index: sentence.index, score: positionScore)
        }
    }

}
