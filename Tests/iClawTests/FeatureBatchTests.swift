import XCTest
@testable import iClawCore

// MARK: - Test 1: Tool Suppression Verification

final class ToolSuppressionTests: XCTestCase {

    func testHealthToolNotRegistered() {
        let fmNames = ToolRegistry.fmTools.map { $0.name }
        XCTAssertFalse(fmNames.contains("health"), "HealthFMDescriptor should not be registered")
    }

    func testCameraToolNotRegistered() {
        let fmNames = ToolRegistry.fmTools.map { $0.name }
        XCTAssertFalse(fmNames.contains("camera"), "CameraFMDescriptor should not be registered")
    }

    func testCreateToolNotRegistered() {
        let coreNames = ToolRegistry.coreTools.map { $0.name }
        XCTAssertFalse(coreNames.contains("Create"), "CreateTool should not be registered")
    }

    func testDictionaryChipRemovedFromManifest() {
        let chipName = ToolManifest.entry(for: "Dictionary")?.chipName
        XCTAssertNil(chipName, "Dictionary should have no chipName in manifest")
    }

    func testCreateChipRemovedFromManifest() {
        let chipName = ToolManifest.entry(for: "Create")?.chipName
        XCTAssertNil(chipName, "Create should have no chipName in manifest")
    }

    func testCreateHiddenInManifest() {
        XCTAssertFalse(ToolManifest.showsInUI(for: "Create"), "Create should be hidden from UI")
    }

    func testHelpToolIsRegistered() {
        let coreNames = ToolRegistry.coreTools.map { $0.name }
        XCTAssertTrue(coreNames.contains("Help"), "HelpTool should be registered")
    }

    #if os(macOS)
    func testTechSupportToolIsRegistered() {
        let coreNames = ToolRegistry.coreTools.map { $0.name }
        XCTAssertTrue(coreNames.contains("TechSupport"), "TechSupportTool should be registered")
    }
    #endif
}

// MARK: - Test 2: Brave Search HTML Parser

final class BraveSearchParserTests: XCTestCase {

    func testParseBraveResultsSingleBlock() throws {
        let html = """
        <html><body>
        <div class="snippet">
          <a class="result-header" href="https://example.com/page">
            <span class="snippet-title">Example Page Title</span>
          </a>
          <p class="snippet-description">This is a brief description of the page content.</p>
        </div>
        </body></html>
        """
        let results = try WebSearchTool.parseBraveResults(html: html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Example Page Title")
        XCTAssertEqual(results[0].url, "https://example.com/page")
        XCTAssertEqual(results[0].snippet, "This is a brief description of the page content.")
    }

    func testParseBraveResultsMultipleBlocks() throws {
        let html = """
        <html><body>
        <div class="snippet">
          <a class="result-header" href="https://a.com"><span class="snippet-title">Result A</span></a>
          <p class="snippet-description">Snippet A</p>
        </div>
        <div class="snippet">
          <a class="result-header" href="https://b.com"><span class="snippet-title">Result B</span></a>
          <p class="snippet-description">Snippet B</p>
        </div>
        <div class="snippet">
          <a class="result-header" href="https://c.com"><span class="snippet-title">Result C</span></a>
          <div class="snippet-description">Snippet C via div</div>
        </div>
        </body></html>
        """
        let results = try WebSearchTool.parseBraveResults(html: html)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[1].title, "Result B")
        XCTAssertEqual(results[2].snippet, "Snippet C via div")
    }

    func testParseBraveResultsEmptyHTML() throws {
        let results = try WebSearchTool.parseBraveResults(html: "<html><body></body></html>")
        XCTAssertTrue(results.isEmpty)
    }

    func testParseBraveResultsNoSnippet() throws {
        let html = """
        <html><body>
        <div class="snippet">
          <a class="result-header" href="https://example.com"><span class="snippet-title">Title Only</span></a>
        </div>
        </body></html>
        """
        let results = try WebSearchTool.parseBraveResults(html: html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Title Only")
        XCTAssertNil(results[0].snippet)
    }
}

// MARK: - Test 3: Conversation History Pagination

@MainActor
final class ConversationPaginationTests: XCTestCase {

    private func makeDB() throws -> DatabaseManager {
        try DatabaseManager(inMemory: true)
    }

