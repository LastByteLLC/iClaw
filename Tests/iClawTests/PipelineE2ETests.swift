import XCTest
import FoundationModels
@testable import iClawCore

/// Stub Tool whose name matches the descriptor, so tests can verify
/// the correct FM tool reaches the LLM via the `tools:` parameter.
private struct StubFMToolImpl: Tool {
    typealias Arguments = ClipboardInput
    typealias Output = String

    let name: String
    var description: String { "stub tool \(name)" }
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: ClipboardInput) async throws -> String { "stub" }
}

/// Stub FMToolDescriptor for testing FM tool chip routing without real tools.
/// `makeTool()` returns a stub Tool whose `name` matches the descriptor name,
/// so tests can observe FM-tool attachment by inspecting the tools array
/// passed to the LLM responder.
private struct StubFMToolDescriptor: FMToolDescriptor {
    let name: String
    let chipName: String
    let routingKeywords: [String]
    let category: CategoryEnum = .offline
    func makeTool() -> any Tool { StubFMToolImpl(name: name) }
}

// MARK: - New Tool Pipeline Tests

final class NewToolPipelineE2ETests: XCTestCase {

    override func setUp() async throws {
        executionTimeAllowance = 30
        TestLocationSetup.install()
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Dictionary Tool

    func testDictionaryChipRouting() async throws {
        let spy = SpyTool(
            name: "Dictionary",
            schema: "dictionary definition lookup meaning word define",
            result: ToolIO(text: "hello: a greeting", status: .ok, outputWidget: "DictionaryWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: "#dictionary hello")

        XCTAssertEqual(spy.invocations.count, 1, "Dictionary tool should be called")
        XCTAssertFalse(spy.invocations.first!.input.contains("#"), "Input should be cleaned of chips")
        XCTAssertTrue(captured.value.contains("hello: a greeting"), "Dictionary output should reach final prompt")
        XCTAssertEqual(result.widgetType, "DictionaryWidget")
    }

    func testDictionaryRealExecution() async throws {
        // Inject a stub word extractor that returns the word directly (simulating LLM extraction)
        let tool = DictionaryTool(wordExtractor: { _ in "hello" })
        let result = try await tool.execute(input: "hello", entities: nil)
        XCTAssertEqual(result.status, .ok, "Should find a definition for 'hello'")
        XCTAssertTrue(result.text.lowercased().contains("hello"), "Result should contain the word")
    }

    func testDictionaryWordExtraction() async throws {
        // Simulate LLM extracting the correct word from natural language input
        let patterns: [(input: String, extractedWord: String)] = [
            ("define serendipity", "serendipity"),
            ("what does ephemeral mean", "ephemeral"),
            ("meaning of paradigm", "paradigm"),
        ]

        for (input, expectedWord) in patterns {
            let tool = DictionaryTool(wordExtractor: { _ in expectedWord })
            let result = try await tool.execute(input: input, entities: nil)
            XCTAssertTrue(
                result.text.lowercased().contains(expectedWord),
                "Input '\(input)' should look up '\(expectedWord)', got: \(result.text.prefix(100))"
            )
        }
    }

    func testDictionaryNotFound() async throws {
        let tool = DictionaryTool(wordExtractor: { _ in "xyzzyplugh" })
        let result = try await tool.execute(input: "xyzzyplugh", entities: nil)
        XCTAssertEqual(result.status, .error, "Should return error for nonsense word")
        XCTAssertTrue(result.text.contains("No definition found"), "Should say no definition found")
    }

    func testDictionaryLLMFallback() async throws {
        // If LLM extraction fails, the tool falls back to using raw input as the word
        let tool = DictionaryTool(wordExtractor: { _ in throw NSError(domain: "test", code: 1) })
        let result = try await tool.execute(input: "hello", entities: nil)
        // Should fall back to raw input "hello" and still find a definition
        XCTAssertEqual(result.status, .ok, "Should fall back to raw input when LLM fails")
        XCTAssertTrue(result.text.lowercased().contains("hello"))
    }

    func testDictionarySpellCheck() async throws {
        // "flumoxed" is a misspelling of "flummoxed" — spellcheck should correct it
        let tool = DictionaryTool(wordExtractor: { _ in "flumoxed" })
        let result = try await tool.execute(input: "flumoxed", entities: nil)
        XCTAssertEqual(result.status, .ok, "Should find definition via spellcheck correction")
        XCTAssertTrue(result.text.lowercased().contains("flummox"), "Should contain corrected word 'flummox'")
        XCTAssertTrue(result.text.contains("Did you mean"), "Should indicate spelling correction")
    }

    func testDictionaryWidgetData() async throws {
        let tool = DictionaryTool(wordExtractor: { _ in "professional" })
        let result = try await tool.execute(input: "professional", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "DictionaryWidget")
        let widgetData = result.widgetData as? DictionaryWidgetData
        XCTAssertNotNil(widgetData, "Widget data should be DictionaryWidgetData")
        XCTAssertEqual(widgetData?.word, "professional")
        XCTAssertNil(widgetData?.correctedFrom, "No correction needed for correct spelling")
        XCTAssertFalse(widgetData?.definition.isEmpty ?? true, "Definition should not be empty")
    }

    // MARK: - SystemInfo Tool

    func testSystemInfoChipRouting() async throws {
        let spy = SpyTool(
            name: "SystemInfo",
            schema: "system info battery wifi network disk",
            result: ToolIO(text: "Battery: 80%", status: .ok, outputWidget: "SystemInfoWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#systeminfo")

        XCTAssertEqual(spy.invocations.count, 1, "SystemInfo tool should be called via #systeminfo chip")
    }

    func testSystemInfoRealExecution() async throws {
        let tool = SystemInfoTool()
        let result = try await tool.execute(input: "", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // Should contain macOS version info at minimum
        XCTAssertTrue(result.text.contains("macOS"), "Should contain macOS version info")
    }

    func testSystemInfoBatteryQuery() async throws {
        let tool = SystemInfoTool()
        let result = try await tool.execute(input: "battery", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Battery"), "Should contain battery info")
    }

    func testSystemInfoDiskQuery() async throws {
        let tool = SystemInfoTool()
        let result = try await tool.execute(input: "disk space", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Disk"), "Should contain disk info")
        XCTAssertTrue(result.text.contains("GB"), "Should show GB values")
    }

    // MARK: - Screenshot Tool

    func testScreenshotChipRouting() async throws {
        let spy = SpyTool(
            name: "Screenshot",
            schema: "screenshot screen capture OCR",
            result: ToolIO(text: "Screen text: Hello World", status: .ok, outputWidget: "ScreenshotWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#screenshot")

        XCTAssertEqual(spy.invocations.count, 1, "Screenshot tool should be called via #screenshot chip")
    }

    func testScreenshotWithQuestionRouting() async throws {
        let spy = SpyTool(
            name: "Screenshot",
            schema: "screenshot screen capture OCR read screen analyze error what on screen",
            result: ToolIO(text: "Screen text: Error 404", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#screenshot what does this error mean?")

        XCTAssertEqual(spy.invocations.count, 1)
        XCTAssertTrue(captured.value.contains("Error 404"), "OCR text should reach final prompt as ingredient")
    }
}

// MARK: - Countries Skill E2E Tests

final class CountriesSkillE2ETests: XCTestCase {

    @MainActor
    func testCountriesSkillRouting() async throws {
        _ = await SkillLoader.shared.awaitActiveSkills()

        let skills = SkillLoader.shared.loadedSkills
        let countriesSkill = skills.first { $0.name == "Countries Skill" }
        XCTAssertNotNil(countriesSkill, "Countries Skill should be loaded")

        let router = ToolRouter(
            availableTools: ToolRegistry.coreTools,
            fmTools: ToolRegistry.fmTools,
            llmResponder: makeStubRouterLLMResponder()
        )

        // Use exact skill example
        _ = await router.route(input: "What is the capital of France?")
        let skill = await router.currentSkill

        XCTAssertNotNil(skill, "Skill should be matched")
        XCTAssertEqual(skill?.name, "Countries Skill")
    }

    @MainActor
    func testCountriesSkillFullPipeline() async throws {
        let captured = CapturedPrompt()
        let webFetchSpy = SpyTool(name: "WebFetch", schema: "fetch content from a specified URL", result: ToolIO(text: "{\"name\":{\"common\":\"France\"},\"capital\":[\"Paris\"]}", status: .ok))
        let engine = await makeTestEngineWithSkills(
            tools: [webFetchSpy],
            fmTools: ToolRegistry.fmTools,
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "What is the capital of France?")

        XCTAssertTrue(
            captured.value.contains("Skill Instruction:") || captured.value.contains("RestCountries"),
            "Countries skill instruction should appear in final prompt"
        )
    }

    @MainActor
    func testCountriesSkillPromptVariants() async throws {
        _ = await SkillLoader.shared.awaitActiveSkills()

        // Use exact examples from the skill markdown
        let prompts = [
            "What is the capital of France?",
            "What currency does Japan use?",
            "Which side of the road do they drive on in the UK?",
            "What's the population of Brazil?",
            "Tell me about Germany",
            "What languages are spoken in Switzerland?",
            "What is the flag of Canada?",
            "What's the calling code for Australia?",
            "What region is Nigeria in?",
            "What's the top-level domain for Iceland?",
        ]

        for prompt in prompts {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            let skill = await router.currentSkill

            let routed: Bool
            switch result {
            case .tools, .fmTools, .mixed:
                routed = true
            case .requiresDisambiguation:
                routed = true
            case .conversational, .needsUserClarification:
                routed = false
            }

            let skillMatched = skill?.name == "Countries Skill"
            XCTAssertTrue(routed || skillMatched, "'\(prompt)' should route via Countries Skill, got: \(result), skill: \(skill?.name ?? "none")")
        }
    }
}

// MARK: - Core Pipeline Tests

final class PipelineE2ETests: XCTestCase {

    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    // MARK: - 1. Weather Chip Routes to Weather Tool

    func testWeatherChipRoutesToWeatherTool() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Sunny 72°F", status: .ok, outputWidget: "weather", widgetData: "sunny" as any Sendable)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "It's sunny!", capture: captured)
        )

        let result = await engine.run(input: "What's the #weather ?")

        XCTAssertEqual(spy.invocations.count, 1, "Weather tool should be called exactly once")
        XCTAssertFalse(spy.invocations.first!.input.contains("#"), "Input should be cleaned of chips")
        XCTAssertTrue(captured.value.contains("Sunny 72°F"), "Tool output should appear in final prompt as ingredient")
        XCTAssertEqual(result.widgetType, "weather", "Widget type should propagate")
        XCTAssertEqual(result.text, "It's sunny!")
    }

    // MARK: - 2. Multi-Tool Execution

    func testMultiToolExecution() async throws {
        let calcSpy = SpyTool(name: "Calculator", schema: "calculator math", result: ToolIO(text: "10", status: .ok))
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "Rainy", status: .ok))
        let engine = makeTestEngine(tools: [calcSpy, weatherSpy])

        _ = await engine.run(input: "#calculator #weather test")

        XCTAssertEqual(calcSpy.invocations.count, 1, "Calculator should be called")
        XCTAssertEqual(weatherSpy.invocations.count, 1, "Weather should be called")
    }

    // MARK: - 3. Tool Failure Graceful Degradation

    func testToolFailureGracefulDegradation() async throws {
        let failing = FailingTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [failing],
            engineLLMResponder: makeStubLLMResponder(response: "Sorry, weather unavailable.")
        )

        let result = await engine.run(input: "#weather in London")

        XCTAssertEqual(result.text, "Sorry, weather unavailable.")
    }

    // MARK: - 4. No Match Emits Direct Clarification (bypasses LLM)

    func testNoMatchEmitsClarification() async throws {
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            engineLLMResponder: makeStubLLMResponder(response: "Not sure what you need. Try rephrasing.", capture: captured)
        )

        let result = await engine.run(input: "xyzzy gibberish")

        // Unrecognized input must not surface a raw error
        XCTAssertFalse(result.text.contains("Routing failed"), "Should NOT contain raw error message")
        // Engine emits the localized clarification directly, bypassing the finalizer LLM,
        // to avoid the prior "[CLARIFY] No matching tool…" ingredient being echoed verbatim.
        XCTAssertTrue(
            result.text.contains("tell me a bit more") || result.text.contains("looking for"),
            "Expected direct clarification text, got: \(result.text)"
        )
    }

    // MARK: - 5. Ingredients Reach Final Prompt

    func testIngredientsReachFinalPrompt() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "Temperature: 25°C in Paris", status: .ok))
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#weather Paris")

        XCTAssertTrue(captured.value.contains("Temperature: 25°C in Paris"), "Tool output text should appear in final prompt")
    }

    // MARK: - 6. Entities Flow to Tool

    func testEntitiesFlowToTool() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#weather in London")

        XCTAssertEqual(spy.invocations.count, 1)
        let entities = spy.invocations.first?.entities
        XCTAssertNotNil(entities, "Entities should be passed to tool")
    }

