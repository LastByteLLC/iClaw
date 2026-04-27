import Foundation

/// Response formatting rules loaded from ResponseFormatting.json.
struct ResponseFormattingConfig: Decodable {
    let concisenessRules: [ConcisenessRule]
    let charLimitMultiplier: Int
    let minCharLimitForTruncation: Int

    struct ConcisenessRule: Decodable {
        let maxWords: Int
        let maxIngredients: Int
        let instruction: String
    }

    static let shared: ResponseFormattingConfig = ConfigLoader.load("ResponseFormatting", as: ResponseFormattingConfig.self) ?? .defaults

    /// Returns the conciseness instruction for the given word count and ingredient count.
    func concisenessInstruction(promptWords: Int, ingredientCount: Int) -> String {
        for rule in concisenessRules {
            if promptWords <= rule.maxWords && ingredientCount <= rule.maxIngredients {
                return rule.instruction
            }
        }
        return concisenessRules.last?.instruction ?? "3-6 sentences"
    }

    static let defaults = ResponseFormattingConfig(
        concisenessRules: [
            ConcisenessRule(maxWords: 8, maxIngredients: 1, instruction: "1-2 sentences"),
            ConcisenessRule(maxWords: 20, maxIngredients: 3, instruction: "2-4 sentences"),
            ConcisenessRule(maxWords: 999, maxIngredients: 999, instruction: "3-6 sentences"),
        ],
        charLimitMultiplier: 4,
        minCharLimitForTruncation: 50
    )
}
