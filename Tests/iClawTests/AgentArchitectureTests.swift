import XCTest
import os
import FoundationModels
@testable import iClawCore

// MARK: - Comprehensive tests for the hybrid agent architecture:
// Self-healing (reflexion), ReAct loop, scratchpad cache, progress stream,
// and their interactions.

final class AgentArchitectureTests: XCTestCase {

    override func setUp() async throws {
        executionTimeAllowance = 30
        await ScratchpadCache.shared.reset()
    }

    // =========================================================================
    // MARK: - A. HEALING LOOP — EDGE CASES (13 tests)
    // =========================================================================

    // A1: Healing a thrown error (not just .error status)
    func testHealingRecoversThrownError() async throws {
        let tool = ThrowThenSuccessSpyTool(
            name: "Transcribe",
            schema: "transcribe audio speech",
            successResult: ToolIO(text: "transcription text", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "retry with shorter clip"
                }
                return "Here is the transcription"
            }
        )

        let result = await engine.run(input: "#transcribe my_audio.mp3")
        XCTAssertEqual(tool.invocations.count, 2, "Should throw once then succeed on retry")
        XCTAssertFalse(result.isError, "Healed thrown error should not surface as error")
    }

    // A2: Healing LLM returns empty string → treated as UNFIXABLE
    func testHealingEmptyResponseTreatedAsUnfixable() async throws {
        let tool = AlwaysErrorSpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return ""
                }
                return "error fallback"
            }
        )

        let result = await engine.run(input: "#weather London")
        XCTAssertEqual(tool.invocations.count, 1, "Empty healing response should not trigger retry")
        XCTAssertTrue(result.isError)
    }

    // A3: Healing LLM returns whitespace-only → treated as UNFIXABLE
    func testHealingWhitespaceOnlyTreatedAsUnfixable() async throws {
        let tool = AlwaysErrorSpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "   \n\t  "
                }
                return "error fallback"
            }
        )

        let result = await engine.run(input: "#weather London")
        XCTAssertEqual(tool.invocations.count, 1, "Whitespace-only healing should not retry")
        XCTAssertTrue(result.isError)
    }

    // A4: Healing LLM returns "unfixable" in mixed case
    func testHealingUnfixableCaseInsensitive() async throws {
        let tool = AlwaysErrorSpyTool(name: "Calculator", schema: "calculator math")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "Unfixable"
                }
                return "error response"
            }
        )

        let result = await engine.run(input: "#calculator divide by zero")
        XCTAssertEqual(tool.invocations.count, 1)
        XCTAssertTrue(result.isError)
    }

    // A5: Healing passes the corrected input to the retry
    func testHealingPassesCorrectedInputToRetry() async throws {
        let tool = ErrorThenSuccessSpyTool(
            name: "Convert",
            schema: "convert units currency",
            successResult: ToolIO(text: "100 USD = 85 EUR", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "convert 100 USD to EUR"
                }
                return "100 USD is 85 EUR"
            }
        )

        _ = await engine.run(input: "#convert 100 bucks to euros")
        XCTAssertEqual(tool.invocations.count, 2)
        XCTAssertEqual(tool.invocations[1].input, "convert 100 USD to EUR", "Retry should use corrected input")
    }

    // A6: Healed result preserves widget data
    func testHealedResultPreservesWidgetData() async throws {
        let widgetData: [String: String] = ["temp": "22", "city": "Paris"]
        let tool = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "Paris 22°C", status: .ok, outputWidget: "WeatherWidget", widgetData: widgetData)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "weather Paris" }
                return "It's 22°C in Paris"
            }
        )

        let result = await engine.run(input: "#weather Pariis")  // typo
        XCTAssertEqual(result.widgetType, "WeatherWidget", "Healed result should carry widget data")
    }

    // A7: Healed result preserves verified data flag
    func testHealedResultPreservesVerifiedFlag() async throws {
        let tool = ErrorThenSuccessSpyTool(
            name: "Stocks",
            schema: "stock price quote",
            successResult: ToolIO(text: "AAPL: $175", status: .ok, isVerifiedData: true)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                captured.set(prompt)
                if prompt.contains("Output ONLY a corrected input") { return "AAPL" }
                return "Apple stock is $175"
            }
        )

        _ = await engine.run(input: "#stocks APPL")  // typo
        XCTAssertTrue(captured.value.contains("[VERIFIED]"), "Healed verified data should have [VERIFIED] prefix")
    }

    // A8: Multi-tool where first fails and heals, second succeeds normally
    func testMultiToolOneFailsHealsOtherSucceeds() async throws {
        let failHeal = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "London 15°C", status: .ok)
        )
        let normalSpy = SpyTool(
            name: "Calculator",
            schema: "calculator math",
            result: ToolIO(text: "42", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [failHeal, normalSpy],
            engineLLMResponder: { prompt, _ in
                captured.set(prompt)
                if prompt.contains("Output ONLY a corrected input") { return "weather London" }
                return "London is 15°C and the answer is 42"
            }
        )

        let result = await engine.run(input: "#weather #calculator London 6*7")
        XCTAssertEqual(failHeal.invocations.count, 2, "Weather should heal")
        XCTAssertEqual(normalSpy.invocations.count, 1, "Calculator should run once")
        XCTAssertFalse(result.isError, "Overall result should not be an error")
        XCTAssertTrue(captured.value.contains("London 15°C"), "Healed weather output should reach finalization")
        XCTAssertTrue(captured.value.contains("42"), "Calculator output should reach finalization")
    }

    // A9: Multi-tool where first succeeds, second fails and heals
    func testMultiToolSecondFailsAndHeals() async throws {
        let normalSpy = SpyTool(
            name: "Calculator",
            schema: "calculator math",
            result: ToolIO(text: "42", status: .ok)
        )
        let failHeal = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "Tokyo 28°C", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [normalSpy, failHeal],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "weather Tokyo" }
                return "done"
            }
        )

        let result = await engine.run(input: "#calculator #weather 6*7 Tokyo")
        XCTAssertEqual(normalSpy.invocations.count, 1)
        XCTAssertEqual(failHeal.invocations.count, 2)
        XCTAssertFalse(result.isError)
    }

    // A10: Healing LLM itself throws → falls back to personalized error
    func testHealingLLMThrowsFallsBackToError() async throws {
        let tool = AlwaysErrorSpyTool(name: "Weather", schema: "weather forecast")
        let llmCallCount = AtomicCounter()
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                llmCallCount.increment()
                if prompt.contains("Output ONLY a corrected input") {
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "LLM unavailable"])
                }
                return "error response"
            }
        )

        let result = await engine.run(input: "#weather London")
        XCTAssertEqual(tool.invocations.count, 1, "Tool called once, healing LLM threw so no retry")
        XCTAssertTrue(result.isError)
    }

    // A11: Healing prompt contains original tool name and error text
    func testHealingPromptContainsContextualInfo() async throws {
        let tool = AlwaysErrorSpyTool(
            name: "Translate",
            schema: "translate language",
            errorResult: ToolIO(text: "Unsupported language pair: en→xx", status: .error)
        )
        let healingPrompts = AtomicArray<String>()
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    healingPrompts.append(prompt)
                    return "UNFIXABLE"
                }
                return "error"
            }
        )

        _ = await engine.run(input: "#translate hello to Klingon")
        XCTAssertEqual(healingPrompts.value.count, 1)
        let prompt = healingPrompts.value[0]
        XCTAssertTrue(prompt.contains("Translate"), "Healing prompt should name the tool")
        XCTAssertTrue(prompt.contains("Unsupported language pair"), "Healing prompt should include error message")
    }

    // A12: Tool returning .pending status is NOT treated as error → no healing
    func testPendingStatusDoesNotTriggerHealing() async throws {
        let tool = SpyTool(
            name: "Timer",
            schema: "timer countdown",
            result: ToolIO(text: "Timer set for 5 minutes", status: .pending)
        )
        let healingCalled = OSAllocatedUnfairLock(initialState: false)
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    healingCalled.withLock { $0 = true }
                }
                return "Timer is set"
            }
        )

        _ = await engine.run(input: "#timer 5 minutes")
        XCTAssertFalse(healingCalled.withLock { $0 }, ".pending should not trigger healing")
        XCTAssertEqual(tool.invocations.count, 1)
    }

    // A13: Both tools in a multi-tool execution fail → both attempt healing
    func testBothToolsFailBothAttemptHealing() async throws {
        let tool1 = AlwaysErrorSpyTool(name: "Weather", schema: "weather forecast",
                                       errorResult: ToolIO(text: "Weather API down", status: .error))
        let tool2 = AlwaysErrorSpyTool(name: "Stocks", schema: "stock price",
                                       errorResult: ToolIO(text: "Stock API down", status: .error))
        let healingCount = AtomicCounter()
        let engine = makeTestEngine(
            tools: [tool1, tool2],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    healingCount.increment()
                    return "UNFIXABLE"
                }
                return "both failed"
            }
        )

        let result = await engine.run(input: "#weather #stocks London AAPL")
        XCTAssertEqual(healingCount.value, 2, "Both tools should attempt healing")
        XCTAssertTrue(result.isError)
    }

    // =========================================================================
    // MARK: - B. REACT LOOP — COMPARATIVE HEURISTIC (12 tests)
    // =========================================================================

    // B1-B8: Each comparative pattern triggers ReAct iteration.
    // Verified via .reactIteration progress events (spy invocation count stays at 1
    // because iteration 2 hits the scratchpad cache).
    func testReActTriggeredByCompare() async throws {
        try await assertComparativeTriggersIteration("#weather compare London weather and Paris weather")
    }

    func testReActTriggeredByWhichIsBest() async throws {
        try await assertComparativeTriggersIteration("#weather which is best weather city")
    }

    func testReActTriggeredByWhichIsBetter() async throws {
        try await assertComparativeTriggersIteration("#weather which is better London or Paris weather")
    }

    func testReActTriggeredByVs() async throws {
        try await assertComparativeTriggersIteration("#weather London vs Paris weather")
    }

    func testReActTriggeredByVersus() async throws {
        try await assertComparativeTriggersIteration("#weather London versus Paris temperature")
    }

    func testReActTriggeredByDifferenceBetween() async throws {
        try await assertComparativeTriggersIteration("#weather difference between London and Paris weather")
    }

    func testReActTriggeredByWarmer() async throws {
        try await assertComparativeTriggersIteration("#weather is London warmer than Paris")
    }

    func testReActTriggeredByCheaper() async throws {
        try await assertComparativeTriggersIteration("#weather which city weather is cheaper")
    }

    // B9: Non-comparative query with single tool → exactly 1 invocation
    func testNonComparativeQuerySingleInvocation() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather how's the weather in London")
        XCTAssertEqual(spy.invocations.count, 1, "Non-comparative should run once")
    }

    // B10: Comparative query but tool errors → no iteration (hadToolError blocks it)
    func testReActStopsOnToolError() async throws {
        let tool = AlwaysErrorSpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "UNFIXABLE" }
                return "error"
            }
        )

        _ = await engine.run(input: "#weather compare London vs Paris weather")
        // Should NOT iterate because hadToolError is true after healing fails
        XCTAssertEqual(tool.invocations.count, 1, "Should not iterate after error")
    }

    // B11: Comparative with multiple ingredients already → no extra iteration
    func testReActNoIterationWhenMultipleIngredients() async throws {
        let tool1 = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London 15°C", status: .ok))
        let tool2 = SpyTool(name: "Calculator", schema: "calculator math", result: ToolIO(text: "42", status: .ok))
        let engine = makeTestEngine(tools: [tool1, tool2], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather #calculator compare these results")
        // Two tools produce 2 ingredients, so needsMoreSteps returns false
        XCTAssertEqual(tool1.invocations.count, 1)
        XCTAssertEqual(tool2.invocations.count, 1)
    }

    // B12: Case insensitivity — "COMPARE" should still trigger iteration
    func testReActComparativeCaseInsensitive() async throws {
        try await assertComparativeTriggersIteration("#weather COMPARE London VS Paris")
    }

    // =========================================================================
    // MARK: - C. SCRATCHPAD CACHE — ADVANCED (10 tests)
    // =========================================================================

    // C1: Same phrasing different word order → cache hit
    func testCacheHitsOnReorderedPhrasing() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London 15°C", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather weather in London")
        _ = await engine.run(input: "#weather London weather")
        XCTAssertEqual(spy.invocations.count, 1, "Reordered phrasing should hit cache")
    }

    // C2: Extra stop words don't break cache
    func testCacheHitsWithExtraStopWords() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "Tokyo 28°C", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather what is the weather in Tokyo")
        _ = await engine.run(input: "#weather show me Tokyo weather")
        XCTAssertEqual(spy.invocations.count, 1, "Stop word variations should hit same cache key")
    }

    // C3: Verified data gets [VERIFIED] [CACHED] prefix
    func testCacheVerifiedDataPrefix() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast",
                          result: ToolIO(text: "Berlin 20°C", status: .ok, isVerifiedData: true))
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "r", capture: captured)
        )

        _ = await engine.run(input: "#weather Berlin")
        _ = await engine.run(input: "#weather Berlin")
        XCTAssertTrue(captured.value.contains("[VERIFIED] [CACHED]"), "Verified cached data should have double prefix")
    }

    // C4: Non-verified data gets [CACHED] prefix only (no [VERIFIED])
    func testCacheNonVerifiedDataPrefix() async throws {
        let spy = SpyTool(name: "Dictionary", schema: "dictionary definition",
                          result: ToolIO(text: "hello: a greeting", status: .ok, isVerifiedData: false))
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "r", capture: captured)
        )

        _ = await engine.run(input: "#dictionary hello")
        _ = await engine.run(input: "#dictionary hello")
        XCTAssertTrue(captured.value.contains("[CACHED]"))
        XCTAssertFalse(captured.value.contains("[VERIFIED] [CACHED]"), "Non-verified should not have [VERIFIED] prefix")
    }

    // C5: Healed result gets cached for subsequent use
    func testHealedResultGetsCached() async throws {
        let tool = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "London 15°C", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "weather London" }
                return "response"
            }
        )

        // First run: fails, heals, succeeds — result should be cached
        _ = await engine.run(input: "#weather Londoon")
        XCTAssertEqual(tool.invocations.count, 2, "First run: error + healed retry")

        // Brief wait for the Task that stores in cache
        try await Task.sleep(nanoseconds: 50_000_000)

        // Second run: should hit cache (healed input may differ, but cache key is from clean original input)
        _ = await engine.run(input: "#weather Londoon")
        // The healed retry used "weather London" as input, but the cache key is based on the
        // engine's cleanInput which strips chips. The healed result was stored under the
        // original cleanInput key, so this should be 2 (no additional tool calls).
        XCTAssertEqual(tool.invocations.count, 2, "Second run should use cached healed result")
    }

    // C6: Different engines share the cache (singleton)
    func testCacheSharedAcrossEngines() async throws {
        let spy1 = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London 15°C", status: .ok))
        let engine1 = makeTestEngine(tools: [spy1], engineLLMResponder: makeStubLLMResponder())

        let spy2 = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London 16°C", status: .ok))
        let engine2 = makeTestEngine(tools: [spy2], engineLLMResponder: makeStubLLMResponder())

        _ = await engine1.run(input: "#weather London")
        XCTAssertEqual(spy1.invocations.count, 1)

        _ = await engine2.run(input: "#weather London")
        XCTAssertEqual(spy2.invocations.count, 0, "Second engine should hit shared cache")
    }

    // C7: Cache respects tool name — same input, different tool → no hit
    func testCacheSeparatesByToolName() async throws {
        let weather = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London weather", status: .ok))
        let maps = SpyTool(name: "Maps", schema: "maps directions", result: ToolIO(text: "London map", status: .ok))
        let engine = makeTestEngine(tools: [weather, maps], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#maps London")
        XCTAssertEqual(weather.invocations.count, 1)
        XCTAssertEqual(maps.invocations.count, 1, "Different tool should not share cache key")
    }

    // C8: Cache update overwrites stale entry
    func testCacheUpdateOverwritesEntry() async throws {
        let nthTool = NthCallSpyTool(
            name: "Stocks",
            schema: "stock price",
            results: [
                ToolIO(text: "AAPL: $170", status: .ok, isVerifiedData: true),
                ToolIO(text: "AAPL: $175", status: .ok, isVerifiedData: true),
            ]
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [nthTool],
            engineLLMResponder: makeStubLLMResponder(response: "r", capture: captured)
        )

        // First run — cache stores $170
        _ = await engine.run(input: "#stocks AAPL")
        XCTAssertEqual(nthTool.invocations.count, 1)

        // Reset cache to force re-execution (simulating TTL expiry)
        await ScratchpadCache.shared.reset()

        // Second run — executes again, cache stores $175
        _ = await engine.run(input: "#stocks AAPL")
        XCTAssertEqual(nthTool.invocations.count, 2)

        // Third run — should use cached $175
        _ = await engine.run(input: "#stocks AAPL")
        XCTAssertEqual(nthTool.invocations.count, 2, "Third call should hit updated cache")
        XCTAssertTrue(captured.value.contains("$175"), "Should serve updated cached value")
    }

    // C9: Cache entries from failed healing are NOT stored
    func testFailedHealingNotCached() async throws {
        let tool = AlwaysErrorSpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "UNFIXABLE" }
                return "error"
            }
        )

        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(tool.invocations.count, 2, "Failed results should not be cached")
    }

    // C10: Cache key handles punctuation and special chars
    func testCacheKeyHandlesSpecialChars() {
        let key1 = ScratchpadCache.makeKey(toolName: "WebFetch", input: "https://example.com/page?q=test")
        let key2 = ScratchpadCache.makeKey(toolName: "WebFetch", input: "https://example.com/page?q=test")
        XCTAssertEqual(key1, key2, "Identical URLs should produce same key")

        let key3 = ScratchpadCache.makeKey(toolName: "WebFetch", input: "fetch example.com")
        XCTAssertNotEqual(key1, key3, "Different URLs should produce different keys")
    }

    // =========================================================================
    // MARK: - D. PROGRESS STREAM — DETAILED (8 tests)
    // =========================================================================

    // D1: Progress includes .routing event
    func testProgressEmitsRouting() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let updates = try await collectProgress(tool: spy, input: "#weather London")
        XCTAssertTrue(updates.contains { if case .routing = $0 { return true }; return false },
                      "Should emit .routing")
    }

    // D2: Progress includes .executing event with correct tool name
    func testProgressEmitsExecutingWithToolName() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let updates = try await collectProgress(tool: spy, input: "#weather London")
        let executing = updates.compactMap { update -> String? in
            if case .executing(let name, _, _) = update { return name }
            return nil
        }
        XCTAssertTrue(executing.contains("Weather"), "Should emit .executing with 'Weather'")
    }

    // D3: Progress includes .finalizing event
    func testProgressEmitsFinalizing() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let updates = try await collectProgress(tool: spy, input: "#weather London")
        XCTAssertTrue(updates.contains { if case .finalizing = $0 { return true }; return false },
                      "Should emit .finalizing")
    }

    // D4: Progress events are ordered: processing → routing → executing → finalizing
    func testProgressEventsOrdered() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let updates = try await collectProgress(tool: spy, input: "#weather London")

        // Map to simplified event names for ordering check
        let names = updates.map { update -> String in
            switch update {
            case .processing: return "processing"
            case .routing: return "routing"
            case .executing: return "executing"
            case .finalizing: return "finalizing"
            case .retrying: return "retrying"
            case .reactIteration: return "reactIteration"
            case .planning: return "planning"
            case .planStep: return "planStep"
            case .chaining: return "chaining"
            case .performance: return "performance"
            }
        }

        if let procIdx = names.firstIndex(of: "processing"),
           let routeIdx = names.firstIndex(of: "routing"),
           let execIdx = names.firstIndex(of: "executing"),
           let finalIdx = names.firstIndex(of: "finalizing") {
            XCTAssertLessThan(procIdx, routeIdx, "processing before routing")
            XCTAssertLessThan(routeIdx, execIdx, "routing before executing")
            XCTAssertLessThan(execIdx, finalIdx, "executing before finalizing")
        } else {
            XCTFail("Missing expected progress events: \(names)")
        }
    }

    // D5: Healing emits .retrying event
    func testProgressEmitsRetryingDuringHealing() async throws {
        let tool = ErrorThenSuccessSpyTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "retry input" }
                return "response"
            }
        )

        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        _ = await engine.run(input: "#weather London")
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        let updates = updatesLock.withLock { $0 }
        let retrying = updates.compactMap { update -> String? in
            if case .retrying(let name, _) = update { return name }
            return nil
        }
        XCTAssertTrue(retrying.contains("Weather"), "Should emit .retrying during healing")
    }

    // D6: Multi-tool progress shows correct step counts
    func testProgressMultiToolStepCounts() async throws {
        let tool1 = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "w", status: .ok))
        let tool2 = SpyTool(name: "Calculator", schema: "calculator math", result: ToolIO(text: "c", status: .ok))
        let engine = makeTestEngine(tools: [tool1, tool2], engineLLMResponder: makeStubLLMResponder())

        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        _ = await engine.run(input: "#weather #calculator London 2+2")
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        let updates = updatesLock.withLock { $0 }
        let steps = updates.compactMap { update -> (Int, Int)? in
            if case .executing(_, let step, let total) = update { return (step, total) }
            return nil
        }
        XCTAssertTrue(steps.contains { $0.0 == 1 && $0.1 == 2 }, "Should have step 1/2")
        XCTAssertTrue(steps.contains { $0.0 == 2 && $0.1 == 2 }, "Should have step 2/2")
    }

    // D7: Conversational (no tool) still emits routing + finalizing
    func testProgressConversationalRoute() async throws {
        let engine = makeTestEngine(tools: [], engineLLMResponder: makeStubLLMResponder())

        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        _ = await engine.run(input: "hello how are you")
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        let updates = updatesLock.withLock { $0 }
        let names = updates.map { update -> String in
            switch update {
            case .routing: return "routing"
            case .finalizing: return "finalizing"
            default: return "other"
            }
        }
        XCTAssertTrue(names.contains("routing"), "Conversational should emit routing")
        XCTAssertTrue(names.contains("finalizing"), "Conversational should emit finalizing")
    }

    // D8: Cached tool does NOT emit .executing (it's skipped)
    func testProgressCachedToolSkipsExecuting() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        // First run — populates cache
        _ = await engine.run(input: "#weather London")

        // Second run — collect progress, should still show executing (the toolExecution state is entered for cache)
        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        _ = await engine.run(input: "#weather London")
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        let updates = updatesLock.withLock { $0 }
        // The executing event is still emitted (step tracking happens before cache check)
        let hasExecuting = updates.contains { if case .executing = $0 { return true }; return false }
        XCTAssertTrue(hasExecuting, "Executing event still emitted for cached tools (before cache check)")
        // But the spy should NOT have been called
        XCTAssertEqual(spy.invocations.count, 1, "Tool should not have been re-executed")
    }

    // =========================================================================
    // MARK: - E. COMBINED SCENARIOS — HEALING + REACT + CACHE (12 tests)
    // =========================================================================

    // E1: Comparative query where tool errors on iteration 1 → healing succeeds →
    //     iteration 2 hits cache from the healed result
    func testReActWithHealingAndCacheOnSecondIteration() async throws {
        let tool = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "London 15°C", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "weather London" }
                return "comparison"
            }
        )

        // "vs" triggers comparative heuristic, #weather ensures routing
        let result = await engine.run(input: "#weather London vs Paris weather")
        XCTAssertFalse(result.isError)
        // Tool should be called at least 2 times: error + healed retry on iteration 1.
        // Iteration 2 hits cache (no additional tool call). Under parallel execution
        // the shared ScratchpadCache may carry entries from other tests.
        XCTAssertGreaterThanOrEqual(tool.invocations.count, 2)
        XCTAssertLessThanOrEqual(tool.invocations.count, 3, "At most 3 calls (2 healing + 1 if cache miss)")
    }

    // E2: Sequential queries build up cache → third query all from cache
    func testSequentialQueriesBuildCache() async throws {
        let weather = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London 15°C", status: .ok))
        let engine = makeTestEngine(tools: [weather], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather Paris")
        _ = await engine.run(input: "#weather Tokyo")
        XCTAssertEqual(weather.invocations.count, 3, "Three different cities = three executions")

        // Re-query all three — should all hit cache
        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather Paris")
        _ = await engine.run(input: "#weather Tokyo")
        XCTAssertEqual(weather.invocations.count, 3, "Re-queries should all hit cache")
    }

    // E3: Healing result from thrown error also gets cached
    func testHealedThrownErrorGetsCached() async throws {
        let tool = ThrowThenSuccessSpyTool(
            name: "Translate",
            schema: "translate language",
            successResult: ToolIO(text: "Hola", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "translate hello to Spanish" }
                return "Hola"
            }
        )

        _ = await engine.run(input: "#translate hello to Spanish")
        XCTAssertEqual(tool.invocations.count, 2, "Throw + healed retry")

        try await Task.sleep(nanoseconds: 50_000_000)

        _ = await engine.run(input: "#translate hello to Spanish")
        XCTAssertEqual(tool.invocations.count, 2, "Second run should use cached healed result")
    }

    // E4: Engine reset doesn't clear the shared scratchpad cache
    func testEngineResetDoesNotClearCache() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1)

        await engine.reset()

        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1, "Cache should survive engine reset")
    }

    // E5: Rapid sequential runs of the same query don't double-execute
    func testRapidSequentialRunsUseCache() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1, "All subsequent runs should hit cache")
    }

    // E6: Non-comparative query followed by comparative → cache helps
    func testNonComparativeThenComparativeUsesCache() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "London 15°C", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        // Prime cache
        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1)

        // Comparative query — use chip to ensure routing
        _ = await engine.run(input: "#weather compare London vs Paris")
        // The cache serves London each time; Paris produces a different key so it misses
        // But the routing matches the same tool, so Weather gets called for the new key
        XCTAssertGreaterThanOrEqual(spy.invocations.count, 2, "Paris should miss cache")
    }

    // E7: Tool with widget data → healing preserves it → cache preserves it → all consistent
    func testWidgetDataSurvivesHealingAndCaching() async throws {
        let widgetData: [String: String] = ["symbol": "AAPL", "price": "175"]
        let tool = ErrorThenSuccessSpyTool(
            name: "Stocks",
            schema: "stock price",
            successResult: ToolIO(text: "AAPL $175", status: .ok, outputWidget: "StockWidget", widgetData: widgetData)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "AAPL" }
                return "Apple is $175"
            }
        )

        let result1 = await engine.run(input: "#stocks AAPL")
        XCTAssertEqual(result1.widgetType, "StockWidget", "Healed result should have widget")

        try await Task.sleep(nanoseconds: 50_000_000)

        let result2 = await engine.run(input: "#stocks AAPL")
        XCTAssertEqual(result2.widgetType, "StockWidget", "Cached result should have widget")
        XCTAssertEqual(tool.invocations.count, 2, "Should not re-execute on cached hit")
    }

    // E8: Three different tools, one fails, one cached from prior, one fresh
    func testMixedCacheHealingFresh() async throws {
        // Pre-populate cache with calculator result.
        // The engine strips chips/tickers before computing the cache key, so
        // for input "#calculator #weather #dictionary 6*7 London hello" the
        // cleanInput is "6*7 London hello". The cache key for Calculator uses
        // that full cleaned input.
        let cleanedInput = "6*7 London hello"
        let calcKey = ScratchpadCache.makeKey(toolName: "Calculator", input: cleanedInput)
        await ScratchpadCache.shared.store(key: calcKey, entry: .init(
            toolName: "Calculator", textSummary: "42", ttl: 3600
        ))

        let calcSpy = SpyTool(name: "Calculator", schema: "calculator math",
                               result: ToolIO(text: "42", status: .ok))
        let weatherFail = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "London 15°C", status: .ok)
        )
        let dictSpy = SpyTool(name: "Dictionary", schema: "dictionary definition",
                               result: ToolIO(text: "hello: greeting", status: .ok))

        let engine = makeTestEngine(
            tools: [calcSpy, weatherFail, dictSpy],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "weather London" }
                return "mixed result"
            }
        )

        let result = await engine.run(input: "#calculator #weather #dictionary 6*7 London hello")
        XCTAssertEqual(calcSpy.invocations.count, 0, "Calculator should hit cache")
        XCTAssertEqual(weatherFail.invocations.count, 2, "Weather should fail + heal")
        XCTAssertEqual(dictSpy.invocations.count, 1, "Dictionary should execute fresh")
        XCTAssertFalse(result.isError)
    }

    // E9: After cache reset, previously cached tool re-executes
    func testAfterCacheResetToolReExecutes() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast", result: ToolIO(text: "data", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1)

        await ScratchpadCache.shared.reset()

        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 2, "After reset, tool should re-execute")
    }

    // E10: Healing + cache + progress all work together
    func testFullPipelineHealingCacheProgress() async throws {
        let tool = ErrorThenSuccessSpyTool(
            name: "Weather",
            schema: "weather forecast",
            successResult: ToolIO(text: "London 15°C", status: .ok, isVerifiedData: true)
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "weather London" }
                return "It's 15°C in London"
            }
        )

        // Collect progress during first run (includes healing)
        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        let result1 = await engine.run(input: "#weather London")
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        XCTAssertFalse(result1.isError, "Should heal successfully")
        XCTAssertEqual(tool.invocations.count, 2, "Error + healed retry")

        let updates = updatesLock.withLock { $0 }
        let hasRetrying = updates.contains { if case .retrying = $0 { return true }; return false }
        XCTAssertTrue(hasRetrying, "Progress should include .retrying")

        // Second run — should hit cache
        let captured = CapturedPrompt()
        let engine2 = makeTestEngine(
            tools: [tool],
            engineLLMResponder: makeStubLLMResponder(response: "cached response", capture: captured)
        )
        let result2 = await engine2.run(input: "#weather London")
        XCTAssertFalse(result2.isError)
        XCTAssertEqual(tool.invocations.count, 2, "Should use cache")
        XCTAssertTrue(captured.value.contains("[CACHED]"))
    }

    // E11: FailingTool (throws) gets healing attempt, fails again → personalized error
    func testFailingToolHealingAttemptThenPersonalizedError() async throws {
        let tool = FailingTool(name: "Weather", schema: "weather forecast")
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") { return "retry weather" }
                return "sorry"
            }
        )

        let result = await engine.run(input: "#weather London")
        // FailingTool always throws, so healing retry also throws → personalized error
        XCTAssertTrue(result.isError, "Should surface as error after healing fails")
    }

    // E12: Very long input doesn't break cache key derivation
    func testLongInputCacheKeyStable() {
        let longInput = String(repeating: "weather in London ", count: 100)
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: longInput)
        let key2 = ScratchpadCache.makeKey(toolName: "Weather", input: longInput)
        XCTAssertEqual(key1, key2, "Long input should produce stable cache key")
        XCTAssertFalse(key1.isEmpty)
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    /// Asserts that a comparative input triggers ReAct iteration by checking for
    /// `.reactIteration` progress events. (The spy may only be invoked once because
    /// iteration 2 hits the scratchpad cache, but the loop still iterates.)
    private func assertComparativeTriggersIteration(_ input: String,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) async throws {
        try require(.auditTests)
        let spy = SpyTool(name: "Weather", schema: "weather forecast temperature",
                          result: ToolIO(text: "weather data", status: .ok))
        let engine = makeTestEngine(tools: [spy], engineLLMResponder: makeStubLLMResponder())

        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        _ = await engine.run(input: input)
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        let updates = updatesLock.withLock { $0 }
        let hasReActIteration = updates.contains { update in
            if case .reactIteration = update { return true }
            return false
        }
        XCTAssertTrue(hasReActIteration,
            "Comparative input '\(input)' should trigger ReAct iteration (expected .reactIteration progress event)",
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(spy.invocations.count, 1,
            "Tool should be invoked at least once",
            file: file, line: line)
    }

    /// Runs an engine with a single tool and collects all progress updates.
    private func collectProgress(tool: SpyTool, input: String) async throws -> [ProgressUpdate] {
        let engine = makeTestEngine(tools: [tool], engineLLMResponder: makeStubLLMResponder())
        let stream = engine.makeProgressStream()
        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream { updatesLock.withLock { $0.append(update) } }
        }

        _ = await engine.run(input: input)
        collectTask.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await collectTask.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }

        return updatesLock.withLock { $0 }
    }
}
