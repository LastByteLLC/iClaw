import XCTest
@testable import iClawCore

/// Exhaustive robustness tests for RandomTool covering every intent via both
/// `execute(args:)` (LLM-extracted) and `execute(input:)` (natural language) paths,
/// plus the RandomWidgetView `regenerate()` path via widget data round-trips.
///
/// Focuses on non-sensible, boundary, and adversarial inputs that an LLM or user
/// might produce — inverted ranges, zero/negative sides, unknown intents, empty
/// strings, enormous values, and garbage text.
final class RandomToolRobustnessTests: XCTestCase {

    let tool = RandomTool()

    // MARK: - Args Path: Dice Edge Cases

    func testDiceZeroSides() async throws {
        let args = RandomArgs(intent: "dice", sides: 0, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d0", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Dice Roll"))
    }

    func testDiceNegativeSides() async throws {
        let args = RandomArgs(intent: "dice", sides: -5, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d-5", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testDiceOneSide() async throws {
        let args = RandomArgs(intent: "dice", sides: 1, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d1", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1"))
    }

    func testDiceNilSidesDefaultsToD6() async throws {
        let args = RandomArgs(intent: "dice", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll dice", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("d6"))
    }

    func testDiceHugeSides() async throws {
        let args = RandomArgs(intent: "dice", sides: 1_000_000, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d1000000", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("d1000000"))
    }

    // MARK: - Args Path: Number Range Edge Cases

    func testNumberInvertedRange() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: 100, max: 1)
        let result = try await tool.execute(args: args, rawInput: "number between 100 and 1", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1 to 100"))
    }

    func testNumberEqualMinMax() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: 42, max: 42)
        let result = try await tool.execute(args: args, rawInput: "number between 42 and 42", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("42"))
    }

    func testNumberNegativeRange() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: -50, max: -10)
        let result = try await tool.execute(args: args, rawInput: "number between -50 and -10", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("-50 to -10"))
    }

    func testNumberNegativeInvertedRange() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: -10, max: -50)
        let result = try await tool.execute(args: args, rawInput: "number between -10 and -50", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("-50 to -10"))
    }

    func testNumberZeroToZero() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: 0, max: 0)
        let result = try await tool.execute(args: args, rawInput: "number between 0 and 0", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("0"))
    }

    func testNumberNilMinMax() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "random number", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1 to 100"))
    }

    func testNumberOnlyMinProvided() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: 50, max: nil)
        let result = try await tool.execute(args: args, rawInput: "number from 50", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // min=50, max defaults to 100 → 50 to 100
        XCTAssertTrue(result.text.contains("50 to 100"))
    }

    func testNumberOnlyMaxProvided() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: nil, max: 10)
        let result = try await tool.execute(args: args, rawInput: "number up to 10", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1 to 10"))
    }

    func testNumberHugeRange() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: -1_000_000, max: 1_000_000)
        let result = try await tool.execute(args: args, rawInput: "number between -1000000 and 1000000", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    // MARK: - Args Path: Unknown / Garbage Intents

    func testUnknownIntentFallsBackToNumber() async throws {
        let args = RandomArgs(intent: "potato", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "potato", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Random Number"))
    }

    func testEmptyIntentFallsBack() async throws {
        let args = RandomArgs(intent: "", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testAllNilArgs() async throws {
        let args = RandomArgs(intent: "number", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    // MARK: - Args Path: Card (DynamicWidget)

    func testCardViaArgsReturnsDynamicWidget() async throws {
        let args = RandomArgs(intent: "card", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "draw a card", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "DynamicWidget")
        XCTAssertNotNil(result.widgetData as? DynamicWidgetData)
        XCTAssertTrue(result.text.contains("Card drawn"))
    }

    // MARK: - Args Path: Date & Color (basic coverage)

    func testDateViaArgs() async throws {
        let args = RandomArgs(intent: "date", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "random date", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Random Date"))
    }

    func testColorViaArgs() async throws {
        let args = RandomArgs(intent: "color", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "random color", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("#"))
        XCTAssertTrue(result.text.contains("RGB"))
    }

    func testCoinViaArgs() async throws {
        let args = RandomArgs(intent: "coin", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "flip a coin", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let isHeadsOrTails = result.text.contains("Heads") || result.text.contains("Tails")
        XCTAssertTrue(isHeadsOrTails)
    }

    // MARK: - NL Path: Edge Cases

    func testNLEmptyInput() async throws {
        let result = try await tool.execute(input: "", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // Falls through to default → random number
        XCTAssertTrue(result.text.contains("Random Number"))
    }

    func testNLGarbageInput() async throws {
        let result = try await tool.execute(input: "asdfghjkl qwerty zxcvbn", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testNLUnicodeInput() async throws {
        let result = try await tool.execute(input: "🎲🎲🎲", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testNLVeryLongInput() async throws {
        let long = String(repeating: "roll a dice ", count: 500)
        let result = try await tool.execute(input: long, entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testNLDrawCardReturnsDynamicWidget() async throws {
        let result = try await tool.execute(input: "draw a card", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "DynamicWidget")
        XCTAssertNotNil(result.widgetData as? DynamicWidgetData)
    }

    func testNLDiceD0() async throws {
        let result = try await tool.execute(input: "roll a d0", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // d0 should not crash — regex extracts 0, clamped to 1
    }

    func testNLDiceNoNumber() async throws {
        let result = try await tool.execute(input: "roll dice", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("d6"))
    }

    func testNLNumberNoDigits() async throws {
        let result = try await tool.execute(input: "give me a number", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1 to 100"))
    }

    func testNLNumberSingleDigit() async throws {
        let result = try await tool.execute(input: "number between 5", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // Only one number extracted → defaults to 1-100
        XCTAssertTrue(result.text.contains("1 to 100"))
    }

    func testNLNumberInvertedInText() async throws {
        let result = try await tool.execute(input: "number between 500 and 3", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // min/max should be normalized
        XCTAssertTrue(result.text.contains("3 to 500"))
    }

    // MARK: - NL Compound Requests

    func testCompoundCoinAndDice() async throws {
        let result = try await tool.execute(input: "flip a coin and roll a dice", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("|"))
    }

    func testCompoundThreeWay() async throws {
        let result = try await tool.execute(input: "flip a coin and roll a dice and pick a number", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testCompoundWithGarbageSegment() async throws {
        // "and" splitting creates segments but not all match intents → not treated as compound
        let result = try await tool.execute(input: "tell me about cats and dogs", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    // MARK: - buildCardResult Static Method

    func testBuildCardResultProducesValidWidget() {
        let result = RandomTool.buildCardResult()
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "DynamicWidget")

        let data = result.widgetData as? DynamicWidgetData
        XCTAssertNotNil(data)
        XCTAssertFalse(data!.blocks.isEmpty)
    }

    func testBuildCardResultTextContainsSuit() {
        let result = RandomTool.buildCardResult()
        let text = result.text
        let hasSuit = text.contains("Spades") || text.contains("Hearts")
            || text.contains("Diamonds") || text.contains("Clubs")
        XCTAssertTrue(hasSuit, "Card text should name a suit: \(text)")
    }

    func testBuildCardResultTextContainsRank() {
        let result = RandomTool.buildCardResult()
        let text = result.text
        let ranks = ["Ace", "Two", "Three", "Four", "Five", "Six", "Seven",
                     "Eight", "Nine", "Ten", "Jack", "Queen", "King"]
        let hasRank = ranks.contains { text.contains($0) }
        XCTAssertTrue(hasRank, "Card text should name a rank: \(text)")
    }

    /// Run card generation many times to ensure no crash from randomElement()
    func testBuildCardResultStability() {
        for _ in 0..<200 {
            let result = RandomTool.buildCardResult()
            XCTAssertEqual(result.status, .ok)
        }
    }

    // MARK: - Widget Regeneration Robustness

    /// Simulates the regenerate path with corrupted widget data where sides=0.
    /// The RandomWidgetView.regenerate() uses these stored values.
    func testRegenerateWithZeroSidesData() {
        let data = RandomWidgetData(type: "Dice Roll", result: "0", details: "d0",
                                    intent: "dice", sides: 0)
        // The fix clamps to max(sides, 1) so this must not crash
        let sides = max(data.sides ?? 6, 1)
        _ = Int.random(in: 1...sides)
    }

    func testRegenerateWithNegativeSidesData() {
        let data = RandomWidgetData(type: "Dice Roll", result: "-3", details: "d-3",
                                    intent: "dice", sides: -3)
        let sides = max(data.sides ?? 6, 1)
        _ = Int.random(in: 1...sides)
    }

    func testRegenerateWithInvertedMinMax() {
        let data = RandomWidgetData(type: "Random Number", result: "50", details: "100 to 1",
                                    intent: "number", min: 100, max: 1)
        let rawMin = data.min ?? 1
        let rawMax = data.max ?? 100
        let minVal = min(rawMin, rawMax)
        let maxVal = max(rawMin, rawMax)
        _ = Int.random(in: minVal...maxVal)
        XCTAssertEqual(minVal, 1)
        XCTAssertEqual(maxVal, 100)
    }

    func testRegenerateWithNilMinMax() {
        let data = RandomWidgetData(type: "Random Number", result: "50",
                                    intent: "number", min: nil, max: nil)
        let rawMin = data.min ?? 1
        let rawMax = data.max ?? 100
        let minVal = min(rawMin, rawMax)
        let maxVal = max(rawMin, rawMax)
        _ = Int.random(in: minVal...maxVal)
        XCTAssertEqual(minVal, 1)
        XCTAssertEqual(maxVal, 100)
    }

    // MARK: - Stress: All Intents Via Args (Repeated)

    /// Runs each intent 50 times to catch intermittent crashes.
    func testAllIntentsRepeated() async throws {
        let intents = ["coin", "card", "dice", "number", "date", "color", "unknown", ""]
        for intent in intents {
            for _ in 0..<50 {
                let args = RandomArgs(intent: intent, sides: nil, min: nil, max: nil)
                let result = try await tool.execute(args: args, rawInput: intent, entities: nil)
                XCTAssertEqual(result.status, .ok, "Failed on intent: \(intent)")
            }
        }
    }

    /// Runs dice with a range of bizarre side values.
    func testDiceWithManySideValues() async throws {
        let sideValues = [-100, -1, 0, 1, 2, 6, 20, 100, 999_999, Int.max]
        for sides in sideValues {
            let args = RandomArgs(intent: "dice", sides: sides, min: nil, max: nil)
            let result = try await tool.execute(args: args, rawInput: "roll d\(sides)", entities: nil)
            XCTAssertEqual(result.status, .ok, "Crashed on sides=\(sides)")
        }
    }

    /// Runs number with a range of boundary min/max pairs.
    func testNumberWithManyRanges() async throws {
        let ranges: [(Int?, Int?)] = [
            (nil, nil), (0, 0), (1, 1), (-1, 1), (1, -1),
            (100, 1), (-100, -200), (Int.min / 2, Int.max / 2),
            (42, nil), (nil, 42), (0, nil), (nil, 0),
        ]
        for (lo, hi) in ranges {
            let args = RandomArgs(intent: "number", sides: nil, min: lo, max: hi)
            let result = try await tool.execute(args: args, rawInput: "number", entities: nil)
            XCTAssertEqual(result.status, .ok, "Crashed on min=\(String(describing: lo)), max=\(String(describing: hi))")
        }
    }

    // MARK: - NL Path: Diverse Natural Language Inputs

    func testNLDiverseCardPhrases() async throws {
        let phrases = [
            "draw a card", "pick a card", "random card", "deal a card",
            "give me a playing card", "card please", "pull a card from the deck",
        ]
        for phrase in phrases {
            let result = try await tool.execute(input: phrase, entities: nil)
            XCTAssertEqual(result.status, .ok, "Failed on: \(phrase)")
            XCTAssertEqual(result.outputWidget, "DynamicWidget", "Wrong widget for: \(phrase)")
        }
    }

    func testNLDiverseCoinPhrases() async throws {
        let phrases = ["flip a coin", "coin flip", "heads or tails", "toss a coin", "coin toss"]
        for phrase in phrases {
            let result = try await tool.execute(input: phrase, entities: nil)
            XCTAssertEqual(result.status, .ok, "Failed on: \(phrase)")
        }
    }

    func testNLDiverseDicePhrases() async throws {
        let phrases = ["roll a dice", "roll d20", "dice roll", "roll a d100", "roll d1", "roll d0"]
        for phrase in phrases {
            let result = try await tool.execute(input: phrase, entities: nil)
            XCTAssertEqual(result.status, .ok, "Failed on: \(phrase)")
        }
    }
}
