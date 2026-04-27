import Foundation

/// Result of a guardrail validation check.
public enum GuardrailResult: Sendable {
    /// Validation passed — proceed normally.
    case passed
    /// Validation passed but the input/output was modified (e.g., sanitized).
    case modified(String)
    /// Validation failed — block execution with the given reason.
    case blocked(reason: String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// Validates input before it reaches the agent or tool.
///
/// Replaces scattered inline checks (toxicity filter, spellcheck, permission
/// checks) with a composable protocol. New guardrails (budget enforcement,
/// fact validation) slot in without modifying ExecutionEngine.
public protocol InputGuardrail: Sendable {
    /// A short identifier for logging.
    var name: String { get }
    /// Validates the input. Return `.passed`, `.modified(correctedInput)`, or `.blocked(reason:)`.
    func validate(_ input: String, entities: ExtractedEntities?) async -> GuardrailResult
}

/// Validates tool output before it becomes an ingredient.
///
/// Replaces the inline ingredient validation logic in ExecutionEngine
/// (domain keyword check, entity overlap, LLM validation) with a composable
/// protocol. The ReAct re-routing behavior is now expressed as a guardrail
/// returning `.blocked`, which the engine interprets as "suppress and re-route".
public protocol OutputGuardrail: Sendable {
    /// A short identifier for logging.
    var name: String { get }
    /// Validates the tool output against the original query context.
    func validate(output: ToolIO, toolName: String, query: String, entities: ExtractedEntities?) async -> GuardrailResult
}

/// Runs a chain of input guardrails, short-circuiting on block.
public enum GuardrailRunner {
    /// Runs input guardrails in order. Returns the (possibly modified) input, or nil if blocked.
    public static func runInput(
        _ guardrails: [any InputGuardrail],
        input: String,
        entities: ExtractedEntities?
    ) async -> (input: String, blocked: String?) {
        var current = input
        for guardrail in guardrails {
            let result = await guardrail.validate(current, entities: entities)
            switch result {
            case .passed:
                continue
            case .modified(let corrected):
                Log.engine.debug("Guardrail '\(guardrail.name)' modified input")
                current = corrected
            case .blocked(let reason):
                Log.engine.debug("Guardrail '\(guardrail.name)' blocked: \(reason)")
                return (current, reason)
            }
        }
        return (current, nil)
    }

    /// Runs output guardrails in order. Returns the result or a block reason.
    public static func runOutput(
        _ guardrails: [any OutputGuardrail],
        output: ToolIO,
        toolName: String,
        query: String,
        entities: ExtractedEntities?
    ) async -> GuardrailResult {
        for guardrail in guardrails {
            let result = await guardrail.validate(output: output, toolName: toolName, query: query, entities: entities)
            if result.isBlocked {
                return result
            }
        }
        return .passed
    }
}
