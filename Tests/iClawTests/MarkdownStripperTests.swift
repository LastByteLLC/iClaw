import XCTest
@testable import iClawCore

final class MarkdownStripperTests: XCTestCase {

    func testStripsBold() {
        XCTAssertEqual(MarkdownStripper.plainText(from: "This is **bold** text"), "This is bold text")
    }

    func testStripsUnderscoreBold() {
        XCTAssertEqual(MarkdownStripper.plainText(from: "This is __bold__ text"), "This is bold text")
    }

    func testStripsItalic() {
        XCTAssertEqual(MarkdownStripper.plainText(from: "This is *italic* text"), "This is italic text")
    }

    func testStripsInlineCode() {
        XCTAssertEqual(MarkdownStripper.plainText(from: "Use `print()` here"), "Use print() here")
    }

    func testStripsLinks() {
        XCTAssertEqual(MarkdownStripper.plainText(from: "Click [here](https://example.com) now"), "Click here now")
    }

    func testStripsHeaders() {
        let input = "# Title\n## Subtitle\nBody text"
        let result = MarkdownStripper.plainText(from: input)
        XCTAssertTrue(result.contains("Title"))
        XCTAssertTrue(result.contains("Subtitle"))
        XCTAssertTrue(result.contains("Body text"))
        XCTAssertFalse(result.contains("# "))
    }

    func testStripsCodeBlocks() {
        let input = "Before\n```swift\nlet x = 1\n```\nAfter"
        let result = MarkdownStripper.plainText(from: input)
        XCTAssertTrue(result.contains("let x = 1"))
        XCTAssertFalse(result.contains("```"))
    }

    func testStripsStrikethrough() {
        XCTAssertEqual(MarkdownStripper.plainText(from: "This is ~~wrong~~ right"), "This is wrong right")
    }

    func testStripsBulletPoints() {
        let input = "- Item one\n- Item two\n* Item three"
        let result = MarkdownStripper.plainText(from: input)
        XCTAssertTrue(result.contains("Item one"))
        XCTAssertFalse(result.hasPrefix("- "))
    }

    func testStripsLatexDelimiters() {
        let input = "The formula \\(x^2\\) and \\[y = mx + b\\]"
        let result = MarkdownStripper.plainText(from: input)
        XCTAssertTrue(result.contains("x^2"))
        XCTAssertFalse(result.contains("\\("))
        XCTAssertFalse(result.contains("\\)"))
    }

    func testPlainTextPassesThrough() {
        let input = "Just a regular sentence with no formatting."
        XCTAssertEqual(MarkdownStripper.plainText(from: input), input)
    }

    func testEmptyString() {
        XCTAssertEqual(MarkdownStripper.plainText(from: ""), "")
    }

    func testCombinedFormatting() {
        let input = "# Welcome\nThis is **bold** and *italic* with a [link](url) and `code`."
        let result = MarkdownStripper.plainText(from: input)
        XCTAssertEqual(result, "Welcome\nThis is bold and italic with a link and code.")
    }
}
