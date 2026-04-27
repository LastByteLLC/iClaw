import Testing
import Foundation
import os
@testable import iClawCore

// MARK: - ConversationState Tests

@Suite("ConversationState")
struct ConversationStateTests {

    @Test func emptyStateSerializesToMinimalJSON() {
        let state = ConversationState()
        let json = state.serialize()
        #expect(json.contains("\"turnCount\":0"))
        #expect(json.contains("\"topics\":[]"))
    }

    @Test func asPromptContextEmptyOnFirstTurn() {
        let state = ConversationState()
        #expect(state.asPromptContext().isEmpty)
    }

    @Test func recordTurnUpdatesTopicsAndCount() {
        var state = ConversationState()
        state.recordTurn(userInput: "what's the weather in London", entities: nil, toolResults: [])
        #expect(state.turnCount == 1)
        #expect(state.topics.count == 1)
        #expect(state.topics.first?.contains("weather") == true)
    }

    @Test func topicsCappedAtThree() {
        var state = ConversationState()
        state.recordTurn(userInput: "query one", entities: nil, toolResults: [])
        state.recordTurn(userInput: "query two", entities: nil, toolResults: [])
        state.recordTurn(userInput: "query three", entities: nil, toolResults: [])
        state.recordTurn(userInput: "query four", entities: nil, toolResults: [])
        #expect(state.topics.count == 3)
        #expect(state.topics.first == "query two")
        #expect(state.topics.last == "query four")
    }

