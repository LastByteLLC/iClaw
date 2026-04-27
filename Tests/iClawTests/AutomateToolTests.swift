import XCTest
import FoundationModels
@testable import iClawCore

final class AutomateToolTests: XCTestCase {

    override func setUp() async throws {
        await ScriptCache.shared.clear()
    }

    // MARK: - Response Parsing

    func testParseScriptFromCodeBlock() {
        let response = """
        DESCRIPTION: Renames all .txt files on the desktop to .md
        ```applescript
        tell application "Finder"
            set txtFiles to every file of desktop whose name extension is "txt"
            repeat with f in txtFiles
                set name extension of f to "md"
            end repeat
        end tell
        ```
        """
        let parsed = AutomateTool.parseScriptResponse(response)
        XCTAssertEqual(parsed.description, "Renames all .txt files on the desktop to .md")
        XCTAssertTrue(parsed.script.contains("tell application \"Finder\""))
        XCTAssertTrue(parsed.script.contains("end tell"))
        XCTAssertTrue(parsed.script.contains("name extension"))
    }

    func testParseScriptWithoutCodeBlock() {
        let response = """
        DESCRIPTION: Opens Safari
        tell application "Safari"
            activate
        end tell
        """
        let parsed = AutomateTool.parseScriptResponse(response)
        XCTAssertEqual(parsed.description, "Opens Safari")
        XCTAssertTrue(parsed.script.contains("tell application \"Safari\""))
        XCTAssertTrue(parsed.script.contains("activate"))
    }

    func testParseScriptEmptyResponse() {
        let parsed = AutomateTool.parseScriptResponse("I can't generate that.")
        XCTAssertTrue(parsed.script.isEmpty)
        XCTAssertTrue(parsed.description.isEmpty)
    }

    func testParseScriptNestedTellBlocks() {
        let response = """
        DESCRIPTION: Copies a file
        ```applescript
        tell application "Finder"
            tell folder "Documents" of home
                duplicate file "test.txt" to desktop
            end tell
        end tell
        ```
        """
        let parsed = AutomateTool.parseScriptResponse(response)
        XCTAssertTrue(parsed.script.contains("tell folder"))
        XCTAssertTrue(parsed.script.hasPrefix("tell application"))
    }

    // MARK: - App Catalog

    func testListCapabilities() {
        let capabilities = AutomateTool.listCapabilities()
        XCTAssertTrue(capabilities.contains("Finder"), "Should list Finder")
        XCTAssertTrue(capabilities.contains("Safari"), "Should list Safari")
        XCTAssertTrue(capabilities.contains("Mail"), "Should list Mail")
        XCTAssertTrue(capabilities.contains("Calendar"), "Should list Calendar")
        XCTAssertTrue(capabilities.contains("System Events"), "Should list System Events")
    }

    func testFindRelevantAppsForEmail() {
        let apps = AutomateTool.findRelevantApps(for: "send an email to John")
        XCTAssertTrue(apps.contains(where: { $0.name == "Mail" }), "Should match Mail for 'email'")
    }

    func testFindRelevantAppsForFiles() {
        let apps = AutomateTool.findRelevantApps(for: "rename files on desktop")
        XCTAssertTrue(apps.contains(where: { $0.name == "Finder" }), "Should match Finder for 'files'")
    }

    func testFindRelevantAppsForMusic() {
        let apps = AutomateTool.findRelevantApps(for: "play my playlist in Music")
        XCTAssertTrue(apps.contains(where: { $0.name == "Music" }), "Should match Music")
    }

    func testFindRelevantAppsForReminders() {
        let apps = AutomateTool.findRelevantApps(for: "create a reminder")
        XCTAssertTrue(apps.contains(where: { $0.name == "Reminders" }), "Should match Reminders")
    }

    func testFindRelevantAppsForBrowser() {
        let apps = AutomateTool.findRelevantApps(for: "open a URL in Safari")
        XCTAssertTrue(apps.contains(where: { $0.name == "Safari" }), "Should match Safari")
    }

    func testFindRelevantAppsForSystemEvents() {
        let apps = AutomateTool.findRelevantApps(for: "click a button using System Events")
        XCTAssertTrue(apps.contains(where: { $0.name == "System Events" }), "Should match System Events")
    }

    // MARK: - Prompt Building

    func testBuildGenerationPromptFirstAttempt() {
        let prompt = AutomateTool.buildGenerationPrompt(
            request: "send an email",
            appContext: "Mail: email",
            previousScript: nil,
            syntaxError: nil
        )
        XCTAssertTrue(prompt.contains("send an email"))
        XCTAssertTrue(prompt.contains("Mail: email"))
        XCTAssertFalse(prompt.contains("syntax error"), "First attempt should not mention errors")
    }

    func testBuildGenerationPromptWithSyntaxError() {
        let prompt = AutomateTool.buildGenerationPrompt(
            request: "send an email",
            appContext: "Mail: email",
            previousScript: "tell application \"Mail\"\nend",
            syntaxError: "Expected \"end tell\" but found \"end\""
        )
        XCTAssertTrue(prompt.contains("syntax error"))
        XCTAssertTrue(prompt.contains("Expected \"end tell\""))
        XCTAssertTrue(prompt.contains("tell application \"Mail\""))
    }

    // MARK: - Tool Execution (with DI)

