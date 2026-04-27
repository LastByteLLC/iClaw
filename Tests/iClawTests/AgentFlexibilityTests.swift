import XCTest
@testable import iClawCore

/// Tests for osaurus-inspired agent flexibility improvements:
/// - JSON coercion layer
/// - Fact contradiction detection
/// - Dynamic ingredient compaction in AgentRunner
/// - Raised max tool calls (6)
/// - Widened ToolVerifier band (0.75 threshold)
final class AgentFlexibilityTests: XCTestCase {

    // =========================================================================
    // MARK: - A. JSON Coercion (5 tests)
    // =========================================================================

    func testCoercionStringToInt() throws {
        let json = #"{"count": "5", "name": "test"}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        let result = try JSONSerialization.jsonObject(with: coerced) as! [String: Any]
        XCTAssertEqual(result["count"] as? Int, 5)
        XCTAssertEqual(result["name"] as? String, "test")
    }

    func testCoercionStringToDouble() throws {
        let json = #"{"price": "29.99"}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        let result = try JSONSerialization.jsonObject(with: coerced) as! [String: Any]
        XCTAssertEqual(result["price"] as? Double, 29.99)
    }

    func testCoercionStringToBool() throws {
        let json = #"{"enabled": "true", "disabled": "false"}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        let result = try JSONSerialization.jsonObject(with: coerced) as! [String: Any]
        XCTAssertEqual(result["enabled"] as? Bool, true)
        XCTAssertEqual(result["disabled"] as? Bool, false)
    }

    func testCoercionStringEncodedArray() throws {
        let json = #"{"tags": "[\"swift\",\"macos\"]"}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        let result = try JSONSerialization.jsonObject(with: coerced) as! [String: Any]
        let tags = result["tags"] as? [String]
        XCTAssertEqual(tags, ["swift", "macos"])
    }

    func testCoercionPreservesValidJSON() throws {
        let json = #"{"count": 5, "name": "test", "active": true}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        // Should be unchanged — no coercion needed
        XCTAssertEqual(data, coerced)
    }

    func testCoercionDoesNotCoerceSpacedStrings() throws {
        // "5 miles" should stay as a string, not become 5
        let json = #"{"distance": "5 miles"}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        let result = try JSONSerialization.jsonObject(with: coerced) as! [String: Any]
        XCTAssertEqual(result["distance"] as? String, "5 miles")
    }

    func testCoercionStringNull() throws {
        let json = #"{"value": "null"}"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        let result = try JSONSerialization.jsonObject(with: coerced) as! [String: Any]
        XCTAssertTrue(result["value"] is NSNull)
    }

    func testCoercionNonObjectPassthrough() throws {
        let json = #"[1, 2, 3]"#
        let data = json.data(using: .utf8)!
        let coerced = JSONCoercion.coerce(data)
        // Non-object JSON should pass through unchanged
        XCTAssertEqual(data, coerced)
    }

    // =========================================================================
    // MARK: - B. Fact Contradiction Detection (5 tests)
    // =========================================================================

    func testFactContradictsSameToolSameKeyDifferentValue() {
        let old = Fact(tool: "Weather", key: "San Francisco", value: "62°F cloudy")
        let new = Fact(tool: "Weather", key: "San Francisco", value: "68°F sunny")
        XCTAssertTrue(new.contradicts(old))
    }

    func testFactDoesNotContradictSameValue() {
        let old = Fact(tool: "Weather", key: "San Francisco", value: "62°F cloudy")
        let same = Fact(tool: "Weather", key: "San Francisco", value: "62°F cloudy")
        XCTAssertFalse(same.contradicts(old))
    }

    func testFactDoesNotContradictDifferentTool() {
        let weather = Fact(tool: "Weather", key: "London", value: "50°F rain")
        let news = Fact(tool: "News", key: "London", value: "UK Parliament votes...")
        XCTAssertFalse(news.contradicts(weather))
    }

    func testFactDoesNotContradictDifferentKey() {
        let sf = Fact(tool: "Weather", key: "San Francisco", value: "62°F")
        let ny = Fact(tool: "Weather", key: "New York", value: "45°F")
        XCTAssertFalse(ny.contradicts(sf))
    }

    func testFactContradictsCaseInsensitiveKey() {
        let old = Fact(tool: "Stocks", key: "$AAPL", value: "$286.05")
        let new = Fact(tool: "Stocks", key: "$aapl", value: "$290.00")
        XCTAssertTrue(new.contradicts(old))
    }

