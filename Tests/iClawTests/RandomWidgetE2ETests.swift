import XCTest
@testable import iClawCore

/// E2E tests for the RandomTool → RandomWidgetData → regenerate round-trip.
///
/// Validates that:
/// 1. Multi-dice NdS notation produces correct widget data (count + sides)
/// 2. Widget data survives the regenerate cycle with correct parameters
/// 3. The rawInput fallback correctly overrides missing LLM-extracted args
/// 4. Adversarial and edge-case inputs don't crash or lose dice configuration
final class RandomWidgetE2ETests: XCTestCase {

    let tool = RandomTool()

    // MARK: - Helper: Simulate regenerate()

    /// Replicates the dice branch of RandomWidgetView.regenerate() so we can
    /// test the round-trip without instantiating a SwiftUI view.
    private func simulateRegenerate(_ d: RandomWidgetData) -> RandomWidgetData {
        switch d.intent ?? d.type.lowercased() {
        case "dice", "dice roll":
            let sides = max(d.sides ?? 6, 1)
            let diceCount = max(d.count ?? 1, 1)
            if diceCount == 1 {
                return RandomWidgetData(
                    type: "Dice Roll", result: "\(Int.random(in: 1...sides))",
                    details: "d\(sides)", intent: "dice", sides: sides
                )
            } else {
                let rolls = (0..<diceCount).map { _ in Int.random(in: 1...sides) }
                let total = rolls.reduce(0, +)
                let result = rolls.map(String.init).joined(separator: ", ") + " (total: \(total))"
                return RandomWidgetData(
                    type: "Dice Roll", result: result,
                    details: "\(diceCount)d\(sides)", intent: "dice", sides: sides, count: diceCount
                )
            }
        case "number":
            let rawMin = d.min ?? 1
            let rawMax = d.max ?? 100
            let minVal = min(rawMin, rawMax)
            let maxVal = max(rawMin, rawMax)
            return RandomWidgetData(
                type: "Random Number", result: "\(Int.random(in: minVal...maxVal))",
                details: "\(minVal) to \(maxVal)", intent: "number", min: minVal, max: maxVal
            )
        default:
            return d
        }
    }

    // MARK: - NL Path: Multi-Dice Widget Data