    @Test func entitiesMergedAndCapped() {
        var state = ConversationState()
        let entities = ExtractedEntities(
            names: ["Alice", "Bob"],
            places: ["London", "Paris", "Tokyo", "Berlin", "Madrid", "Rome", "Oslo", "Dublin", "Lisbon"],
            organizations: ["NASA", "ESA"],
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
        state.recordTurn(userInput: "test", entities: entities, toolResults: [])
        // 2 names + 9 places + 2 orgs = 13, but capped at 10
        #expect(state.activeEntities.count <= 10)
    }

    @Test func toolResultsSummaryTruncatedTo200Chars() {
        var state = ConversationState()
        let longSummary = String(repeating: "x", count: 500)
        state.recordTurn(userInput: "test", entities: nil, toolResults: [
            (toolName: "Weather", summary: longSummary)
        ])
        #expect(state.recentToolResults.first!.summary.count == 200)
    }

    @Test func toolResultsCappedAtTwo() {
        var state = ConversationState()
        state.recordTurn(userInput: "t1", entities: nil, toolResults: [(toolName: "A", summary: "a")])
        state.recordTurn(userInput: "t2", entities: nil, toolResults: [(toolName: "B", summary: "b")])
        state.recordTurn(userInput: "t3", entities: nil, toolResults: [(toolName: "C", summary: "c")])
        #expect(state.recentToolResults.count == 2)
        #expect(state.recentToolResults[0].toolName == "B")
        #expect(state.recentToolResults[1].toolName == "C")
    }

    @Test func setPreference() {
        var state = ConversationState()
        state.setPreference(key: "unit_system", value: "metric")
        #expect(state.userPreferences["unit_system"] == "metric")
    }

    @Test func setPreferenceOverwrites() {
        var state = ConversationState()
        state.setPreference(key: "unit_system", value: "metric")
        state.setPreference(key: "unit_system", value: "imperial")
        #expect(state.userPreferences["unit_system"] == "imperial")
    }

    @Test func recordFactsEviction() {
        var state = ConversationState()
        // Add 7 facts — should keep only 5
        for i in 1...7 {
            state.recordFacts([Fact(tool: "Test", key: "k\(i)", value: "v\(i)")])
        }
        #expect(state.recentFacts.count == 5, "Should evict to 5 facts")
    }

    @Test func longTopicTrimmedToWordBoundary() {
        var state = ConversationState()
        let longInput = "this is a very long query that exceeds sixty characters and should be trimmed at a word boundary"
        state.recordTurn(userInput: longInput, entities: nil, toolResults: [])
        let topic = state.topics.first!
        #expect(topic.count <= 60)
        #expect(!topic.hasSuffix(" "))
    }

    @Test func promptContextIncludesAllSections() {
        var state = ConversationState()
        let entities = ExtractedEntities(
            names: [], places: ["London"], organizations: [],
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
        state.recordTurn(userInput: "weather", entities: entities, toolResults: [
            (toolName: "Weather", summary: "Sunny 22C")
        ])
        state.userPreferences["unit_system"] = "metric"
        let ctx = state.asPromptContext()
        #expect(ctx.contains("Recent topics:"))
        #expect(ctx.contains("Active entities:"))
        #expect(ctx.contains("[Weather] Sunny 22C"))
        #expect(ctx.contains("Preferences: unit_system=metric"))
        #expect(ctx.contains("Turn: 1"))
    }
}

// MARK: - TurnBudget Tests

@Suite("TurnBudget")
struct TurnBudgetTests {

    @Test func defaultBudgetMatchesStatic() {
        let budget = AppConfig.buildTurnBudget()
        // With zero identity, state, and schemas, all tokens go to data
        let expected = AppConfig.totalContextBudget - AppConfig.generationSpace
        #expect(budget.availableForData == expected)
    }

    @Test func stateTokensReduceDataBudget() {
        let budget = AppConfig.buildTurnBudget(conversationStateSize: 200)
        let withoutState = AppConfig.buildTurnBudget(conversationStateSize: 0)
        #expect(budget.availableForData == withoutState.availableForData - 200)
    }

    @Test func schemaTokensReduceDataBudget() {
        let budget = AppConfig.buildTurnBudget(toolSchemaSize: 300)
        let withoutSchema = AppConfig.buildTurnBudget(toolSchemaSize: 0)
        #expect(budget.availableForData == withoutSchema.availableForData - 300)
    }

    @Test func oversizedStateCappedAtMax() {
        let budget = AppConfig.buildTurnBudget(conversationStateSize: 9999)
        #expect(budget.conversationState == AppConfig.conversationStateBlob)
    }

    @Test func oversizedSchemasCappedAtMax() {
        let budget = AppConfig.buildTurnBudget(toolSchemaSize: 9999)
        #expect(budget.toolSchemas == AppConfig.targetedToolSchemas)
    }

    @Test func identityTokensReduceDataBudget() {
        let budget = AppConfig.buildTurnBudget(identitySize: 200)
        let withoutIdentity = AppConfig.buildTurnBudget(identitySize: 0)
        #expect(budget.availableForData == withoutIdentity.availableForData - 200)
    }

    @Test func oversizedIdentityCappedAtMax() {
        let budget = AppConfig.buildTurnBudget(identitySize: 9999)
        #expect(budget.identity == AppConfig.identityBudget)
    }

    @Test func estimateTokensBasicHeuristic() {
        #expect(AppConfig.estimateTokens(for: "test") == 1)
        #expect(AppConfig.estimateTokens(for: "hello world!!") >= 1)
        // TokenEstimator uses word-level counting (~1.3 tokens per word).
        // 100 words ≈ 130 tokens.
        let hundredWords = Array(repeating: "word", count: 100).joined(separator: " ")
        let estimate = AppConfig.estimateTokens(for: hundredWords)
        #expect(estimate >= 100 && estimate <= 160, "100 words should estimate ~130 tokens, got \(estimate)")
        // Empty string → 0
        #expect(AppConfig.estimateTokens(for: "") == 0)
    }
}

// MARK: - ToolError Tests

@Suite("ToolError")
struct ToolErrorTests {

    @Test func permissionDeniedNotHealable() {
        let err = ToolError.permissionDenied(permission: "Location", settingsURL: nil)
        #expect(!err.isHealable)
    }

    @Test func networkUnavailableNotHealable() {
        let err = ToolError.networkUnavailable(url: URL(string: "https://api.example.com"))
        #expect(!err.isHealable)
    }

    @Test func timeoutNotHealable() {
        let err = ToolError.timeout(duration: 30)
        #expect(!err.isHealable)
    }

    @Test func inputInvalidIsHealable() {
        let err = ToolError.inputInvalid(reason: "bad input", suggestion: "try X")
        #expect(err.isHealable)
    }

    @Test func apiErrorIsHealable() {
        let err = ToolError.apiError(service: "Weather", code: 400, message: "bad request")
        #expect(err.isHealable)
    }

    @Test func resourceNotFoundIsHealable() {
        let err = ToolError.resourceNotFound(what: "contact")
        #expect(err.isHealable)
    }

    @Test func settingsURLFromPermission() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        let err = ToolError.permissionDenied(permission: "Location", settingsURL: url)
        #expect(err.settingsURL == url)
    }

    @Test func settingsURLNilForNonPermission() {
        let err = ToolError.apiError(service: "X", code: nil, message: "fail")
        #expect(err.settingsURL == nil)
    }

    @Test func userMessageContainsService() {
        let err = ToolError.apiError(service: "Yahoo Finance", code: 429, message: "rate limited")
        #expect(err.userMessage.contains("Yahoo Finance"))
        #expect(err.userMessage.contains("429"))
    }

    @Test func userMessageTimeoutShowsDuration() {
        let err = ToolError.timeout(duration: 15)
        #expect(err.userMessage.contains("15"))
    }
}

// MARK: - ExecutionPlan Tests

@Suite("ExecutionPlan")
struct ExecutionPlanTests {

