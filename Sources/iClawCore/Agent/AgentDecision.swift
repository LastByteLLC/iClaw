import Foundation
import FoundationModels

/// Structured output from the agent loop's continuation check.
///
/// After each tool execution turn, the agent asks the LLM whether the task
/// is complete or needs more work. This replaces the hardcoded `needsMoreSteps()`
/// heuristic (which only checked for "compare" keywords) with a general-purpose
/// LLM decision that works across all query types.
@Generable
public struct AgentDecision: ConvertibleFromGeneratedContent, Sendable, Codable {
    @Guide(description: "true if the task is fully complete and a final answer can be given")
    public var isComplete: Bool

    @Guide(description: "If not complete, describe the next step needed in one sentence")
    public var nextStep: String?

    @Guide(description: "true if the agent needs to ask the user a clarifying question before proceeding")
    public var needsUserInput: Bool

    @Guide(description: "If needsUserInput is true, the question to ask the user")
    public var userQuestion: String?
}

extension AgentDecision: JSONSchemaProviding {
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "isComplete": ["type": "boolean", "description": "true if the task is fully complete"],
                "nextStep": ["type": "string", "description": "next step needed if not complete"],
                "needsUserInput": ["type": "boolean", "description": "true if a clarifying question is needed"],
                "userQuestion": ["type": "string", "description": "the question to ask the user"]
            ],
            "required": ["isComplete", "needsUserInput"]
        ]
    }
}