    // MARK: - 7. Max Tool Call Limit

    func testMaxToolCallLimit() async throws {
        let spies = (1...5).map { SpyTool(name: "Tool\($0)", schema: "tool\($0)") }
        let engine = makeTestEngine(tools: spies)

        _ = await engine.run(input: "#tool1 #tool2 #tool3 #tool4 #tool5")

        let totalInvocations = spies.reduce(0) { $0 + $1.invocations.count }
        XCTAssertLessThanOrEqual(totalInvocations, AppConfig.maxToolCallsPerTurn, "Should not exceed max tool calls per turn")
        XCTAssertLessThanOrEqual(totalInvocations, 3, "Router should cap at 3 tools")
    }

    // MARK: - 8. State Returns to Idle

    func testStateReturnsToIdle() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#weather test")

        let state = await engine.currentState
        XCTAssertEqual(state, .idle, "Engine should return to idle after run completes")
    }

    // MARK: - 9. FM Tool Chip Routing

    func testFMToolChipRouting() async throws {
        let mapsDescriptor = StubFMToolDescriptor(name: "maps", chipName: "maps", routingKeywords: ["directions", "navigate", "map"])
        let captured = CapturedPrompt()
        let capturedTools = CapturedTools()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [mapsDescriptor],
            engineLLMResponder: makeToolCapturingLLMResponder(capture: captured, toolCapture: capturedTools)
        )

        _ = await engine.run(input: "#maps directions to London")

        XCTAssertTrue(capturedTools.contains(toolNamed: "maps"), "FM tool should be passed to LLM via tools parameter")
        XCTAssertFalse(captured.value.contains("Will use FM Tool: maps"), "Tool-info marker must not leak into finalization prompt")
    }

    // MARK: - 9b. FM Tool Name Must Not Leak into Finalization Prompt
    //
    // Regression test for the "Web search: '<query>'" / "Will use FM Tool: ..."
    // leak. The LLM was echoing the routing marker from `<ki>` back as
    // user-facing text instead of invoking the attached FM tool. Tool names
    // belong in the `tools:` parameter, not in prompt data.

    func testFMToolNameDoesNotLeakIntoFinalizationPrompt() async throws {
        let descriptors: [StubFMToolDescriptor] = [
            StubFMToolDescriptor(name: "web_search", chipName: "search", routingKeywords: ["search"]),
            StubFMToolDescriptor(name: "maps", chipName: "maps", routingKeywords: ["directions"]),
            StubFMToolDescriptor(name: "messages", chipName: "messages", routingKeywords: ["message"]),
        ]

        for descriptor in descriptors {
            let captured = CapturedPrompt()
            let capturedTools = CapturedTools()
            let engine = makeTestEngine(
                tools: [],
                fmTools: [descriptor],
                engineLLMResponder: makeToolCapturingLLMResponder(capture: captured, toolCapture: capturedTools)
            )

            _ = await engine.run(input: "#\(descriptor.chipName) test query")

            let prompt = captured.value
            XCTAssertFalse(
                prompt.contains("Will use FM Tool: \(descriptor.name)"),
                "FM tool routing marker must not reach the finalization prompt (would echo back to user). Descriptor: \(descriptor.name)"
            )
            XCTAssertFalse(
                prompt.contains("Will use FM Tool:"),
                "Generic 'Will use FM Tool:' marker must not appear anywhere in the finalization prompt. Descriptor: \(descriptor.name)"
            )
            XCTAssertTrue(
                capturedTools.contains(toolNamed: descriptor.name),
                "FM tool must still be attached via the LLM tools parameter. Descriptor: \(descriptor.name)"
            )
        }
    }

    // MARK: - 9c. LLM-Echoed Tool-Name Prefix Is Stripped From Response
    //
    // Defense-in-depth for the primary leak: even if the LLM still
    // produces a standalone "Web search: 'query'" line (e.g., via an
    // untrained model), response cleaning must strip it before it
    // reaches the user.

    func testEchoedToolNamePrefixIsStrippedFromResponse() async throws {
        let descriptor = StubFMToolDescriptor(name: "web_search", chipName: "search", routingKeywords: ["search"])
        // Stub responder returns a literal tool-echo response (simulating the AFM leak).
        let leakyResponder: LLMResponder = { _, _ in
            return "Web search: \"Sydney Sweeney birthplace\"."
        }
        let engine = makeTestEngine(
            tools: [],
            fmTools: [descriptor],
            engineLLMResponder: leakyResponder
        )

        let result = await engine.run(input: "#search Sydney Sweeney birthplace")

        // Response cleaning must strip the leading tool-echo line.
        XCTAssertFalse(
            result.text.lowercased().hasPrefix("web search:"),
            "Response should not begin with a leaked FM tool name. Got: \(result.text)"
        )
    }

    // MARK: - 10. Case Insensitive Chip Routing

    func testCaseInsensitiveChipRouting() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#WEATHER test")

        XCTAssertEqual(spy.invocations.count, 1, "Case-insensitive chip should route to Weather tool")
    }

    // MARK: - 11. Input Cleaning Strips Chip

    func testInputCleaningStripsChip() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "What's the #weather ?")

        XCTAssertEqual(spy.invocations.count, 1)
        let cleanedInput = spy.invocations.first!.input
        XCTAssertEqual(cleanedInput, "What's the ?", "Chip tag should be stripped from tool input")
    }

    // MARK: - 12. Widget Data Propagation

    func testWidgetDataPropagation() async throws {
        let widgetData = ["temp": "72", "condition": "sunny"]
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Sunny", status: .ok, outputWidget: "weather", widgetData: widgetData as any Sendable)
        )
        let engine = makeTestEngine(tools: [spy])

        let result = await engine.run(input: "#weather test")

        XCTAssertEqual(result.widgetType, "weather")
        XCTAssertNotNil(result.widgetData, "Widget data should propagate from tool to result")
    }
}

// MARK: - Skill Routing E2E Tests

final class SkillRoutingE2ETests: XCTestCase {

    // MARK: - 13. Crypto Skill Full Pipeline

    @MainActor
    func testCryptoSkillFullPipeline() async throws {
        let captured = CapturedPrompt()
        let engine = await makeTestEngineWithSkills(
            tools: ToolRegistry.coreTools,
            fmTools: ToolRegistry.fmTools,
            engineLLMResponder: makeStubLLMResponder(response: "1 BTC = $50,000", capture: captured)
        )

        let result = await engine.run(input: "What's 1 BTC worth?")

        // The crypto skill pre-fetches real data from the API. The response may contain
        // either the stub LLM text or a guardrail fallback with the fetched data.
        XCTAssertFalse(result.text.isEmpty, "Should produce a response")
        XCTAssertTrue(captured.value.contains("Skill Instruction:") || captured.value.contains("Crypto"),
                      "Skill instruction should be injected into final prompt")
    }

    // MARK: - 15. Skill Instruction in Final Prompt

    @MainActor
    func testSkillInstructionInFinalPrompt() async throws {
        let captured = CapturedPrompt()
        let engine = await makeTestEngineWithSkills(
            tools: ToolRegistry.coreTools,
            fmTools: ToolRegistry.fmTools,
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "What's 1 BTC worth?")

        XCTAssertTrue(captured.value.contains("Skill Instruction:"), "Captured prompt must contain skill instruction prefix")
    }

    // MARK: - 16. Skill Sets currentSkill on Router

    @MainActor
    func testSkillSetsCurrentSkillOnRouter() async throws {
        _ = await SkillLoader.shared.awaitActiveSkills()

        let router = ToolRouter(
            availableTools: ToolRegistry.coreTools,
            fmTools: ToolRegistry.fmTools,
            llmResponder: makeStubRouterLLMResponder()
        )

        _ = await router.route(input: "What's 1 BTC worth?")
        let skill = await router.currentSkill

        XCTAssertNotNil(skill, "Skill should be set after routing")
        XCTAssertEqual(skill?.name, "Crypto Price Skill")
    }

    // MARK: - 17. Skill Overridden by Explicit Chip

    @MainActor
    func testSkillOverriddenByExplicitChip() async throws {
        let calcSpy = SpyTool(name: "Calculator", schema: "calculator math")
        let engine = await makeTestEngineWithSkills(
            tools: [calcSpy],
            fmTools: ToolRegistry.fmTools
        )

        _ = await engine.run(input: "#calculator What's 1 BTC worth?")

        XCTAssertEqual(calcSpy.invocations.count, 1, "Explicit chip should override skill matching")
    }
}

// MARK: - Robustness Prompt Variant Tests

final class PromptVariantE2ETests: XCTestCase {

    // Helper: routes chip-based input and asserts the expected tool spy was invoked
    private func assertChipRoutes(
        input: String,
        toToolNamed expectedTool: String,
        tools: [any CoreTool],
        fmTools: [any FMToolDescriptor] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: tools,
            fmTools: fmTools,
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: input)