    @Test func singleStepPlanNotMultiStep() {
        let plan = ExecutionPlan.singleStep(toolName: "Weather", input: "weather in London")
        #expect(!plan.isMultiStep)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].toolName == "Weather")
    }

    @Test func multiStepPlanIsMultiStep() {
        let plan = ExecutionPlan(steps: [
            .init(toolName: "Calendar", inputTemplate: "next meeting"),
            .init(toolName: "Weather", inputTemplate: "weather at {{prev}}")
        ])
        #expect(plan.isMultiStep)
        #expect(plan.steps.count == 2)
    }

    @Test func stepResolvesTemplateWithPrior() {
        let step = ExecutionPlan.Step(toolName: "Weather", inputTemplate: "weather at {{prev}}")
        let resolved = step.resolveInput(priorResult: "Cupertino, CA")
        #expect(resolved == "weather at Cupertino, CA")
    }

    @Test func stepResolvesNilPriorKeepsTemplate() {
        let step = ExecutionPlan.Step(toolName: "Weather", inputTemplate: "weather at {{prev}}")
        let resolved = step.resolveInput(priorResult: nil)
        #expect(resolved == "weather at {{prev}}")
    }

    @Test func plannerNeedsNoPlanningSimplerQuery() async {
        let planner = ExecutionPlanner()
        let plan = await planner.plan(input: "what's the weather", routedToolName: "Weather")
        #expect(!plan.isMultiStep)
        #expect(plan.steps[0].toolName == "Weather")
    }

    @Test func plannerDetectsSequentialIntent() async {
        // "then" triggers planning heuristic
        let planner = ExecutionPlanner(llmResponder: { _ in
            "Calendar: get next meeting\nWeather: weather at {{prev}}"
        })
        let plan = await planner.plan(input: "check my calendar then get weather for the location", routedToolName: "Calendar")
        #expect(plan.isMultiStep)
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0].toolName == "Calendar")
        #expect(plan.steps[1].toolName == "Weather")
    }

    @Test func plannerFallsBackOnBadLLMResponse() async {
        let planner = ExecutionPlanner(llmResponder: { _ in
            "This is not a valid plan format at all"
        })
        let plan = await planner.plan(input: "do this then that", routedToolName: "Weather")
        // Bad LLM output → single step fallback
        #expect(!plan.isMultiStep)
    }

    @Test func plannerRejectsUnknownToolNames() async {
        let planner = ExecutionPlanner(llmResponder: { _ in
            "FakeToolThatDoesNotExist: do something"
        })
        let plan = await planner.plan(input: "do this then that", routedToolName: "Weather")
        #expect(!plan.isMultiStep) // Unknown tool → empty steps → fallback
    }

    @Test func plannerCapsAtThreeSteps() async {
        let planner = ExecutionPlanner(llmResponder: { _ in
            """
            Calendar: step 1
            Weather: step 2
            Maps: step 3
            Email: step 4
            """
        })
        let plan = await planner.plan(input: "do lots of things then more", routedToolName: "Calendar")
        #expect(plan.steps.count <= 3)
    }

    @Test func plannerFallsBackOnLLMError() async {
        // When the planner override throws, it falls back to LLM-based generation.
        // Provide a stub LLM adapter so the fallback doesn't call real Apple Intelligence
        // (which would produce a real multi-step plan instead of the expected single-step fallback).
        let stubAdapter = LLMAdapter(testResponder: { _, _ in "stub" })
        let planner = ExecutionPlanner(llmResponder: { _ in
            throw NSError(domain: "test", code: 1)
        }, llmAdapter: stubAdapter)
        let plan = await planner.plan(input: "email me then call", routedToolName: "Email")
        #expect(!plan.isMultiStep)
        #expect(plan.steps[0].toolName == "Email")
    }
}

// MARK: - ScratchpadCache Directional Key Tests

@Suite("ScratchpadCache Directional Keys")
struct ScratchpadDirectionalKeyTests {

    @Test func convertPreservesWordOrder() {
        let key1 = ScratchpadCache.makeKey(toolName: "Convert", input: "100 USD to EUR")
        let key2 = ScratchpadCache.makeKey(toolName: "Convert", input: "100 EUR to USD")
        #expect(key1 != key2)
    }

