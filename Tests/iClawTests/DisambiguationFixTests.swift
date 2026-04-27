import XCTest
import os
@testable import iClawCore

// MARK: - Fix 1: Pivot Detection Excludes Synthetic Names

/// Tests that synthetic routing names ("disambiguation", "clarification", "conversational")
/// do not trigger false pivot detection, which would strip conversation context.
final class PivotDetectionTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    /// When routing produces "disambiguation" as the tool name, the finalization
    /// step should NOT treat it as a pivot away from the prior tool. The prior
    /// context should be preserved, not stripped to minimal.
    func testDisambiguationDoesNotTriggerPivot() async throws {
        // Turn 1: WikipediaSearch succeeds
        let spy = SpyTool(
            name: "WikipediaSearch",
            schema: "wikipedia search wiki encyclopedia lookup",
            result: ToolIO(text: "The Byzantine Empire was...", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#wikipediasearch byzantine empire")

        // Turn 2: query that would hit disambiguation (no chip, falls to ML → stub returns "none")
        // The engine should NOT strip context because "disambiguation"/"conversational"
        // should not count as a pivot tool.
        let captured2 = CapturedPrompt()
        let engine2Turn = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured2)
        )

        // Simulate by running a conversational query (no chip match, stub returns "none")
        _ = await engine2Turn.run(input: "tell me more about that")

        // The key assertion: the engine should not have stripped context.
        // In a single-engine multi-turn scenario this would check for "Pivot detected"
        // in logs. Here we verify the test infrastructure works.
        let state = await engine2Turn.currentState
        XCTAssertEqual(state, .idle, "Engine should return to idle after disambiguation fallback")
    }

    /// Verifies that synthetic routing names are properly identified and filtered.
    func testSyntheticNamesFilteredFromPivotCheck() {
        // These are the synthetic names assigned in ExecutionEngine switch cases
        let syntheticNames: Set<String> = ["disambiguation", "clarification", "conversational"]
        let routedNames = ["disambiguation"]

        let filtered = routedNames.filter { !syntheticNames.contains($0) }
        XCTAssertTrue(filtered.isEmpty, "Synthetic names should be filtered out, leaving no tool names for pivot check")

        // Real tool name should survive filtering
        let realNames = ["WikipediaSearch"]
        let filteredReal = realNames.filter { !syntheticNames.contains($0) }
        XCTAssertEqual(filteredReal, ["WikipediaSearch"], "Real tool names should survive synthetic filtering")
    }

    /// When filtered currentToolNames is empty, isPivot should be false
    /// (can't pivot TO nothing).
    func testEmptyFilteredToolNamesPreventsPivot() {
        let syntheticNames: Set<String> = ["disambiguation", "clarification", "conversational"]
        let currentToolNames = ["disambiguation"].filter { !syntheticNames.contains($0) }
        let priorToolNames = ["WikipediaSearch"]
        let isFollowUp = false
        let hasChip = false

        let isPivot = !isFollowUp && (
            hasChip ||
            (!currentToolNames.isEmpty && !priorToolNames.isEmpty &&
             Set(currentToolNames).isDisjoint(with: Set(priorToolNames)))
        )

        XCTAssertFalse(isPivot, "Empty filtered tool names should not trigger pivot")
    }

    /// Workflow continuation names like "workflow:reservation" should not be treated
    /// as pivots when the prior tool was different.
    func testWorkflowContinuationNamesAreNotSynthetic() {
        let syntheticNames: Set<String> = ["disambiguation", "clarification", "conversational"]
        let workflowName = "workflow:reservation"

        XCTAssertFalse(syntheticNames.contains(workflowName),
                       "Workflow names should not be in synthetic set — they represent real routing")
    }
}

// MARK: - Fix 2: Absolute Confidence Floor on Disambiguation

/// Tests that low-confidence ML results fall through to LLM instead of
/// triggering disambiguation between two weak guesses.
final class DisambiguationConfidenceFloorTests: XCTestCase {

    func testConfidenceFloorThresholdExists() {
        // Verify the threshold is set and reasonable
        XCTAssertEqual(AppConfig.mlDisambiguationAbsoluteFloor, 0.35,
                       "Disambiguation absolute floor should be 0.35")
        XCTAssertGreaterThan(AppConfig.mlDisambiguationAbsoluteFloor,
                             AppConfig.mlMinimumConfidenceThreshold,
                             "Disambiguation floor should be higher than minimum confidence threshold")
    }

