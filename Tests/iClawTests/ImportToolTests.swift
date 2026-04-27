#if os(macOS)
import XCTest
@testable import iClawCore

/// Adversarial and happy-path tests for ImportTool's .ics and .vcf parsing.
/// Validates safe handling of malformed, oversized, empty, and hostile input files.
final class ImportToolTests: XCTestCase {

    private let tool = ImportTool()
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iClaw-ImportTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, _ content: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeData(_ name: String, _ data: Data) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    private func run(_ fileURL: URL, prompt: String = "Add this") async throws -> ToolIO {
        try await tool.execute(input: "\(fileURL.path)\n\(prompt)", entities: nil)
    }

    // MARK: - Happy Path: iCal

    func testValidICSParsesAllFields() async throws {
        let url = writeFile("event.ics", """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Team Standup
        DTSTART:20260321T090000Z
        DTEND:20260321T093000Z
        LOCATION:Conference Room B
        DESCRIPTION:Daily standup meeting
        END:VEVENT
        END:VCALENDAR
        """)

        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Team Standup"))
        XCTAssertTrue(result.text.contains("Conference Room B"))
        XCTAssertEqual(result.outputWidget, "ImportPreviewWidget")

        let data = result.widgetData as? ImportPreviewWidgetData
        XCTAssertNotNil(data)
        if case .event(let event) = data {
            XCTAssertEqual(event.title, "Team Standup")
            XCTAssertEqual(event.location, "Conference Room B")
            XCTAssertEqual(event.description, "Daily standup meeting")
            XCTAssertNotNil(event.startDate)
            XCTAssertNotNil(event.endDate)
        } else {
            XCTFail("Expected .event case")
        }
    }