    private func insertPair(db: DatabaseManager, user: String, agent: String) async throws {
        var userMem = Memory(id: nil, role: "user", content: user, embedding: nil, created_at: Date(), is_important: false)
        userMem = try await db.saveMemory(userMem)
        let agentMem = Memory(id: nil, role: "agent", content: agent, embedding: nil, created_at: Date(), is_important: false)
        _ = try await db.saveMemory(agentMem)
    }

    func testRecentPairsReturnsChronologicalOrder() async throws {
        let db = try makeDB()
        for i in 1...6 {
            try await insertPair(db: db, user: "q\(i)", agent: "a\(i)")
        }

        let page = await db.recentConversationPairs(limit: 3)
        XCTAssertEqual(page.pairs.count, 3)
        XCTAssertEqual(page.scannedCount, 3)
        // Should be chronological (oldest first within chunk): q4, q5, q6
        XCTAssertEqual(page.pairs[0].user.content, "q4")
        XCTAssertEqual(page.pairs[1].user.content, "q5")
        XCTAssertEqual(page.pairs[2].user.content, "q6")
        // Agent messages should match
        XCTAssertEqual(page.pairs[0].agent.content, "a4")
        XCTAssertEqual(page.pairs[2].agent.content, "a6")
    }

    func testRecentPairsPaginationWithBeforeID() async throws {
        let db = try makeDB()
        for i in 1...6 {
            try await insertPair(db: db, user: "q\(i)", agent: "a\(i)")
        }

        // First page: most recent 3
        let page1 = await db.recentConversationPairs(limit: 3)
        XCTAssertEqual(page1.pairs.count, 3)
        XCTAssertEqual(page1.pairs[0].user.content, "q4")

        // Second page: next 3 before the cursor
        let page2 = await db.recentConversationPairs(limit: 3, beforeID: page1.cursorID)
        XCTAssertEqual(page2.pairs.count, 3)
        XCTAssertEqual(page2.pairs[0].user.content, "q1")
        XCTAssertEqual(page2.pairs[2].user.content, "q3")
    }

    func testRecentPairsExhausted() async throws {
        let db = try makeDB()
        for i in 1...2 {
            try await insertPair(db: db, user: "q\(i)", agent: "a\(i)")
        }

        let page1 = await db.recentConversationPairs(limit: 5)
        XCTAssertEqual(page1.pairs.count, 2)
        XCTAssertEqual(page1.scannedCount, 2)

        // Page 2 should be empty
        let page2 = await db.recentConversationPairs(limit: 5, beforeID: page1.cursorID)
        XCTAssertTrue(page2.pairs.isEmpty)
        XCTAssertEqual(page2.scannedCount, 0)
    }

    func testRecentPairsEmptyDatabase() async throws {
        let db = try makeDB()
        let page = await db.recentConversationPairs(limit: 5)
        XCTAssertTrue(page.pairs.isEmpty)
        XCTAssertNil(page.cursorID)
    }
}

// MARK: - Test 4: HelpTool Sub-Topic Routing

final class HelpToolTests: XCTestCase {

    func testOverviewHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "what can you do", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("[HELP]"), "Overview should be a HELP response")
        XCTAssertEqual(result.outputWidget, "HelpOverviewWidget")
        XCTAssertNotNil(result.widgetData, "Overview should include widget data")
    }

    func testModesHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "help modes", entities: nil)
        XCTAssertTrue(result.text.contains("#research"))
        XCTAssertTrue(result.text.contains("#rewrite"))
        XCTAssertTrue(result.text.contains("#techsupport"))
        XCTAssertTrue(result.text.contains("#rubberduck"))
        XCTAssertFalse(result.text.contains("#create"))
    }

    func testChipsHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "help chips", entities: nil)
        XCTAssertTrue(result.text.contains("#math"))
        XCTAssertTrue(result.text.contains("#search"))
        XCTAssertTrue(result.text.contains("#live"))
        XCTAssertTrue(result.text.contains("#email"))
        XCTAssertFalse(result.text.contains("#create"))
    }

    func testSearchHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "help search", entities: nil)
        XCTAssertTrue(result.text.contains("DuckDuckGo"))
        XCTAssertTrue(result.text.contains("Brave"))
        XCTAssertTrue(result.text.contains("Google"))
    }

    func testSettingsHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "help settings", entities: nil)
        XCTAssertTrue(result.text.contains("Personality"))
        XCTAssertTrue(result.text.contains("Permissions"))
    }
}

// MARK: - Test 5: TechSupport Keyword Dispatch

