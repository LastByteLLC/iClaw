import Foundation
import FoundationModels

/// LLM-based verification of ML classifier routing decisions.
///
/// Replaces the hardcoded English keyword heuristic overrides in ToolRouter
/// (unit keywords, compute signals, entity lookup verbs, comparison connectors,
/// local indicators, contact indicators, stock hint words, system keywords,
/// financial keywords — ~600+ phrases across RouterHeuristics.json, ComputeSignals.json,
/// WeatherKeywords.json, etc.) with a single structured LLM call via `LLMAdapter`.
///
/// This is language-agnostic by design: the on-device model understands intent
/// semantically rather than through keyword matching, enabling multi-lingual
/// support without translating ~6000+ phrases to each target language.
///
/// Cost: ~100 tokens, ~1-2s. Only called when ML classifier confidence is in the
/// medium range (0.35-0.90) where heuristic overrides previously fired.
/// High-confidence matches skip this entirely (fast path).

// MARK: - Structured Output Types

/// The LLM's assessment of whether a routing decision is correct.
@Generable
public struct RoutingVerification: ConvertibleFromGeneratedContent, Sendable, Codable {
    @Guide(description: "true if the suggested tool is the best match for this query")
    public var isCorrect: Bool

    @Guide(description: "If not correct, the name of the better tool from the available list, or nil if no tool is needed")
    public var betterTool: String?

    @Guide(description: "true if this query needs no tool — it is conversational, emotional, a meta-question about the assistant, or simply does not require any tool action")
    public var isConversational: Bool

    @Guide(description: "Brief reason, in 5 words or fewer")
    public var reason: String?
}

extension RoutingVerification: JSONSchemaProviding {
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "isCorrect": ["type": "boolean", "description": "true if the suggested tool is the best match for this query"],
                "betterTool": ["type": "string", "description": "name of a better tool from the available list, or null"],
                "isConversational": ["type": "boolean", "description": "true if no tool is needed — conversational, emotional, or meta-question"],
                "reason": ["type": "string", "description": "brief reason in 5 words or fewer"]
            ],
            "required": ["isCorrect", "isConversational"]
        ]
    }
}

// MARK: - Verifier Actor

/// Verifies and corrects ML classifier routing decisions using `LLMAdapter`.
///
/// All LLM calls go through `LLMAdapter.shared.generateStructured()` — never
/// `LanguageModelSession` directly — so the backend can be swapped (e.g., to
/// the maclocal-api HTTP server or a future cloud provider).
public actor ToolVerifier {

    /// Test injection for verification.
    public typealias VerifierOverride = @Sendable (String, String, [String]) async throws -> RoutingVerification

    private let verifierOverride: VerifierOverride?
    private let llmAdapter: LLMAdapter

    public init(verifierOverride: VerifierOverride? = nil, llmAdapter: LLMAdapter = .shared) {
        self.verifierOverride = verifierOverride
        self.llmAdapter = llmAdapter
    }

    /// Verifies whether the ML classifier's tool choice is correct for the given query.
    ///
    /// Only called for medium-confidence ML results (0.35-0.90). High-confidence
    /// results skip verification (fast path). Low-confidence results go to the
    /// full agent planner.
    public func verify(
        query: String,
        suggestedTool: String,
        availableTools: [String]
    ) async -> RoutingVerification {
        if let override = verifierOverride {
            do {
                return try await override(query, suggestedTool, availableTools)
            } catch {
                Log.engine.debug("Verifier override failed: \(error)")
                return RoutingVerification(isCorrect: true, betterTool: nil, isConversational: false, reason: nil)
            }
        }

        let toolList = availableTools.prefix(15).joined(separator: ", ")
        let instructions = makeInstructions {
            Directive("""
            You verify tool routing decisions. The user's query was matched to \
            '\(suggestedTool)'. Available tools: \(toolList). \
            Is '\(suggestedTool)' the best tool for this query? If not, which tool is better? \
            If the query is conversational, emotional, a greeting, feedback about the assistant, \
            a meta-question about the assistant's capabilities, or simply does not need any tool, \
            set isConversational to true.
            """)
        }

        do {
            return try await llmAdapter.generateStructured(
                prompt: query,
                instructions: instructions,
                generating: RoutingVerification.self,
                profile: .extraction
            )
        } catch {
            Log.engine.debug("Tool verification LLM failed: \(error). Trusting ML classifier.")
            return RoutingVerification(isCorrect: true, betterTool: nil, isConversational: false, reason: nil)
        }
    }

}
