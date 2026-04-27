import XCTest
@testable import iClawCore

final class ReadEmailToolTests: XCTestCase {

    // MARK: - Intent Detection

    func testDetectIntentUnread() {
        let tool = ReadEmailTool()
        let intent = tool.detectIntent(input: "show me my unread emails")
        if case .unread = intent {} else {
            XCTFail("Expected .unread, got \(intent)")
        }
    }

    func testDetectIntentUnreadNewMail() {
        let tool = ReadEmailTool()
        let intent = tool.detectIntent(input: "do I have any new mail")
        if case .unread = intent {} else {
            XCTFail("Expected .unread, got \(intent)")
        }
    }

    func testDetectIntentSender() {
        let tool = ReadEmailTool()
        let entities = ExtractedEntities(names: ["Sarah"], places: [], organizations: [], urls: [], phoneNumbers: [], emails: [], ocrText: nil)
        let intent = tool.detectIntent(input: "emails from Sarah", entities: entities)
        if case .fromSender(let name) = intent {
            XCTAssertEqual(name, "Sarah")
        } else {
            XCTFail("Expected .fromSender, got \(intent)")
        }
    }

    func testDetectIntentSearch() {
        let tool = ReadEmailTool()
        let intent = tool.detectIntent(input: "search email for invoice")
        if case .search(let query) = intent {
            XCTAssertFalse(query.isEmpty)
            XCTAssertTrue(query.contains("invoice"))
        } else {
            XCTFail("Expected .search, got \(intent)")
        }
    }

    func testDetectIntentLatestDefault() {
        let tool = ReadEmailTool()
        let intent = tool.detectIntent(input: "check my email")
        if case .latest(let count) = intent {
            XCTAssertEqual(count, AppConfig.maxReadEmailResults)
        } else {
            XCTFail("Expected .latest, got \(intent)")
        }
    }

    func testDetectIntentLatestInbox() {
        let tool = ReadEmailTool()
        let intent = tool.detectIntent(input: "show me my inbox")
        if case .latest = intent {} else {
            XCTFail("Expected .latest, got \(intent)")
        }
    }

    // MARK: - AppleScript Builder

    func testBuildAppleScriptLatest() {
        let tool = ReadEmailTool()
        let script = tool.buildAppleScript(for: .latest(count: 5))
        XCTAssertTrue(script.contains("messages 1 thru 5"))
        XCTAssertTrue(script.contains("tell application \"Mail\""))
        XCTAssertTrue(script.contains("end tell"))
    }

    func testBuildAppleScriptUnread() {
        let tool = ReadEmailTool()
        let script = tool.buildAppleScript(for: .unread)
        XCTAssertTrue(script.contains("read status is false"))
    }

    func testBuildAppleScriptSearchEscapesQuotes() {
        let tool = ReadEmailTool()
        let script = tool.buildAppleScript(for: .search(query: "invoice \"2024\""))
        XCTAssertTrue(script.contains("subject contains"))
        XCTAssertTrue(script.contains("\\\"2024\\\""))
    }

    func testBuildAppleScriptFromSender() {
        let tool = ReadEmailTool()
        let script = tool.buildAppleScript(for: .fromSender(name: "Alice"))
        XCTAssertTrue(script.contains("sender contains \"Alice\""))
    }

    func testBuildAppleScriptLatestRespectsLimit() {
        let tool = ReadEmailTool()
        let script = tool.buildAppleScript(for: .latest(count: 100))
        // Should be capped to AppConfig.maxReadEmailResults
        XCTAssertTrue(script.contains("messages 1 thru \(AppConfig.maxReadEmailResults)"))
    }

    // MARK: - Output Parsing

    func testParseEmailOutputValidEntries() {
        let tool = ReadEmailTool()
        let output = "Meeting Tomorrow||alice@example.com||2026-04-13 10:00||false||Let's discuss the Q2 plan.<<END>>Invoice #42||bob@corp.com||2026-04-12 09:00||true||Please review attached.<<END>>"
        let emails = tool.parseEmailOutput(output)
        XCTAssertEqual(emails.count, 2)
        XCTAssertEqual(emails[0].subject, "Meeting Tomorrow")
        XCTAssertEqual(emails[0].sender, "alice@example.com")
        XCTAssertFalse(emails[0].isRead)
        XCTAssertEqual(emails[1].subject, "Invoice #42")
        XCTAssertTrue(emails[1].isRead)
    }

    func testParseEmailOutputMalformedSkipped() {
        let tool = ReadEmailTool()
        let output = "Good Entry||sender||date||true||body<<END>>Bad||Entry<<END>>Another Good||sender2||date2||false||body2<<END>>"
        let emails = tool.parseEmailOutput(output)
        XCTAssertEqual(emails.count, 2)
        XCTAssertEqual(emails[0].subject, "Good Entry")
        XCTAssertEqual(emails[1].subject, "Another Good")
    }

    func testParseEmailOutputEmpty() {
        let tool = ReadEmailTool()
        let emails = tool.parseEmailOutput("")
        XCTAssertTrue(emails.isEmpty)
    }

    // MARK: - Empty Result Messages

    func testEmptyResultMessageLatest() {
        let tool = ReadEmailTool()
        let msg = tool.emptyResultMessage(for: .latest(count: 10))
        XCTAssertTrue(msg.contains("inbox"))
    }

    func testEmptyResultMessageUnread() {
        let tool = ReadEmailTool()
        let msg = tool.emptyResultMessage(for: .unread)
        XCTAssertTrue(msg.contains("caught up"))
    }

    func testEmptyResultMessageSearch() {
        let tool = ReadEmailTool()
        let msg = tool.emptyResultMessage(for: .search(query: "budget"))
        XCTAssertTrue(msg.contains("budget"))
    }

    func testEmptyResultMessageSender() {
        let tool = ReadEmailTool()
        let msg = tool.emptyResultMessage(for: .fromSender(name: "Sarah"))
        XCTAssertTrue(msg.contains("Sarah"))
    }

    // MARK: - Widget Data

    func testEmailWidgetDataConstruction() {
        let email = ReadEmailTool.EmailSummary(
            subject: "Test Subject",
            sender: "alice@example.com",
            date: "Today",
            bodySnippet: "Hello world",
            isRead: false
        )
        let data = ReadEmailTool.EmailListWidgetData(emails: [email], intentLabel: "Inbox")
        XCTAssertEqual(data.emails.count, 1)
        XCTAssertEqual(data.intentLabel, "Inbox")
        XCTAssertNil(data.query)
        XCTAssertEqual(data.emails[0].subject, "Test Subject")
        XCTAssertFalse(data.emails[0].isRead)
    }

    func testEmailWidgetDataWithQuery() {
        let data = ReadEmailTool.EmailListWidgetData(emails: [], intentLabel: "Search", query: "invoice")
        XCTAssertEqual(data.query, "invoice")
    }
}
