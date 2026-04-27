import XCTest
import os
import FoundationModels
@testable import iClawCore

final class HealingReActCacheTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Phase 3: Healing Loop

    func testHealingSucceeds() async throws {
        // Tool fails first, succeeds on retry with corrected input
        let tool = ErrorThenSuccessSpyTool(
            name: "TestTool",
            schema: "test tool for healing"
        )

        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "corrected input"
                }
                return "final response"
            }
        )

        let result = await engine.run(input: "#test_tool something")
        XCTAssertEqual(tool.invocations.count, 2, "Tool should be called twice (original + healing retry)")
        XCTAssertFalse(result.isError, "Final result should not be an error after healing")
    }

    func testHealingGivesUpOnUNFIXABLE() async throws {
        let tool = AlwaysErrorSpyTool(
            name: "TestTool",
            schema: "test tool for healing"
        )

        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "UNFIXABLE"
                }
                return "error response"
            }
        )

        let result = await engine.run(input: "#test_tool something")
        XCTAssertEqual(tool.invocations.count, 1, "Tool should only be called once when LLM says UNFIXABLE")
        XCTAssertTrue(result.isError, "Result should be an error")
    }

    func testHealingGivesUpOnPermanentError() async throws {
        let tool = AlwaysErrorSpyTool(
            name: "TestTool",
            schema: "test tool for healing"
        )

        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "try this instead"
                }
                return "error response"
            }
        )

        let result = await engine.run(input: "#test_tool something")
        XCTAssertEqual(tool.invocations.count, 2, "Tool should be called twice (original + retry)")
        XCTAssertTrue(result.isError, "Result should be an error when retry also fails")
    }

    func testNoHealingForSuccessfulTool() async throws {
        let tool = SpyTool(
            name: "TestTool",
            schema: "test tool",
            result: ToolIO(text: "success", status: .ok)
        )

        let healingCalled = OSAllocatedUnfairLock(initialState: false)
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    healingCalled.withLock { $0 = true }
                }
                return "response"
            }
        )

        _ = await engine.run(input: "#test_tool something")
        XCTAssertEqual(tool.invocations.count, 1, "Tool should be called once")
        XCTAssertFalse(healingCalled.withLock { $0 }, "Healing LLM should not be called for successful tools")
    }

    // MARK: - Phase 4: ReAct Loop

    func testSimpleQueryNoIteration() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "London: 15°C", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "It's 15°C in London")
        )

        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1, "Simple query should execute once, no iteration")
    }

    func testFMOnlyNoIteration() async throws {
        let fmDescriptor = StubFMToolDescriptor(name: "Calendar Events", chipName: "calendar_events", routingKeywords: ["events", "schedule", "calendar"])
        let engine = makeTestEngine(
            tools: [],
            fmTools: [fmDescriptor],
            engineLLMResponder: makeStubLLMResponder(response: "Here are your events")
        )

        let result = await engine.run(input: "#calendar_events today")
        XCTAssertFalse(result.isError)
    }

    func testMaxIterationCap() async throws {
        // A comparative query where needsMoreSteps always returns true
        // (only 1 ingredient per iteration since the same tool matches each time)
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "London: 15°C", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "comparison result")
        )

        // "compare" triggers the comparative heuristic
        _ = await engine.run(input: "compare weather London vs Paris")

        // Should not exceed maxReActIterations (3) tool calls
        XCTAssertLessThanOrEqual(
            spy.invocations.count,
            AppConfig.maxReActIterations,
            "Loop should not exceed max iterations"
        )
    }

    // MARK: - Phase 5: Scratchpad Wiring

    func testCacheHitSkipsToolExecution() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "London: 15°C, partly cloudy", status: .ok, isVerifiedData: true)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "response", capture: captured)
        )

        // First run — should execute tool
        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1, "First run should execute tool")

        // Second run — should hit cache
        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1, "Second run should use cache, not re-execute tool")

        // Verify [CACHED] prefix in ingredients
        XCTAssertTrue(
            captured.value.contains("[CACHED]"),
            "Cached result should have [CACHED] prefix in ingredients"
        )
    }

    func testDifferentInputBypassesCache() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "weather data", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "response")
        )

        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather Paris")
        XCTAssertEqual(spy.invocations.count, 2, "Different inputs should not share cache")
    }

    func testCachedWidgetDataReturned() async throws {
        let widgetData: [String: String] = ["temp": "15"]
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "London: 15°C", status: .ok, outputWidget: "WeatherWidget", widgetData: widgetData)
        )
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "response")
        )

        let result1 = await engine.run(input: "#weather London")
        XCTAssertEqual(result1.widgetType, "WeatherWidget")

        let result2 = await engine.run(input: "#weather London")
        XCTAssertEqual(result2.widgetType, "WeatherWidget", "Cached widget type should be returned")
    }

    func testErrorResultNotCached() async throws {
        let tool = AlwaysErrorSpyTool(
            name: "Weather",
            schema: "weather forecast temperature"
        )
        let engine = makeTestEngine(
            tools: [tool],
            engineLLMResponder: { prompt, _ in
                if prompt.contains("Output ONLY a corrected input") {
                    return "UNFIXABLE"
                }
                return "error response"
            }
        )

        _ = await engine.run(input: "#weather London")
        _ = await engine.run(input: "#weather London")
        // Should be called twice (once per run), not cached
        XCTAssertEqual(tool.invocations.count, 2, "Error results should not be cached")
    }

    // MARK: - Progress Stream

    func testProgressStreamEmitsUpdates() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "data", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "response")
        )

        let stream = engine.makeProgressStream()

        let updatesLock = OSAllocatedUnfairLock(initialState: [ProgressUpdate]())
        let collectTask = Task {
            for await update in stream {
                updatesLock.withLock { $0.append(update) }
            }
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
        XCTAssertFalse(updates.isEmpty, "Progress stream should emit at least one update")
    }
}

// MARK: - Stub FMToolDescriptor

private struct StubFMToolDescriptor: FMToolDescriptor {
    let name: String
    let chipName: String
    let routingKeywords: [String]
    let category: CategoryEnum = .offline
    func makeTool() -> any Tool { ClipboardTool() }
}
