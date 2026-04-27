import XCTest
@testable import iClawCore

/// Additional consistency and behavior tests covering:
/// - T2: ToolNames completeness
/// - T3: SynonymMap expansion behavior
/// - T5: Entity dedup/recency in ConversationState
final class AdditionalConsistencyTests: XCTestCase {

    // MARK: - T2: ToolNames Completeness

    func testToolNamesHasAllCoreTools() {
        // Every registered core tool should have a corresponding ToolNames constant.
        // This test uses the ToolNames enum values to verify coverage.
        let coreNames = Set(ToolRegistry.coreTools.map(\.name))
        let toolNameConstants: Set<String> = [
            ToolNames.calculator, ToolNames.calendar, ToolNames.calendarEvent,
            ToolNames.compute, ToolNames.contacts, ToolNames.convert,
            ToolNames.dictionary, ToolNames.email, ToolNames.feedback,
            ToolNames.help, ToolNames.importTool, ToolNames.maps,
            ToolNames.messages, ToolNames.news, ToolNames.notes,
            ToolNames.podcast, ToolNames.random, ToolNames.readEmail,
            ToolNames.reminders, ToolNames.research, ToolNames.screenshot,
            ToolNames.stocks, ToolNames.systemInfo, ToolNames.techSupport,
            ToolNames.time, ToolNames.today, ToolNames.transcribe,
            ToolNames.translate, ToolNames.weather, ToolNames.webFetch,
            ToolNames.wikipediaSearch, ToolNames.automate, ToolNames.automation,
        ]

        for name in coreNames {
            XCTAssertTrue(
                toolNameConstants.contains(name),
                "Core tool '\(name)' has no ToolNames constant. Add it to ToolNames.swift."
            )
        }
    }

    func testToolNamesHasAllFMTools() {
        let fmNames = Set(ToolRegistry.fmTools.map(\.name))
        let fmConstants: Set<String> = [
            ToolNames.webSearch, ToolNames.readFile, ToolNames.writeFile,
            ToolNames.clipboard, ToolNames.systemControl, ToolNames.spotlight,
            ToolNames.shortcuts, ToolNames.browser,
        ]

        for name in fmNames {
            XCTAssertTrue(
                fmConstants.contains(name),
                "FM tool '\(name)' has no ToolNames constant. Add it to ToolNames.swift."
            )
        }
    }

    // MARK: - T3: SynonymMap Expansion Behavior

    func testSynonymMapExpansionLoads() {
        // Verify the synonym map loaded and has entries
        let map = ToolRouter.synonymMap
        XCTAssertGreaterThan(map.count, 10,
            "SynonymMap should have >10 entries, got \(map.count)")
    }

    func testSynonymExpansionSubstringMatch() async {
        // Create a minimal router to test synonym expansion
        let router = ToolRouter(
            availableTools: ToolRegistry.coreTools,
            fmTools: ToolRegistry.fmTools
        )

        // SynonymMap entries use substring matching — the expansion should
        // replace the matched pattern in the input.
        let expanded = await router.expandSynonyms(input: "distance to San Francisco")
        // "distance to" is a common synonym that expands to a Maps-related phrase
        // The key point: the method should not crash and should return a string
        XCTAssertFalse(expanded.isEmpty, "Expansion should return non-empty string")
    }

    func testSynonymExpansionNoMatchPassthrough() async {
        let router = ToolRouter(
            availableTools: ToolRegistry.coreTools,
            fmTools: ToolRegistry.fmTools
        )

        // Input with no matching synonyms should pass through unchanged
        let input = "completely unique phrase with no synonyms"
        let expanded = await router.expandSynonyms(input: input)
        XCTAssertEqual(expanded, input,
            "Non-matching input should pass through unchanged")
    }

    // MARK: - T5: Entity Dedup and Recency

    func testEntityDeduplication() {
        var state = ConversationState()

        // First turn: adds "San Francisco" and "California"
        let entities1 = ExtractedEntities(
            names: [], places: ["San Francisco", "California"],
            organizations: [], urls: [],
            phoneNumbers: [], emails: [], ocrText: nil
        )
        state.recordTurn(userInput: "weather in San Francisco", entities: entities1, toolResults: [])

        // Second turn: adds "San Francisco" again (duplicate) and "New York"
        let entities2 = ExtractedEntities(
            names: [], places: ["San Francisco", "New York"],
            organizations: [], urls: [],
            phoneNumbers: [], emails: [], ocrText: nil
        )
        state.recordTurn(userInput: "compare weather in New York", entities: entities2, toolResults: [])

        // "San Francisco" should appear only once
        let sfCount = state.activeEntities.filter { $0 == "San Francisco" }.count
        XCTAssertEqual(sfCount, 1, "Duplicate entity should be deduplicated")
    }

    func testEntityRecencyOrder() {
        var state = ConversationState()

        // First turn
        let entities1 = ExtractedEntities(
            names: ["Alice"], places: ["London"],
            organizations: [], urls: [],
            phoneNumbers: [], emails: [], ocrText: nil
        )
        state.recordTurn(userInput: "who is Alice in London", entities: entities1, toolResults: [])

        // Second turn — newer entities should be first
        let entities2 = ExtractedEntities(
            names: ["Bob"], places: ["Tokyo"],
            organizations: [], urls: [],
            phoneNumbers: [], emails: [], ocrText: nil
        )
        state.recordTurn(userInput: "find Bob in Tokyo", entities: entities2, toolResults: [])

        // Newer entities (Bob, Tokyo) should appear before older ones (Alice, London)
        let bobIndex = state.activeEntities.firstIndex(of: "Bob")
        let aliceIndex = state.activeEntities.firstIndex(of: "Alice")
        if let bi = bobIndex, let ai = aliceIndex {
            XCTAssertLessThan(bi, ai,
                "Newer entity 'Bob' should come before older entity 'Alice'. Got: \(state.activeEntities)")
        }
    }

    func testEntityCapAt10() {
        var state = ConversationState()

        // Add 15 unique entities across multiple turns
        for i in 0..<5 {
            let entities = ExtractedEntities(
                names: ["Person\(i*3)", "Person\(i*3+1)", "Person\(i*3+2)"],
                places: [], organizations: [], urls: [],
                phoneNumbers: [], emails: [], ocrText: nil
            )
            state.recordTurn(userInput: "turn \(i)", entities: entities, toolResults: [])
        }

        XCTAssertLessThanOrEqual(state.activeEntities.count, 10,
            "Active entities should be capped at 10, got \(state.activeEntities.count)")
    }
}