#if os(macOS)
final class TechSupportToolTests: XCTestCase {

    private var tool: TechSupportTool!

    override func setUp() {
        TestLocationSetup.install()
        tool = TechSupportTool(session: makeStubURLSession())
    }

    func testWiFiDispatch() async throws {
        let result = try await tool.execute(input: "wifi issues", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Wi-Fi"), "Should contain Wi-Fi section")
        XCTAssertTrue(result.isVerifiedData)
    }

    func testStorageDispatch() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "check disk space", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Storage"), "Should contain Storage section")
    }

    func testBatteryDispatch() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "what's draining my battery", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Battery"), "Should contain Battery section")
    }

    func testRunningAppsDispatch() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "what's running on my mac", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Running Apps"), "Should contain Running Apps section")
    }

    func testMemoryDispatch() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "memory usage ram", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Memory"), "Should contain Memory section")
        XCTAssertTrue(result.text.contains("GB"))
    }

    func testLoginItemsDispatch() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "startup login items", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Login Items"), "Should contain Login Items section")
    }

    func testBluetoothDispatch() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "bluetooth devices", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Bluetooth"), "Should contain Bluetooth section")
    }

    func testGeneralDiagnosticsFallback() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "something is wrong with my computer", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Quick System Diagnostics"), "Should fall back to general diagnostics")
        XCTAssertTrue(result.text.contains("macOS"))
    }

    func testForceQuitNoTarget() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "force quit", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Running apps") || result.text.contains("Which app"),
                       "Should list running apps when no target specified")
    }

    func testConsentPolicyRequiresConsent() {
        let tool = self.tool!
        XCTAssertTrue(tool.consentPolicy.needsConsent, "TechSupport actions should require consent")
    }
}
#endif

// MARK: - Test 6: E2E Pipeline Routing

final class NewFeatureRoutingTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Help Tool Routing

    func testHelpChipRouting() async throws {
        let spy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#help")

        XCTAssertEqual(spy.invocations.count, 1, "Help tool should be invoked via #help chip")
    }

    func testHelpChipWithSubtopic() async throws {
        let spy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#help modes")

        XCTAssertEqual(spy.invocations.count, 1)
        XCTAssertTrue(spy.invocations[0].input.contains("modes"), "Sub-topic should be passed through")
    }

    // MARK: - TechSupport Tool Routing

    #if os(macOS)
    func testTechSupportChipRouting() async throws {
        let spy = SpyTool(name: "TechSupport", schema: "tech support troubleshoot fix kill app wifi bluetooth battery")
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#techsupport wifi issues")

        XCTAssertEqual(spy.invocations.count, 1, "TechSupport tool should be invoked via #techsupport chip")
    }

    func testTechSupportModeConfig() {
        let manifest = ToolManifest.entry(for: "TechSupport")
        XCTAssertNotNil(manifest?.modeConfig, "TechSupport should have a modeConfig")
        XCTAssertEqual(manifest?.modeConfig?.displayName, "Tech Support")

        let entryPhrases = manifest?.modeConfig?.entryPhrases ?? []
        XCTAssertTrue(entryPhrases.contains("tech support"), "'tech support' should be an entry phrase")
        XCTAssertTrue(entryPhrases.contains("troubleshoot"), "'troubleshoot' should be an entry phrase")

        let allowedTools = manifest?.modeConfig?.allowedTools ?? []
        XCTAssertTrue(allowedTools.contains("TechSupport"))
        XCTAssertTrue(allowedTools.contains("SystemInfo"))
    }
    #endif

    // MARK: - Dictionary (no chip, still routable)

    func testDictionaryNotInChipAutocomplete() {
        // Dictionary should still be registered as a tool but not show as a chip
        let coreNames = ToolRegistry.coreTools.map { $0.name }
        #if os(macOS)
        XCTAssertTrue(coreNames.contains("Dictionary"), "Dictionary tool should still exist")
        #endif
        XCTAssertNil(ToolManifest.entry(for: "Dictionary")?.chipName, "Dictionary should have no chip")
    }
}

// MARK: - Test 7: Self-Reflective Help System