    func testNL3d8ProducesMultiDiceWidget() async throws {
        let result = try await tool.execute(input: "roll 3d8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.intent, "dice")
        XCTAssertEqual(data?.sides, 8)
        XCTAssertEqual(data?.count, 3)
        XCTAssertEqual(data?.details, "3d8")
        XCTAssertTrue(result.text.contains("total:"))
    }

    func testNL2d6ProducesMultiDiceWidget() async throws {
        let result = try await tool.execute(input: "roll 2d6", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 6)
        XCTAssertEqual(data?.count, 2)
        XCTAssertEqual(data?.details, "2d6")
    }

    func testNL1d20ProducesSingleDiceWidget() async throws {
        let result = try await tool.execute(input: "roll 1d20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 20)
        // count should be nil for single dice (not stored)
        XCTAssertNil(data?.count)
        XCTAssertEqual(data?.details, "d20")
    }

    func testNLPlainD20ProducesSingleDiceWidget() async throws {
        let result = try await tool.execute(input: "roll d20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 20)
        XCTAssertNil(data?.count)
    }

    // MARK: - Args Path: rawInput Fallback When LLM Misses Count/Sides

    /// Simulates LLM returning intent="dice" with nil count/sides, but rawInput has "3d8".
    func testArgsRawInputFallback3d8() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 3d8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 8, "rawInput fallback should extract sides=8")
        XCTAssertEqual(data?.count, 3, "rawInput fallback should extract count=3")
        XCTAssertEqual(data?.details, "3d8")
        XCTAssertTrue(result.text.contains("total:"))
    }

    /// Simulates LLM returning intent="dice" with nil sides, but rawInput has "d20".
    func testArgsRawInputFallbackD20() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 20, "rawInput fallback should extract sides=20 from d20")
    }

    /// LLM extracts sides correctly but misses count — rawInput fills the gap.
    func testArgsPartialExtraction_SidesPresent_CountMissing() async throws {
        let args = RandomArgs(intent: "dice", sides: 8, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 3d8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 8, "LLM-provided sides should be kept")
        XCTAssertEqual(data?.count, 3, "rawInput fallback should fill missing count")
    }

    /// LLM extracts count correctly but misses sides — rawInput fills the gap.
    func testArgsPartialExtraction_CountPresent_SidesMissing() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: 3, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 3d8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 8, "rawInput fallback should fill missing sides")
        XCTAssertEqual(data?.count, 3, "LLM-provided count should be kept")
    }

    /// LLM extracts both correctly — rawInput should NOT override.
    func testArgsFullExtraction_NoOverride() async throws {
        let args = RandomArgs(intent: "dice", sides: 12, count: 4, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 4d12", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.sides, 12, "LLM-provided sides should be kept")
        XCTAssertEqual(data?.count, 4, "LLM-provided count should be kept")
        XCTAssertEqual(data?.details, "4d12")
    }

    // MARK: - Widget Regenerate Round-Trip

    /// The original bug: "roll 3d8" → widget shows multi-roll → refresh → should still be 3d8.
    func testRegeneratePreserves3d8() async throws {
        let result = try await tool.execute(input: "roll 3d8", entities: nil)
        let data = result.widgetData as! RandomWidgetData

        // Simulate pressing refresh
        let refreshed = simulateRegenerate(data)
        XCTAssertEqual(refreshed.sides, 8, "Refresh should keep sides=8")
        XCTAssertEqual(refreshed.count, 3, "Refresh should keep count=3")
        XCTAssertEqual(refreshed.details, "3d8")
        XCTAssertTrue(refreshed.result.contains("total:"), "Multi-dice refresh should show total")

        // Second refresh should still preserve
        let doubleRefreshed = simulateRegenerate(refreshed)
        XCTAssertEqual(doubleRefreshed.sides, 8)
        XCTAssertEqual(doubleRefreshed.count, 3)
    }

    /// Regenerate preserves single die configuration.
    func testRegeneratePreservesSingleD20() async throws {
        let result = try await tool.execute(input: "roll d20", entities: nil)
        let data = result.widgetData as! RandomWidgetData

        let refreshed = simulateRegenerate(data)
        XCTAssertEqual(refreshed.sides, 20)
        XCTAssertNil(refreshed.count, "Single die should not carry count")
        XCTAssertEqual(refreshed.details, "d20")
    }

    /// Regenerate round-trip via the args path (LLM missed count, rawInput rescued).
    func testRegenerateAfterRawInputFallback() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 5d10", entities: nil)
        let data = result.widgetData as! RandomWidgetData

        XCTAssertEqual(data.sides, 10)
        XCTAssertEqual(data.count, 5)

        let refreshed = simulateRegenerate(data)
        XCTAssertEqual(refreshed.sides, 10, "Refresh after fallback should keep sides")
        XCTAssertEqual(refreshed.count, 5, "Refresh after fallback should keep count")
    }

    /// Number range widget data survives regenerate.
    func testRegeneratePreservesNumberRange() async throws {
        let result = try await tool.execute(input: "random number between 50 and 200", entities: nil)
        let data = result.widgetData as! RandomWidgetData

        let refreshed = simulateRegenerate(data)
        XCTAssertEqual(refreshed.min, 50)
        XCTAssertEqual(refreshed.max, 200)
        XCTAssertEqual(refreshed.details, "50 to 200")
    }

    // MARK: - Adversarial: NdS Notation Edge Cases

    func testNL100d100() async throws {
        let result = try await tool.execute(input: "roll 100d100", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 100)
        XCTAssertEqual(data?.count, 100, "100 is at the cap")
        XCTAssertTrue(result.text.contains("total:"))
    }

    /// Count >100 should be clamped to 100.
    func testNL999d6Clamped() async throws {
        let result = try await tool.execute(input: "roll 999d6", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.count, 100, "dice count should be clamped to 100")
        XCTAssertEqual(data?.sides, 6)
    }

    func testNL0d6() async throws {
        let result = try await tool.execute(input: "roll 0d6", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        // 0 count → clamped to 1 → single die
        XCTAssertNil(data?.count, "0 count should clamp to 1 (single die, no count stored)")
        XCTAssertEqual(data?.sides, 6)
    }

    func testNL1d1() async throws {
        let result = try await tool.execute(input: "roll 1d1", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1"), "1d1 always produces 1")
    }

    func testNL3d0() async throws {
        let result = try await tool.execute(input: "roll 3d0", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // sides=0 clamped to 1
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 1, "d0 should clamp sides to 1")
        XCTAssertEqual(data?.count, 3)
    }

    // MARK: - Adversarial: rawInput Mismatch with Args

    /// rawInput says "3d8" but LLM returned intent="number" — rawInput fallback should NOT fire.
    func testRawInputFallbackOnlyFiresForDiceIntent() async throws {
        let args = RandomArgs(intent: "number", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 3d8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Random Number"), "Number intent should not become dice")
    }

    /// rawInput has no NdS notation — should not crash or inject spurious values.
    func testRawInputWithoutNdS() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll some dice please", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 6, "No NdS → default d6")
        XCTAssertNil(data?.count, "No NdS → single die")
    }

    /// rawInput has NdS buried in a longer sentence.
    func testRawInputNdSInLongerSentence() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(
            args: args,
            rawInput: "hey can you please roll 4d12 for my D&D character",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 12)
        XCTAssertEqual(data?.count, 4)
    }

    /// rawInput has multiple NdS patterns — should use the first one.
    func testRawInputMultipleNdSUsesFirst() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(
            args: args,
            rawInput: "roll 2d8 or maybe 5d12",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 8, "Should use first NdS match")
        XCTAssertEqual(data?.count, 2, "Should use first NdS match")
    }

    // MARK: - Adversarial: Word-Number Dice Counts (NL Path)

    func testNLTwoDice() async throws {
        let result = try await tool.execute(input: "roll two dice", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.count, 2, "Word 'two' should produce 2 dice")
        XCTAssertEqual(data?.sides, 6, "Unspecified sides should default to 6")
    }

    func testNLFiveDice() async throws {
        let result = try await tool.execute(input: "roll five dice", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.count, 5)
    }

    func testNLThreeD20() async throws {
        // Mixed: word-number count + d-notation sides — NdS regex won't match, falls to word parse
        let result = try await tool.execute(input: "roll three d20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.count, 3)
        XCTAssertEqual(data?.sides, 20)
    }

    func testNLNumericCountWithDice() async throws {
        let result = try await tool.execute(input: "roll 4 dice", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.count, 4)
        XCTAssertEqual(data?.sides, 6, "Unspecified sides should default to 6")
    }

    // MARK: - Adversarial: Tricky NdS Patterns

    /// Uppercase "D" instead of lowercase "d".
    func testNLUppercaseD() async throws {
        let result = try await tool.execute(input: "roll 3D8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 8)
        XCTAssertEqual(data?.count, 3)
    }

    /// Mixed case.
    func testNLMixedCaseRoll() async throws {
        let result = try await tool.execute(input: "ROLL 2D20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 20)
        XCTAssertEqual(data?.count, 2)
    }

    /// Bare NdS with no "roll" prefix — the NL parser requires "roll", "dice",
    /// or a word-boundary `d\d+` to enter the dice branch. "3d8" doesn't match
    /// because there's no word boundary before "d". This falls to the default.
    func testNLBareNdSFallsToDefault() async throws {
        let result = try await tool.execute(input: "3d8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // Without "roll"/"dice" keyword, NL parser can't route to dice
        // The args path handles this via rawInput fallback instead
    }

    /// NdS with leading/trailing whitespace.
    func testNLNdSWithWhitespace() async throws {
        let result = try await tool.execute(input: "  roll  2d6  ", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 6)
        XCTAssertEqual(data?.count, 2)
    }

    // MARK: - Adversarial: Args Path rawInput Edge Cases

    /// rawInput is empty — should not crash, use defaults.
    func testArgsEmptyRawInput() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 6, "Empty rawInput → default d6")
    }

    /// rawInput contains "d" but no number after it.
    func testArgsRawInputBareD() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.sides, 6, "Bare 'd' without number → default d6")
    }

    /// rawInput has NdS where N is very large.
    func testArgsRawInputHugeCount() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 500d20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let data = result.widgetData as? RandomWidgetData
        XCTAssertEqual(data?.count, 100, "Count from rawInput should be clamped to 100")
        XCTAssertEqual(data?.sides, 20)
    }

    // MARK: - Stress: Multi-Dice Stability

    /// Run multi-dice rolls many times to ensure no crashes.
    func testMultiDiceStability() async throws {
        let patterns = ["roll 2d6", "roll 3d8", "roll 10d20", "roll 100d100", "roll 1d1"]
        for pattern in patterns {
            for _ in 0..<50 {
                let result = try await tool.execute(input: pattern, entities: nil)
                XCTAssertEqual(result.status, .ok, "Failed on: \(pattern)")
            }
        }
    }

    /// Regenerate round-trip stability — repeated refreshes should never lose config.
    func testRegenerateStability() async throws {
        let result = try await tool.execute(input: "roll 4d12", entities: nil)
        var data = result.widgetData as! RandomWidgetData

        for i in 0..<100 {
            data = simulateRegenerate(data)
            XCTAssertEqual(data.sides, 12, "Lost sides on iteration \(i)")
            XCTAssertEqual(data.count, 4, "Lost count on iteration \(i)")
            XCTAssertEqual(data.details, "4d12", "Wrong details on iteration \(i)")
        }
    }

    /// Regenerate stability for args path with rawInput fallback.
    func testRegenerateStabilityAfterFallback() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, count: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll 3d10", entities: nil)
        var data = result.widgetData as! RandomWidgetData

        for i in 0..<100 {
            data = simulateRegenerate(data)
            XCTAssertEqual(data.sides, 10, "Lost sides on iteration \(i)")
            XCTAssertEqual(data.count, 3, "Lost count on iteration \(i)")
        }
    }

    // MARK: - Multi-Dice Result Format Validation

    /// Validates the output format: "x, y, z (total: N)".
    func testMultiDiceResultFormat() async throws {
        let result = try await tool.execute(input: "roll 3d6", entities: nil)
        let data = result.widgetData as! RandomWidgetData

        // Should contain comma-separated rolls + total
        let parts = data.result.components(separatedBy: " (total: ")
        XCTAssertEqual(parts.count, 2, "Result should have '(total: N)' suffix")

        let rolls = parts[0].components(separatedBy: ", ")
        XCTAssertEqual(rolls.count, 3, "3d6 should produce 3 comma-separated values")

        // Each roll should be 1-6
        for roll in rolls {
            let value = Int(roll.trimmingCharacters(in: .whitespaces))
            XCTAssertNotNil(value, "Roll '\(roll)' should be an integer")
            XCTAssertTrue((1...6).contains(value!), "d6 roll should be 1-6, got \(value!)")
        }

        // Total should match sum
        let totalStr = parts[1].replacingOccurrences(of: ")", with: "")
        let total = Int(totalStr)
        let expectedTotal = rolls.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
        XCTAssertEqual(total, expectedTotal, "Total should equal sum of rolls")
    }

    /// Validates single die result is a plain number (no commas, no total).
    func testSingleDieResultFormat() async throws {
        let result = try await tool.execute(input: "roll d20", entities: nil)
        let data = result.widgetData as! RandomWidgetData

        XCTAssertFalse(data.result.contains(","), "Single die should not have commas")
        XCTAssertFalse(data.result.contains("total"), "Single die should not have total")
        let value = Int(data.result)
        XCTAssertNotNil(value, "Single die result should be a plain integer")
        XCTAssertTrue((1...20).contains(value!), "d20 roll should be 1-20")
    }
}
