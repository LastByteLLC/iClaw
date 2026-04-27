import XCTest
@testable import iClawCore

final class SkillModeTests: XCTestCase {

    // MARK: - ToolManifest Mode Lookup

    func testModeForChipReturnsRubberDuck() {
        let result = ToolManifest.modeForChip("rubberduck")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "RubberDuck")
        XCTAssertEqual(result?.config.displayName, "Rubber Duck")
        XCTAssertTrue(result?.config.allowedTools.isEmpty ?? false)
    }

    func testModeForChipReturnsNilForNonMode() {
        XCTAssertNil(ToolManifest.modeForChip("weather"))
        XCTAssertNil(ToolManifest.modeForChip("Stocks"))
    }

    func testModeForPhraseMatchesEntryPhrases() {
        XCTAssertNotNil(ToolManifest.modeForPhrase("rubber duck"))
        XCTAssertNotNil(ToolManifest.modeForPhrase("let me think out loud"))
        XCTAssertNotNil(ToolManifest.modeForPhrase("I want to do some rubber ducking"))
        XCTAssertNotNil(ToolManifest.modeForPhrase("help me debug my thinking"))
    }

    func testModeForPhraseReturnsNilForNonMode() {
        XCTAssertNil(ToolManifest.modeForPhrase("what's the weather"))
        XCTAssertNil(ToolManifest.modeForPhrase("tell me a joke"))
    }

    func testAllModeChipNamesContainsRubberDuck() {
        let chips = ToolManifest.allModeChipNames
        XCTAssertTrue(chips.contains("rubberduck"))
    }

    // MARK: - Router Mode Activation via Chip

    func testChipActivatesMode() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        let result = await router.route(input: "#rubberduck help me think")
        if case .conversational = result {
            // Expected
        } else {
            XCTFail("Expected conversational routing for mode activation, got \(result)")
        }
        let isActive = await router.isInMode
        XCTAssertTrue(isActive)
        let modeName = await router.activeMode?.name
        XCTAssertEqual(modeName, "RubberDuck")
    }

    // MARK: - Router Mode Persistence

    func testModePersistsAcrossTurns() async {
        let router = ToolRouter(availableTools: [], fmTools: [])

        // Activate
        _ = await router.route(input: "#rubberduck")
        var isActive = await router.isInMode
        XCTAssertTrue(isActive)

        // Second turn — mode should still be active
        let result = await router.route(input: "I think the bug is in the parser")
        if case .conversational = result {} else {
            XCTFail("Expected conversational while in mode")
        }
        isActive = await router.isInMode
        XCTAssertTrue(isActive)

        // Third turn
        _ = await router.route(input: "Actually maybe it's the tokenizer")
        isActive = await router.isInMode
        XCTAssertTrue(isActive)
    }

    // MARK: - Router Mode Exit via Phrase

    func testExitPhraseDeactivatesMode() async {
        let router = ToolRouter(availableTools: [], fmTools: [])

        // Activate
        _ = await router.route(input: "#rubberduck")
        var isActive = await router.isInMode
        XCTAssertTrue(isActive)

        // Exit via phrase
        _ = await router.route(input: "I'm done")
        isActive = await router.isInMode
        XCTAssertFalse(isActive)
    }

    func testExitPhraseVariants() async {
        let phrases = ["stop rubber ducking", "im done", "exit rubber duck", "done thinking", "stop ducking"]
        for phrase in phrases {
            let router = ToolRouter(availableTools: [], fmTools: [])
            _ = await router.route(input: "#rubberduck")
            var isActive = await router.isInMode
            XCTAssertTrue(isActive, "Should be in mode before exit")
            _ = await router.route(input: phrase)
            isActive = await router.isInMode
            XCTAssertFalse(isActive, "Exit phrase '\(phrase)' should deactivate mode")
        }
    }

    // MARK: - Router Mode Exit via Chip Toggle

    func testChipToggleDeactivatesMode() async {
        let router = ToolRouter(availableTools: [], fmTools: [])

        // Activate
        _ = await router.route(input: "#rubberduck")
        var isActive = await router.isInMode
        XCTAssertTrue(isActive)

        // Toggle off via same chip
        _ = await router.route(input: "#rubberduck")
        isActive = await router.isInMode
        XCTAssertFalse(isActive)
    }

    // MARK: - Router Mode Entry via Natural Language

    func testEntryPhraseActivatesMode() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "let me think out loud")
        let isActive = await router.isInMode
        XCTAssertTrue(isActive)
        let modeName = await router.activeMode?.name
        XCTAssertEqual(modeName, "RubberDuck")
    }

    // MARK: - Mode Sets Skill with System Prompt

    func testModeSetsSkillWithSystemPrompt() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#rubberduck")
        let skill = await router.currentSkill
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.name, "RubberDuck")
        XCTAssertTrue(skill?.systemPrompt.contains("rubber duck") ?? false)
    }

    // MARK: - Mode Group ID

    func testModeGroupIdIsSetOnActivation() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#rubberduck")
        let groupId = await router.activeModeGroupId
        XCTAssertNotNil(groupId)
    }

    func testModeGroupIdClearedOnExit() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#rubberduck")
        _ = await router.route(input: "I'm done")
        let groupId = await router.activeModeGroupId
        XCTAssertNil(groupId)
    }

    // MARK: - ModeConfig Decoding

    func testModeConfigDecodesFromManifest() {
        let entry = ToolManifest.entry(for: "RubberDuck")
        XCTAssertNotNil(entry)
        XCTAssertNotNil(entry?.modeConfig)
        XCTAssertEqual(entry?.modeConfig?.exitPhrases.count, 6)
        XCTAssertEqual(entry?.modeConfig?.entryPhrases.count, 5)
        XCTAssertEqual(entry?.chipName, "rubberduck")
    }

    func testNonModeToolHasNilModeConfig() {
        let entry = ToolManifest.entry(for: "Weather")
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.modeConfig)
    }

    // MARK: - Engine Passthroughs

    func testEngineExposesActiveMode() async {
        let spy = SpyTool(name: "Weather", schema: "weather")
        let engine = makeTestEngine(tools: [spy])

        // No mode initially
        let noMode = await engine.activeSkillMode()
        XCTAssertNil(noMode)

        // Activate via router
        _ = await engine.run(input: "#rubberduck")
        let mode = await engine.activeSkillMode()
        XCTAssertEqual(mode?.name, "RubberDuck")
    }

    // MARK: - Message Mode Fields

    func testMessageModeGroupIdDefault() {
        let msg = Message(role: "user", content: "test")
        XCTAssertNil(msg.modeGroupId)
        XCTAssertFalse(msg.isModeSummary)
        XCTAssertNil(msg.modeSummary)
    }

    func testMessageModeGroupIdInit() {
        let gid = UUID()
        let msg = Message(role: "user", content: "test", modeGroupId: gid)
        XCTAssertEqual(msg.modeGroupId, gid)
    }

    // MARK: - Mode Skill Persists Across Turns

    func testModeSkillPersistsAcrossTurns() async {
        let router = ToolRouter(availableTools: [], fmTools: [])

        _ = await router.route(input: "#rubberduck")
        var skill = await router.currentSkill
        XCTAssertEqual(skill?.name, "RubberDuck")

        // Second turn — skill should be re-set by mode override
        _ = await router.route(input: "the problem is in the parser")
        skill = await router.currentSkill
        XCTAssertEqual(skill?.name, "RubberDuck")
    }

    // MARK: - Tint Color

    func testModeConfigHasTintColor() {
        let entry = ToolManifest.entry(for: "RubberDuck")
        XCTAssertEqual(entry?.modeConfig?.tintColor, "#FFCC00")
    }

    func testNonModeToolHasNoTintColor() {
        let entry = ToolManifest.entry(for: "Weather")
        XCTAssertNil(entry?.modeConfig?.tintColor)
    }

    // MARK: - Research Mode

    func testResearchModeConfigExists() {
        let entry = ToolManifest.entry(for: "Research")
        XCTAssertNotNil(entry?.modeConfig)
        XCTAssertEqual(entry?.modeConfig?.displayName, "Research")
        XCTAssertEqual(entry?.modeConfig?.allowedTools, ["Research", "web_search", "WebFetch", "WikipediaSearch", "read_file"])
        XCTAssertEqual(entry?.modeConfig?.tintColor, "#4A90D9")
    }

    func testResearchModeActivatesViaChip() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#research quantum computing")
        let isActive = await router.isInMode
        XCTAssertTrue(isActive)
        let modeName = await router.activeMode?.name
        XCTAssertEqual(modeName, "Research")
    }

    func testResearchModeActivatesViaPhrase() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "research mode")
        let isActive = await router.isInMode
        XCTAssertTrue(isActive)
    }

    func testResearchModeExits() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#research")
        _ = await router.route(input: "done researching")
        let isActive = await router.isInMode
        XCTAssertFalse(isActive)
    }

    // MARK: - Create Mode (disabled — no modeConfig since Image Playground is unstable)

    func testCreateModeConfigRemoved() {
        let entry = ToolManifest.entry(for: "Create")
        XCTAssertNotNil(entry, "Create entry should exist in manifest")
        XCTAssertNil(entry?.modeConfig, "Create should not have modeConfig while disabled")
    }

    // MARK: - Rewrite Mode

    func testRewriteModeConfigExists() {
        let entry = ToolManifest.entry(for: "Rewrite")
        XCTAssertNotNil(entry?.modeConfig)
        XCTAssertEqual(entry?.modeConfig?.displayName, "Rewrite")
        XCTAssertEqual(entry?.modeConfig?.allowedTools, ["Rewrite"])
        XCTAssertEqual(entry?.modeConfig?.tintColor, "#50C878")
    }

    func testRewriteModeActivatesViaChip() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#rewrite this paragraph")
        let isActive = await router.isInMode
        XCTAssertTrue(isActive)
        let modeName = await router.activeMode?.name
        XCTAssertEqual(modeName, "Rewrite")
    }

    func testRewriteModeActivatesViaPhrase() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "editing session")
        let isActive = await router.isInMode
        XCTAssertTrue(isActive)
    }

    func testRewriteModeExits() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        _ = await router.route(input: "#rewrite")
        _ = await router.route(input: "looks good")
        let isActive = await router.isInMode
        XCTAssertFalse(isActive)
    }

    // MARK: - Tool-Based Mode Routes to Allowed Tools

    func testResearchModeRoutesToAllowedTools() async {
        let researchSpy = SpyTool(name: "Research", schema: "research")
        let weatherSpy = SpyTool(name: "Weather", schema: "weather")
        let router = ToolRouter(availableTools: [researchSpy, weatherSpy], fmTools: [])

        // Activate research mode
        _ = await router.route(input: "#research")

        // Next turn should route to Research tools, not Weather
        let result = await router.route(input: "tell me about quantum physics")
        switch result {
        case .tools(let tools):
            let names = tools.map(\.name)
            XCTAssertTrue(names.contains("Research"), "Should route to Research tool")
            XCTAssertFalse(names.contains("Weather"), "Should NOT route to Weather in research mode")
        default:
            // Conversational is also acceptable if Research isn't in the filtered set
            break
        }
    }

    // MARK: - First-Turn Tool Routing

    func testFirstTurnRoutesToToolsNotConversational() async {
        let researchSpy = SpyTool(name: "Research", schema: "research")
        let router = ToolRouter(availableTools: [researchSpy], fmTools: [])

        // Non-bare chip (#research + text) routes to the tool directly, not mode.
        // Mode activation requires bare chip only (#research with no trailing text).
        let result = await router.route(input: "#research the matrix protocol")

        if case .tools(let tools) = result {
            XCTAssertTrue(tools.contains(where: { $0.name == "Research" }))
        } else {
            XCTFail("Expected .tools routing on first turn, got \(result)")
        }

        // Bare chip activates mode
        let bareResult = await router.route(input: "#research")
        let isActive = await router.isInMode
        XCTAssertTrue(isActive, "Bare chip should activate mode")
        if case .conversational = bareResult {
            // Expected — mode routing with no additional text
        } else if case .tools = bareResult {
            // Also acceptable — mode routes to Research tool
        } else {
            XCTFail("Expected tools or conversational for bare mode chip, got \(bareResult)")
        }
    }

    func testFirstTurnRubberDuckStaysConversational() async {
        let router = ToolRouter(availableTools: [], fmTools: [])
        let result = await router.route(input: "#rubberduck help me think")
        if case .conversational = result {
            // Expected — rubber duck has no allowed tools
        } else {
            XCTFail("Rubber duck should stay conversational")
        }
    }

    // MARK: - Suggestion Parsing

    @MainActor func testParseSuggestionsExtractsLines() {
        let response = """
        The Matrix protocol is an open standard for decentralized communication.

        >> Matrix vs XMPP comparison
        >> End-to-end encryption details
        >> Self-hosting a homeserver
        """
        let (text, suggestions) = ChatView.parseSuggestions(from: response)
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(suggestions[0], "Matrix vs XMPP comparison")
        XCTAssertEqual(suggestions[1], "End-to-end encryption details")
        XCTAssertEqual(suggestions[2], "Self-hosting a homeserver")
        XCTAssertFalse(text.contains(">>"))
        XCTAssertTrue(text.contains("Matrix protocol"))
    }

    @MainActor func testParseSuggestionsWithNoSuggestions() {
        let response = "Just a normal response with no follow-ups."
        let (text, suggestions) = ChatView.parseSuggestions(from: response)
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertEqual(text, response)
    }

    @MainActor func testParseSuggestionsTrimsTrailingBlanks() {
        let response = "Content here.\n\n>> Follow up one\n>> Follow up two\n"
        let (text, suggestions) = ChatView.parseSuggestions(from: response)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(text, "Content here.")
    }
}
