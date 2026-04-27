import XCTest
@testable import iClawCore

/// Comprehensive test suite for explicit tool routing via # chips.
/// Adheres to Swift 6 strict concurrency requirements.
final class ExplicitRoutingTests: XCTestCase {
    
    private var router: ToolRouter!
    private var allTools: [any CoreTool]!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Initialize all tools for the router
        allTools = [
            CalculatorTool(),
            CalendarTool(),
            ConvertTool(),
            EmailTool(),
            PodcastTool(),
            RandomTool(),
            TimeTool(),
            TranscribeTool(),
            TranslateTool(),
            WeatherTool(),
            WebFetchTool()
        ]
        
        router = ToolRouter(availableTools: allTools)
    }
    
    override func tearDown() async throws {
        router = nil
        allTools = nil
        try await super.tearDown()
    }
    
    // MARK: - Direct Match Tests
    
    func testDirectMatch() async {
        let toolMappings: [String: String] = [
            "#calculator": "Calculator",
            "#calendar": "Calendar",
            "#convert": "Convert",
            "#email": "Email",
            "#podcast": "Podcast",
            "#random": "Random",
            "#timer": "Time",
            "#time": "Time",
            "#transcribe": "Transcribe",
            "#translate": "Translate",
            "#weather": "Weather",
            "#webfetch": "WebFetch"
        ]
        
        for (input, expectedName) in toolMappings {
            // Deactivate any mode between tests to prevent mode override from
            // intercepting subsequent chip routing (e.g., #rewrite activates mode)
            await router.deactivateMode()
            let result = await router.route(input: input)
            if case .tools(let tools) = result {
                XCTAssertEqual(tools.count, 1, "Expected exactly 1 tool for \(input)")
                XCTAssertEqual(tools.first?.name, expectedName, "Expected tool name \(expectedName) for \(input)")
            } else {
                XCTFail("Failed to route \(input) directly. Result was \(result)")
            }
        }
    }

    // MARK: - Case Insensitivity Tests

    func testCaseInsensitivity() async {
        let inputs = ["#WEATHER", "#Calculator", "#WebFetch", "#TIME", "#eMaIl"]
        let expectedNames = ["Weather", "Calculator", "WebFetch", "Time", "Email"]

        for (index, input) in inputs.enumerated() {
            await router.deactivateMode()
            let result = await router.route(input: input)
            if case .tools(let tools) = result {
                XCTAssertEqual(tools.first?.name, expectedNames[index], "Case insensitivity failed for \(input)")
            } else {
                XCTFail("Failed to route \(input) due to case sensitivity.")
            }
        }
    }
    
    // MARK: - Underscore Mapping Tests
    
    func testUnderscoreMapping() async {
        // The prompt specifically mentions #web_fetch should match WebFetch
        let result = await router.route(input: "#web_fetch")
        if case .tools(let tools) = result {
            XCTAssertEqual(tools.first?.name, "WebFetch", "Underscore mapping failed for #web_fetch")
        } else {
            // If this fails, it might be a bug in ToolRouter implementation
            XCTFail("Failed to route #web_fetch. Result was \(result)")
        }
    }
    
    // MARK: - Contextual Match Tests
    
    func testContextualMatch() async {
        let testCases = [
            "Check the #weather today": "Weather",
            "I need to use the #calculator for this math": "Calculator",
            "Can you #translate this to French?": "Translate",
            "#podcast play the latest news": "Podcast"
        ]
        
        for (input, expectedName) in testCases {
            let result = await router.route(input: input)
            if case .tools(let tools) = result {
                XCTAssertTrue(tools.contains(where: { $0.name == expectedName }), "Contextual match failed for '\(input)', expected \(expectedName)")
            } else {
                XCTFail("Failed to route contextual input: \(input)")
            }
        }
    }
    
    // MARK: - Punctuation Handling Tests
    
    func testPunctuationHandling() async {
        let testCases = [
            "Use #calculator!": "Calculator",
            "What's the #weather?": "Weather",
            "#timer set 5 min": "Time",
            "Go to #webfetch;": "WebFetch"
        ]
        
        for (input, expectedName) in testCases {
            let result = await router.route(input: input)
            if case .tools(let tools) = result {
                XCTAssertEqual(tools.first?.name, expectedName, "Punctuation handling failed for \(input)")
            } else {
                XCTFail("Failed to route input with punctuation: \(input)")
            }
        }
    }
    
    // MARK: - Multiple Tools Test
    
    func testMultipleTools() async {
        let input = "Use #calculator and #weather"
        let result = await router.route(input: input)
        if case .tools(let tools) = result {
            XCTAssertEqual(tools.count, 2)
            let names = tools.map { $0.name }
            XCTAssertTrue(names.contains("Calculator"))
            XCTAssertTrue(names.contains("Weather"))
        } else {
            XCTFail("Failed to route multiple tools: \(input)")
        }
    }
    
    // MARK: - Limit Tests
    
    func testToolLimit() async {
        // ToolRouter limits to 3 tools
        let input = "#calculator #weather #time #calendar #random"
        let result = await router.route(input: input)
        if case .tools(let tools) = result {
            XCTAssertEqual(tools.count, 3, "Expected tool limit of 3 to be enforced")
        } else {
            XCTFail("Failed to route multiple tools with limit.")
        }
    }
}
