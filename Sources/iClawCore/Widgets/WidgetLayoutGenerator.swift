import Foundation
import os

/// Generates dynamic widget layouts from tool ingredients via an on-device LLM call.
///
/// This actor is invoked after OutputFinalizer when no tool widget was returned
/// and the ingredients contain substantial structured data. It makes a separate
/// LLM call with a compact DSL reference, and the LLM outputs a `<dw>` block
/// that `DynamicWidgetParser` converts to `DynamicWidgetData`.
public actor WidgetLayoutGenerator {

    private let llmAdapter: LLMAdapter

    /// Minimum ingredient length to trigger layout generation.
    static let minIngredientLength = 100

    /// Maximum estimated token cost for the layout prompt before we skip generation.
    static let maxPromptTokenBudget = 2000

    public init(llmAdapter: LLMAdapter = .shared) {
        self.llmAdapter = llmAdapter
    }

    /// Examines ingredients and generates a DynamicWidgetData if the data warrants visual presentation.
    /// Returns nil if the data is conversational or doesn't benefit from a widget.
    public func generateLayout(
        ingredients: [String],
        userPrompt: String,
        templateHint: String? = nil
    ) async -> DynamicWidgetData? {
        let substantive = IngredientFilter.substantive(ingredients)

        let combined = substantive.joined(separator: "\n")
        guard combined.count >= Self.minIngredientLength else { return nil }

        let prompt = buildPrompt(ingredients: combined, userPrompt: userPrompt, templateHint: templateHint)

        let estimatedTokens = AppConfig.estimateTokens(for: prompt)
        guard estimatedTokens <= Self.maxPromptTokenBudget else {
            Log.engine.debug("WidgetLayoutGenerator skipped: prompt estimated at \(estimatedTokens) tokens, exceeds budget")
            return nil
        }

        do {
            // DSL output — deterministic structure critical. Greedy + 300-token cap.
            let response = try await llmAdapter.generateText(prompt, profile: .widgetLayout)

            let (_, widget) = DynamicWidgetParser.parse(response)
            if let widget {
                guard !widget.blocks.isEmpty else {
                    Log.engine.debug("WidgetLayoutGenerator produced empty blocks — discarding")
                    return nil
                }
                Log.engine.debug("WidgetLayoutGenerator produced \(widget.blocks.count) blocks")
            }
            return widget
        } catch {
            Log.engine.error("WidgetLayoutGenerator failed: \(error)")
            return nil
        }
    }

    // MARK: - Prompt

    private func buildPrompt(ingredients: String, userPrompt: String, templateHint: String?) -> String {
        var prompt = """
        You are a layout designer. Given data about "\(userPrompt)", output a <dw> block.
        ALWAYS output a <dw> block when the data contains 2+ facts or values. \
        Use 3-6 blocks total. Pick the 1-2 block types that best fit — do NOT use every type.

        DSL (pipe-delimited lines inside <dw></dw>):
        tint:<color>  — pick ONE: blue,green,orange,red,purple,yellow,mint,indigo,teal
        H|icon|title|subtitle?  — header with SF Symbol. Pick a fitting icon: person.fill, globe, car.fill, building.2, fork.knife, chart.bar, cpu, leaf, sportscourt, trophy.fill, heart.fill, book.fill, banknote, film, music.note
        S|value|label  — single hero stat. value MUST be a number or metric (e.g. "23", "$4.2T", "38.9M"), NEVER a title or category name
        SR|val1;label1|val2;label2  — stat row, 2-4 items. Each item MUST have a numeric value, not a label
        KV|key|value  — key-value pair (consecutive lines auto-group)
        L|title|subtitle?|trailing?  — list item (consecutive lines auto-group)
        TB|col1|col2|col3  — table header
        TR|val1|val2|val3  — table row (consecutive lines auto-group under TB)
        T|text|caption  — footnote or source attribution
        D  — divider between sections

        Rules:
        - Header first, then 1-2 content sections. That's it.
        - For bio/profile data: H + KV pairs.
        - For comparisons: ALWAYS use H + TB/TR table. NEVER put both items' data in one KV value.
        - For ranked/ordered data: H + L list items.
        - For metrics/stats: H + S or SR.
        - Omit data you don't have. Never use 0 or "unknown" as placeholder values.
        - Do NOT include IMG or P blocks.
        - Keep labels short (2-3 words max).
        - Do NOT repeat the same data across blocks (e.g. don't show Population in both S and KV).
        NEVER do: S|Nutritional Comparison (stat value must be a NUMBER). SR|Spec|Car A|Car B (use TB/TR table instead).
        """

        // Few-shot examples
        prompt += """


        Examples:

        Person bio:
        <dw>
        tint:purple
        H|person.fill|Serena Williams|Tennis, USA
        S|23|Grand Slam Titles
        KV|Born|September 26, 1981
        KV|Turned Pro|1995
        KV|Career Titles|73
        KV|Weeks at #1|319
        </dw>

        Comparison:
        <dw>
        tint:blue
        H|car.fill|Tesla Model 3 vs BMW i4
        TB|Spec|Model 3|i4
        TR|Range|358 mi|301 mi
        TR|0-60 mph|3.1s|5.5s
        TR|Horsepower|510|335
        TR|Base Price|$42,990|$52,200
        </dw>

        Country facts:
        <dw>
        tint:green
        H|globe|Canada
        SR|38.9M;Population|9.98M km²;Area|$2.1T;GDP
        KV|Capital|Ottawa
        KV|Languages|English, French
        KV|Currency|Canadian Dollar
        </dw>
        """

        if let hint = templateHint {
            prompt += "\n\nFor similar queries, this layout worked well: \(hint). Reuse or adapt it."
        }

        prompt += "\n\nData:\n\(ingredients)"

        return prompt
    }
}