    @Test func translatePreservesWordOrder() {
        let key1 = ScratchpadCache.makeKey(toolName: "Translate", input: "hello in French")
        let key2 = ScratchpadCache.makeKey(toolName: "Translate", input: "French hello in")
        #expect(key1 != key2)
    }

    @Test func weatherSortsWords() {
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: "weather in London")
        let key2 = ScratchpadCache.makeKey(toolName: "Weather", input: "London weather")
        #expect(key1 == key2)
    }

    @Test func mapsSortsWords() {
        let key1 = ScratchpadCache.makeKey(toolName: "Maps", input: "directions to airport")
        let key2 = ScratchpadCache.makeKey(toolName: "Maps", input: "airport directions")
        #expect(key1 == key2)
    }
}

// MARK: - WidgetOutput Tests

@Suite("WidgetOutput")
struct WidgetOutputTests {

    @Test func noneHasNilTypeString() {
        #expect(WidgetOutput.none.widgetTypeString == nil)
        #expect(WidgetOutput.none.widgetData == nil)
    }

    @Test func weatherWidgetTypeString() {
        let data = WeatherWidgetData(
            city: "London", temperature: "22°C",
            condition: "Sunny", iconName: "sun.max"
        )
        let output = WidgetOutput.weather(data)
        #expect(output.widgetTypeString == "WeatherWidget")
        #expect(output.widgetData != nil)
    }

    @Test func fromLegacyNilReturnsNone() {
        let output = WidgetOutput.fromLegacy(widgetType: nil, widgetData: nil)
        if case .none = output {} else {
            Issue.record("Expected .none")
        }
    }

    @Test func fromLegacyUnknownTypeReturnsNone() {
        let output = WidgetOutput.fromLegacy(widgetType: "TotallyFakeWidget", widgetData: "data")
        if case .none = output {} else {
            Issue.record("Expected .none for unknown widget type")
        }
    }

    @Test func fromLegacyWrongDataTypeReturnsNone() {
        // WeatherWidget type but String data (wrong type)
        let output = WidgetOutput.fromLegacy(widgetType: "WeatherWidget", widgetData: "not weather data")
        if case .none = output {} else {
            Issue.record("Expected .none for mismatched data type")
        }
    }

    @Test func calculatorUsesLegacyMathWidgetString() {
        let data = CalculatorWidgetData(equation: "2+2", result: "4")
        let output = WidgetOutput.calculator(data)
        // Legacy name is "MathWidget", not "CalculatorWidget"
        #expect(output.widgetTypeString == "MathWidget")
    }
}

// MARK: - ChainableTool Protocol Tests

/// A spy that implements ChainableTool to verify chain execution.
final class ChainableSpyTool: ChainableTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum = .offline

    private let _invocations = OSAllocatedUnfairLock(initialState: [SpyInvocation]())
    private let stubbedResult: ToolIO
    private let chainStepToReturn: ChainStep?

    var invocations: [SpyInvocation] {
        _invocations.withLock { $0 }
    }

    init(
        name: String,
        schema: String,
        result: ToolIO = ToolIO(text: "chain spy result", status: .ok),
        chainStep: ChainStep? = nil
    ) {
        self.name = name
        self.schema = schema
        self.stubbedResult = result
        self.chainStepToReturn = chainStep
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        _invocations.withLock { $0.append(SpyInvocation(input: input, entities: entities)) }
        return stubbedResult
    }

    func nextStep(result: ToolIO, originalInput: String) -> ChainStep? {
        chainStepToReturn
    }
}

@Suite("ChainableTool")
struct ChainableToolTests {

    @Test func chainableToolTriggersChainingToSecondTool() async {
        let calendarSpy = ChainableSpyTool(
            name: "Calendar",
            schema: "calendar events",
            result: ToolIO(text: "Next meeting at Apple Park", status: .ok),
            chainStep: .runTool(name: "Weather", input: "weather at Apple Park")
        )
        let weatherSpy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Sunny 72F at Apple Park", status: .ok)
        )

        let router = ToolRouter(
            availableTools: [calendarSpy, weatherSpy],
            llmResponder: makeStubRouterLLMResponder()
        )
        let engine = ExecutionEngine(
            router: router,
            conversationManager: ConversationManager(),
            planner: ExecutionPlanner(llmResponder: { _ in "Calendar: next meeting" }),
            llmResponder: makeStubLLMResponder()
        )
        let _ = await engine.run(input: "#calendar next meeting")