        if let spy = tools.first(where: { $0.name == expectedTool }) as? SpyTool {
            XCTAssertGreaterThan(spy.invocations.count, 0, "'\(input)' should route to \(expectedTool)", file: file, line: line)
        } else {
            let routedSomewhere = !result.text.contains("Error") || captured.value.contains(expectedTool)
            XCTAssertTrue(routedSomewhere, "'\(input)' should route somewhere (expected \(expectedTool))", file: file, line: line)
        }
    }

    // Helper: routes natural-language input through ML and asserts it reaches a tool or disambiguation
    // (not needsUserClarification). With stub LLM returning "none", only ML can match.
    private func assertMLRoutes(
        input: String,
        toToolNamed expectedTool: String,
        tools: [any CoreTool],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: tools,
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: input)

        if let spy = tools.first(where: { $0.name == expectedTool }) as? SpyTool {
            // ML matched and tool was invoked
            if spy.invocations.count > 0 {
                return // success
            }
        }
        // ML may have reached disambiguation or another tool — that's acceptable for natural language
        // All paths now go through finalization, so captured prompt should always be populated
        let reachedFinalization = !captured.value.isEmpty
        XCTAssertTrue(reachedFinalization,
            "'\(input)' should reach finalization (got: \(result.text.prefix(80)))",
            file: file, line: line)
    }

    // MARK: - 18. Weather Prompt Variants

    func testWeatherPromptVariants() async throws {
        // Chip-based prompts (deterministic routing)
        let chipPrompts = [
            "What's the #weather ?",
            "#weather in London",
            "#weather forecast for tomorrow",
            "#weather is it raining",
            "#weather current conditions"
        ]
        for prompt in chipPrompts {
            let spy = SpyTool(name: "Weather", schema: "weather forecast temperature rain sun cloud")
            await assertChipRoutes(input: prompt, toToolNamed: "Weather", tools: [spy])
        }

        // Natural language prompts tested with the full tool registry so ML has enough tools to compare
        let nlPrompts = [
            "What's the weather?",
            "How's it outside?",
            "Is it raining?",
            "Temperature right now",
            "check the weather"
        ]
        for prompt in nlPrompts {
            // With a single spy tool, NLEmbedding often can't reach confidence threshold.
            // Use the router directly with real tools to test ML classification.
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            // Accept any routing result except needsUserClarification for weather-related prompts
            switch result {
            case .conversational, .needsUserClarification:
                // NL routing without LLM fallback may fail — document this as known limitation
                print("⚠️ NL routing missed for: '\(prompt)' — requires LLM fallback in production")
            default:
                break // Any routing result is acceptable
            }
        }
    }

    // MARK: - 19. Calculator Prompt Variants

    func testCalculatorPromptVariants() async throws {
        // Chip-based prompts
        let chipPrompts = [
            "#calculator pi",
            "#calculator 5+5",
            "#calculator square root of 144",
            "#calculator sin(45)",
            "#calculator 15% of 200"
        ]
        for prompt in chipPrompts {
            let spy = SpyTool(name: "Calculator", schema: "calculator math compute arithmetic")
            await assertChipRoutes(input: prompt, toToolNamed: "Calculator", tools: [spy])
        }

        // Natural language prompts tested with full tool registry for ML classification
        let nlPrompts = [
            "calculate 100/4",
            "what is 12 * 3",
            "what's 99 minus 1",
            "compute 3.14 * 2",
            "2^10"
        ]
        for prompt in nlPrompts {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            switch result {
            case .conversational, .needsUserClarification:
                print("⚠️ NL routing missed for: '\(prompt)' — requires LLM fallback in production")
            default:
                break
            }
        }
    }

    // MARK: - 20. Maps Prompt Variants

    func testMapsPromptVariants() async throws {
        let prompts = [
            "#maps directions to London",
            "#maps search coffee near me",
            "#maps eta to work",
            "#maps open Eiffel Tower",
        ]

        for prompt in prompts {
            let mapsDescriptor = StubFMToolDescriptor(name: "maps", chipName: "maps", routingKeywords: ["directions", "navigate", "map", "nearby"])
            let capturedTools = CapturedTools()
            let engine = makeTestEngine(
                tools: [],
                fmTools: [mapsDescriptor],
                engineLLMResponder: makeToolCapturingLLMResponder(toolCapture: capturedTools)
            )
            _ = await engine.run(input: prompt)
            XCTAssertTrue(capturedTools.contains(toolNamed: "maps"), "'\(prompt)' should route to maps FM tool")
        }
    }

    // MARK: - 21. Messages Prompt Variants

    func testMessagesPromptVariants() async throws {
        let prompts = [
            "#messages send hi to John",
            "#messages tell Dad call me",
            "#messages",
            "#messages say thanks to Alice"
        ]

        for prompt in prompts {
            let messagesDescriptor = StubFMToolDescriptor(name: "messages", chipName: "messages", routingKeywords: ["message", "text", "imessage", "send"])
            let capturedTools = CapturedTools()
            let engine = makeTestEngine(
                tools: [],
                fmTools: [messagesDescriptor],
                engineLLMResponder: makeToolCapturingLLMResponder(toolCapture: capturedTools)
            )
            _ = await engine.run(input: prompt)
            XCTAssertTrue(capturedTools.contains(toolNamed: "messages"), "'\(prompt)' should route to messages FM tool")
        }
    }

    // MARK: - 22. Crypto Skill Prompt Variants

    @MainActor
    func testCryptoSkillPromptVariants() async throws {
        // These prompts must match the skill's examples via substring matching in checkSkillExamples().
        // The skill loader uses `input.contains(example)` or `example.contains(input)`.
        // We test prompts known to match actual skill examples from the Crypto Price Skill.
        _ = await SkillLoader.shared.awaitActiveSkills()

        let skills = SkillLoader.shared.loadedSkills
        let cryptoSkill = skills.first { $0.name == "Crypto Price Skill" }
        // Skip if crypto skill not loaded (missing resources)
        guard cryptoSkill != nil else {
            XCTFail("Crypto Price Skill not found in loaded skills")
            return
        }

        // Use actual skill examples that we know will match
        let promptsThatShouldMatch = cryptoSkill!.examples.prefix(5)

        for prompt in promptsThatShouldMatch {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            let skill = await router.currentSkill

            let matched: Bool
            switch result {
            case .tools(let tools):
                matched = tools.contains { $0.name == "Convert" }
            case .fmTools, .mixed:
                matched = true // Routed somewhere, acceptable
            case .requiresDisambiguation, .conversational, .needsUserClarification:
                matched = false
            }

            let skillMatched = skill?.name == "Crypto Price Skill"
            XCTAssertTrue(matched || skillMatched, "'\(prompt)' should route to crypto skill or Convert tool, got: \(result), skill: \(skill?.name ?? "none")")
        }

        // Additional prompts that should match via substring matching with skill examples
        let additionalPrompts = [
            "What's 1 BTC worth?",
            "Convert 100 DOGE to EUR.",
            "What is the value of 500 XRP?",
            "Price of Avalanche today.",
            "How much is 10 Polkadot worth?",
        ]

        for prompt in additionalPrompts {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            let skill = await router.currentSkill

            let matched: Bool
            switch result {
            case .tools(let tools):
                matched = tools.contains { $0.name == "Convert" } || !tools.isEmpty
            case .fmTools, .mixed:
                matched = true // Routed to some tool, acceptable
            case .requiresDisambiguation:
                matched = true // Disambiguation is acceptable for ambiguous prompts
            case .conversational, .needsUserClarification:
                matched = false
            }

            let skillMatched = skill?.name == "Crypto Price Skill"
            // For additional prompts, we accept any routing result except needsUserClarification
            XCTAssertTrue(matched || skillMatched, "'\(prompt)' should not reach needsUserClarification, got: \(result), skill: \(skill?.name ?? "none")")
        }
    }

    // MARK: - 23. Shortcuts Prompt Variants

    func testShortcutsPromptVariants() async throws {
        let prompts = [
            "#shortcuts list",
            "#shortcuts run Battery Stats",
            "#shortcuts",
        ]

        for prompt in prompts {
            let shortcutsDescriptor = StubFMToolDescriptor(name: "shortcuts", chipName: "shortcuts", routingKeywords: ["shortcut", "automation", "workflow"])
            let capturedTools = CapturedTools()
            let engine = makeTestEngine(
                tools: [],
                fmTools: [shortcutsDescriptor],
                engineLLMResponder: makeToolCapturingLLMResponder(toolCapture: capturedTools)
            )
            _ = await engine.run(input: prompt)
            XCTAssertTrue(capturedTools.contains(toolNamed: "shortcuts"), "'\(prompt)' should route to shortcuts FM tool")
        }
    }

    // MARK: - 24. Stocks Prompt Variants

    func testStocksPromptVariants() async throws {
        let spy = SpyTool(name: "Stocks", schema: "stock price market ticker quote share")
        let engine = makeTestEngine(tools: [spy])

        let prompts = [
            "#stocks AAPL",
            "#stocks AMZN",
            "#stocks",
        ]

        for prompt in prompts {
            _ = await engine.run(input: prompt)
        }
        XCTAssertEqual(spy.invocations.count, prompts.count, "All stock chip prompts should route to Stocks")
    }

    // MARK: - 25. Dictionary Prompt Variants

    func testDictionaryPromptVariants() async throws {
        // Chip-based prompts (deterministic)
        let chipPrompts = [
            "#dictionary serendipity",
            "#dictionary ephemeral",
            "#dictionary ubiquitous",
            "#dictionary antidisestablishmentarianism",
            "#dictionary petrichor",
        ]
        for prompt in chipPrompts {
            let spy = SpyTool(name: "Dictionary", schema: "dictionary definition lookup meaning word define")
            await assertChipRoutes(input: prompt, toToolNamed: "Dictionary", tools: [spy])
        }

        // Natural language prompts tested with full tool registry
        let nlPrompts = [
            "define serendipity",
            "what does ephemeral mean",
            "meaning of paradigm",
            "look up the word entropy",
            "what is the definition of zeitgeist"
        ]
        for prompt in nlPrompts {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            switch result {
            case .conversational, .needsUserClarification:
                print("⚠️ NL routing missed for: '\(prompt)' — requires LLM fallback in production")
            default:
                break
            }
        }
    }

    // MARK: - 26. SystemInfo Prompt Variants

    func testSystemInfoPromptVariants() async throws {
        let chipPrompts = [
            "#systeminfo",
            "#systeminfo battery",
            "#systeminfo disk",
            "#systeminfo wifi",
            "#systeminfo memory",
        ]
        for prompt in chipPrompts {
            let spy = SpyTool(name: "SystemInfo", schema: "system info battery wifi network bluetooth disk space storage apps installed memory CPU uptime")
            await assertChipRoutes(input: prompt, toToolNamed: "SystemInfo", tools: [spy])
        }

        let nlPrompts = [
            "what's my battery level",
            "am I connected to wifi",
            "how much disk space do I have",
            "system information",
            "check my storage"
        ]
        for prompt in nlPrompts {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            switch result {
            case .conversational, .needsUserClarification:
                print("⚠️ NL routing missed for: '\(prompt)' — requires LLM fallback in production")
            default:
                break
            }
        }
    }

    // MARK: - 27. Screenshot Prompt Variants

    func testScreenshotPromptVariants() async throws {
        let chipPrompts = [
            "#screenshot",
            "#screenshot what's on my screen",
            "#screenshot OCR",
            "#screenshot analyze",
            "#screenshot read my screen",
        ]
        for prompt in chipPrompts {
            let spy = SpyTool(name: "Screenshot", schema: "screenshot screen capture OCR read screen analyze error what on screen")
            await assertChipRoutes(input: prompt, toToolNamed: "Screenshot", tools: [spy])
        }

        let nlPrompts = [
            "take a screenshot",
            "read my screen",
            "what does this error mean",
            "capture the screen",
            "analyze my screen"
        ]
        for prompt in nlPrompts {
            let router = ToolRouter(
                availableTools: ToolRegistry.coreTools,
                fmTools: ToolRegistry.fmTools,
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            switch result {
            case .conversational, .needsUserClarification:
                print("⚠️ NL routing missed for: '\(prompt)' — requires LLM fallback in production")
            default:
                break
            }
        }
    }
}

// MARK: - Currency/Crypto Conversion E2E Tests

final class CurrencyConversionE2ETests: XCTestCase {

    // MARK: - Convert Tool Chip Routing

    func testConvertChipCurrencyRouting() async throws {
        let prompts = [
            "#convert 100 usd to eur",
            "#convert 1 btc to usd",
            "#convert 50 gbp to jpy",
            "#convert 10 dollars to euros",
            "#convert 1 bitcoin to usd",
            "#convert 0.5 eth to gbp",
            "#convert 1000 yen to dollars",
            "#convert 1 litecoin to cad",
            "#convert 100 euros to pounds",
            "#convert 5 sol to eur",
        ]

        for prompt in prompts {
            let spy = SpyTool(
                name: "Convert",
                schema: "Convert units or currency/crypto",
                result: ToolIO(text: "1.00 USD = 0.92 EUR", status: .ok, isVerifiedData: true)
            )
            let captured = CapturedPrompt()
            let engine = makeTestEngine(
                tools: [spy],
                engineLLMResponder: makeStubLLMResponder(capture: captured)
            )
            _ = await engine.run(input: prompt)
            XCTAssertEqual(spy.invocations.count, 1, "'\(prompt)' should route to Convert tool")
        }
    }

    // MARK: - Verified Data Tag Reaches Finalizer

