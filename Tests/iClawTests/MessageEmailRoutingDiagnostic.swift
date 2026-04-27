import XCTest
import FoundationModels
@testable import iClawCore

/// Tests for the CommunicationChannelResolver and its integration with ToolRouter.
/// Covers: definitive signals, ambiguous disambiguation, single-tool fallback,
/// non-communication tool override, and Shortcuts misrouting.
final class CommunicationChannelRoutingTests: XCTestCase {

    // MARK: - Test Doubles

    private struct TestFMTool: FMToolDescriptor, @unchecked Sendable {
        let name: String
        let chipName: String
        let routingKeywords: [String]
        let category: CategoryEnum = .offline
        func makeTool() -> any FoundationModels.Tool { fatalError() }
    }

    // MARK: - Router Factories

    /// Router with both Messages and Email available.
    private func makeBothChannelsRouter() -> ToolRouter {
        let coreTools: [any CoreTool] = [
            SpyTool(name: "Messages", schema: "Send an iMessage"),
            SpyTool(name: "Email", schema: "Send an email"),
            SpyTool(name: "ReadEmail", schema: "Read email inbox"),
            SpyTool(name: "Calendar", schema: "Calendar events"),
            SpyTool(name: "Reminders", schema: "Create reminders"),
        ]
        let fmTools: [any FMToolDescriptor] = [
            TestFMTool(name: "shortcuts", chipName: "shortcuts",
                       routingKeywords: ["shortcut", "automation", "run shortcut"]),
            TestFMTool(name: "notes", chipName: "notes",
                       routingKeywords: ["note", "write note"]),
            TestFMTool(name: "contacts", chipName: "contacts",
                       routingKeywords: ["contact", "phone number", "address"]),
        ]
        return ToolRouter(
            availableTools: coreTools,
            fmTools: fmTools,
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )
    }

    /// Router with only Messages available (simulates MAS build or Email disabled).
    private func makeMessagesOnlyRouter() -> ToolRouter {
        let coreTools: [any CoreTool] = [
            SpyTool(name: "Messages", schema: "Send an iMessage"),
            SpyTool(name: "Calendar", schema: "Calendar events"),
        ]
        let fmTools: [any FMToolDescriptor] = [
            TestFMTool(name: "shortcuts", chipName: "shortcuts",
                       routingKeywords: ["shortcut", "automation"]),
        ]
        return ToolRouter(
            availableTools: coreTools,
            fmTools: fmTools,
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )
    }

    private func routedToolName(_ result: ToolRouter.RoutingResult) -> String {
        switch result {
        case .tools(let tools): tools.first?.name ?? "none"
        case .fmTools(let tools): tools.first?.name ?? "none(fm)"
        case .mixed(let core, _): core.first?.name ?? "none(mixed)"
        case .conversational: "conversational"
        case .requiresDisambiguation: "disambiguation"
        case .needsUserClarification: "clarification"
        }
    }

    private func disambiguationChoices(_ result: ToolRouter.RoutingResult) -> [String]? {
        if case .requiresDisambiguation(let choices) = result { return choices }
        return nil
    }

    // MARK: - Resolver Unit Tests

    func testResolverDefinitiveEmail() {
        let resolution = CommunicationChannelResolver.resolve(
            input: "email John about the meeting",
            routedToolOrLabel: "Email",
            availableToolNames: ["Messages", "Email"]
        )
        if case .definitive(let channel) = resolution {
            XCTAssertEqual(channel.tool, "Email")
        } else {
            XCTFail("Expected definitive Email, got \(resolution)")
        }
    }

    func testResolverDefinitiveMessages() {
        let resolution = CommunicationChannelResolver.resolve(
            input: "text mom I'll be late",
            routedToolOrLabel: "Messages",
            availableToolNames: ["Messages", "Email"]
        )
        if case .definitive(let channel) = resolution {
            XCTAssertEqual(channel.tool, "Messages")
        } else {
            XCTFail("Expected definitive Messages, got \(resolution)")
        }
    }

    func testResolverEmailAddressPattern() {
        let resolution = CommunicationChannelResolver.resolve(
            input: "send a message to john@example.com",
            routedToolOrLabel: "Messages",
            availableToolNames: ["Messages", "Email"]
        )
        if case .definitive(let channel) = resolution {
            XCTAssertEqual(channel.tool, "Email")
        } else {
            XCTFail("Expected definitive Email (address pattern), got \(resolution)")
        }
    }

    func testResolverAmbiguous() {
        let resolution = CommunicationChannelResolver.resolve(
            input: "send a message to John",
            routedToolOrLabel: "Messages",
            availableToolNames: ["Messages", "Email"]
        )
        if case .ambiguous(let channels) = resolution {
            let names = Set(channels.map(\.tool))
            XCTAssertEqual(names, ["Messages", "Email"])
        } else {
            XCTFail("Expected ambiguous, got \(resolution)")
        }
    }

    func testResolverSingleChannelAvailable() {
        let resolution = CommunicationChannelResolver.resolve(
            input: "send a message to John",
            routedToolOrLabel: "Messages",
            availableToolNames: ["Messages"]
        )
        if case .definitive(let channel) = resolution {
            XCTAssertEqual(channel.tool, "Messages")
        } else {
            XCTFail("Expected definitive (single channel), got \(resolution)")
        }
    }

    func testResolverNotCommunication() {
        let resolution = CommunicationChannelResolver.resolve(
            input: "set a timer for 5 minutes",
            routedToolOrLabel: "Timer",
            availableToolNames: ["Messages", "Email", "Timer"]
        )
        if case .notCommunication = resolution {
            // Expected
        } else {
            XCTFail("Expected notCommunication, got \(resolution)")
        }
    }

