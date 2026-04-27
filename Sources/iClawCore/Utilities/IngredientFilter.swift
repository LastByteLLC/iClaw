/// Centralized filter for meta-text ingredients that should not reach
/// LLM finalization, widget generation, or fact compression.
///
/// Previously duplicated across ExecutionEngine (4 copies with varying
/// prefix sets) and WidgetLayoutGenerator (1 copy). This single definition
/// uses the union of all required prefixes.
public enum IngredientFilter {

    /// Prefixes that mark an ingredient as non-substantive meta-text.
    private static let metaPrefixes: [String] = [
        "No tool",
        "No data",
        "No matching tool",
        "No specific tool",
        "Skill Instruction:",
        "Screen context",
        "Will use FM Tool:",
        "This request is ambiguous",
        "[ERROR]"
    ]

    /// Returns `true` if the ingredient contains actual tool data
    /// (not routing/disambiguation/error meta-text).
    public static func isSubstantive(_ ingredient: String) -> Bool {
        !metaPrefixes.contains { ingredient.hasPrefix($0) }
    }

    /// Filters an ingredient array down to substantive entries only.
    public static func substantive(_ ingredients: [String]) -> [String] {
        ingredients.filter { isSubstantive($0) }
    }
}
