import Foundation
import FoundationModels

// MARK: - @Generable Extraction Type

/// LLM-extracted knowledge from user input. The model identifies personal facts,
/// preferences, and relationships that should be remembered across sessions.
@Generable
public struct KnowledgeExtractionResult: ConvertibleFromGeneratedContent, Sendable, Codable {
    @Guide(description: "Category: 'personal', 'preference', 'relationship', or empty if nothing to remember")
    public var category: String

    @Guide(description: "Short entity key, e.g. 'vegetarian', 'home_city', 'Sarah'. Empty if nothing to remember.")
    public var key: String

    @Guide(description: "Compressed fact value, e.g. 'wife, prefers texts', 'Austin, TX'. Empty if nothing to remember.")
    public var value: String
}

extension KnowledgeExtractionResult: JSONSchemaProviding {
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "category": ["type": "string", "description": "personal, preference, relationship, or empty"],
                "key": ["type": "string", "description": "short entity key, or empty"],
                "value": ["type": "string", "description": "compressed fact value, or empty"]
            ],
            "required": ["category", "key", "value"]
        ]
    }
}

// MARK: - Heuristic Gate

/// Determines whether user input likely contains knowledge worth extracting.
/// Returns true for ~20% of inputs (those with personal signals), avoiding
/// unnecessary LLM calls on pure tool commands and factual queries.
public func shouldAttemptKnowledgeExtraction(from input: String) -> Bool {
    let lower = input.lowercased()

    // Skip very short inputs (tool chips, commands)
    guard input.count > 10 else { return false }

    // Skip pure tool commands
    if lower.hasPrefix("#") || lower.hasPrefix("$") { return false }

    // Personal pronouns + possessives
    let personalSignals = [
        " i ", " i'm ", " i am ", " my ", " me ", " we ", " our ",
        " mine ", " myself ", " i've ", " i'd ", " i'll ",
    ]

    // Relationship words
    let relationshipSignals = [
        "wife", "husband", "partner", "boss", "manager", "friend",
        "daughter", "son", "mom", "dad", "mother", "father",
        "sister", "brother", "colleague", "coworker",
    ]

    // Preference indicators
    let preferenceSignals = [
        "prefer", "always", "never", "don't like", "i like",
        "i love", "i hate", "usually", "i want", "i need",
        "allergic", "vegetarian", "vegan", "gluten",
    ]

    // Location/identity indicators
    let identitySignals = [
        "i live", "i'm from", "i work", "my name",
        "i moved", "born in", "grew up",
    ]

    let paddedLower = " \(lower) "
    let allSignals = personalSignals + relationshipSignals + preferenceSignals + identitySignals
    return allSignals.contains { paddedLower.contains($0) }
}

// MARK: - Extraction

/// Attempt to extract knowledge from user input using the LLM.
/// Only called when `shouldAttemptKnowledgeExtraction` returns true.
public func extractKnowledge(from input: String, adapter: LLMAdapter) async -> KnowledgeExtractionResult? {
    let prompt = """
    Extract a personal fact, preference, or relationship from this user message. \
    If the message contains nothing personal worth remembering, return empty strings.

    Message: "\(input)"
    """

    do {
        let result = try await adapter.generateStructured(
            prompt: prompt,
            generating: KnowledgeExtractionResult.self,
            profile: .extraction
        )
        // Validate: non-empty key and value means something was extracted
        guard !result.key.trimmingCharacters(in: .whitespaces).isEmpty,
              !result.value.trimmingCharacters(in: .whitespaces).isEmpty,
              !result.category.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return result
    } catch {
        return nil
    }
}
