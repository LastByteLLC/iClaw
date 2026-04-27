import Foundation
import NaturalLanguage
/// A type alias for the LLM responder used by FeedbackTool.
public typealias FeedbackLLMResponder = SafeLLMResponder

/// CoreTool that processes user feedback on agent responses.
/// Parses the conversation chain, generates dynamic follow-up suggestions
/// and sentiment analysis via on-device LLM, and returns a FeedbackWidget
/// for interactive review.
public struct FeedbackTool: CoreTool, Sendable {
    public let name = "Feedback"
    public let schema = "Give feedback on a response, report an issue, or flag something wrong."
    public let isInternal = false
    public let category = CategoryEnum.offline

    private let llmResponder: FeedbackLLMResponder?
    private let llmAdapter: LLMAdapter

    public init(llmResponder: FeedbackLLMResponder? = nil, llmAdapter: LLMAdapter = .shared) {
        self.llmResponder = llmResponder
        self.llmAdapter = llmAdapter
    }

    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            // Parse chain prefix: [Feedback on: "u1"→"a1" | "u2"→"a2"]
            let chain = parseChain(from: input)
            let feedbackText = stripChainPrefix(from: input)

            guard !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolIO(
                    text: "Tell me what's on your mind — what went wrong, what could be better, or what you liked.",
                    status: .ok
                )
            }

            // Build summary
            var summary = "Feedback: \(feedbackText)"
            if !chain.isEmpty {
                let chainDesc = chain.map { "You: \"\($0.user)\" → iClaw: \"\($0.agent)\"" }.joined(separator: "\n")
                summary = "Context:\n\(chainDesc)\n\nFeedback: \(feedbackText)"
            }

            // Generate dynamic follow-up suggestions via LLM
            let suggestions = await generateSuggestions(feedbackText: feedbackText, summary: summary)

            let widgetData = FeedbackWidgetData(
                phase: .review,
                summary: summary,
                suggestedQuestions: suggestions
            )

            return ToolIO(
                text: summary,
                status: .ok,
                outputWidget: "FeedbackWidget",
                widgetData: widgetData
            )
        }
    }

    // MARK: - LLM Suggestions

    private func generateSuggestions(feedbackText: String, summary: String) async -> [String] {
        let prompt = """
        Analyze this user feedback and respond with EXACTLY this format:
        Q1: [follow-up question based on their specific feedback]
        Q2: [another relevant follow-up question]
        Q3: [a third follow-up question]

        The questions should be specific to what the user said, not generic.
        For positive feedback, ask what they liked most.
        For negative feedback, ask for specifics on what to improve.

        Feedback: \(feedbackText)
        """

        do {
            let response: String
            if let responder = llmResponder {
                response = await responder(prompt, "")
            } else {
                response = try await llmAdapter.generateText(prompt, profile: .feedbackSuggestions)
            }

            var suggestions: [String] = []

            let lines = response.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Q1:") || trimmed.hasPrefix("Q2:") || trimmed.hasPrefix("Q3:") {
                    let question = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if !question.isEmpty {
                        suggestions.append(question)
                    }
                }
            }

            if suggestions.isEmpty {
                suggestions = fallbackSuggestions(feedbackText: feedbackText)
            }

            return suggestions
        } catch {
            Log.tools.debug("Feedback LLM call failed: \(error.localizedDescription)")
            return fallbackSuggestions(feedbackText: feedbackText)
        }
    }

    private func fallbackSuggestions(feedbackText: String) -> [String] {
        // Multilingual sentiment via Apple's built-in NLTagger. Returns a
        // score in [-1, 1] where >0 is positive, <0 is negative, 0 is neutral.
        // Works for ~12 languages out of the box — this path used to be an
        // English-only contains("love") || contains("bug") keyword list that
        // always hit the generic bucket for non-English feedback.
        let score = Self.sentimentScore(of: feedbackText)
        if score > 0.15 {
            return [
                "What feature do you use most?",
                "Anything you'd like to see added?",
                "Would you recommend iClaw to others?"
            ]
        } else if score < -0.15 {
            return [
                "What were you doing when this happened?",
                "Does this happen every time?",
                "Which tool or feature was affected?"
            ]
        } else {
            return [
                "What specifically should have been different?",
                "Was the information wrong or just the phrasing?",
                "Can you give an example of a better response?"
            ]
        }
    }

    /// Returns the document-level sentiment score of `text` in range [-1, 1],
    /// or 0 when unavailable. `NLTagger` is multilingual on supported
    /// languages; unsupported inputs return 0 (neutral bucket).
    private static func sentimentScore(of text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = trimmed
        let (tag, _) = tagger.tag(
            at: trimmed.startIndex,
            unit: .paragraph,
            scheme: .sentimentScore
        )
        guard let raw = tag?.rawValue, let score = Double(raw) else { return 0 }
        return score
    }

    // MARK: - Parsing

    func parseChain(from input: String) -> [(user: String, agent: String)] {
        guard let bracketRange = input.range(of: "\\[Feedback on: .+?\\]", options: .regularExpression) else {
            return []
        }
        let bracketContent = String(input[bracketRange])
        var pairs: [(user: String, agent: String)] = []

        let pairPattern = try? NSRegularExpression(pattern: "\"([^\"]+)\"→\"([^\"]+)\"")
        let nsString = bracketContent as NSString
        let matches = pairPattern?.matches(in: bracketContent, range: NSRange(location: 0, length: nsString.length)) ?? []

        for match in matches {
            if match.numberOfRanges >= 3 {
                let user = nsString.substring(with: match.range(at: 1))
                let agent = nsString.substring(with: match.range(at: 2))
                pairs.append((user: user, agent: agent))
            }
        }
        return pairs
    }

    func stripChainPrefix(from input: String) -> String {
        guard let bracketRange = input.range(of: "\\[Feedback on: .+?\\]", options: .regularExpression) else {
            return input
        }
        var result = input
        result.removeSubrange(bracketRange)
        if result.hasPrefix("\n") { result = String(result.dropFirst()) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
