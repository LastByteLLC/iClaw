import Foundation

/// Tracks cumulative token usage and estimated cost across a stress test session.
@Observable
@MainActor
final class TokenTracker {
    var totalPromptTokens: Int = 0
    var totalCompletionTokens: Int = 0
    var totalTokens: Int = 0
    var estimatedCostUSD: Double = 0
    var callCount: Int = 0

    /// The pricing model for the current provider/model. Set before the run starts.
    var inputPricePer1M: Double = 0
    var outputPricePer1M: Double = 0

    func reset() {
        totalPromptTokens = 0
        totalCompletionTokens = 0
        totalTokens = 0
        estimatedCostUSD = 0
        callCount = 0
    }

    func record(_ response: LLMProviderResponse) {
        callCount += 1

        let prompt = response.promptTokens ?? 0
        let completion = response.completionTokens ?? 0
        let total = response.totalTokens ?? (prompt + completion)

        totalPromptTokens += prompt
        totalCompletionTokens += completion
        totalTokens += total

        // Compute incremental cost
        let inputCost = Double(prompt) * inputPricePer1M / 1_000_000
        let outputCost = Double(completion) * outputPricePer1M / 1_000_000
        estimatedCostUSD += inputCost + outputCost
    }

    var formattedCost: String {
        if estimatedCostUSD < 0.01 && estimatedCostUSD > 0 {
            return String(format: "<$0.01")
        }
        return String(format: "$%.2f", estimatedCostUSD)
    }

    var formattedTokens: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        }
        if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }
}