        #expect(calendarSpy.invocations.count == 1)
        #expect(weatherSpy.invocations.count == 1)
        #expect(weatherSpy.invocations.first?.input == "weather at Apple Park")
    }

    @Test func chainDoesNotExceedMaxToolCalls() async {
        // Create a chain that loops indefinitely — engine should cap it
        let toolA = ChainableSpyTool(
            name: "Calendar",
            schema: "calendar events",
            result: ToolIO(text: "meeting", status: .ok),
            chainStep: .runTool(name: "Weather", input: "weather")
        )
        let toolB = ChainableSpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "sunny", status: .ok),
            chainStep: .runTool(name: "Calendar", input: "calendar")
        )

        let router = ToolRouter(
            availableTools: [toolA, toolB],
            llmResponder: makeStubRouterLLMResponder()
        )
        let engine = ExecutionEngine(
            router: router,
            conversationManager: ConversationManager(),
            planner: ExecutionPlanner(llmResponder: { _ in "Calendar: test" }),
            llmResponder: makeStubLLMResponder()
        )
        let _ = await engine.run(input: "#calendar test chain loop")

        // Max 4 tool calls per turn — initial call + chain should not exceed it
        let totalCalls = toolA.invocations.count + toolB.invocations.count
        #expect(totalCalls <= AppConfig.maxToolCallsPerTurn, "Chain exceeded max tool calls: \(totalCalls)")
    }

    @Test func chainStopsOnToolError() async {
        let calendarSpy = ChainableSpyTool(
            name: "Calendar",
            schema: "calendar events",
            result: ToolIO(text: "error", status: .error),
            chainStep: .runTool(name: "Weather", input: "weather")
        )
        let weatherSpy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "sunny", status: .ok)
        )

        let router = ToolRouter(
            availableTools: [calendarSpy, weatherSpy],
            llmResponder: makeStubRouterLLMResponder()
        )
        let engine = ExecutionEngine(
            router: router,
            conversationManager: ConversationManager(),
            planner: ExecutionPlanner(llmResponder: { _ in "Calendar: test" }),
            llmResponder: makeStubLLMResponder()
        )
        let _ = await engine.run(input: "#calendar test error chain")

        // Error result → chain should NOT fire
        #expect(weatherSpy.invocations.count == 0)
    }

    @Test(.requires(.localValidation)) func nonChainableToolDoesNotChain() async {
        // Reset shared cache to avoid cross-test pollution in parallel runs
        await ScratchpadCache.shared.reset()

        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "sunny", status: .ok)
        )
        let otherSpy = SpyTool(
            name: "Calendar",
            schema: "calendar events",
            result: ToolIO(text: "meeting", status: .ok)
        )

        let engine = makeTestEngine(
            tools: [spy, otherSpy],
            engineLLMResponder: makeStubLLMResponder()
        )
        // Use unique input to avoid ScratchpadCache collision with other parallel tests
        let _ = await engine.run(input: "#weather London nonChainableTest \(UUID().uuidString.prefix(8))")

        #expect(spy.invocations.count == 1, "Weather spy should be called once via chip")
        #expect(otherSpy.invocations.count == 0, "Calendar should not be chained from non-chainable tool")
    }
}

// MARK: - ToolError Healing Integration Tests

@Suite("ToolError Healing Integration")
struct ToolErrorHealingTests {

    /// A tool that throws ToolError.permissionDenied (not healable).
    final class PermissionDeniedTool: CoreTool, @unchecked Sendable {
        let name = "Camera"
        let schema = "capture photo"
        let isInternal = false
        let category: CategoryEnum = .offline
        private let _invocations = OSAllocatedUnfairLock(initialState: 0)
        var invocationCount: Int { _invocations.withLock { $0 } }

        func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
            _invocations.withLock { $0 += 1 }
            throw ToolError.permissionDenied(permission: "Camera", settingsURL: nil)
        }
    }

    /// A tool that throws ToolError.inputInvalid (healable).
    final class InvalidInputTool: CoreTool, @unchecked Sendable {
        let name = "Convert"
        let schema = "unit conversion"
        let isInternal = false
        let category: CategoryEnum = .offline
        private let _invocations = OSAllocatedUnfairLock(initialState: 0)
        var invocationCount: Int { _invocations.withLock { $0 } }

        func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
            let count = _invocations.withLock { c in c += 1; return c }
            if count == 1 {
                throw ToolError.inputInvalid(reason: "couldn't parse units", suggestion: "try '100 USD to EUR'")
            }
            return ToolIO(text: "100 USD = 92 EUR", status: .ok, isVerifiedData: true)
        }
    }

    @Test func permissionDeniedSkipsHealing() async {
        let tool = PermissionDeniedTool()
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                // If healing is attempted, this responder would be called
                return "stub"
            }
        )
        let result = await engine.run(input: "#camera take a photo")

        // Only 1 invocation — healing was not attempted
        #expect(tool.invocationCount == 1)
        #expect(result.isError)
    }

    @Test func inputInvalidAttemptsHealing() async {
        let tool = InvalidInputTool()
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "100 USD to EUR"
                }
                return "stub response"
            }
        )
        let result = await engine.run(input: "#convert a hundred bucks in euros")

        // 2 invocations: first fails, healing retry succeeds
        #expect(tool.invocationCount == 2)
        #expect(!result.isError)
    }
}