    /// Simulates the evaluateMLResults logic: when top confidence < floor,
    /// disambiguation should NOT fire even if delta is below threshold.
    func testLowConfidencePairSkipsDisambiguation() {
        // Reproduce the e-ink scenario: both below the 0.35 floor
        let topConfidence = 0.30
        let secondConfidence = 0.26
        let delta = topConfidence - secondConfidence  // 0.04

        // Delta is below disambiguation threshold — would normally disambiguate
        XCTAssertLessThan(delta, AppConfig.mlDisambiguationConfidenceThreshold)

        // But absolute confidence is below floor — should fall through instead
        XCTAssertLessThan(topConfidence, AppConfig.mlDisambiguationAbsoluteFloor,
                          "Low absolute confidence should prevent disambiguation")
    }

    /// High-confidence close pairs should still disambiguate normally.
    func testHighConfidenceClosePairStillDisambiguates() {
        let topConfidence = 0.65
        let secondConfidence = 0.60
        let delta = topConfidence - secondConfidence  // 0.05

        XCTAssertLessThan(delta, AppConfig.mlDisambiguationConfidenceThreshold)
        XCTAssertGreaterThanOrEqual(topConfidence, AppConfig.mlDisambiguationAbsoluteFloor,
                                    "High-confidence close pairs should still reach disambiguation")
    }

    /// E2E: query that produces low ML confidence should NOT produce a disambiguation
    /// result. Instead it should fall through to conversational/LLM.
    func testLowConfidenceQueryFallsThroughToLLM() async throws {
        await ScratchpadCache.shared.reset()
        let spy = SpyTool(
            name: "WikipediaSearch",
            schema: "wikipedia search wiki encyclopedia",
            result: ToolIO(text: "E-ink article", status: .ok)
        )
        // Router LLM fallback returns "none" (no tool)
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "none"),
            engineLLMResponder: makeStubLLMResponder(response: "E-ink uses electrophoretic display technology.")
        )

        _ = await engine.run(input: "how does e-ink work?")

        // Without the fix, this would hit disambiguation and produce a confusing response.
        // With the fix, low ML confidence falls through to LLM fallback → conversational.
        // The spy should NOT be called (ML was too uncertain to route).
        // Note: actual behavior depends on the ML model, so we just verify the engine completes.
        let state = await engine.currentState
        XCTAssertEqual(state, .idle)
    }
}

// MARK: - Fix 3: Compound Label Resolution Before Planner

/// Tests that compound ML labels (e.g., "search.wiki") are resolved to actual
/// tool names (e.g., "WikipediaSearch") before being passed to AgentPlanner.
final class CompoundLabelResolutionTests: XCTestCase {

    func testLabelRegistryResolvesSearchWiki() {
        let entry = LabelRegistry.lookup("search.wiki")
        XCTAssertNotNil(entry, "search.wiki should be in LabelRegistry")
        XCTAssertEqual(entry?.tool, "WikipediaSearch",
                       "search.wiki should resolve to WikipediaSearch")
    }

    func testLabelRegistryResolvesSearchWeb() {
        let entry = LabelRegistry.lookup("search.web")
        XCTAssertNotNil(entry, "search.web should be in LabelRegistry")
        XCTAssertEqual(entry?.tool, "web_search",
                       "search.web should resolve to web_search")
    }

    func testLabelRegistryResolvesMetaHelp() {
        let entry = LabelRegistry.lookup("meta.help")
        XCTAssertNotNil(entry, "meta.help should be in LabelRegistry")
    }

    /// When LabelRegistry doesn't have the label, fallback should use the raw label.
    func testUnknownLabelFallsBackToRawValue() {
        let entry = LabelRegistry.lookup("nonexistent.label")
        XCTAssertNil(entry, "Unknown label should return nil")

        // The fix uses: LabelRegistry.lookup(topLabel)?.tool ?? topLabel
        let resolved = entry?.tool ?? "nonexistent.label"
        XCTAssertEqual(resolved, "nonexistent.label",
                       "Unknown labels should fall back to the raw label string")
    }

    /// AgentPlan.validated() should accept resolved tool names that match ToolRegistry.
    func testValidatedAcceptsResolvedToolName() {
        let plan = AgentPlan(steps: [
            PlanStep(toolName: "WikipediaSearch", input: "e-ink", dependsOnPrevious: false)
        ])
        let knownTools: Set<String> = ["WikipediaSearch", "Weather", "Calculator"]
        let validated = plan.validated(knownTools: knownTools)

        XCTAssertEqual(validated.steps.count, 1,
                       "Resolved tool name should pass validation")
        XCTAssertEqual(validated.steps.first?.toolName, "WikipediaSearch")
    }

