import XCTest
import FoundationModels
@testable import iClawCore

final class RouterTests: XCTestCase {
    
    struct MockTool: CoreTool, Sendable {
        let name: String
        let schema: String = "Mock schema for tool."
        let isInternal: Bool = false
        let category: CategoryEnum = .offline
        
        func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
            return ToolIO(text: "Mock result for \(name)")
        }
    }

    struct MockFMTool: FMToolDescriptor, @unchecked Sendable {
        let name: String
        let chipName: String
        let routingKeywords: [String] = []
        let category: CategoryEnum = .offline
        func makeTool() -> any Tool {
            // This is just a mock, so we don't need a real Tool implementation
            // In a real test, we might need a more concrete mock if we execute it.
            fatalError("Not implemented")
        }
    }
    
    // MARK: - ToolRouter Tests
    
    func testToolChipsOverride() async throws {
        let tools: [any CoreTool] = [
            MockTool(name: "Weather"),
            MockTool(name: "Calendar"),
            MockTool(name: "News")
        ]
        let router = ToolRouter(availableTools: tools)
        
        let input = "Check the #weather and #news"
        let result = await router.route(input: input)
        
        if case .tools(let matchedTools) = result {
            XCTAssertEqual(matchedTools.count, 2)
            XCTAssertTrue(matchedTools.contains { $0.name == "Weather" })
            XCTAssertTrue(matchedTools.contains { $0.name == "News" })
        } else {
            XCTFail("Expected .tools result")
        }
    }
    
    func testToolRouterLimit() async throws {
        let tools: [any CoreTool] = [
            MockTool(name: "Weather"),
            MockTool(name: "Calendar"),
            MockTool(name: "News"),
            MockTool(name: "Calculator"),
            MockTool(name: "Translate")
        ]
        let router = ToolRouter(availableTools: tools)
        
        // Input with 5 chips
        let input = "#weather #calendar #news #calculator #translate"
        let result = await router.route(input: input)
        
        if case .tools(let matchedTools) = result {
            // Should be limited to 3 as per ToolRouter.maxToolsToReturn
            XCTAssertEqual(matchedTools.count, 3)
        } else {
            XCTFail("Expected .tools result")
        }
    }
    
    func testFMToolChips() async throws {
        let coreTools: [any CoreTool] = [MockTool(name: "Weather")]
        let fmTools: [any FMToolDescriptor] = [
            MockFMTool(name: "Calendar FM", chipName: "calendar"),
            MockFMTool(name: "News FM", chipName: "news")
        ]
        let router = ToolRouter(availableTools: coreTools, fmTools: fmTools, llmResponder: makeStubRouterLLMResponder())
        
        let input = "Check the #calendar and #news"
        let result = await router.route(input: input)
        
        if case .fmTools(let matchedTools) = result {
            XCTAssertEqual(matchedTools.count, 2)
            XCTAssertTrue(matchedTools.contains { $0.chipName == "calendar" })
            XCTAssertTrue(matchedTools.contains { $0.chipName == "news" })
        } else {
            XCTFail("Expected .fmTools result, got \(result)")
        }
    }
    
    func testMixedToolChips() async throws {
        let coreTools: [any CoreTool] = [MockTool(name: "Weather")]
        let fmTools: [any FMToolDescriptor] = [
            MockFMTool(name: "Calendar FM", chipName: "calendar")
        ]
        let router = ToolRouter(availableTools: coreTools, fmTools: fmTools, llmResponder: makeStubRouterLLMResponder())
        
        let input = "Check the #weather and #calendar"
        let result = await router.route(input: input)
        
        if case .mixed(let core, let fm) = result {
            XCTAssertEqual(core.count, 1)
            XCTAssertEqual(fm.count, 1)
            XCTAssertEqual(core.first?.name, "Weather")
            XCTAssertEqual(fm.first?.chipName, "calendar")
        } else {
            XCTFail("Expected .mixed result, got \(result)")
        }
    }
    
    // MARK: - ExecutionEngine Tests
    
    func testExecutionEngineStateTransitions() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast",
                          result: ToolIO(text: "Sunny 25°C", status: .ok))
        let engine = makeTestEngine(tools: [spy])

        // Initial state
        var state = await engine.currentState
        XCTAssertEqual(state, .idle)

        // Run the loop
        _ = await engine.run(input: "#weather London")

        // Should transition back to idle
        state = await engine.currentState
        XCTAssertEqual(state, .idle)
    }

    func testExecutionEngineMaxToolCalls() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast",
                          result: ToolIO(text: "Sunny 25°C", status: .ok))
        let engine = makeTestEngine(tools: [spy])

        // AppConfig.maxToolCallsPerTurn is 4
        // The ExecutionEngine stub logic will cycle through states.
        // We verify it doesn't crash and completes.
        _ = await engine.run(input: "#weather complex task")

        let state = await engine.currentState
        XCTAssertEqual(state, .idle)
    }
}
