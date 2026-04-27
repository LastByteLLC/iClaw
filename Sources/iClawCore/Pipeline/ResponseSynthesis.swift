import Foundation
import FoundationModels

extension ExecutionEngine {
    // MARK: - Guardrail Fallback

    /// Builds a response from raw ingredients when the LLM refuses due to safety guardrails.
    /// Uses ExtractiveSummarizer (NLP sentence embeddings) for semantic summarization -- no LLM involved.
    func buildGuardrailFallbackResponse(ingredients: [String], userPrompt: String) -> String {
        // Filter to substantive ingredients (skip meta-instructions)
        let substantive = ingredients.filter { ingredient in
            !ingredient.hasPrefix("No tool is needed") &&
            !ingredient.hasPrefix("No data was retrieved") &&
            !ingredient.hasPrefix("Skill Instruction:")
        }

        guard !substantive.isEmpty else {
            return errorFallbackPhrases.randomElement() ?? "Can't process that one. Try rephrasing?"
        }

        // Strip [VERIFIED] / [CACHED] prefixes for cleaner output
        let combined = substantive.map { ingredient in
            var text = ingredient
            for prefix in ["[VERIFIED] [CACHED] ", "[VERIFIED] ", "[CACHED] "] {
                if text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count))
                }
            }
            return text
        }.joined(separator: "\n\n")

        // Use NLP extractive summarization biased toward the user's query
        let summarized = ExtractiveSummarizer.summarize(combined, maxSentences: 8, query: userPrompt)

        // Return the summary directly without preamble. The "Here's what I
        // found:" prefix that used to be here was a leak-shaped user string
        // (readers flagged it as a template marker). Empty content falls
        // back to a randomized error phrase.
        let trimmedSummary = summarized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSummary.isEmpty {
            return errorFallbackPhrases.randomElement() ?? "Can't process that one. Try rephrasing?"
        }

        return trimmedSummary
    }

    // MARK: - User-Friendly Tool Names

    /// Loaded from ToolFriendlyNames.json — maps ML labels and tool names to descriptions.
    private static let friendlyNames: [String: String] = ConfigLoader.load("ToolFriendlyNames", as: [String: String].self) ?? [:]

    /// Maps internal tool names / ML labels to user-friendly descriptions for disambiguation.
    static func userFriendlyToolName(_ name: String) -> String {
        friendlyNames[name.lowercased()]
            ?? name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
    }

    // MARK: - Widget / Tool Name Mapping

    /// Maps a widget type string back to a tool name. Shared between
    /// `updatePriorContext` and `recordTurn` to avoid duplication.
    public static let widgetToToolMap: [String: String] = [
        "newswidget": "News", "weatherwidget": "Weather",
        "weatherforecastwidget": "Weather", "weathercomparisonwidget": "Weather",
        "stockwidget": "Stocks", "clockwidget": "Time",
        "timecomparisonwidget": "Time", "timerwidget": "Timer",
        "calendarwidget": "Calendar", "dictionarywidget": "Dictionary",
        "mapwidget": "Maps", "randomwidget": "Random",
        "todaysummarywidget": "Today", "emaillistwidget": "ReadEmail",
        "mathwidget": "Calculator", "audioplayerwidget": "Transcribe",
        "podcastepisodeswidget": "Podcast", "feedbackwidget": "Feedback",
        "remotefilelistwidget": "Remote", "createwidget": "Create",
        "researchwidget": "Research",
        "moonwidget": "Weather",
        "dynamicwidget": "Dynamic",
    ]

    static func toolNameFromWidget(_ widgetType: String?) -> String? {
        guard let wt = widgetType else { return nil }
        return widgetToToolMap[wt.lowercased()]
    }

}
