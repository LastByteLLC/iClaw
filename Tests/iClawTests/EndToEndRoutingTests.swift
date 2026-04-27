import XCTest
@testable import iClawCore

/// End-to-end tests for routing and input cleaning.
/// Verifies that tools receive cleaned input (tags removed) from the ExecutionEngine.
final class EndToEndRoutingTests: XCTestCase {

    private var engine: ExecutionEngine!

    override func invokeTest() {
        // These tests hit real APIs (weather, podcasts) via ExecutionEngine.shared.
        // Gate behind auditTests to prevent hangs in the fast test suite.
        guard TestCapabilities.isAvailable(.auditTests) else { return }
        super.invokeTest()
    }

    override func setUp() async throws {
        try await super.setUp()
        TestLocationSetup.install()
        engine = ExecutionEngine.shared
    }
    
    override func tearDown() async throws {
        await engine.reset()
        engine = nil
        try await super.tearDown()
    }
    
    // MARK: - Input Cleaning Tests
    
    func testInputCleaningLogic() async {
        let testCases = [
            "Calculate 5+5 #calculator": "Calculate 5+5",
            "Time in London #time": "Time in London",
            "#podcast search for Lex": "search for Lex",
            "Translate #translate 'hello' to French": "Translate 'hello' to French",
            "What is #weather in SF? #cal": "What is in SF?"
        ]
        
        for (input, expected) in testCases {
            let cleaned = await engine.cleanInputForTool(input)
            XCTAssertEqual(cleaned, expected, "Cleaning failed for input: \(input)")
        }
    }
    
    // MARK: - Tool Execution with Cleaned Input
    
    func testCalculatorWithChippedInput() async throws {
        let tool = CalculatorTool()
        let input = "5 + 5 #calculator"
        let cleaned = await engine.cleanInputForTool(input)
        
        let result = try await tool.execute(input: cleaned, entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("10"), "Expected 10 in result, got \(result.text)")
    }
    
    func testTimeWithChippedInput() async throws {
        let tool = TimeTool()
        let input = "Time in London #time"
        let cleaned = await engine.cleanInputForTool(input)
        
        // Test with explicit entities (simulating successful NER)
        let entities = ExtractedEntities(
            names: [],
            places: ["London"],
            organizations: [],
            urls: [],
            phoneNumbers: [],
            emails: [],
            ocrText: nil
        )
        
        let result = try await tool.execute(input: cleaned, entities: entities)
        
        // Since it's a real network call/geocoding, we check for success or specific error
        if result.status == .ok {
            XCTAssertTrue(result.text.contains("London"), "Expected London in result, got \(result.text)")
        }
        
        // Also test fallback logic (entities: nil)
        // The tool should now be smart enough to extract London from "Time in London"
        let fallbackResult = try await tool.execute(input: cleaned, entities: nil)
        if fallbackResult.status == .ok {
            XCTAssertTrue(fallbackResult.text.contains("London"), "Expected London in fallback result, got \(fallbackResult.text)")
        }
    }
    
    func testPodcastWithChippedInput() async throws {
        let tool = PodcastTool()
        let input = "search for Lex Friedman #podcast"
        let cleaned = await engine.cleanInputForTool(input)
        
        let result = try await tool.execute(input: cleaned, entities: nil)
        // Result should mention Lex or result from API
        XCTAssertTrue(result.text.contains("Lex") || result.text.contains("No podcasts found") || result.status == .ok)
    }
    
    func testWeatherWithChippedInput() async throws {
        let tool = WeatherTool()
        let input = "Weather in Paris #weather"
        let cleaned = await engine.cleanInputForTool(input)
        
        // Test with explicit entities
        let entities = ExtractedEntities(
            names: [],
            places: ["Paris"],
            organizations: [],
            urls: [],
            phoneNumbers: [],
            emails: [],
            ocrText: nil
        )
        
        let result = try await tool.execute(input: cleaned, entities: entities)
        if result.status == .ok {
            XCTAssertTrue(result.text.contains("Paris"), "Expected Paris in weather result")
        }
        
        // Test fallback logic
        let fallbackResult = try await tool.execute(input: cleaned, entities: nil)
        if fallbackResult.status == .ok {
            XCTAssertTrue(fallbackResult.text.contains("Paris"), "Expected Paris in fallback weather result")
        }
    }
    
    func testConvertWithChippedInput() async throws {
        let tool = ConvertTool()
        let input = "10 miles to km #convert"
        let cleaned = await engine.cleanInputForTool(input)
        
        let result = try await tool.execute(input: cleaned, entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("16.09"), "Expected 16.09 in result, got \(result.text)")
    }
    
    // MARK: - ExecutionEngine Routing Integration
    
    // Note: This test verifies the routing transition logic inside ExecutionEngine.
    // We don't call run() because it hits the LLM, but we verify the tool execution flow.
    // Instead of run(), we could test internal state transitions if they were accessible,
    // but here we focus on verifying that the components work together.
}