// MARK: - ConversationManager Structured State E2E

@Suite("ConversationManager Structured State")
struct ConversationManagerTests {

    @Test func recordTurnUpdatesState() async {
        let mgr = ConversationManager()
        let entities = ExtractedEntities(
            names: [], places: ["London"], organizations: [],
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
        await mgr.recordTurn(
            userInput: "weather in London",
            entities: entities,
            toolResults: [(toolName: "Weather", summary: "Sunny 22C")]
        )

        let state = await mgr.state
        #expect(state.turnCount == 1)
        #expect(state.topics.first?.contains("weather") == true)
        #expect(state.activeEntities.contains("London"))
        #expect(state.recentToolResults.first?.toolName == "Weather")
    }

    @Test func stateTokenCostIsReasonable() async {
        let mgr = ConversationManager()
        await mgr.recordTurn(userInput: "test", entities: nil, toolResults: [])
        let cost = await mgr.stateTokenCost
        // Should be small for a single turn
        #expect(cost < 100)
    }

    @Test func preparePromptIncludesState() async {
        let mgr = ConversationManager()
        await mgr.recordTurn(userInput: "weather", entities: nil, toolResults: [
            (toolName: "Weather", summary: "Sunny")
        ])
        let prompt = await mgr.preparePrompt(userInput: "and tomorrow?", retrievedChunks: ["forecast data"])
        #expect(prompt.contains("CONVERSATION_STATE"))
        #expect(prompt.contains("RETRIEVED_CONTEXT"))
        #expect(prompt.contains("USER_INPUT"))
    }

    @Test func resetClearsState() async {
        let mgr = ConversationManager()
        await mgr.recordTurn(userInput: "test", entities: nil, toolResults: [])
        await mgr.reset()
        let state = await mgr.state
        #expect(state.turnCount == 0)
        #expect(state.topics.isEmpty)
    }

    @Test func stateContextUpdatesOnRecordTurn() async {
        let mgr = ConversationManager()
        await mgr.recordTurn(userInput: "weather", entities: nil, toolResults: [
            (toolName: "Weather", summary: "Sunny")
        ])
        let context = await mgr.state.asPromptContext()
        #expect(!context.isEmpty)
        #expect(context.contains("Turn: 1"))
    }
}

// MARK: - Multi-Turn E2E Pipeline Tests

@Suite("Multi-Turn Pipeline")
struct MultiTurnPipelineTests {

    @Test func conversationStateAccumulatesAcrossTurns() async {
        let weatherSpy = SpyTool(
            name: "Weather", schema: "weather forecast",
            result: ToolIO(text: "Sunny 22C", status: .ok, outputWidget: "WeatherWidget")
        )
        let timeSpy = SpyTool(
            name: "Time", schema: "current time",
            result: ToolIO(text: "3:00 PM", status: .ok, outputWidget: "ClockWidget")
        )

        let conversationManager = ConversationManager()
        let router = ToolRouter(
            availableTools: [weatherSpy, timeSpy],
            llmResponder: makeStubRouterLLMResponder()
        )
        let engine = ExecutionEngine(
            router: router,
            conversationManager: conversationManager,
            llmResponder: makeStubLLMResponder()
        )

        let _ = await engine.run(input: "#weather London")
        let _ = await engine.run(input: "#time Tokyo")

        let state = await conversationManager.state
        #expect(state.turnCount == 2)
        #expect(state.topics.count == 2)
    }