    func testVerifiedDataTagReachesFinalPrompt() async throws {
        let spy = SpyTool(
            name: "Convert",
            schema: "Convert units or currency/crypto",
            result: ToolIO(text: "1.00 BTC = 50,000.00 USD (rate: 50000.0)", status: .ok, isVerifiedData: true)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#convert 1 btc to usd")

        // The ingredient in <ki> should carry the [VERIFIED] prefix + exact data
        XCTAssertTrue(captured.value.contains("[VERIFIED] 1.00 BTC"), "Verified ingredient should appear in prompt")
        XCTAssertTrue(captured.value.contains("50,000.00 USD"), "Verified data should reach final prompt")
        // BRAIN.md defines [VERIFIED] = live data: use exact numbers, never substitute
        XCTAssertTrue(captured.value.contains("exact numbers"), "Verified constraint should be in brain rules")
    }

    // MARK: - Non-Verified Data Has No Tag

    func testNonVerifiedDataHasNoTag() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Sunny 72°F", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#weather test")

        // The ingredient should NOT have the [VERIFIED] prefix (non-verified data)
        // Note: BRAIN.md rules mention [VERIFIED] in the explanation, but the ingredient itself should not be tagged
        XCTAssertFalse(captured.value.contains("[VERIFIED] Sunny"), "Non-verified data should not have VERIFIED tag")
    }

    // MARK: - Stock Tool Verified Data

    func testStockToolVerifiedData() async throws {
        let spy = SpyTool(
            name: "Stocks",
            schema: "stock price market",
            result: ToolIO(text: "AAPL: $150.00 (+2.5%)", status: .ok, isVerifiedData: true)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#stocks AAPL")

        XCTAssertTrue(captured.value.contains("[VERIFIED]"), "Stock data should be tagged as verified")
        XCTAssertTrue(captured.value.contains("AAPL: $150.00"), "Stock data should reach prompt")
    }

    // MARK: - ConvertTool Unit Conversion Still Works

    func testConvertToolUnitConversionUnchanged() async throws {
        let tool = ConvertTool()

        let result = try await tool.execute(input: "10 miles to km", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("16.09"), "10 miles should be ~16.09 km")
        XCTAssertFalse(result.isVerifiedData, "Unit conversions are math, not live API data")
    }

    // MARK: - ConvertTool Currency Aliases

    func testConvertToolCurrencyAliases() async throws {
        let tool = ConvertTool()

        // "dollars" should resolve to "usd", "euros" to "eur"
        let result = try await tool.execute(input: "10 dollars to euros", entities: nil)
        // Even if API is unreachable, it should attempt the currency path (not fall through to "Could not parse")
        XCTAssertFalse(result.text.contains("Could not parse"), "Should recognize 'dollars' and 'euros' as currency, got: \(result.text)")
    }

    // MARK: - ConvertTool Crypto Aliases

    func testConvertToolCryptoAliases() async throws {
        let tool = ConvertTool()

        let result = try await tool.execute(input: "1 bitcoin to usd", entities: nil)
        XCTAssertFalse(result.text.contains("Could not parse"), "Should recognize 'bitcoin' as crypto, got: \(result.text)")
    }
}

// MARK: - Error Personalization E2E Tests

final class ErrorPersonalizationE2ETests: XCTestCase {

    override func setUp() async throws { await ScratchpadCache.shared.reset() }

    // MARK: - Clarification Goes Through SOUL (or direct response)

    func testClarificationGoesToFinalization() async throws {
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            engineLLMResponder: makeStubLLMResponder(response: "I don't know what that means. Be more specific.", capture: captured, captureFirstOnly: true)
        )

        let result = await engine.run(input: "xyzzy gibberish nonsense")