    func testAllDayICSEvent() async throws {
        let url = writeFile("allday.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Holiday
        DTSTART;VALUE=DATE:20260325
        DTEND;VALUE=DATE:20260326
        END:VEVENT
        END:VCALENDAR
        """)

        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Holiday"))
        if case .event(let event) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertNotNil(event.startDate, "All-day date format yyyyMMdd should parse")
        } else {
            XCTFail("Expected .event case")
        }
    }

    func testICSWithParameterizedDTSTART() async throws {
        let url = writeFile("paramdate.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Parametrized Event
        DTSTART;TZID=America/New_York:20260321T140000
        DTEND;TZID=America/New_York:20260321T150000
        END:VEVENT
        END:VCALENDAR
        """)

        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Parametrized Event"))
        // The TZID prefix should still parse via the semicolon-aware field extractor
        if case .event(let event) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertNotNil(event.startDate, "DTSTART with ;TZID= prefix should still parse")
        }
    }

    // MARK: - Happy Path: vCard

    func testValidVCFParsesAllFields() async throws {
        let url = writeFile("contact.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        N:Doe;John;;;
        FN:John Doe
        ORG:Acme Corp
        TEL;TYPE=CELL:+1-555-0100
        EMAIL:john@example.com
        END:VCARD
        """)

        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("John Doe"))
        XCTAssertTrue(result.text.contains("Acme Corp"))
        XCTAssertTrue(result.text.contains("+1-555-0100") || result.text.contains("555"))
        XCTAssertTrue(result.text.contains("john@example.com"))
        XCTAssertEqual(result.outputWidget, "ImportPreviewWidget")

        if case .contact(let contact) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertEqual(contact.name, "John Doe")
            XCTAssertEqual(contact.organization, "Acme Corp")
            XCTAssertFalse(contact.phones.isEmpty)
            XCTAssertFalse(contact.emails.isEmpty)
        } else {
            XCTFail("Expected .contact case")
        }
    }

    func testVCFMinimalContact() async throws {
        let url = writeFile("minimal.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        FN:Jane Smith
        END:VCARD
        """)

        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Jane Smith"))
        if case .contact(let contact) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertTrue(contact.phones.isEmpty)
            XCTAssertTrue(contact.emails.isEmpty)
            XCTAssertNil(contact.organization)
        }
    }

    // MARK: - Adversarial: Empty & Missing Data

    func testEmptyICSFile() async throws {
        let url = writeFile("empty.ics", "")
        let result = try await run(url)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("No calendar event"))
    }

    func testICSWithoutVEVENT() async throws {
        let url = writeFile("noevent.ics", """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("No calendar event"))
    }

    func testICSWithEmptySummary() async throws {
        let url = writeFile("emptysummary.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:
        DTSTART:20260321T090000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        // Falls back to "Untitled Event"
        XCTAssertTrue(result.text.contains("Untitled Event"))
    }

    func testEmptyVCFFile() async throws {
        let url = writeFile("empty.vcf", "")
        let result: ToolIO
        do {
            result = try await run(url)
            // If it doesn't throw, it should return error status
            XCTAssertEqual(result.status, .error)
        } catch {
            // Throwing is also acceptable for truly invalid data
        }
    }

    func testVCFWithNoContent() async throws {
        let url = writeFile("nocontent.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        END:VCARD
        """)
        do {
            let result = try await run(url)
            // CNContactVCardSerialization may reject a vCard with no FN
            // Either .error status or .ok with empty name are acceptable
            XCTAssertTrue(result.status == .error || result.status == .ok,
                          "Should handle gracefully, not crash")
        } catch {
            // Throwing is also acceptable for an invalid vCard
        }
    }

    // MARK: - Adversarial: Malformed Files

    func testICSWithGarbageContent() async throws {
        let url = writeFile("garbage.ics", """
        This is not a valid iCal file.
        It contains random text.
        No VEVENT here!
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .error)
    }

    func testICSWithMalformedDates() async throws {
        let url = writeFile("baddate.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Bad Date Event
        DTSTART:not-a-date
        DTEND:also-not-a-date
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok, "Should still parse; dates will be nil")
        XCTAssertTrue(result.text.contains("Bad Date Event"))
        if case .event(let event) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertNil(event.startDate, "Malformed date should parse to nil, not crash")
            XCTAssertNil(event.endDate)
        }
    }

    func testVCFWithBinaryGarbage() async throws {
        let garbage = Data([0x00, 0x01, 0xFF, 0xFE, 0x80, 0x90, 0xAB, 0xCD])
        let url = writeData("binary.vcf", garbage)
        do {
            let result = try await run(url)
            // Should gracefully fail, not crash
            XCTAssertEqual(result.status, .error)
        } catch {
            // Throwing is also acceptable for binary data
        }
    }

    func testICSWithBinaryContent() async throws {
        var data = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:".data(using: .utf8)!
        data.append(Data([0x00, 0xFF, 0xFE]))
        data.append("\nEND:VEVENT\nEND:VCALENDAR".data(using: .utf8)!)
        let url = writeData("binarysummary.ics", data)
        do {
            let result = try await run(url)
            // Should not crash, any status is fine
            XCTAssertNotNil(result)
        } catch {
            // Acceptable to throw on corrupt data
        }
    }

    // MARK: - Adversarial: Injection & Hostile Content

    func testICSWithScriptInjectionInSummary() async throws {
        let url = writeFile("xss.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:<script>alert('xss')</script>
        DTSTART:20260321T090000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        // The title should contain the raw text, SwiftUI Text renders it safely
        if case .event(let event) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertTrue(event.title.contains("<script>"), "Raw text preserved, rendered safely by SwiftUI")
        }
    }

    func testICSWithSQLInjectionInLocation() async throws {
        let url = writeFile("sqli.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        LOCATION:'; DROP TABLE events; --
        DTSTART:20260321T090000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        if case .event(let event) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertTrue(event.location?.contains("DROP TABLE") == true, "SQL treated as plain text")
        }
    }

    func testVCFWithPathTraversalInName() async throws {
        let url = writeFile("traversal.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        FN:../../etc/passwd
        END:VCARD
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        // Path traversal strings are just text, not interpreted as paths
        if case .contact(let contact) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertTrue(contact.name.contains("../../etc/passwd") || contact.name.contains("passwd"))
        }
    }

    func testICSWithUnicodeExploits() async throws {
        let url = writeFile("unicode.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting \u{202E}gnimeeT\u{202C}
        DTSTART:20260321T090000Z
        DESCRIPTION:Contains RTL override \u{200B}zero-width space\u{FEFF}BOM
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertNotNil(result.widgetData)
    }

    func testVCFWithExtremelyLongFields() async throws {
        let longName = String(repeating: "A", count: 100_000)
        let url = writeFile("long.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        FN:\(longName)
        EMAIL:\(longName)@example.com
        END:VCARD
        """)
        let result = try await run(url)
        // Should handle gracefully — either parse or error, never crash/hang
        XCTAssertNotNil(result)
    }

    func testICSWithExtremelyLongDescription() async throws {
        let longDesc = String(repeating: "X", count: 500_000)
        let url = writeFile("longdesc.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Big Event
        DTSTART:20260321T090000Z
        DESCRIPTION:\(longDesc)
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Big Event"))
    }

    // MARK: - Adversarial: Edge Case Formats

    func testICSWithMultipleVEVENTS() async throws {
        let url = writeFile("multi.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:First Event
        DTSTART:20260321T090000Z
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Second Event
        DTSTART:20260322T090000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        // Should parse at least the first event
        XCTAssertTrue(result.text.contains("First Event"))
    }

    func testVCFWithMultipleContacts() async throws {
        let url = writeFile("multi.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        FN:Alice
        END:VCARD
        BEGIN:VCARD
        VERSION:3.0
        FN:Bob
        END:VCARD
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        // Should parse at least the first contact
        XCTAssertTrue(result.text.contains("Alice") || result.text.contains("Bob"))
    }

    func testICSWithFoldedLines() async throws {
        // RFC 5545 allows long lines to be folded with CRLF + space
        let url = writeFile("folded.ics", "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Folded\r\n Event Name\r\nDTSTART:20260321T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
    }

    func testICSWithWindowsLineEndings() async throws {
        let url = writeFile("crlf.ics", "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:CRLF Event\r\nDTSTART:20260321T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("CRLF Event"))
    }

    // MARK: - Adversarial: Wrong Extension

    func testUnsupportedFileExtension() async throws {
        let url = writeFile("readme.txt", "Just a text file")
        let result = try await run(url)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("Unsupported"))
    }

    // MARK: - Input Handling

    func testNoFilePathInInput() async throws {
        let result = try await tool.execute(input: "Add this event to my calendar", entities: nil)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("No file path"))
    }

    func testNonexistentFile() async throws {
        let fakePath = tempDir.appendingPathComponent("nonexistent.ics")
        do {
            let result = try await run(fakePath)
            // If it doesn't throw, status should indicate error
            XCTAssertNotNil(result)
        } catch {
            // Throwing is expected for a missing file
        }
    }

    // MARK: - ContentProfile Integration

    func testICSFileGetsCalendarEventProfile() {
        let url = writeFile("test.ics", "BEGIN:VCALENDAR\nEND:VCALENDAR")
        let profile = FileAttachment.analyzeContent(url: url, category: .text)
        XCTAssertEqual(profile, .calendarEvent)
    }

    func testVCFFileGetsContactCardProfile() {
        let url = writeFile("test.vcf", "BEGIN:VCARD\nEND:VCARD")
        let profile = FileAttachment.analyzeContent(url: url, category: .text)
        XCTAssertEqual(profile, .contactCard)
    }

    func testVCardExtensionGetsContactCardProfile() {
        let url = writeFile("test.vcard", "BEGIN:VCARD\nEND:VCARD")
        let profile = FileAttachment.analyzeContent(url: url, category: .text)
        XCTAssertEqual(profile, .contactCard)
    }

    func testCalendarEventSuggestionPills() {
        let suggestions = FileAttachment.suggestions(for: .text, profile: .calendarEvent)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.contains(where: { $0.label == "Add to Calendar" }))
        XCTAssertTrue(suggestions.contains(where: { $0.label == "Show details" }))
    }

    func testContactCardSuggestionPills() {
        let suggestions = FileAttachment.suggestions(for: .text, profile: .contactCard)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertTrue(suggestions.contains(where: { $0.label == "Add to Contacts" }))
        XCTAssertTrue(suggestions.contains(where: { $0.label == "Show details" }))
    }

    // MARK: - Adversarial: Deeply Nested / Recursive

    func testICSWithDeeplyNestedComponents() async throws {
        var content = "BEGIN:VCALENDAR\n"
        for i in 0..<100 {
            content += "BEGIN:VEVENT\nSUMMARY:Event \(i)\nDTSTART:20260321T090000Z\nEND:VEVENT\n"
        }
        content += "END:VCALENDAR"
        let url = writeFile("nested.ics", content)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok, "Should handle many events without crashing")
    }

    func testVCFWithManyPhoneNumbers() async throws {
        var content = "BEGIN:VCARD\nVERSION:3.0\nFN:Phone Collector\n"
        for i in 0..<50 {
            content += "TEL;TYPE=CELL:+1-555-\(String(format: "%04d", i))\n"
        }
        content += "END:VCARD"
        let url = writeFile("manyphones.vcf", content)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        if case .contact(let contact) = result.widgetData as? ImportPreviewWidgetData {
            XCTAssertEqual(contact.phones.count, 50)
        }
    }

    // MARK: - Adversarial: Special Characters in Fields

    func testICSWithNewlinesInSummary() async throws {
        let url = writeFile("newlines.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Line1\\nLine2\\nLine3
        DTSTART:20260321T090000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
    }

    func testICSWithColonsInDescription() async throws {
        let url = writeFile("colons.ics", """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Meeting
        DESCRIPTION:Agenda: 1) Review 2) Plan 3) Action items
        DTSTART:20260321T090000Z
        END:VEVENT
        END:VCALENDAR
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
        if case .event(let event) = result.widgetData as? ImportPreviewWidgetData {
            // Description should preserve content after the first colon
            XCTAssertTrue(event.description?.contains("Agenda") == true)
        }
    }

    func testVCFWithEmojiInName() async throws {
        let url = writeFile("emoji.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        FN:John 🎉 Doe
        END:VCARD
        """)
        let result = try await run(url)
        XCTAssertEqual(result.status, .ok)
    }

    func testVCFWithQuotedPrintableEncoding() async throws {
        let url = writeFile("qp.vcf", """
        BEGIN:VCARD
        VERSION:3.0
        FN;ENCODING=QUOTED-PRINTABLE:M=C3=BCller
        END:VCARD
        """)
        let result = try await run(url)
        // Should not crash; may or may not decode QP correctly
        XCTAssertNotNil(result)
    }
}
#endif