final class ToolHelpTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Chip+Help Redirect (E2E)

    func testChipHelpRedirectsToHelp() async throws {
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast temperature")
        let helpSpy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [weatherSpy, helpSpy])

        _ = await engine.run(input: "#weather help")

        XCTAssertEqual(weatherSpy.invocations.count, 0, "WeatherTool should NOT be invoked for #weather help")
        XCTAssertEqual(helpSpy.invocations.count, 1, "HelpTool should be invoked for #weather help")
        XCTAssertTrue(helpSpy.invocations[0].input.contains("Weather"), "HelpTool should receive Weather context")
    }

    func testBareChipDoesNotRedirectToHelp() async throws {
        let feedbackSpy = SpyTool(name: "Feedback", schema: "feedback")
        let helpSpy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [feedbackSpy, helpSpy])

        _ = await engine.run(input: "#feedback")

        XCTAssertEqual(feedbackSpy.invocations.count, 1, "#feedback should route to FeedbackTool, not Help")
        XCTAssertEqual(helpSpy.invocations.count, 0, "HelpTool should NOT intercept bare #feedback")
    }

    func testQuestionMarkDoesNotTriggerHelp() async throws {
        let stocksSpy = SpyTool(name: "Stocks", schema: "stocks price ticker")
        let helpSpy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [stocksSpy, helpSpy])

        _ = await engine.run(input: "#stocks ?")

        XCTAssertEqual(stocksSpy.invocations.count, 1, "#stocks ? should route to StocksTool")
        XCTAssertEqual(helpSpy.invocations.count, 0, "? should NOT trigger help redirect")
    }

    func testNormalChipStillRoutesToTool() async throws {
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast temperature")
        let helpSpy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [weatherSpy, helpSpy])

        _ = await engine.run(input: "#weather London")

        XCTAssertEqual(weatherSpy.invocations.count, 1, "WeatherTool should still handle normal chip routing")
        XCTAssertEqual(helpSpy.invocations.count, 0, "HelpTool should NOT be invoked for normal chip query")
    }

    func testBareHelpChipStillWorks() async throws {
        let helpSpy = SpyTool(name: "Help", schema: "help what can you do features capabilities")
        let engine = makeTestEngine(tools: [helpSpy])

        _ = await engine.run(input: "#help")

        XCTAssertEqual(helpSpy.invocations.count, 1, "#help should still route to HelpTool")
    }

    // MARK: - HelpTool Content Dispatch

    func testToolSpecificHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "tool:Weather", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.hasPrefix("[HELP]"), "Should be tagged with [HELP] for BRAIN rule")
        XCTAssertTrue(result.text.contains("WEATHER"), "Should contain tool name header")
        XCTAssertTrue(result.text.contains("#weather"), "Should contain chip name")
        XCTAssertTrue(result.text.contains("EXAMPLE QUERIES"), "Should contain examples section")
        XCTAssertTrue(result.text.contains("user is asking how"), "Should frame the task for the LLM")
    }

    func testToolSpecificHelpCalculator() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "tool:Calculator", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("CALCULATOR"), "Should contain Calculator header")
        XCTAssertTrue(result.text.contains("#calculator"), "Should contain chip name")
    }

    func testToolSpecificHelpUnknownFallback() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "tool:NonexistentTool", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // Should fall back to overview help
        XCTAssertTrue(result.text.contains("[HELP]"), "Should fall back to overview help for unknown tool")
    }

    func testIdentityHelp() async throws {
        let tool = HelpTool()
        let result = try await tool.execute(input: "what is iclaw", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("on-device"), "Identity help should mention on-device")
        XCTAssertTrue(result.text.contains("Apple Intelligence"), "Identity help should mention Apple Intelligence")
    }

    // MARK: - ToolHelpProvider

    func testToolHelpProviderLoads() {
        let help = ToolHelpProvider.help(for: "Weather")
        XCTAssertNotNil(help, "Should load Weather help from ToolHelp.json")
        XCTAssertFalse(help!.description.isEmpty, "Description should not be empty")
        XCTAssertFalse(help!.examples.isEmpty, "Examples should not be empty")
    }

    func testToolHelpProviderCaseInsensitive() {
        let help = ToolHelpProvider.help(for: "weather")
        XCTAssertNotNil(help, "Should find Weather via case-insensitive lookup")
    }

    func testToolNameMatching() {
        XCTAssertEqual(ToolHelpProvider.toolName(matchingInput: "weather help"), "Weather")
        XCTAssertEqual(ToolHelpProvider.toolName(matchingInput: "how do I use the calculator"), "Calculator")
        XCTAssertNil(ToolHelpProvider.toolName(matchingInput: "hello world"))
    }
}