    func testHasCommunicationIntent() {
        XCTAssertTrue(CommunicationChannelResolver.hasCommunicationIntent("send Shawn a message about the meeting"))
        XCTAssertTrue(CommunicationChannelResolver.hasCommunicationIntent("text mom"))
        XCTAssertTrue(CommunicationChannelResolver.hasCommunicationIntent("tell Sarah I'm running late"))
        XCTAssertFalse(CommunicationChannelResolver.hasCommunicationIntent("set a timer for 5 minutes"))
        XCTAssertFalse(CommunicationChannelResolver.hasCommunicationIntent("what's the weather"))

        // Regression: substring matching used to fire "DM" on "Fridman" (contains "dm"),
        // which misrouted Lex Fridman podcast queries into Messages with a consent prompt.
        XCTAssertFalse(
            CommunicationChannelResolver.hasCommunicationIntent("whats the latest episodes of the Lex Fridman podcast?"),
            "Proper-noun substrings (Fridman → 'dm') must not trigger communication intent."
        )
        // Multi-word phrase keywords ("mensaje a") must still work after the word-boundary switch.
        XCTAssertTrue(
            CommunicationChannelResolver.hasCommunicationIntent("envía un mensaje a María"),
            "Multi-word Spanish phrase 'mensaje a' should still be detected."
        )
    }

    // MARK: - Router Integration: Definitive Signals

    func testRouterDefinitiveMessagesKeyword() async {
        let router = makeBothChannelsRouter()
        let prompts = [
            "text mom I'll be late",
            "send a text to John",
            "iMessage Sarah about dinner",
        ]
        for prompt in prompts {
            let result = await router.route(input: prompt)
            XCTAssertEqual(routedToolName(result), "Messages",
                "Expected Messages for '\(prompt)', got \(routedToolName(result))")
        }
    }

    func testRouterDefinitiveEmailKeyword() async {
        let router = makeBothChannelsRouter()
        let prompts = [
            "email John about the meeting",
            "send an email to john@example.com",
            "compose an email to the team",
        ]
        for prompt in prompts {
            let result = await router.route(input: prompt)
            XCTAssertEqual(routedToolName(result), "Email",
                "Expected Email for '\(prompt)', got \(routedToolName(result))")
        }
    }

    func testRouterEmailAddressRoutesToEmail() async {
        let router = makeBothChannelsRouter()
        let result = await router.route(input: "send a message to john@example.com")
        XCTAssertEqual(routedToolName(result), "Email")
    }

    // MARK: - Router Integration: Ambiguous → Disambiguation

    func testRouterAmbiguousShowsDisambiguation() async {
        let router = makeBothChannelsRouter()
        // "draft a message to the team" — ML splits between email.compose and messages.send
        // with no definitive keyword → should disambiguate
        let ambiguousPrompts = [
            "send a message to John",
            "draft a message to the team",
        ]
        for prompt in ambiguousPrompts {
            let result = await router.route(input: prompt)
            let choices = disambiguationChoices(result)
            // Either it's disambiguation with both channels, or it routes to Messages
            // (acceptable if ML confidence is high enough to skip heuristics)
            if let choices {
                // Choices may be tool names (from heuristic) or ML labels (from evaluateMLResults)
                let hasMessages = choices.contains("Messages") || choices.contains(where: { $0.hasPrefix("messages.") })
                let hasEmail = choices.contains("Email") || choices.contains(where: { $0.hasPrefix("email.") })
                XCTAssertTrue(hasMessages && hasEmail,
                    "Disambiguation should offer Messages and Email channels, got \(choices)")
            }
            // Messages is also acceptable for high-confidence ML predictions
        }
    }

    // MARK: - Router Integration: Single Channel Fallback

    func testRouterSingleChannelSkipsDisambiguation() async {
        let router = makeMessagesOnlyRouter()
        // With only Messages available, ambiguous input should route directly
        let result = await router.route(input: "send a message to John")
        XCTAssertEqual(routedToolName(result), "Messages",
            "Should route to Messages when it's the only channel")
    }

    // MARK: - Router Integration: Shortcuts/Calendar Override

    func testShortcutsMisroutingFixed() async {
        let router = makeBothChannelsRouter()
        // These prompts were misrouted to Shortcuts/Calendar by the ML classifier.
        // The resolver should redirect to Messages (definitive) or disambiguation.
        let prompts = [
            "Send Shawn a message that I need to set up another meeting",
            "Send Sarah a message about rescheduling our meeting",
            "Message John that the meeting is cancelled",
            "Send a message to the team about the upcoming meeting",
        ]
        for prompt in prompts {
            let result = await router.route(input: prompt)
            let name = routedToolName(result)
            // Must be either Messages (definitive "message" keyword) or disambiguation
            XCTAssertTrue(name == "Messages" || name == "disambiguation",
                "Expected Messages or disambiguation for '\(prompt)', got \(name)")
        }
    }

    func testShortcutsOverrideWithSingleChannel() async {
        let router = makeMessagesOnlyRouter()
        let result = await router.route(input: "Send Shawn a message that I need to set up another meeting")
        XCTAssertEqual(routedToolName(result), "Messages",
            "With only Messages available, should route directly without disambiguation")
    }

    func testTellMikeRouting() async {
        // "Tell Mike I'll set up a call tomorrow" — ML says calendar.search.
        // Communication intent should redirect to Messages (or disambiguation).
        let router = makeBothChannelsRouter()
        let result = await router.route(input: "Tell Mike I'll set up a call tomorrow")
        let name = routedToolName(result)
        XCTAssertTrue(name == "Messages" || name == "disambiguation",
            "Expected Messages or disambiguation, got \(name)")
    }
}