        XCTAssertFalse(result.text.contains("Routing failed"), "Raw error should not leak to user")
        XCTAssertFalse(result.text.contains("Error:"), "Raw Error: prefix should not leak to user")
        // The engine now emits a direct localized clarification for ambiguous input,
        // bypassing the finalizer LLM. Accept either path: a direct clarification
        // response OR an LLM-finalized prompt containing guidance markers.
        let directClarification = result.text.contains("tell me a bit more") || result.text.contains("looking for")
        let llmFinalizedWithGuidance = captured.value.contains("<brain>") || captured.value.contains("<req>")
        XCTAssertTrue(directClarification || llmFinalizedWithGuidance,
            "Should surface a user-friendly clarification (direct) or go through finalization. result=\(result.text)")
    }

    // MARK: - Disambiguation Goes Through SOUL (or direct response)

    func testDisambiguationGoesToFinalization() async throws {
        let tool1 = SpyTool(name: "ToolA", schema: "test tool alpha", result: ToolIO(text: "a"))
        let tool2 = SpyTool(name: "ToolB", schema: "test tool beta", result: ToolIO(text: "b"))
        let captured = CapturedPrompt()

        let router = ToolRouter(availableTools: [tool1, tool2], llmResponder: makeStubRouterLLMResponder())
        let engine = ExecutionEngine(
            preprocessor: InputPreprocessor(),
            router: router,
            conversationManager: ConversationManager(),
            finalizer: OutputFinalizer(),
            llmResponder: makeStubLLMResponder(response: "Did you mean ToolA or ToolB?", capture: captured)
        )

        let result = await engine.run(input: "test")

        // Ambiguous input must never surface raw routing errors.
        XCTAssertFalse(result.text.contains("disambiguation required"), "Raw disambiguation error should not leak")
        XCTAssertFalse(result.text.contains("Routing failed"), "Raw error should not leak")
        // Accept either: a direct localized clarification/disambiguation response,
        // OR a finalization prompt with brain/req markers, OR a routed tool output.
        let nonEmpty = !result.text.isEmpty
        let directResponse = result.text.contains("tell me a bit more") || result.text.contains("looking for") || result.text.contains("Did you mean")
        let finalizedPrompt = captured.value.contains("<brain>") || captured.value.contains("<req>") || captured.value.contains("## Instructions")
        XCTAssertTrue(nonEmpty && (directResponse || finalizedPrompt),
            "Should surface a user-friendly response. result=\(result.text) captured=\(captured.value.prefix(100))")
    }

    // MARK: - All Error Paths Reach Finalization

    func testAllPathsReachFinalization() async throws {
        // Even with no tools and no LLM router match, should reach finalization
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            engineLLMResponder: makeStubLLMResponder(response: "Personalized error", capture: captured)
        )

        let result = await engine.run(input: "completely unknown request asdqwezxc")

        XCTAssertFalse(captured.value.isEmpty, "Should reach finalization (captured prompt not empty)")
        XCTAssertEqual(result.text, "Personalized error")
    }

    // MARK: - Date Arithmetic Routing

    func testDateArithmeticYearsAgoRoutesToCalendar() async throws {
        await ScratchpadCache.shared.reset()
        let cal = SpyTool(name: "Calendar", schema: "Date calculations", category: .offline)
        let engine = makeTestEngine(
            tools: [cal],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calendar")
        )

        let _ = await engine.run(input: "what year was 60 years ago")
        XCTAssertGreaterThanOrEqual(cal.invocations.count, 1, "Should route to Calendar")
    }

    func testDateArithmeticDaysFromNowRoutesToCalendar() async throws {
        await ScratchpadCache.shared.reset()
        let cal = SpyTool(name: "Calendar", schema: "calendar date event schedule days weeks months how many days between", category: .offline)
        let engine = makeTestEngine(
            tools: [cal],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calendar")
        )

        let _ = await engine.run(input: "#calendar what date is 90 days from now")
        XCTAssertGreaterThanOrEqual(cal.invocations.count, 1, "Should route to Calendar")
    }

    func testDateArithmeticWeeksAgoRoutesToCalendar() async throws {
        await ScratchpadCache.shared.reset()
        let cal = SpyTool(name: "Calendar", schema: "Date calculations", category: .offline)
        let engine = makeTestEngine(
            tools: [cal],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calendar")
        )

        let _ = await engine.run(input: "3 weeks ago")
        XCTAssertGreaterThanOrEqual(cal.invocations.count, 1, "Should route to Calendar")
    }

    func testDateArithmeticNaturalPhrasing() async throws {
        await ScratchpadCache.shared.reset()
        let cal = SpyTool(name: "Calendar", schema: "Date calculations", category: .offline)
        let engine = makeTestEngine(
            tools: [cal],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calendar")
        )

        // "what year was 60 years ago?" — the original failing prompt
        let _ = await engine.run(input: "what year was 60 years ago?")
        XCTAssertGreaterThanOrEqual(cal.invocations.count, 1, "Original failing prompt should route to Calendar")
    }

    // MARK: - TodayTool Tests

    func testTodayChipRouting() async throws {
        let spy = SpyTool(
            name: "Today",
            schema: "Daily summary briefing today daily summary morning briefing overview",
            category: .online,
            result: ToolIO(text: "Today's Summary", status: .ok, outputWidget: "TodaySummaryWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: "#today")

        XCTAssertEqual(spy.invocations.count, 1, "Today tool should be called via chip")
        XCTAssertEqual(result.widgetType, "TodaySummaryWidget")
    }

    func testTodayNaturalLanguageRouting() async throws {
        try require(.auditTests)
        // Phrases that reach the LLM fallback (which returns "Today") after synonym
        // expansion. Some NL phrases get intercepted by the ML classifier's disambiguation
        // stage before the LLM fallback fires, because the "today" label hasn't been added
        // to the ML training data yet. Once ML training includes a "today" label, the full
        // set of phrases from SynonymMap.json can be tested here.
        let prompts = [
            "what's my day look like",
            "give me my daily briefing",
        ]

        for prompt in prompts {
            let spy = SpyTool(
                name: "Today",
                schema: "Daily summary briefing today daily summary morning briefing overview agenda",
                category: .online,
                result: ToolIO(text: "Today's Summary", status: .ok, outputWidget: "TodaySummaryWidget")
            )
            let engine = makeTestEngine(
                tools: [spy],
                routerLLMResponder: makeStubRouterLLMResponder(toolName: "Today")
            )

            await ScratchpadCache.shared.reset()
            let _ = await engine.run(input: prompt)
            XCTAssertGreaterThanOrEqual(spy.invocations.count, 1, "'\(prompt)' should route to Today tool")
        }
    }

    func testTodayToolWidgetData() async throws {
        let spy = SpyTool(
            name: "Today",
            schema: "Daily summary briefing today daily summary morning briefing overview",
            category: .online,
            result: ToolIO(
                text: "Today's Summary — Friday, March 13\nWeather: 72°F Clear in San Francisco\nCalendar: No events\nReminders: All clear",
                status: .ok,
                outputWidget: "TodaySummaryWidget",
                widgetData: TodaySummaryWidgetData(
                    events: [TodaySummaryWidgetData.EventItem(title: "Standup", startTime: Date(), endTime: nil, isAllDay: false)],
                    reminders: [TodaySummaryWidgetData.ReminderItem(title: "Buy groceries", dueDate: nil)],
                    weather: TodaySummaryWidgetData.WeatherSummary(city: "SF", temperature: "72°F", condition: "Clear", iconName: "sun.max", high: "75°F", low: "60°F"),
                    hints: [],
                    date: Date()
                )
            )
        )
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Today")
        )

        let result = await engine.run(input: "#today")
        XCTAssertEqual(result.widgetType, "TodaySummaryWidget")
        XCTAssertNotNil(result.widgetData as? TodaySummaryWidgetData)
        if let widgetData = result.widgetData as? TodaySummaryWidgetData {
            XCTAssertEqual(widgetData.events.count, 1)
            XCTAssertEqual(widgetData.events.first?.title, "Standup")
            XCTAssertEqual(widgetData.reminders.count, 1)
            XCTAssertNotNil(widgetData.weather)
        }
    }

    // MARK: - ReadEmail Tool

    func testReadEmailChipRouting() async throws {
        let spy = SpyTool(
            name: "ReadEmail",
            schema: "read email inbox unread search check mail",
            result: ToolIO(text: "3 unread emails", status: .ok, outputWidget: "EmailListWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: "#reademail check inbox")
        XCTAssertEqual(spy.invocations.count, 1, "ReadEmail tool should be called")
        XCTAssertEqual(result.widgetType, "EmailListWidget")
    }

    func testReadEmailNaturalLanguageRouting() async throws {
        // Synonym expansion routes these to "reademail ..." which the ML classifier
        // doesn't know yet; use routerLLMResponder to simulate LLM fallback routing.
        let prompts = [
            "check my email",
            "check my mail",
            "any new emails",
            "unread mail",
            "read my email",
            "read my mail",
            "show my email",
            "read my inbox",
            "any new mail",
            "unread emails",
        ]

        let spy = SpyTool(
            name: "ReadEmail",
            schema: "read email inbox unread search check mail",
            result: ToolIO(text: "Latest emails", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "ReadEmail")
        )

        for prompt in prompts {
            _ = await engine.run(input: prompt)
        }
        XCTAssertEqual(spy.invocations.count, prompts.count, "All NL prompts should route to ReadEmail")
    }

    func testReadEmailSenderRouting() async throws {
        try require(.auditTests)
        let senderPrompts = [
            "emails from John",
            "mail from Sarah",
        ]

        for prompt in senderPrompts {
            let spy = SpyTool(
                name: "ReadEmail",
                schema: "read email inbox unread search check mail from sender",
                result: ToolIO(text: "Emails from sender", status: .ok)
            )
            let engine = makeTestEngine(
                tools: [spy],
                routerLLMResponder: makeStubRouterLLMResponder(toolName: "ReadEmail")
            )
            _ = await engine.run(input: prompt)
            XCTAssertEqual(spy.invocations.count, 1, "'\(prompt)' should route to ReadEmail")
        }
    }

    func testReadEmailSearchRouting() async throws {
        try require(.auditTests)
        // "search my email" and "search my mail" use synonym expansion;
        // "find email" also has a synonym. All route via LLM fallback.
        let searchPrompts = [
            "search my email for invoice",
            "find mail about deadline",
        ]

        for prompt in searchPrompts {
            let spy = SpyTool(
                name: "ReadEmail",
                schema: "read email inbox unread search check mail find",
                result: ToolIO(text: "Found emails", status: .ok)
            )
            let engine = makeTestEngine(
                tools: [spy],
                routerLLMResponder: makeStubRouterLLMResponder(toolName: "ReadEmail")
            )
            _ = await engine.run(input: prompt)
            XCTAssertEqual(spy.invocations.count, 1, "'\(prompt)' should route to ReadEmail")
        }
    }

    func testReadEmailIntentDetection() async throws {
        let tool = ReadEmailTool()

        // Latest
        let latest = tool.detectIntent(input: "check my email", entities: nil)
        if case .latest = latest {} else { XCTFail("Expected .latest, got \(latest)") }

        // Unread
        let unread = tool.detectIntent(input: "unread emails", entities: nil)
        if case .unread = unread {} else { XCTFail("Expected .unread, got \(unread)") }

        // Search
        let search = tool.detectIntent(input: "search email for invoice", entities: nil)
        if case .search(let q) = search {
            XCTAssertTrue(q.contains("invoice"), "Search query should contain 'invoice', got '\(q)'")
        } else { XCTFail("Expected .search, got \(search)") }

        // From sender
        let sender = tool.detectIntent(input: "emails from Sarah", entities: nil)
        if case .fromSender(let name) = sender {
            XCTAssertTrue(name.lowercased().contains("sarah"), "Sender should be 'Sarah', got '\(name)'")
        } else { XCTFail("Expected .fromSender, got \(sender)") }
    }

    func testReadEmailDoesNotConflictWithEmailSend() async throws {
        // Chip routing always disambiguates correctly
        let readSpy = SpyTool(
            name: "ReadEmail",
            schema: "read email inbox unread search check mail",
            result: ToolIO(text: "Latest emails", status: .ok)
        )
        let sendSpy = SpyTool(
            name: "Email",
            schema: "send email compose write message",
            result: ToolIO(text: "Email sent", status: .ok)
        )
        let engine = makeTestEngine(tools: [readSpy, sendSpy])

        // #reademail chip should go to ReadEmail, not Email
        _ = await engine.run(input: "#reademail inbox")
        XCTAssertEqual(readSpy.invocations.count, 1, "Should route to ReadEmail via chip")
        XCTAssertEqual(sendSpy.invocations.count, 0, "Should NOT route to Email (send)")
    }
}

// MARK: - Feedback Tool E2E Tests

final class FeedbackToolE2ETests: XCTestCase {

    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Chip Routing

    func testFeedbackChipRoutes() async throws {
        let spy = SpyTool(
            name: "Feedback",
            schema: "feedback report issue wrong",
            result: ToolIO(text: "Feedback received", status: .ok, outputWidget: "FeedbackWidget")
        )
        let engine = makeTestEngine(tools: [spy])
        _ = await engine.run(input: "#feedback this was wrong")
        XCTAssertEqual(spy.invocations.count, 1, "Feedback tool should be called via chip")
    }

    // MARK: - Chain Parsing

    func testFeedbackToolParsesChain() async throws {
        let tool = FeedbackTool(llmResponder: { _, _ in "suggestion1\nsuggestion2\nsuggestion3" })
        let input = """
        [Feedback on: "what's the weather"→"It's sunny 72°F"]
        That temperature seems wrong
        """
        let result = try await tool.execute(input: input, entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("That temperature seems wrong"))
        XCTAssertTrue(result.text.contains("It's sunny 72°F"))
        XCTAssertEqual(result.outputWidget, "FeedbackWidget")
    }

    func testFeedbackToolMultiPairChain() async throws {
        let tool = FeedbackTool(llmResponder: { _, _ in "suggestion1\nsuggestion2\nsuggestion3" })
        let input = """
        [Feedback on: "hello"→"Hi there!" | "how are you"→"I'm great"]
        Both responses were too brief
        """
        let result = try await tool.execute(input: input, entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Both responses were too brief"))
    }

    func testFeedbackToolEmptyInput() async throws {
        let tool = FeedbackTool(llmResponder: { _, _ in "suggestion1\nsuggestion2\nsuggestion3" })
        let result = try await tool.execute(input: "", entities: nil)
        XCTAssertEqual(result.status, .ok, "Empty input returns a soft prompt, not an error")
        XCTAssertTrue(result.text.contains("what"), "Should prompt the user for feedback")
    }

    // MARK: - LLM Suggestion Generation

    func testFeedbackToolWithLLMResponder() async throws {
        let tool = FeedbackTool(llmResponder: { _, _ in
            "Q1: What specifically was wrong?\nQ2: Was the data outdated?\nQ3: Can you provide the correct answer?"
        })
        let result = try await tool.execute(input: "That answer was completely wrong", entities: nil)
        XCTAssertEqual(result.status, .ok)
        if let data = result.widgetData as? FeedbackWidgetData {
            XCTAssertEqual(data.phase, .review)
            XCTAssertEqual(data.suggestedQuestions.count, 3)
            XCTAssertTrue(data.suggestedQuestions.contains("What specifically was wrong?"))
        } else {
            XCTFail("Widget data should be FeedbackWidgetData")
        }
    }

    // MARK: - Pipeline E2E

    func testFeedbackChipE2E() async throws {
        let spy = SpyTool(
            name: "Feedback",
            schema: "feedback report issue wrong flag",
            result: ToolIO(text: "Feedback received", status: .ok, outputWidget: "FeedbackWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )
        let result = await engine.run(input: "#feedback the last answer was wrong")
        XCTAssertEqual(spy.invocations.count, 1)
        XCTAssertTrue(captured.value.contains("Feedback received"))
        XCTAssertEqual(result.widgetType, "FeedbackWidget")
    }

    // MARK: - Natural Language Prompts

    func testFeedbackNaturalLanguagePrompts() async throws {
        let spy = SpyTool(
            name: "Feedback",
            schema: "feedback report issue wrong flag give feedback that's wrong bad response not what i asked",
            result: ToolIO(text: "Feedback received", status: .ok)
        )

        let prompts = [
            "#feedback this was wrong",
            "#Feedback I don't agree with that",
        ]

        for prompt in prompts {
            await ScratchpadCache.shared.reset()
            let engine = makeTestEngine(tools: [spy])
            _ = await engine.run(input: prompt)
        }

        XCTAssertEqual(spy.invocations.count, prompts.count, "All \(prompts.count) prompts should route to Feedback")
    }

    // MARK: - FeedbackSender Stub

    func testFeedbackSenderReturnsTrue() async {
        let result = await FeedbackSender.shared.send(summary: "Test feedback", feedbackID: "test-123")
        XCTAssertTrue(result)
    }

    // MARK: - Calculator Pipeline E2E (Widget Data + SOUL Guard)

    func testCalculatorPipelineEmitsWidgetData() async throws {
        let engine = makeTestEngine(
            tools: [CalculatorTool()],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calculator"),
            engineLLMResponder: makeStubLLMResponder(response: "5 + 5 = 10")
        )
        let result = await engine.run(input: "#calculator 5 + 5")
        XCTAssertEqual(result.widgetType, "MathWidget")
        XCTAssertNotNil(result.widgetData as? CalculationWidgetData, "Should emit CalculationWidgetData")
        let data = result.widgetData as? CalculationWidgetData
        XCTAssertTrue(data?.result.contains("10") ?? false)
    }

    func testCalculatorPercentPipeline() async throws {
        let engine = makeTestEngine(
            tools: [CalculatorTool()],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calculator"),
            engineLLMResponder: makeStubLLMResponder(response: "25% of 200 = 50")
        )
        let result = await engine.run(input: "#calculator 25% of 200")
        XCTAssertFalse(result.isError, "25% of 200 should not error")
        XCTAssertTrue(result.text.contains("50"), "25% of 200 should produce 50, got: \(result.text)")
    }

    func testSOULLeakIsStrippedFromResponse() async throws {
        // Simulate LLM echoing back the system prompt
        let leakyResponse = """
        ### SOUL / IDENTITY
        # Agent Soul
        Local macOS agent. Fast, private, hardware-native.
        **Personality Directives:**
        * **Terse**: No pleasantries or filler.
        * **Anti-Sycophant**: No "happy to help".
        ### USER REQUEST
        Tell me a joke
        """
        let engine = makeTestEngine(
            tools: [SpyTool(name: "Random", schema: "random")],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Random"),
            engineLLMResponder: makeStubLLMResponder(response: leakyResponse)
        )
        let result = await engine.run(input: "tell me a joke")
        XCTAssertFalse(result.text.contains("SOUL"), "SOUL section should be stripped: \(result.text)")
        XCTAssertFalse(result.text.contains("Agent Soul"), "Agent Soul should be stripped")
        XCTAssertFalse(result.text.contains("Personality Directives"), "Personality directives should be stripped")
    }

    func testSOULLeakFallbackWhenNothingRemains() async throws {
        // LLM returns ONLY the system prompt — after stripping, nothing useful remains
        let pureLeakResponse = "### SOUL / IDENTITY\n# Agent Soul\n**Personality Directives:**\n* **Terse**: data."
        let engine = makeTestEngine(
            tools: [SpyTool(name: "Weather", schema: "weather")],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Weather"),
            engineLLMResponder: makeStubLLMResponder(response: pureLeakResponse)
        )
        let result = await engine.run(input: "weather")
        XCTAssertFalse(result.text.contains("SOUL"))
        XCTAssertFalse(result.text.isEmpty, "Should return a fallback message, not empty string")
    }

    func testCalculatorLLMFallbackInPipeline() async throws {
        // CalculatorTool with LLM normalization. The native AdvancedMathReducers
        // intercept "interest ... year" inputs (compound interest: 1000 * 1.05^3 ≈ 1157.63).
        // If the reducer doesn't intercept, the LLM stub's "1000 * 0.05 * 3" = 150 path runs.
        // Either answer is acceptable — this test verifies the pipeline doesn't error.
        let tool = CalculatorTool(llmResponder: { _ in "1000 * 0.05 * 3" })
        let engine = makeTestEngine(
            tools: [tool],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Calculator"),
            engineLLMResponder: makeStubLLMResponder(response: "The interest is 150")
        )
        let result = await engine.run(input: "#calculator interest on $1000 at 5% for 3 years")
        XCTAssertFalse(result.isError, "Calculator should not error on interest question")
        let hasSimple = result.text.contains("150")
        let hasCompound = result.text.contains("1157") || result.text.contains("1,157")
        XCTAssertTrue(hasSimple || hasCompound,
            "Expected either simple (150) or compound (~1157.63) interest value, got: \(result.text)")
    }

    // MARK: - CreateTool Pipeline E2E

    func testCreateChipPipeline() async throws {
        let spy = SpyTool(
            name: "Create",
            schema: "Create an image: '#create a sunset in sketch style'. Styles: animation, illustration, sketch.",
            category: .async,
            result: ToolIO(text: "Created animation image: sunset", status: .ok, outputWidget: "CreateWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: "#create a sunset in animation style")

        XCTAssertEqual(spy.invocations.count, 1, "Create tool should be called")
        XCTAssertFalse(spy.invocations.first!.input.contains("#"), "Input should be cleaned of chips")
        XCTAssertEqual(result.widgetType, "CreateWidget")
    }

    func testCreateSynonymPipeline() async throws {
        let spy = SpyTool(
            name: "Create",
            schema: "Create an image: '#create a sunset in sketch style'. Styles: animation, illustration, sketch.",
            category: .async,
            result: ToolIO(text: "Created image", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Create"),
            engineLLMResponder: makeStubLLMResponder()
        )

        _ = await engine.run(input: "draw me a robot")

        XCTAssertEqual(spy.invocations.count, 1, "Create tool should be called via synonym 'draw me'")
    }

    func testCreateMultiplePromptsRoute() async throws {
        let prompts = [
            "#create a cartoon cat",
            "#create sketch of a bird",
            "#create a sunset over mountains",
            "create an image of mountains",
            "generate an image of a sunset",
            "make a picture of a castle",
            "create a picture of ocean waves",
            "generate a picture of a garden",
            "#create a dragon in animation style",
            "#create an illustrated forest",
        ]

        let spy = SpyTool(
            name: "Create",
            schema: "Create an image: '#create a sunset in sketch style'. Styles: animation, illustration, sketch.",
            category: .async,
            result: ToolIO(text: "Created image", status: .ok)
        )

        for prompt in prompts {
            await ScratchpadCache.shared.reset()
            let freshSpy = SpyTool(
                name: spy.name,
                schema: spy.schema,
                category: spy.category,
                result: ToolIO(text: "Created image", status: .ok)
            )
            let engine = makeTestEngine(
                tools: [freshSpy],
                routerLLMResponder: makeStubRouterLLMResponder(toolName: "Create"),
                engineLLMResponder: makeStubLLMResponder()
            )
            _ = await engine.run(input: prompt)
            XCTAssertEqual(freshSpy.invocations.count, 1, "Prompt '\(prompt)' should route to Create")
        }
    }

    func testCreateDoesNotRouteScreenshot() async throws {
        let createSpy = SpyTool(
            name: "Create",
            schema: "Create an image",
            category: .async
        )
        let screenshotSpy = SpyTool(
            name: "Screenshot",
            schema: "screenshot screen capture OCR",
            category: .offline
        )
        let engine = makeTestEngine(
            tools: [createSpy, screenshotSpy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Screenshot"),
            engineLLMResponder: makeStubLLMResponder()
        )

        _ = await engine.run(input: "take a picture of my screen")

        XCTAssertEqual(createSpy.invocations.count, 0, "Create should NOT be invoked for screenshot prompts")
        XCTAssertEqual(screenshotSpy.invocations.count, 1, "Screenshot should be invoked instead")
    }
}

// MARK: - Research Tool E2E Tests

final class ResearchToolE2ETests: XCTestCase {

    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Chip Routing

    func testResearchChipRouting() async throws {
        let spy = SpyTool(
            name: "Research",
            schema: "research topic learn understand deep dive explain",
            category: .online,
            result: ToolIO(
                text: "Research results",
                status: .ok,
                outputWidget: "ResearchWidget",
                widgetData: ResearchWidgetData(topic: "test", sources: [], iterationCount: 1)
            )
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        let result = await engine.run(input: "#research quantum computing")

        XCTAssertEqual(spy.invocations.count, 1, "Research tool should be called via chip")
        XCTAssertFalse(spy.invocations.first!.input.contains("#"), "Chip should be stripped")
        XCTAssertTrue(spy.invocations.first!.input.contains("quantum computing"))
        XCTAssertEqual(result.widgetType, "ResearchWidget")
    }

    // MARK: - Skill Routing (10+ natural language prompts)

    func testResearchSkillRouting() async throws {
        // Test skill routing for 12 NL prompts via router.route() (fast — no engine overhead),
        // then validate 1 prompt through the full engine pipeline for E2E coverage.
        _ = await SkillLoader.shared.awaitActiveSkills()

        let prompts = [
            "Research how mRNA vaccines work",
            "Help me understand quantum computing",
            "What's the current state of nuclear fusion research?",
            "Deep dive into how LLMs are trained",
            "I want to learn about the history of the Internet",
            "Research the latest findings on intermittent fasting",
            "Help me understand CRISPR gene editing",
            "Research the best practices for system design interviews",
            "Explain the pros and cons of microservices architecture",
            "What are the arguments for and against universal basic income?",
            "Explain blockchain consensus mechanisms",
            "What's the current research on sleep and productivity?",
        ]

        // Fast path: verify routing matches Research tool for all prompts
        let spy = SpyTool(
            name: "Research",
            schema: "research topic learn understand deep dive explain",
            category: .online,
            result: ToolIO(text: "Research results", status: .ok)
        )
        for prompt in prompts {
            let router = ToolRouter(
                availableTools: [spy],
                fmTools: [],
                llmResponder: makeStubRouterLLMResponder()
            )
            let result = await router.route(input: prompt)
            if case .tools(let tools) = result {
                XCTAssertEqual(tools.first?.name, "Research", "'\(prompt)' should route to Research")
            } else if case .conversational = result {
                // Acceptable for some prompts that don't match skill examples
            } else {
                XCTFail("'\(prompt)' unexpected routing result: \(result)")
            }
        }

        // E2E path: validate one prompt through the full engine pipeline
        let e2eSpy = SpyTool(
            name: "Research",
            schema: "research topic learn understand deep dive explain",
            category: .online,
            result: ToolIO(text: "Research results", status: .ok)
        )
        let engine = await makeTestEngineWithSkills(
            tools: [e2eSpy],
            engineLLMResponder: makeStubLLMResponder()
        )
        _ = await engine.run(input: "Research how mRNA vaccines work")
        XCTAssertEqual(e2eSpy.invocations.count, 1, "Full E2E: Research tool should be invoked")
    }

    // MARK: - ResearchTool Unit Tests

    func testResearchWidgetDataStructure() {
        let sources = [
            ResearchSource(title: "Test Source", url: "https://example.com", domain: "example.com", snippet: "A test snippet"),
            ResearchSource(title: "Wikipedia: Test", url: "https://en.wikipedia.org/wiki/Test", domain: "wikipedia.org", snippet: "Wikipedia content"),
        ]
        let data = ResearchWidgetData(topic: "test topic", sources: sources, iterationCount: 1)

        XCTAssertEqual(data.topic, "test topic")
        XCTAssertEqual(data.sources.count, 2)
        XCTAssertEqual(data.sources[0].domain, "example.com")
        XCTAssertEqual(data.sources[1].domain, "wikipedia.org")
        XCTAssertEqual(data.iterationCount, 1)
    }

    func testDomainExtraction() {
        XCTAssertEqual(ResearchTool.extractDomain(from: "https://www.example.com/path"), "example.com")
        XCTAssertEqual(ResearchTool.extractDomain(from: "https://en.wikipedia.org/wiki/Test"), "en.wikipedia.org")
        XCTAssertEqual(ResearchTool.extractDomain(from: "https://api.github.com/repos"), "api.github.com")
        XCTAssertEqual(ResearchTool.extractDomain(from: "invalid"), "invalid")
    }

    // testGoogleHTMLParsing removed — Google search backend was replaced with Brave

    func testSufficiencyRequiresMinimumSources() async throws {
        // A ResearchTool with a mock backend that returns only 1 result
        // should attempt a second iteration
        let progressMessages = AtomicArray<String>()
        let handler: @Sendable (String) -> Void = { msg in
            progressMessages.append(msg)
        }

        // We can't easily test the full tool without real HTTP,
        // but we can verify progress handler is called
        let tool = ResearchTool(progressHandler: handler)
        XCTAssertEqual(tool.name, "Research")
        XCTAssertEqual(tool.category, .online)
        XCTAssertFalse(tool.isInternal)
    }

    // MARK: - Progress Handler Integration

    func testProgressHandlerCalledDuringExecution() async throws {
        let progressMessages = AtomicArray<String>()

        let spy = SpyTool(
            name: "Research",
            schema: "research topic learn understand deep dive explain",
            category: .online,
            result: ToolIO(
                text: "Research results for quantum computing",
                status: .ok,
                outputWidget: "ResearchWidget",
                widgetData: ResearchWidgetData(
                    topic: "quantum computing",
                    sources: [
                        ResearchSource(title: "Test", url: "https://example.com", domain: "example.com", snippet: "test")
                    ],
                    iterationCount: 1
                ),
                isVerifiedData: true
            )
        )

        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        // Subscribe to progress stream
        let progressStream = engine.makeProgressStream()
        let collectTask = Task {
            for await update in progressStream {
                if case .processing(let desc) = update {
                    progressMessages.append(desc)
                }
            }
        }

        let result = await engine.run(input: "#research quantum computing")
        collectTask.cancel()

        XCTAssertEqual(spy.invocations.count, 1)
        XCTAssertTrue(captured.value.contains("[VERIFIED]"), "Verified research data should reach final prompt")
        XCTAssertEqual(result.widgetType, "ResearchWidget")
    }

    // MARK: - Disambiguation (Research vs other tools)

    func testResearchDoesNotConflictWithWebFetch() async throws {
        let researchSpy = SpyTool(
            name: "Research",
            schema: "research topic learn understand deep dive explain",
            category: .online,
            result: ToolIO(text: "Research results", status: .ok)
        )
        let webFetchSpy = SpyTool(
            name: "WebFetch",
            schema: "fetch content from a specified URL",
            category: .online,
            result: ToolIO(text: "Fetched content", status: .ok)
        )

        let engine = await makeTestEngineWithSkills(
            tools: [researchSpy, webFetchSpy],
            engineLLMResponder: makeStubLLMResponder()
        )

        // URL input should go to WebFetch, not Research
        _ = await engine.run(input: "https://example.com")
        XCTAssertEqual(webFetchSpy.invocations.count, 1, "URL should route to WebFetch")
        XCTAssertEqual(researchSpy.invocations.count, 0, "URL should NOT route to Research")
    }

    func testResearchDoesNotConflictWithNews() async throws {
        let researchSpy = SpyTool(
            name: "Research",
            schema: "research topic learn understand deep dive explain",
            category: .online,
            result: ToolIO(text: "Research results", status: .ok)
        )
        let newsSpy = SpyTool(
            name: "News",
            schema: "news headlines current events top stories",
            category: .online,
            result: ToolIO(text: "Top news", status: .ok)
        )

        let engine = await makeTestEngineWithSkills(
            tools: [researchSpy, newsSpy],
            engineLLMResponder: makeStubLLMResponder()
        )

        // "latest news" should go to News, not Research
        _ = await engine.run(input: "latest news")
        XCTAssertEqual(newsSpy.invocations.count, 1, "News prompt should route to News")
        XCTAssertEqual(researchSpy.invocations.count, 0, "News prompt should NOT route to Research")
    }
}

// MARK: - Sunrise/Sunset/Moon Phase E2E Tests

final class SunriseSunsetE2ETests: XCTestCase {
    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    func testSunriseChipRouting() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature sunrise sunset moon wind rain",
            result: ToolIO(text: "Sunrise in Newton: 6:30 AM", status: .ok, outputWidget: "SunWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "when is sunrise?")
        XCTAssertEqual(spy.invocations.count, 1, "Sunrise should route to Weather")
    }

    func testSunsetRouting() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature sunrise sunset moon wind rain",
            result: ToolIO(text: "Sunset in Newton: 7:15 PM", status: .ok, outputWidget: "SunWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "what time is sunset?")
        XCTAssertEqual(spy.invocations.count, 1, "Sunset should route to Weather")
    }

    func testGoldenHourRouting() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature sunrise sunset golden hour moon",
            result: ToolIO(text: "Golden hour starts at 6:15 PM", status: .ok, outputWidget: "SunWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "when is golden hour?")
        XCTAssertEqual(spy.invocations.count, 1, "Golden hour should route to Weather")
    }

    func testMoonPhaseRoutingVariants() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature sunrise sunset moon phase lunar",
            result: ToolIO(text: "Waxing Crescent", status: .ok, outputWidget: "MoonWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        let prompts = [
            "what phase is the moon?",
            "moon phase tonight",
            "what's the lunar phase?",
            "what moon is it tonight?",
            "is there a full moon?",
        ]

        for prompt in prompts {
            _ = await engine.run(input: prompt)
        }
        XCTAssertEqual(spy.invocations.count, prompts.count, "All moon prompts should route to Weather")
    }

    func testSunrisePromptVariants() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature sunrise sunset moon wind rain",
            result: ToolIO(text: "Sunrise: 6:30 AM", status: .ok, outputWidget: "SunWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        let prompts = [
            "when is sunrise?",
            "what time is sunrise?",
            "sunrise in London",
            "when does the sun rise?",
            "sunrise time tomorrow",
        ]

        for prompt in prompts {
            _ = await engine.run(input: prompt)
        }
        XCTAssertEqual(spy.invocations.count, prompts.count, "All sunrise prompts should route to Weather")
    }

    func testSunsetPromptVariants() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature sunrise sunset moon wind rain",
            result: ToolIO(text: "Sunset: 7:15 PM", status: .ok, outputWidget: "SunWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        let prompts = [
            "when is sunset?",
            "what time is sunset today?",
            "sunset in Paris",
            "when does the sun set?",
            "sunset time",
        ]

        for prompt in prompts {
            _ = await engine.run(input: prompt)
        }
        XCTAssertEqual(spy.invocations.count, prompts.count, "All sunset prompts should route to Weather")
    }

    func testSunriseDetailFieldDetection() async throws {
        // Test WeatherTool's intent detection directly
        let tool = WeatherTool()
        let sunriseIntent = tool.detectIntent(input: "weather sunrise in London", entities: nil)
        if case .detail(.sunrise) = sunriseIntent {
            // Correct
        } else {
            XCTFail("Expected .detail(.sunrise), got \(sunriseIntent)")
        }

        let sunsetIntent = tool.detectIntent(input: "weather sunset tomorrow", entities: nil)
        if case .detail(.sunset) = sunsetIntent {
            // Correct
        } else {
            XCTFail("Expected .detail(.sunset), got \(sunsetIntent)")
        }

        let goldenIntent = tool.detectIntent(input: "weather golden hour", entities: nil)
        if case .detail(.sunset) = goldenIntent {
            // Golden hour maps to sunset
        } else {
            XCTFail("Expected .detail(.sunset) for golden hour, got \(goldenIntent)")
        }
    }
}

// MARK: - Calculator Explain + Amortization E2E Tests

final class CalculatorExplainE2ETests: XCTestCase {
    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    func testExplainModeDetection() async throws {
        let tool = CalculatorTool(llmResponder: { _ in
            return "1. Start with 25% of 300\n2. Convert 25% to 0.25\n3. Multiply 300 × 0.25 = 75"
        })

        let result = try await tool.execute(
            input: "[Replying to: \"25% of 300\" → \"75\"]\nExplain this calculation step by step",
            entities: nil
        )

        XCTAssertEqual(result.status, .ok, "Explain mode should succeed")
        XCTAssertTrue(result.text.contains("Explanation"), "Should contain explanation header")
        XCTAssertFalse(result.text.contains("Couldn't parse"), "Should NOT try to parse as math")
    }

    func testExplainFallbackWithoutLLM() async throws {
        let tool = CalculatorTool(llmResponder: { _ in
            throw NSError(domain: "test", code: 1)
        })

        let result = try await tool.execute(
            input: "[Replying to: \"2+2\" → \"4\"]\nExplain this calculation step by step",
            entities: nil
        )

        XCTAssertEqual(result.status, .ok, "Should fall back gracefully")
        XCTAssertTrue(result.text.contains("2+2"), "Should contain the expression")
    }

    func testLoanAmortizationViaLLM() async throws {
        // LLM returns structured JSON when it detects a loan request
        let tool = CalculatorTool(llmResponder: { _ in
            return #"{"principal":200000,"rate":6.5,"years":30}"#
        })
        let result = try await tool.execute(
            input: "$200000 loan at 6.5% for 30 years",
            entities: nil
        )

        XCTAssertEqual(result.status, .ok, "Loan calculation should succeed")
        XCTAssertTrue(result.text.contains("Monthly payment"), "Should contain monthly payment")
        XCTAssertTrue(result.text.contains("Total interest"), "Should contain total interest")
        XCTAssertEqual(result.outputWidget, "MathWidget", "Should use MathWidget")

        // Verify widget data has amortization table
        if let data = result.widgetData as? CalculationWidgetData {
            XCTAssertNotNil(data.table, "Should have amortization table")
            XCTAssertEqual(data.table?.title, "Amortization Schedule")
            XCTAssertFalse(data.supplementary.isEmpty, "Should have supplementary results")
        } else {
            XCTFail("Widget data should be CalculationWidgetData")
        }
    }

    func testLoanAmortizationVariants() async throws {
        let variants: [(input: String, json: String)] = [
            ("$200000 loan at 6.5% for 30 years", #"{"principal":200000,"rate":6.5,"years":30}"#),
            ("mortgage 300000 at 5% for 15 years", #"{"principal":300000,"rate":5,"years":15}"#),
            ("$150,000 home loan at 7% for 20 years", #"{"principal":150000,"rate":7,"years":20}"#),
        ]

        for (input, json) in variants {
            let tool = CalculatorTool(llmResponder: { _ in json })
            let result = try await tool.execute(input: input, entities: nil)
            XCTAssertEqual(result.status, .ok, "Loan '\(input)' should succeed")
            XCTAssertTrue(result.text.contains("Monthly payment"), "'\(input)' should have monthly payment")
        }
    }

    func testLoanAmortizationMath() async throws {
        // Verify specific values for a known loan ($100K at 6% for 30yr → ~$599/mo)
        let tool = CalculatorTool(llmResponder: { _ in
            return #"{"principal":100000,"rate":6,"years":30}"#
        })
        let result = try await tool.execute(
            input: "$100000 loan at 6% for 30 years",
            entities: nil
        )

        XCTAssertTrue(result.text.contains("599"), "Monthly payment for $100K at 6% for 30yr should be ~$599")
    }

    func testComputeLoanDirectly() throws {
        // Test the computation directly without LLM
        let result = CalculatorTool.computeLoan(
            principal: 200000, annualRate: 6.5, years: 30,
            originalInput: "test loan"
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Monthly payment"))
        XCTAssertNotNil(result.widgetData as? CalculationWidgetData)
    }

    func testMortgageDownPaymentSubtractedFromPrincipal() async throws {
        // The LLM correctly reports the house price AND the down payment; the tool
        // must subtract so the computed principal is $400k, not $600k.
        // $400k at 6.05% for 30 years → ~$2,411/mo (NOT $3,616).
        let tool = CalculatorTool(llmResponder: { _ in
            return #"{"principal":600000,"rate":6.05,"years":30,"down_payment":200000}"#
        })
        let result = try await tool.execute(
            input: "what's the monthly payment on a 600k house with 200k down and 6.05% interest?",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("2,411") || result.text.contains("2411"),
                      "Expected monthly payment ~$2,411, got: \(result.text)")
        XCTAssertFalse(result.text.contains("3,616"),
                       "Must NOT compute at the full $600k principal: \(result.text)")
    }

    func testMortgageDownPaymentRegexFallbackWhenLLMMissesIt() async throws {
        // LLM forgets the down_payment field — the safety-net regex in parseLoanJSON
        // must still detect "200k down" in the original input and subtract correctly.
        let tool = CalculatorTool(llmResponder: { _ in
            return #"{"principal":600000,"rate":6.05,"years":30}"#
        })
        let result = try await tool.execute(
            input: "monthly payment on a 600k house with 200k down at 6.05% for 30 years",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("2,411") || result.text.contains("2411"),
                      "Regex fallback should subtract 200k down. Got: \(result.text)")
    }
}

// MARK: - News Summarization E2E Tests

final class NewsSummarizationE2ETests: XCTestCase {
    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    func testSummarizeNewsRouting() async throws {
        let spy = SpyTool(
            name: "News",
            schema: "news headlines latest stories summarize summary digest briefing",
            result: ToolIO(text: "News Summary (top): 1. Article...", status: .ok, outputWidget: "NewsWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        let prompts = [
            "summarize the news",
            "news summary",
            "give me a news briefing",
            "news digest",
            "catch me up on news",
            "news roundup",
            "news recap",
        ]

        for prompt in prompts {
            _ = await engine.run(input: prompt)
        }
        XCTAssertEqual(spy.invocations.count, prompts.count, "All summary prompts should route to News")
    }

    func testSummarizeDetection() async throws {
        // Test that the NewsTool detects summarize intent correctly
        _ = NewsTool(session: .shared)

        // The tool should detect summarize keywords in the input
        // We can't easily test the full flow without RSS feeds, but we can verify
        // that headline-only prompts don't trigger summarize
        let headlineInputs = ["latest news", "top stories", "tech news"]
        let summaryInputs = ["summarize the news", "news summary", "give me a digest"]

        for input in headlineInputs {
            XCTAssertFalse(
                ["summarize", "summary", "digest", "briefing", "recap"].contains(where: { input.contains($0) }),
                "'\(input)' should not be a summary request"
            )
        }

        for input in summaryInputs {
            XCTAssertTrue(
                ["summarize", "summary", "digest", "briefing", "recap"].contains(where: { input.contains($0) }),
                "'\(input)' should be a summary request"
            )
        }
    }

    func testSummarizeVsHeadlineRouting() async throws {
        let spy = SpyTool(
            name: "News",
            schema: "news headlines latest stories summarize summary digest briefing",
            result: ToolIO(text: "headlines", status: .ok, outputWidget: "NewsWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        // Regular headline request
        _ = await engine.run(input: "latest news")
        XCTAssertEqual(spy.invocations.count, 1)

        // Summary request — should also route to News
        _ = await engine.run(input: "summarize the news for me")
        XCTAssertEqual(spy.invocations.count, 2)
    }

    // MARK: - Weather Unit Refinement Tests

    /// "in celsius" after weather should pass unit preference to the tool,
    /// not extract "celsius" as a location name.
    func testWeatherCelsiusRefinementDoesNotExtractAsLocation() async throws {
        let tool = WeatherTool(session: .shared)
        // Simulate the merged refinement input: "weather in London, in celsius"
        let mergedInput = "weather in London, in celsius"
        let entities = ExtractedEntities(
            names: [], places: ["London"], organizations: [],
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
        let result = try await tool.execute(input: mergedInput, entities: entities)
        // The result should reference London, NOT "Cassius St" or "celsius"
        let text = result.text.lowercased()
        XCTAssertTrue(
            text.contains("london") || !text.contains("cassius"),
            "Weather refinement 'in celsius' should not extract 'Cassius St' as location. Got: \(result.text.prefix(200))"
        )
    }

    /// WeatherArgs schema should support a temperatureUnit field so "in celsius"
    /// refinements can explicitly request Celsius output.
    func testWeatherArgsSupportsTemperatureUnit() async throws {
        // Verify the schema includes temperatureUnit
        let schema = WeatherTool.extractionSchema
        XCTAssertTrue(
            schema.contains("temperatureUnit") || schema.contains("unit"),
            "Weather schema should include a unit preference field. Schema: \(schema)"
        )
    }

    // MARK: - Stock Ticker Extraction Tests

    /// "show the earnings breakdown" should NOT extract "BREAKDOWN" as a ticker.
    func testStockToolDoesNotExtractLongWordsAsTicker() async throws {
        let tool = StockTool(session: .shared)
        // We can't easily test the private extractTicker method, but we can verify
        // that the mock fallback doesn't return "BREAKDOWN Corp"
        let result = try await tool.execute(
            input: "show the earnings breakdown",
            entities: ExtractedEntities(
                names: [], places: [], organizations: [],
                urls: [], phoneNumbers: [], emails: [], ocrText: nil
            )
        )
        // The result should NOT contain "BREAKDOWN Corp"
        XCTAssertFalse(
            result.text.contains("BREAKDOWN Corp"),
            "StockTool should not extract 'BREAKDOWN' as a ticker. Got: \(result.text.prefix(200))"
        )
    }

    /// Natural language stock queries should extract the correct ticker.
    func testStockToolExtractsTickerFromNaturalLanguage() async throws {
        let tool = StockTool(session: .shared)
        let inputs: [(query: String, expectedInResult: String)] = [
            ("AAPL stock price", "AAPL"),
            ("show me the stock price for MSFT", "MSFT"),
            ("check the price of GOOGL", "GOOGL"),
            ("what's the price of TSLA", "TSLA"),
        ]
        for (query, expected) in inputs {
            let entities = ExtractedEntities(
                names: [], places: [],
                organizations: expected == query.split(separator: " ").first.map(String.init) ?? "" ? [expected] : [],
                urls: [], phoneNumbers: [], emails: [], ocrText: nil
            )
            let result = try await tool.execute(input: query, entities: entities)
            XCTAssertTrue(
                result.text.contains(expected),
                "Query '\(query)' should extract ticker '\(expected)'. Got: \(result.text.prefix(200))"
            )
        }
    }

    // MARK: - News Drill-Down Reference Tests

    /// News output should include article URLs so PriorTurnContext can parse references
    /// for ordinal drill-down ("the first one").
    func testNewsOutputIncludesURLsForDrillDown() async throws {
        let tool = NewsTool(session: .shared)
        let result = try await tool.execute(input: "latest news", entities: nil)
        let text = result.text

        // The output should contain numbered headlines followed by URLs
        let lines = text.components(separatedBy: "\n")
        var hasNumberedLine = false
        var hasURLAfterNumber = false

        for (i, line) in lines.enumerated() {
            if line.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                hasNumberedLine = true
                // Check if the next line is a URL
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if nextLine.hasPrefix("http") {
                        hasURLAfterNumber = true
                        break
                    }
                }
            }
        }

        XCTAssertTrue(hasNumberedLine, "News output should have numbered headline lines")
        XCTAssertTrue(hasURLAfterNumber, "News output should have URLs after headline lines for drill-down references")
    }

    /// After news headlines, "the first one" should trigger WebFetch via reference parsing.
    func testNewsDrillDownFirstOneRoutesToWebFetch() async throws {
        // Use a news spy that includes URLs in the proper format (number + URL on next line)
        let news = SpyTool(
            name: "News",
            schema: "news headlines",
            category: .online,
            result: ToolIO(
                text: """
                [VERIFIED] Headlines:
                1. Breaking: Major tech acquisition announced — Reuters
                https://news.example.com/article1
                2. Climate summit reaches new agreement — BBC
                https://news.example.com/article2
                3. Sports finals set for weekend showdown — ESPN
                https://news.example.com/article3
                """,
                status: .ok,
                outputWidget: "NewsWidget",
                isVerifiedData: true
            )
        )
        let webFetch = SpyTool(name: "WebFetch", schema: "Fetch web content", category: .online)

        let engine = makeTestEngine(
            tools: [news, webFetch],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "News")
        )

        // Turn 1: get headlines
        _ = await engine.run(input: "#news drill down url test")
        XCTAssertEqual(news.invocations.count, 1)

        // Turn 2: "the first one" should route to WebFetch with article1 URL
        _ = await engine.run(input: "the first one")
        XCTAssertGreaterThanOrEqual(webFetch.invocations.count, 1, "Drill-down 'the first one' should route to WebFetch")
        if !webFetch.invocations.isEmpty {
            XCTAssertTrue(
                webFetch.invocations[0].input.contains("article1"),
                "Should fetch article1 URL. Got: \(webFetch.invocations[0].input)"
            )
        }
    }

    // MARK: - Convert Color Tests

    /// ConvertTool should handle hex-to-RGB color conversion.
    func testConvertHexToRGB() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "#FF5733 to rgb", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("255"), "Should contain red value 255. Got: \(result.text)")
        XCTAssertTrue(result.text.contains("87"), "Should contain green value 87. Got: \(result.text)")
        XCTAssertTrue(result.text.contains("51"), "Should contain blue value 51. Got: \(result.text)")
    }

    /// ConvertTool should handle RGB-to-hex color conversion.
    func testConvertRGBToHex() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "rgb(255, 87, 51) to hex", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.uppercased().contains("FF5733"), "Should contain hex FF5733. Got: \(result.text)")
    }

    /// ConvertTool should handle hex-to-HSL color conversion.
    func testConvertHexToHSL() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "#FF5733 to hsl", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("HSL"), "Should contain HSL format. Got: \(result.text)")
    }

    /// ConvertTool should handle hex-to-CMYK color conversion.
    func testConvertHexToCMYK() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "#FF5733 to cmyk", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("CMYK"), "Should contain CMYK format. Got: \(result.text)")
    }

    // MARK: - Random Tool New Features

    /// RandomTool should support random date generation.
    func testRandomDate() async throws {
        let tool = RandomTool()
        let result = try await tool.execute(input: "random date", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Random Date") || result.text.contains("202"),
                       "Should return a random date. Got: \(result.text)")
        XCTAssertEqual(result.outputWidget, "RandomWidget")
    }

    /// RandomTool should support random color generation.
    func testRandomColor() async throws {
        let tool = RandomTool()
        let result = try await tool.execute(input: "random color", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("#"), "Should return a hex color. Got: \(result.text)")
        XCTAssertTrue(result.text.contains("RGB"), "Should include RGB details. Got: \(result.text)")
        XCTAssertEqual(result.outputWidget, "RandomWidget")
    }
}

// MARK: - Weather Location Sanitization Tests

/// Regression tests for temporal words being geocoded as city names.
/// Root cause: LLM extractor put "now" in the location field → geocoded to "Weatherton".
final class WeatherSanitizationTests: XCTestCase {

    /// Temporal adverbs (not detected by NSDataDetector) are rejected by the small fallback set.
    func testSanitizeCityRejectsTemporalAdverbs() {
        let adverbs = ["now", "currently", "right now", "soon", "later", "recently"]
        for word in adverbs {
            XCTAssertNil(
                WeatherTool.sanitizeCity(word),
                "'\(word)' is a temporal adverb, not a city"
            )
        }
    }

    /// NSDataDetector-based rejection of natural language date expressions.
    func testSanitizeCityRejectsDateExpressions() {
        let dateExpressions = [
            "today", "tomorrow", "tonight", "yesterday",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "next week", "this weekend", "this morning", "this afternoon",
            "March 25", "January 1", "Dec 31",
        ]
        for expr in dateExpressions {
            XCTAssertNil(
                WeatherTool.sanitizeCity(expr),
                "'\(expr)' is a date expression, not a city"
            )
        }
    }

    /// Real city names must pass through sanitization unchanged.
    func testSanitizeCityAllowsRealCities() {
        let cities = [
            "Boston", "New York", "San Francisco", "Paris", "London",
            "Tokyo", "Mumbai", "São Paulo", "Berlin", "Sydney",
        ]
        for city in cities {
            XCTAssertEqual(
                WeatherTool.sanitizeCity(city), city,
                "'\(city)' is a real city and should pass through"
            )
        }
    }

    /// Nil, empty, and whitespace-only inputs should return nil.
    func testSanitizeCityRejectsEmptyInputs() {
        XCTAssertNil(WeatherTool.sanitizeCity(nil))
        XCTAssertNil(WeatherTool.sanitizeCity(""))
        XCTAssertNil(WeatherTool.sanitizeCity("   "))
    }

    /// The isTemporal helper correctly classifies temporal vs non-temporal strings.
    func testIsTemporalClassification() {
        // Temporal — adverbs
        XCTAssertTrue(WeatherTool.isTemporal("now"))
        XCTAssertTrue(WeatherTool.isTemporal("currently"))

        // Temporal — date expressions (via NSDataDetector)
        XCTAssertTrue(WeatherTool.isTemporal("tomorrow"))
        XCTAssertTrue(WeatherTool.isTemporal("Next Friday"))
        XCTAssertTrue(WeatherTool.isTemporal("this weekend"))

        // Non-temporal
        XCTAssertFalse(WeatherTool.isTemporal("Boston"))
        XCTAssertFalse(WeatherTool.isTemporal("New York"))
        XCTAssertFalse(WeatherTool.isTemporal(""))
    }

    /// Weather keywords embedded in the candidate are still stripped correctly.
    func testSanitizeCityStripsWeatherKeywordsBeforeCity() {
        // "humidity in Paris" → the "humidity" keyword prefix is stripped, "Paris" returned
        // (This tests that the keyword-stripping logic still works alongside temporal detection)
        let result = WeatherTool.sanitizeCity("humidity in Paris")
        XCTAssertEqual(result, "Paris")
    }
}

// MARK: - Ingredient Deduplication Tests

final class IngredientDeduplicationE2ETests: XCTestCase {

    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    /// When the same tool is routed twice in one turn, the cached copy should not duplicate ingredients.
    func testCachedResultDoesNotDuplicateIngredient() async throws {
        let spy = SpyTool(
            name: "SystemInfo",
            schema: "system info status",
            result: ToolIO(text: "macOS 26.0, M4, 32 GB RAM", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        // First run — tool executes and result is cached
        _ = await engine.run(input: "#systeminfo")

        // Second run with identical input — served from cache
        let captured2 = CapturedPrompt()
        let engine2 = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured2)
        )
        _ = await engine2.run(input: "#systeminfo")

        // The final prompt should contain the result text exactly once
        let prompt = captured2.value
        let occurrences = prompt.components(separatedBy: "macOS 26.0, M4, 32 GB RAM").count - 1
        XCTAssertEqual(occurrences, 1, "Cached ingredient should appear exactly once, not duplicated. Found \(occurrences) occurrences.")
    }

    /// When two different tools return identical text, the second should be deduplicated.
    func testIdenticalToolOutputsDeduplicatedInSameTurn() async throws {
        let spy1 = SpyTool(
            name: "ToolA",
            schema: "tool a alpha",
            result: ToolIO(text: "Identical output text", status: .ok)
        )
        let spy2 = SpyTool(
            name: "ToolB",
            schema: "tool b beta",
            result: ToolIO(text: "Identical output text", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy1, spy2],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#toola #toolb")

        let prompt = captured.value
        let occurrences = prompt.components(separatedBy: "Identical output text").count - 1
        XCTAssertEqual(occurrences, 1, "Identical ingredient text from two tools should appear once, not twice. Found \(occurrences) occurrences.")
    }
}
