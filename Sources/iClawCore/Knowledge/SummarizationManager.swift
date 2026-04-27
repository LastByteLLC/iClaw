import Foundation

@MainActor
class SummarizationManager {
    static let shared = SummarizationManager()

    private let llmAdapter: LLMAdapter

    private init(llmAdapter: LLMAdapter = .shared) {
        self.llmAdapter = llmAdapter
    }

    func summarize(text: String, query: String? = nil) async -> String {
        let truncated = String(text.prefix(8000))
        let instruction = "Summarize the following text in 2-3 concise sentences. Output ONLY the summary."
        do {
            return try await llmAdapter.generateWithInstructions(
                prompt: truncated,
                instructions: instruction,
                profile: .summarization
            )
        } catch let adapterError as LLMAdapter.AdapterError {
            Log.tools.debug("Summarization LLM error: \(adapterError)")
            return extractiveFallback(text, query: query)
        } catch {
            Log.tools.debug("Summarization failed: \(error)")
            return extractiveFallback(text, query: query)
        }
    }

    /// NLP-based extractive fallback using sentence embeddings when the LLM
    /// is unavailable or refuses due to safety guardrails.
    private func extractiveFallback(_ text: String, query: String?) -> String {
        ExtractiveSummarizer.summarize(text, maxSentences: 5, query: query)
    }
}