    func testFactContradictsBySubstringKey() {
        // "San Francisco" contains "Francisco" — should detect overlap
        let old = Fact(tool: "Weather", key: "San Francisco", value: "62°F")
        let new = Fact(tool: "Weather", key: "Francisco", value: "68°F")
        XCTAssertTrue(new.contradicts(old))
    }

    // =========================================================================
    // MARK: - C. Progressive Memory Contradiction Replacement (3 tests)
    // =========================================================================

    func testProgressiveMemoryReplacesContradictingFact() async {
        let memory = ProgressiveMemoryManager(maxFacts: 5)
        let old = Fact(tool: "Weather", key: "London", value: "50°F rain")
        await memory.recordFacts([old], activeEntities: ["London"])

        let new = Fact(tool: "Weather", key: "London", value: "55°F cloudy")
        await memory.recordFacts([new], activeEntities: ["London"])

        let facts = await memory.workingFacts
        // Should have 1 fact (replaced), not 2 (accumulated)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.value, "55°F cloudy")
    }

    func testProgressiveMemoryAppendsNonContradicting() async {
        let memory = ProgressiveMemoryManager(maxFacts: 5)
        let weather = Fact(tool: "Weather", key: "London", value: "50°F")
        await memory.recordFacts([weather], activeEntities: ["London"])

        let stock = Fact(tool: "Stocks", key: "$AAPL", value: "$286.05")
        await memory.recordFacts([stock], activeEntities: ["AAPL"])

        let facts = await memory.workingFacts
        XCTAssertEqual(facts.count, 2)
    }

    func testProgressiveMemoryReplacesAmongMultiple() async {
        let memory = ProgressiveMemoryManager(maxFacts: 5)
        let facts = [
            Fact(tool: "Weather", key: "London", value: "50°F"),
            Fact(tool: "Stocks", key: "$AAPL", value: "$280"),
            Fact(tool: "News", key: "Headlines", value: "Top story"),
        ]
        await memory.recordFacts(facts, activeEntities: [])

        // Contradict only the stock fact
        let newStock = Fact(tool: "Stocks", key: "$AAPL", value: "$290")
        await memory.recordFacts([newStock], activeEntities: [])

        let current = await memory.workingFacts
        XCTAssertEqual(current.count, 3, "Should still be 3 facts, not 4")
        let stockFact = current.first(where: { $0.tool == "Stocks" })
        XCTAssertEqual(stockFact?.value, "$290")
    }

    // =========================================================================
    // MARK: - D. Max Tool Calls Raised (1 test)
    // =========================================================================

    func testMaxToolCallsRaisedTo6() {
        XCTAssertEqual(AppConfig.maxToolCallsPerTurn, 6)
    }

    // =========================================================================
    // MARK: - E. Pipeline Integration with New Thresholds (3 tests)
    // =========================================================================

    func testMaxToolCallsAllows3ChippedTools() async throws {
        // Router sends at most 3 tools per chip routing. Verify all 3 execute.
        let spies = (1...3).map { i in
            SpyTool(
                name: "Tool\(i)",
                schema: "tool\(i) schema",
                result: ToolIO(text: "Result \(i)", status: .ok)
            )
        }
        let engine = makeTestEngine(tools: spies)

        let chipInput = spies.map { "#\($0.name)" }.joined(separator: " ") + " test"
        _ = await engine.run(input: chipInput)

        let totalInvocations = spies.reduce(0) { $0 + $1.invocations.count }
        XCTAssertEqual(totalInvocations, 3, "All 3 chipped tools should execute")
    }

    func testClarificationIngredientIsConversational() async throws {
        // When no tool matches (needsUserClarification), the ingredient should
        // guide the LLM to respond conversationally
        let spy = SpyTool(name: "Weather", schema: "weather", result: ToolIO(text: "Sunny", status: .ok))
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "none"),
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "tell me about the meaning of life and the universe")

        // Should NOT have invoked Weather
        XCTAssertEqual(spy.invocations.count, 0)
        // The finalization prompt should include the conversational guidance
        XCTAssertTrue(
            captured.value.contains("conversational") || captured.value.contains("clarifying"),
            "Clarification ingredient should guide conversational response"
        )
    }

}