    func testEmptyInputListsCapabilities() async throws {
        let tool = AutomateTool()
        let result = try await tool.execute(input: "#automate", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Finder"))
        XCTAssertTrue(result.text.contains("Safari"))
        XCTAssertTrue(result.text.contains("#automate"))
        XCTAssertNil(result.outputWidget, "Capabilities listing should not show widget")
    }

    func testEmptyInputWithWhitespace() async throws {
        let tool = AutomateTool()
        let result = try await tool.execute(input: "#automate   ", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("I can create AppleScript automations"))
    }

    func testSuccessfulScriptGeneration() async throws {
        let scriptSource = """
        tell application "Finder"
            activate
        end tell
        """
        let llmResponse = """
        DESCRIPTION: Activates Finder
        ```applescript
        \(scriptSource)
        ```
        """

        let tool = AutomateTool(
            llmResponder: { prompt, _ in
                if prompt.contains("Does this AppleScript accomplish") { return "PASS" }
                return llmResponse
            },
            scriptRunner: { _ in (success: true, output: "", error: nil) }
        )

        let result = try await tool.execute(input: "#automate open Finder", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "AutomateWidget")

        if let data = result.widgetData as? AutomateWidgetData {
            XCTAssertTrue(data.script.contains("tell application \"Finder\""))
            XCTAssertEqual(data.description, "Activates Finder")
            XCTAssertEqual(data.iterations, 1, "Should succeed on first iteration")
        } else {
            XCTFail("Widget data should be AutomateWidgetData")
        }
    }

    func testReActLoopFixesSyntaxError() async throws {
        let badScript = """
        tell application "Finder"
            activate
        end
        """
        let goodScript = """
        tell application "Finder"
            activate
        end tell
        """
        let callCount = AtomicCounter()

        let tool = AutomateTool(
            llmResponder: { prompt, _ in
                if prompt.contains("Does this AppleScript accomplish") { return "PASS" }
                let count = callCount.increment()
                if count == 1 {
                    return "DESCRIPTION: Opens Finder\n```applescript\n\(badScript)\n```"
                } else {
                    return "DESCRIPTION: Opens Finder\n```applescript\n\(goodScript)\n```"
                }
            },
            scriptRunner: { script in
                // The bad script ends with "end" instead of "end tell"
                let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasSuffix("end") {
                    return (success: false, output: "", error: "Expected \"end tell\" but found \"end\"")
                }
                return (success: true, output: "", error: nil)
            }
        )

        let result = try await tool.execute(input: "#automate open Finder", entities: nil)
        XCTAssertEqual(result.status, .ok)

        if let data = result.widgetData as? AutomateWidgetData {
            XCTAssertTrue(data.script.contains("end tell"))
            XCTAssertEqual(data.iterations, 2, "Should take 2 iterations to fix syntax")
        } else {
            XCTFail("Widget data should be AutomateWidgetData")
        }
    }

    func testReActLoopMaxIterations() async throws {
        let tool = AutomateTool(
            llmResponder: { _, _ in
                "DESCRIPTION: Bad script\n```applescript\ntell\n```"
            },
            scriptRunner: { _ in
                (success: false, output: "", error: "Syntax error")
            }
        )

        let result = try await tool.execute(input: "#automate do something", entities: nil)
        XCTAssertEqual(result.status, .ok) // Returns script anyway with warning

        if let data = result.widgetData as? AutomateWidgetData {
            XCTAssertEqual(data.iterations, AutomateTool.maxIterations)
        } else {
            XCTFail("Widget data should be AutomateWidgetData")
        }
    }

    func testLLMFailureReturnsError() async throws {
        struct TestError: Error {}
        let tool = AutomateTool(
            llmResponder: { _, _ in throw TestError() }
        )

        let result = try await tool.execute(input: "#automate send email", entities: nil)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("Failed to generate"))
    }

    func testEmptyScriptReturnsError() async throws {
        let tool = AutomateTool(
            llmResponder: { _, _ in "I can't generate that script." }
        )

        let result = try await tool.execute(input: "#automate do something impossible", entities: nil)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("couldn't generate"))
    }

    func testWidgetDataContainsAppNames() async throws {
        let tool = AutomateTool(
            llmResponder: { prompt, _ in
                if prompt.contains("Does this AppleScript accomplish") { return "PASS" }
                return "DESCRIPTION: Sends email\n```applescript\ntell application \"Mail\"\nactivate\nend tell\n```"
            },
            scriptRunner: { _ in (success: true, output: "", error: nil) }
        )

        let result = try await tool.execute(input: "#automate send an email", entities: nil)
        XCTAssertEqual(result.status, .ok)

        if let data = result.widgetData as? AutomateWidgetData {
            XCTAssertTrue(data.apps.contains("Mail"), "Apps should include Mail")
        } else {
            XCTFail("Widget data should be AutomateWidgetData")
        }
    }

    // MARK: - Chip Routing E2E

    func testAutomateChipRouting() async throws {
        let spy = SpyTool(
            name: "Automate",
            schema: "Create AppleScript automations",
            result: ToolIO(text: "automation result", status: .ok, outputWidget: "AutomateWidget")
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "#automate rename files")

        XCTAssertEqual(spy.invocations.count, 1, "Automate tool should be called via chip")
        XCTAssertFalse(spy.invocations.first!.input.contains("#"), "Chip should be stripped")
        XCTAssertTrue(spy.invocations.first!.input.contains("rename files"))
    }

    func testAutomateChipNotTriggeredByNaturalLanguage() async throws {
        let spy = SpyTool(
            name: "Automate",
            schema: "Create AppleScript automations"
        )
        let engine = makeTestEngine(
            tools: [spy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "none"),
            engineLLMResponder: makeStubLLMResponder()
        )

        // Natural language without #automate chip — should NOT route to AutomateTool
        // since it's chip-only (not in ML training data)
        let _ = await engine.run(input: "create an automation script")

        XCTAssertEqual(spy.invocations.count, 0, "Automate should only trigger via #automate chip")
    }
}