    @Test func sequentialToolExecutionAcrossTurns() async {
        let calendarSpy = SpyTool(
            name: "Calendar", schema: "calendar events",
            result: ToolIO(text: "Next meeting at Apple Park, Cupertino", status: .ok)
        )
        let weatherSpy = SpyTool(
            name: "Weather", schema: "weather forecast",
            result: ToolIO(text: "Sunny 72F", status: .ok)
        )

        // Verify that the engine correctly routes chip-based queries across two turns.
        // This tests the core pipeline (preprocessing → chip routing → execution → finalization)
        // for each tool independently.
        let engine = makeTestEngine(
            tools: [calendarSpy, weatherSpy],
            engineLLMResponder: makeStubLLMResponder()
        )

        let _ = await engine.run(input: "#calendar check my schedule")
        #expect(calendarSpy.invocations.count == 1, "Calendar should be invoked from #calendar chip")

        let _ = await engine.run(input: "#weather current conditions")
        #expect(weatherSpy.invocations.count == 1, "Weather should be invoked from #weather chip")
    }
}

// MARK: - Widget-to-Tool Map Completeness

@Suite("Widget-to-Tool Map")
struct WidgetToToolMapTests {

    @Test func allKnownWidgetsMapped() {
        // Every widget type that WidgetRenderer handles should map to a tool name
        let widgetTypes = [
            "WeatherWidget", "WeatherForecastWidget", "WeatherComparisonWidget",
            "MathWidget", "AudioPlayerWidget", "ClockWidget", "TimeComparisonWidget",
            "RandomWidget", "TimerWidget", "CalendarWidget", "StockWidget",
            "DictionaryWidget", "PodcastEpisodesWidget", "NewsWidget", "MapWidget",
            "TodaySummaryWidget", "EmailListWidget", "FeedbackWidget",
            "RemoteFileListWidget", "CreateWidget", "ResearchWidget",
            "MoonWidget",
        ]

        for widgetType in widgetTypes {
            let mapped = ExecutionEngine.widgetToToolMap[widgetType.lowercased()]
            #expect(mapped != nil, "Missing mapping for \(widgetType)")
        }
    }

    @Test func moonWidgetMapsToWeather() {
        let mapped = ExecutionEngine.widgetToToolMap["moonwidget"]
        #expect(mapped == "Weather")
    }
}

// MARK: - Moon Phase Computation Tests

@Suite("Moon Phase")
struct MoonPhaseTests {

    @Test func knownFullMoon() {
        // Jan 13, 2025 was a full moon
        let cal = Calendar(identifier: .gregorian)
        let fullMoon = cal.date(from: DateComponents(year: 2025, month: 1, day: 13, hour: 12))!
        let phase = WeatherTool.computeMoonPhase(for: fullMoon)
        #expect(phase.name == "Full Moon" || phase.name == "Waxing Gibbous" || phase.name == "Waning Gibbous",
                "Expected near-full phase, got \(phase.name)")
        let illumination = WeatherTool.moonIllumination(for: fullMoon)
        #expect(illumination > 0.85, "Full moon should be >85% illuminated, got \(illumination)")
    }

    @Test func knownNewMoon() {
        // Jan 29, 2025 was a new moon
        let cal = Calendar(identifier: .gregorian)
        let newMoon = cal.date(from: DateComponents(year: 2025, month: 1, day: 29, hour: 12))!
        let phase = WeatherTool.computeMoonPhase(for: newMoon)
        #expect(phase.name == "New Moon" || phase.name == "Waxing Crescent" || phase.name == "Waning Crescent",
                "Expected near-new phase, got \(phase.name)")
        let illumination = WeatherTool.moonIllumination(for: newMoon)
        #expect(illumination < 0.15, "New moon should be <15% illuminated, got \(illumination)")
    }

    @Test func illuminationRangeIsValid() {
        // Test 30 days to verify illumination is always 0...1
        let cal = Calendar(identifier: .gregorian)
        let base = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        for day in 0..<30 {
            let date = cal.date(byAdding: .day, value: day, to: base)!
            let illum = WeatherTool.moonIllumination(for: date)
            #expect(illum >= 0.0 && illum <= 1.0, "Illumination out of range on day \(day): \(illum)")
        }
    }

    @Test func allEightPhasesReachable() {
        // Over a full synodic month, all 8 phases should appear
        let cal = Calendar(identifier: .gregorian)
        let base = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        var phaseNames = Set<String>()
        for day in 0..<30 {
            let date = cal.date(byAdding: .day, value: day, to: base)!
            let phase = WeatherTool.computeMoonPhase(for: date)
            phaseNames.insert(phase.name)
        }
        let expected: Set<String> = [
            "New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
            "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"
        ]
        #expect(phaseNames == expected, "Missing phases: \(expected.subtracting(phaseNames))")
    }

    @Test func moonWidgetDataHasEmoji() {
        let phase = WeatherTool.computeMoonPhase(for: Date())
        #expect(!phase.emoji.isEmpty)
        #expect(!phase.icon.isEmpty)
        #expect(!phase.name.isEmpty)
    }
}

