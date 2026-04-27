import Foundation
import FoundationModels

/// Result of an agent execution run.
public struct AgentResult: Sendable {
    /// The accumulated facts produced during execution.
    public let facts: [Fact]
    /// Raw text ingredients for finalization.
    public let ingredients: [String]
    /// Total agent turns consumed.
    public let turnsUsed: Int
    /// Widget type from the last tool execution, if any.
    public let widgetType: String?
    /// Widget data from the last tool execution, if any.
    public let widgetData: (any Sendable)?
    /// If the agent needs user input before continuing.
    public let pendingQuestion: String?
    /// Whether any tool encountered an error.
    public let hadError: Bool

    public init(
        facts: [Fact] = [],
        ingredients: [String] = [],
        turnsUsed: Int = 0,
        widgetType: String? = nil,
        widgetData: (any Sendable)? = nil,
        pendingQuestion: String? = nil,
        hadError: Bool = false
    ) {
        self.facts = facts
        self.ingredients = ingredients
        self.turnsUsed = turnsUsed
        self.widgetType = widgetType
        self.widgetData = widgetData
        self.pendingQuestion = pendingQuestion
        self.hadError = hadError
    }
}

/// The outer reasoning loop for complex queries.
///
/// Wraps `LanguageModelSession` with turn management, domain-scoped tool sets,
/// and structured continuation decisions. Apple's `respond(to:)` handles the
/// inner tool-call loop (parallel/serial calls, transcript insertion, continuation).
/// The AgentRunner adds the outer loop: "does the task need another turn?"
///
/// Design principles:
/// - Only 3-8 tools registered per session (scoped by domain) — AFM handles this well
/// - Each turn produces structured facts for working memory
/// - Continuation decision is LLM-based via `@Generable AgentDecision`
/// - No hardcoded English phrases — all decisions are semantic
public actor AgentRunner {

    /// Maximum agent turns per execution. Bounded by token budget considerations.
    private let maxTurns: Int

    /// Optional test override for the LLM session.
    public typealias RunnerLLMResponder = SimpleLLMResponder

    private let llmResponder: RunnerLLMResponder?
    private let llmAdapter: LLMAdapter

    /// Optional override for core tools — allows tests to inject spy tools
    /// instead of relying on `ToolProvider.coreTools(for:)`.
    private let coreToolsOverride: [any CoreTool]?

    public init(
        maxTurns: Int = AppConfig.maxToolCallsPerTurn,
        llmResponder: RunnerLLMResponder? = nil,
        llmAdapter: LLMAdapter = .shared,
        coreToolsOverride: [any CoreTool]? = nil
    ) {
        self.maxTurns = maxTurns
        self.llmResponder = llmResponder
        self.llmAdapter = llmAdapter
        self.coreToolsOverride = coreToolsOverride
    }

    /// Executes a multi-step agent plan with inter-step reasoning.
    ///
    /// Unlike the old `executePlan()` which blindly ran steps with `{{prev}}`
    /// substitution, this method:
    /// 1. Executes each step using domain-scoped tools
    /// 2. Compresses results into structured facts
    /// 3. Asks the LLM if the task is complete after each step
    /// 4. Adapts or bails out based on intermediate results
    ///
    /// - Parameters:
    ///   - plan: The structured execution plan from `AgentPlanner`.
    ///   - query: The original user query.
    ///   - domains: Tool domains to scope the execution.
    ///   - entities: Extracted entities from preprocessing.
    ///   - outputGuardrails: Guardrails to validate each tool's output.
    /// - Returns: An `AgentResult` with accumulated facts and ingredients.
    public func execute(
        plan: AgentPlan,
        query: String,
        domains: Set<ToolDomain>,
        entities: ExtractedEntities?,
        outputGuardrails: [any OutputGuardrail] = []
    ) async -> AgentResult {
        let coreTools = coreToolsOverride ?? ToolProvider.coreTools(for: domains)
        var facts: [Fact] = []
        var ingredients: [String] = []
        var lastWidgetType: String?
        var lastWidgetData: (any Sendable)?
        var priorResult: String?
        var hadError = false
        var turnsUsed = 0

        for (index, step) in plan.steps.enumerated() {
            guard turnsUsed < maxTurns else {
                Log.engine.debug("AgentRunner: max turns (\(self.maxTurns)) reached at step \(index + 1)")
                break
            }

            // Budget pressure: signal the LLM when on the final available turn
            let isFinalTurn = turnsUsed == maxTurns - 1

            // Find the tool
            guard let tool = coreTools.first(where: { $0.name.caseInsensitiveCompare(step.toolName) == .orderedSame }) else {
                Log.engine.debug("AgentRunner: tool '\(step.toolName)' not found in scoped tools")
                continue
            }

            // Resolve input with prior result if dependent
            let resolvedInput = plan.resolvedInput(for: index, priorResult: priorResult)

            // Execute
            do {
                try Task.checkCancellation()
                let result = try await tool.execute(input: resolvedInput, entities: entities)
                turnsUsed += 1

                if result.status == .ok {
                    // Validate output against guardrails
                    let guardrailResult = await GuardrailRunner.runOutput(
                        outputGuardrails, output: result, toolName: tool.name,
                        query: query, entities: entities
                    )
                    if case .blocked(let reason) = guardrailResult {
                        Log.engine.debug("AgentRunner: output guardrail blocked step \(index + 1): \(reason)")
                        continue // Skip this step's output, try next step
                    }

                    // Compress into facts
                    let stepFacts = FactCompressorRegistry.compress(toolName: tool.name, result: result)
                    facts.append(contentsOf: stepFacts)

                    // Store raw ingredient for finalization
                    ingredients.append(result.text)
                    priorResult = result.text

                    // Dynamic compaction: when accumulated ingredients approach
                    // the data budget, compact older ones to their Fact form.
                    // Keeps the most recent ingredient raw (best for finalization)
                    // while freeing tokens for subsequent steps.
                    compactIngredientsIfNeeded(&ingredients, facts: facts)

                    // Track widget
                    if let wt = result.outputWidget { lastWidgetType = wt }
                    if let wd = result.widgetData { lastWidgetData = wd }
                } else {
                    hadError = true
                    ingredients.append(result.text)
                    break // Stop on error
                }
            } catch is CancellationError {
                break
            } catch {
                Log.engine.error("AgentRunner: step \(index + 1) failed: \(error)")
                hadError = true
                break
            }

            // For multi-step plans, check if we should continue
            if plan.isMultiStep && index < plan.steps.count - 1 {
                let continuationResult = await checkContinuation(
                    query: query,
                    completedSteps: index + 1,
                    totalSteps: plan.steps.count,
                    currentFacts: facts,
                    isFinalTurn: isFinalTurn
                )
                switch continuationResult {
                case .continue:
                    break // proceed to next step
                case .complete:
                    Log.engine.debug("AgentRunner: early exit after step \(index + 1) — task complete")
                    break
                case .clarify(let question):
                    Log.engine.debug("AgentRunner: pausing after step \(index + 1) — needs user input")
                    return AgentResult(
                        facts: facts,
                        ingredients: ingredients,
                        turnsUsed: turnsUsed,
                        widgetType: lastWidgetType,
                        widgetData: lastWidgetData,
                        pendingQuestion: question,
                        hadError: hadError
                    )
                }
                if case .complete = continuationResult { break }
            }
        }

        return AgentResult(
            facts: facts,
            ingredients: ingredients,
            turnsUsed: turnsUsed,
            widgetType: lastWidgetType,
            widgetData: lastWidgetData,
            pendingQuestion: nil,
            hadError: hadError
        )
    }

    // MARK: - Dynamic Ingredient Compaction

    /// When accumulated ingredient tokens exceed 70% of the data budget, compact
    /// older ingredients to their Fact form. Keeps the most recent ingredient raw
    /// (best quality for finalization) while freeing tokens for subsequent steps.
    private func compactIngredientsIfNeeded(_ ingredients: inout [String], facts: [Fact]) {
        let totalTokens = ingredients.reduce(0) { $0 + AppConfig.estimateTokens(for: $1) }
        let threshold = Int(Double(AppConfig.retrievedDataChunks) * 0.7)
        guard totalTokens > threshold, ingredients.count > 1 else { return }

        // Replace all but the last ingredient with compact fact representations
        let lastIngredient = ingredients.removeLast()
        var compacted: [String] = []
        for (i, ingredient) in ingredients.enumerated() {
            // Find the fact that corresponds to this ingredient position
            if i < facts.count {
                compacted.append(facts[i].compact())
            } else {
                // No matching fact — truncate the raw ingredient
                compacted.append(String(ingredient.prefix(100)))
            }
        }
        compacted.append(lastIngredient)
        ingredients = compacted
        Log.engine.debug("AgentRunner: compacted \(compacted.count - 1) older ingredients to save tokens")
    }

    // MARK: - Continuation Check

    /// Result of a continuation check after an agent step.
    private enum ContinuationResult {
        case `continue`
        case complete
        case clarify(question: String)
    }

    /// Asks the LLM whether the task is complete after intermediate steps.
    ///
    /// Uses `@Generable AgentDecision` for structured output. Returns a three-way
    /// result: continue, complete, or clarify (pause for user input).
    private func checkContinuation(
        query: String,
        completedSteps: Int,
        totalSteps: Int,
        currentFacts: [Fact],
        isFinalTurn: Bool = false
    ) async -> ContinuationResult {
        // If all planned steps are done, no need to check
        if completedSteps >= totalSteps { return .complete }

        // If test mode, always continue
        if llmResponder != nil { return .continue }

        // Budget pressure: if this is the final turn, signal the LLM to wrap up
        if isFinalTurn {
            Log.engine.debug("AgentRunner: budget pressure — final turn, forcing completion")
            return .complete
        }

        let factSummary = currentFacts.map { $0.compact() }.joined(separator: "; ")
        let budgetHint = (completedSteps >= totalSteps - 1)
            ? "\n[BUDGET: 1 turn remaining — summarize results if the next step is not critical]"
            : ""
        let prompt = """
        Original request: "\(query)"
        Completed \(completedSteps) of \(totalSteps) planned steps.
        Results so far: \(factSummary)\(budgetHint)
        Should I continue with the remaining steps, or is the task already complete?
        """

        do {
            let decision = try await llmAdapter.generateStructured(
                prompt: prompt,
                instructions: makeInstructions {
                    Directive("You are a task completion checker. Decide if more steps are needed.")
                },
                generating: AgentDecision.self,
                profile: .planning
            )

            if decision.isComplete {
                return .complete
            }
            if decision.needsUserInput, let question = decision.userQuestion, !question.isEmpty {
                return .clarify(question: question)
            }
            if decision.needsUserInput {
                return .clarify(question: "I need more information to continue. Could you clarify?")
            }
            return .continue
        } catch {
            Log.engine.debug("AgentRunner: continuation check failed: \(error). Continuing.")
            return .continue
        }
    }
}
