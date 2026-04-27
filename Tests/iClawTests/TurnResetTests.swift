import Foundation
import Testing
@testable import iClawCore

/// Correctness net for `ExecutionEngine.resetRunState()`: mutate every
/// turn-scoped property via a real turn, reset, and assert every field in
/// the snapshot is back to its default. Closes the M8-class of bug where a
/// new property was added but `resetRunState()` was not updated, leaving
/// stale state that leaked into the next turn.
///
/// If a future maintainer adds a property to `TurnStateSnapshot` without
/// resetting it, this test fails. If they add a property to the actor
/// without adding it to `TurnStateSnapshot`, the snapshot itself becomes
/// incomplete — the reviewer of that PR should notice the missing field.
@Suite("Turn reset correctness")
@MainActor
struct TurnResetTests {

    @Test("After run + resetRunState, snapshot equals empty")
    func resetReturnsStateToEmpty() async {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(
                text: "It's 18°C in Paris",
                status: .ok,
                outputWidget: "WeatherWidget",
                widgetData: "stub-data",
                isVerifiedData: true,
                suggestedQueries: ["What about tomorrow?"]
            )
        )
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Weather"),
            engineLLMResponder: makeStubLLMResponder(response: "Paris is 18°C.")
        )

        // Drive a real turn so turn-scoped fields actually get mutated —
        // this protects the test against accidentally passing because the
        // run path didn't touch a field we think it does.
        _ = await engine.run(input: "#weather in Paris")

        await engine.resetRunState()

        let snapshot = await engine.debugTurnSnapshot()
        let failureHint: Comment = """
            resetRunState() did not return every turn-scoped property to default. \
            If you just added a new property, add it to resetRunState() — and make \
            sure it is covered by TurnStateSnapshot.
            """
        #expect(snapshot == .empty, failureHint)
    }

    @Test("Fresh engine starts with empty snapshot")
    func freshEngineIsEmpty() async {
        let engine = makeTestEngine(
            tools: [SpyTool(name: "Weather", schema: "weather")],
            routerLLMResponder: makeStubRouterLLMResponder()
        )
        let snapshot = await engine.debugTurnSnapshot()
        #expect(snapshot == .empty)
    }
}