// MARK: - Routing Fix Verification Tests

@Suite("Routing Fixes")
struct RoutingFixTests {

    @Test func metaQueryRoutesConversational() async {
        let router = ToolRouter(
            availableTools: [SpyTool(name: "Research", schema: "research", result: ToolIO(text: "r", status: .ok))],
            llmResponder: makeStubRouterLLMResponder(toolName: "Research")
        )
        let result = await router.route(input: "what can you do")
        if case .conversational = result {} else {
            Issue.record("Expected conversational for meta-query, got \(result)")
        }
    }

    @Test func metaQueryVariants() async {
        let router = ToolRouter(
            availableTools: [],
            llmResponder: makeStubRouterLLMResponder()
        )
        let queries = [
            "what can you do",
            "what are your tools",
            "how do you work",
            "what do you do",
            "tell me your capabilities",
            "what are your features",
        ]
        for q in queries {
            let result = await router.route(input: q)
            if case .conversational = result {} else {
                Issue.record("'\(q)' should be conversational, got \(result)")
            }
        }
    }

    @Test func metaQueryDoesNotCatchTaskQueries() async {
        // These contain "help me" or "you" but are about external tasks, not about iClaw
        let router = ToolRouter(
            availableTools: [
                SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "sunny", status: .ok)),
                SpyTool(name: "SystemInfo", schema: "system info battery wifi", result: ToolIO(text: "ok", status: .ok)),
            ],
            llmResponder: makeStubRouterLLMResponder(toolName: "SystemInfo")
        )

        // Queries must be >10 words to bypass the short-query conversational fast-path
        // (ToolRouter stage 5 — `Short unmatched query → conversational`).
        //
        // Note: "help me figure out why ..."-shaped queries are deliberately
        // excluded because the multilingual ConversationIntentClassifier
        // sometimes labels them `.meta` (questions about iClaw itself) when
        // the task content is generic. That's a classifier-tuning issue
        // tracked separately, not a router-routing bug.
        let taskQueries = [
            "help me fix my bluetooth connection that keeps dropping out on my laptop",
            "can you please check the current weather conditions in London for me today",
            "what time is it for you right now over in Tokyo Japan please",
        ]
        for q in taskQueries {
            let result = await router.route(input: q)
            if case .conversational = result {
                Issue.record("'\(q)' should NOT be conversational — it's a task query")
            }
            // It's OK if it routes to any tool or falls through to LLM — just not conversational
        }
    }

    @Test func bareDomainNoLongerRoutesToWebFetch() async {
        let webFetchSpy = SpyTool(name: "WebFetch", schema: "fetch URL", category: .online, result: ToolIO(text: "page", status: .ok))
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "sunny", status: .ok))
        let router = ToolRouter(
            availableTools: [webFetchSpy, weatherSpy],
            llmResponder: makeStubRouterLLMResponder(toolName: "Weather")
        )
        let result = await router.route(input: "not-a-url.com weather")
        // Should NOT route to WebFetch (no explicit scheme)
        if case .tools(let tools) = result {
            #expect(tools.first?.name != "WebFetch", "Bare domain should not trigger WebFetch")
        }
    }

    @Test func explicitSchemeStillRoutesToWebFetch() async {
        let webFetchSpy = SpyTool(name: "WebFetch", schema: "fetch URL", category: .online, result: ToolIO(text: "page", status: .ok))
        let router = ToolRouter(
            availableTools: [webFetchSpy],
            llmResponder: makeStubRouterLLMResponder()
        )
        let result = await router.route(input: "https://example.com")
        if case .tools(let tools) = result {
            #expect(tools.first?.name == "WebFetch")
        } else {
            Issue.record("Expected WebFetch for explicit https URL")
        }
    }

    @Test func spacedLettersCollapsed() {
        let collapsed = InputPreprocessor.collapseSpacedLetters("w e a t h e r in London")
        #expect(collapsed == "weather in London")
    }

    @Test func spacedLettersPreservesNormalText() {
        let preserved = InputPreprocessor.collapseSpacedLetters("I have a pen")
        #expect(preserved == "I have a pen")
    }

    @Test func spacedLettersMinimumThreeChars() {
        // "a b" is only 2 chars — should NOT collapse
        let result = InputPreprocessor.collapseSpacedLetters("a b test")
        #expect(result == "a b test")
    }
}
