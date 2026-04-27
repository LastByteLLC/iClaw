import Foundation

/// A multi-step execution plan decomposed from a complex user query.
///
/// This is the legacy plan format used by ExecutionEngine. New code should use
/// `AgentPlan` (which uses `@Generable` structured output). This type is retained
/// for backward compatibility with `executePlan()` and `ChainableTool`.
public struct ExecutionPlan: Sendable {

    /// A single step in the execution plan.
    public struct Step: Sendable {
        /// The tool to invoke (matched by name via ToolNameNormalizer).
        public let toolName: String
        /// The input template. May contain `{{prev}}` to reference the prior step's result.
        public let inputTemplate: String

        public init(toolName: String, inputTemplate: String) {
            self.toolName = toolName
            self.inputTemplate = inputTemplate
        }

        /// Resolves the input template by substituting `{{prev}}` with the prior result.
        public func resolveInput(priorResult: String?) -> String {
            guard let prior = priorResult else { return inputTemplate }
            return inputTemplate.replacingOccurrences(of: "{{prev}}", with: prior)
        }
    }

    /// The ordered steps to execute.
    public let steps: [Step]

    /// Whether this is a multi-step plan (vs a passthrough single step).
    public var isMultiStep: Bool { steps.count > 1 }

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// A trivial single-step plan that just runs the routed tool with original input.
    public static func singleStep(toolName: String, input: String) -> ExecutionPlan {
        ExecutionPlan(steps: [Step(toolName: toolName, inputTemplate: input)])
    }
}

// MARK: - Planner

/// Decomposes complex queries into multi-step execution plans.
///
/// Now delegates to `AgentPlanner` for LLM-based decomposition using `@Generable`
/// structured output, eliminating the hardcoded English heuristics (`needsPlanning()`)
/// and fragile `"ToolName: input"` string parsing.
public actor ExecutionPlanner {

    /// Closure for injecting a test LLM responder.
    public typealias PlannerLLMResponder = SimpleLLMResponder

    private let llmResponder: PlannerLLMResponder?
    private let agentPlanner: AgentPlanner

    public init(llmResponder: PlannerLLMResponder? = nil, llmAdapter: LLMAdapter? = nil) {
        self.llmResponder = llmResponder
        // When a test LLM responder is provided, create an AgentPlanner with
        // a compatible override that uses the test responder.
        // Also pass the LLM adapter so the fallback path (when the override throws)
        // uses the test adapter instead of LLMAdapter.shared (real Apple Intelligence).
        if let responder = llmResponder {
            self.agentPlanner = AgentPlanner(plannerOverride: { input, tools in
                let prompt = "Decompose: \(input). Tools: \(tools.sorted().joined(separator: ", "))"
                let response = try await responder(prompt)
                // Parse test response as "ToolName: input" lines for backward compatibility
                let steps = ExecutionPlanner.parseLegacySteps(from: response, knownTools: tools)
                return AgentPlan(steps: steps)
            }, llmAdapter: llmAdapter ?? .shared)
        } else {
            self.agentPlanner = AgentPlanner(llmAdapter: llmAdapter ?? .shared)
        }
    }

    /// Available tool names for the planner to reference.
    private static var knownTools: Set<String> {
        Set(ToolRegistry.allToolNames)
    }

    /// Analyzes a query and returns a structured agent plan.
    ///
    /// Delegates to `AgentPlanner` for LLM-based decomposition. The LLM decides
    /// whether 1 or multiple steps are needed — no hardcoded English heuristics.
    /// Returns `AgentPlan` directly (no intermediate `ExecutionPlan` conversion).
    public func plan(input: String, routedToolName: String) async -> AgentPlan {
        return await agentPlanner.plan(
            input: input,
            availableTools: Self.knownTools,
            routedTool: routedToolName
        )
    }

    /// Parses legacy "ToolName: input" format from test responders.
    static func parseLegacySteps(from response: String, knownTools: Set<String>) -> [PlanStep] {
        let lines = response.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var steps: [PlanStep] = []
        for line in lines.prefix(3) {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let toolName = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let stepInput = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            let matchedTool = knownTools.first { $0.caseInsensitiveCompare(toolName) == .orderedSame }
            guard let validTool = matchedTool, !stepInput.isEmpty else { continue }

            let hasDependency = stepInput.contains("{{prev}}")
            steps.append(PlanStep(
                toolName: validTool,
                input: stepInput.replacingOccurrences(of: "{{prev}}", with: ""),
                dependsOnPrevious: hasDependency
            ))
        }
        return steps
    }
}