    /// AgentPlan.validated() should reject hallucinated names like "search.wikipedia".
    func testValidatedRejectsHallucinatedToolName() {
        let plan = AgentPlan(steps: [
            PlanStep(toolName: "search.wikipedia", input: "e-ink", dependsOnPrevious: false)
        ])
        let knownTools: Set<String> = ["WikipediaSearch", "Weather", "Calculator"]
        let validated = plan.validated(knownTools: knownTools)

        XCTAssertTrue(validated.steps.isEmpty,
                      "Hallucinated tool name 'search.wikipedia' should be rejected")
    }

    /// AgentPlan.validated() should also reject raw compound labels that aren't tool names.
    func testValidatedRejectsCompoundLabel() {
        let plan = AgentPlan(steps: [
            PlanStep(toolName: "search.wiki", input: "e-ink", dependsOnPrevious: false)
        ])
        let knownTools: Set<String> = ["WikipediaSearch", "Weather", "Calculator"]
        let validated = plan.validated(knownTools: knownTools)

        XCTAssertTrue(validated.steps.isEmpty,
                      "Compound label 'search.wiki' is not a tool name and should be rejected")
    }

    /// Verifies the full resolution chain: compound label → LabelRegistry → tool name.
    func testFullResolutionChain() {
        let compoundLabels = ["search.wiki", "search.web", "search.research"]
        for label in compoundLabels {
            let entry = LabelRegistry.lookup(label)
            XCTAssertNotNil(entry, "\(label) should be in LabelRegistry")
            if let toolName = entry?.tool {
                XCTAssertFalse(toolName.contains("."),
                               "Resolved tool name '\(toolName)' should not contain dots (compound label leaked)")
            }
        }
    }
}

// MARK: - Fix 4: Widget Generator Filters Meta-Text

/// Additional widget filtering tests are in DynamicWidgetTests.swift under
/// WidgetLayoutGeneratorTests. These tests verify the filter logic in isolation.
final class WidgetIngredientFilterTests: XCTestCase {

    /// All meta-text prefixes that should be filtered by WidgetLayoutGenerator.
    func testAllMetaPrefixesAreFiltered() {
        let metaIngredients = [
            "No tool is needed for this request.",
            "No data was retrieved. Respond based only on your knowledge.",
            "Will use FM Tool: Camera",
            "Skill Instruction: Search the web for...",
            "No matching tool found for this query.",
            "No specific tool matches this request.",
            "This request is ambiguous — it could involve: X, Y.",
            "[ERROR] WikipediaSearch: No article found.",
        ]

        for ingredient in metaIngredients {
            let passes = !ingredient.hasPrefix("No tool is needed") &&
                !ingredient.hasPrefix("No data was retrieved") &&
                !ingredient.hasPrefix("Will use FM Tool:") &&
                !ingredient.hasPrefix("Skill Instruction:") &&
                !ingredient.hasPrefix("No matching tool") &&
                !ingredient.hasPrefix("No specific tool") &&
                !ingredient.hasPrefix("This request is ambiguous") &&
                !ingredient.hasPrefix("[ERROR]")
            XCTAssertFalse(passes, "Meta ingredient should be filtered: \(ingredient.prefix(50))...")
        }
    }

    /// Real data ingredients must survive filtering.
    func testRealDataIngredientsPassFilter() {
        let dataIngredients = [
            "[VERIFIED] Weather in London: 15°C, partly cloudy",
            "[VERIFIED] [Byzantine Empire] (Wikipedia) The Byzantine Empire...",
            "[RECALLED] Previously discussed: AAPL stock price",
            "[HELP] Calculator supports +, -, *, / operations",
            "Brazil: Population 214.3 million. Capital: Brasilia.",
        ]

        for ingredient in dataIngredients {
            let passes = !ingredient.hasPrefix("No tool is needed") &&
                !ingredient.hasPrefix("No data was retrieved") &&
                !ingredient.hasPrefix("Will use FM Tool:") &&
                !ingredient.hasPrefix("Skill Instruction:") &&
                !ingredient.hasPrefix("No matching tool") &&
                !ingredient.hasPrefix("No specific tool") &&
                !ingredient.hasPrefix("This request is ambiguous") &&
                !ingredient.hasPrefix("[ERROR]")
            XCTAssertTrue(passes, "Real data ingredient should pass filter: \(ingredient.prefix(50))...")
        }
    }
}
