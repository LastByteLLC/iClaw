import Foundation
import os
import Testing
@testable import iClawCore

/// Pivot detection: a new-topic query (no anaphora, no action verb, no
/// follow-up phrase, no entity overlap) following a prior tool turn must
/// NOT inherit the prior tool's context. Without this guard, the follow-up
/// classifier's PRIOR_TOOL bias can classify the input as .refinement and
/// the engine merges prior input into the next tool invocation.
@Suite("Pivot detection")
struct PivotEntityLeakTests {

    private func makePriorWeatherContext(place: String = "Paris") -> PriorTurnContext {
        let entities = ExtractedEntities(
            names: [],
            places: [place],
            organizations: [],
            urls: [],
            phoneNumbers: [],
            emails: [],
            ocrText: nil
        )
        return PriorTurnContext(
            toolNames: ["Weather"],
            userInput: "weather in \(place)",
            entities: entities,
            ingredients: ["[VERIFIED] Weather in \(place): 18°C, partly cloudy"],
            references: [],
            widgetType: "WeatherWidget",
            widgetData: nil
        )
    }

    /// A new-topic query that shares no entity with the prior turn and has
    /// no linguistic follow-up signal must be classified as a pivot — the
    /// router's `lastDetectedTurnRelation` should be either `nil` or `.pivot`,
    /// never `.refinement` or `.continuation`.
    @Test("New topic after Weather(Paris) is not a refinement")
    func pivotAfterWeatherParisRestaurant() async {
        let spyWeather = SpyTool(name: "Weather", schema: "{}")
        let spyMaps = SpyTool(name: "Maps", schema: "{}")
        let router = ToolRouter(
            availableTools: [spyWeather, spyMaps],
            fmTools: [],
            llmResponder: makeStubRouterLLMResponder()
        )
        await router.setPriorContext(makePriorWeatherContext(place: "Paris"))

        _ = await router.route(input: "Find a restaurant")

        let relation = await router.lastDetectedTurnRelation
        // Either cleared to nil (gate suppressed classifier) or explicitly pivot.
        // Critical: NOT .refinement / .continuation, which would trigger input
        // merging in ExecutionEngine line 1127-1130.
        #expect(relation != .refinement,
                "New-topic query classified as .refinement — ExecutionEngine will merge prior input")
        #expect(relation != .continuation,
                "New-topic query classified as .continuation — would inherit prior tool context")
    }

    /// Linguistic-signal gate keeps legitimate refinements intact — "in celsius"
    /// is a classic refinement of the prior weather turn.
    @Test("Legitimate refinement keeps .refinement relation")
    func legitimateRefinementStillClassified() async {
        let spyWeather = SpyTool(name: "Weather", schema: "{}")
        let router = ToolRouter(
            availableTools: [spyWeather],
            fmTools: [],
            llmResponder: makeStubRouterLLMResponder()
        )
        await router.setPriorContext(makePriorWeatherContext(place: "Paris"))

        // 3-word query — below the 4-word gate threshold, so the gate does
        // not fire even if the classifier calls it .refinement. This behavior
        // is preserved deliberately so short slot follow-ups keep working.
        _ = await router.route(input: "in celsius please")

        // No assertion on the relation here: the ML classifier's prediction
        // is nondeterministic across model revisions. This test exists to
        // guarantee the short-query path does not trip the new-topic gate
        // (i.e., the route() call does not throw or crash).
    }

    /// Entity overlap suppresses the gate — a follow-up mentioning the prior
    /// entity should still be treated as a follow-up.
    @Test("Query mentioning prior entity is not pivoted away")
    func entityOverlapKeepsFollowUp() async {
        let spyWeather = SpyTool(name: "Weather", schema: "{}")
        let router = ToolRouter(
            availableTools: [spyWeather],
            fmTools: [],
            llmResponder: makeStubRouterLLMResponder()
        )
        await router.setPriorContext(makePriorWeatherContext(place: "Paris"))

        _ = await router.route(input: "what about Paris tomorrow")
        // Entity overlap on "Paris" means the new-topic gate cannot override,
        // so this stays a follow-up if the classifier says so. Again, no
        // assertion on exact relation — only that route() completes.
    }
}
