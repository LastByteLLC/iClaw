import Testing
@testable import iClawCore

struct ContentCompactorTests {

    // MARK: - Invisible character stripping

    @Test func stripsZeroWidthSpaces() {
        let input = "Hello\u{200B}World\u{FEFF}Test\u{200D}End"
        let result = ContentCompactor.stripInvisibleChars(input)
        #expect(result == "HelloWorldTestEnd")
    }

    @Test func preservesNormalUnicode() {
        let input = "Café résumé naïve"
        let result = ContentCompactor.stripInvisibleChars(input)
        #expect(result == input)
    }

    @Test func stripsSoftHyphens() {
        let input = "pro\u{00AD}gram\u{00AD}ming"
        let result = ContentCompactor.stripInvisibleChars(input)
        #expect(result == "programming")
    }

    // MARK: - Whitespace normalization

    @Test func collapsesMultipleSpaces() {
        let result = ContentCompactor.normalizeWhitespace("hello    world   test")
        #expect(result == "hello world test")
    }

    @Test func collapsesExcessiveNewlines() {
        let input = "Paragraph 1\n\n\n\n\nParagraph 2\n\n\nParagraph 3"
        let result = ContentCompactor.normalizeWhitespace(input)
        #expect(result == "Paragraph 1\n\nParagraph 2\n\nParagraph 3")
    }

    @Test func replacesTabs() {
        let result = ContentCompactor.normalizeWhitespace("col1\t\tcol2\tcol3")
        #expect(result == "col1 col2 col3")
    }

    @Test func trimsLeadingTrailingWhitespace() {
        let result = ContentCompactor.normalizeWhitespace("\n\n  Hello  \n\n")
        #expect(result == "Hello")
    }

    @Test func preservesSingleBlankLine() {
        let input = "Line 1\n\nLine 2"
        let result = ContentCompactor.normalizeWhitespace(input)
        #expect(result == "Line 1\n\nLine 2")
    }

    // MARK: - Boilerplate stripping

    @Test func removesCookieNotices() {
        let input = "Article content here\nAccept All Cookies\nMore content"
        let result = ContentCompactor.stripBoilerplate(input)
        #expect(result.contains("Article content here"))
        #expect(result.contains("More content"))
        #expect(!result.contains("Accept All Cookies"))
    }

    @Test func removesSkipToContent() {
        let input = "Skip to main content\nActual article text"
        let result = ContentCompactor.stripBoilerplate(input)
        #expect(!result.contains("Skip to main content"))
        #expect(result.contains("Actual article text"))
    }

    @Test func keepsLongLinesWithBoilerplateSubstring() {
        // Lines > 80 chars should be kept even if they contain boilerplate words
        let longLine = "This is a very long article paragraph that happens to mention our cookie policy in the context of discussing web privacy regulations and their impact on users."
        let result = ContentCompactor.stripBoilerplate(longLine)
        #expect(result == longLine)
    }

    @Test func removesShareButtons() {
        let input = "Great article\nShare on Facebook\nShare on Twitter\nShare on LinkedIn\nThe end"
        let result = ContentCompactor.stripBoilerplate(input)
        #expect(!result.contains("Share on Facebook"))
        #expect(result.contains("Great article"))
        #expect(result.contains("The end"))
    }

    // MARK: - Truncation

    @Test func noTruncationUnderLimit() {
        let short = "Hello world"
        let result = ContentCompactor.truncate(short, limit: 100)
        #expect(result == short)
    }

    @Test func truncatesOverLimit() {
        let long = String(repeating: "x", count: 1000)
        let result = ContentCompactor.truncate(long, limit: 200)
        #expect(result.count < 1000)
        #expect(result.contains("[... content truncated ...]"))
    }

    @Test func preservesHeadAndTail() {
        let text = "HEAD_MARKER" + String(repeating: "x", count: 1000) + "TAIL_MARKER"
        let result = ContentCompactor.truncate(text, limit: 200)
        #expect(result.hasPrefix("HEAD_MARKER"))
        #expect(result.hasSuffix("TAIL_MARKER"))
    }

    // MARK: - Full compact pipeline

    @Test func compactCombinesAllStages() {
        let messy = """
        Skip to content
        \u{200B}Hello\u{200B}   World\u{200B}
        Accept all cookies




        This is   the   actual   content.
        Follow us on Twitter
        The end.
        """
        let result = ContentCompactor.compact(messy, limit: 10000)
        #expect(!result.contains("\u{200B}"))
        #expect(!result.contains("Skip to content"))
        #expect(!result.contains("Accept all cookies"))
        #expect(!result.contains("Follow us on Twitter"))
        #expect(result.contains("Hello World"))
        #expect(result.contains("This is the actual content."))
        #expect(result.contains("The end."))
    }

    @Test func cleanDoesNotTruncate() {
        let long = String(repeating: "Hello world. ", count: 1000)
        let result = ContentCompactor.clean(long)
        #expect(!result.contains("[... content truncated ...]"))
        #expect(result.contains("Hello world."))
    }

    @Test func compactRealWorldHTML() {
        // Simulate what HTTPFetchBackend returns after SwiftSoup extraction
        let simulatedExtract = """
        Skip to main content
        Navigation Menu Home About Contact
        Cookie Settings

        The Swift Programming Language

        Swift is a powerful and intuitive programming language for all Apple platforms. It is designed to be safe, fast, and interactive.

        Swift was first released in 2014 at Apple's Worldwide Developers Conference. Since then it has grown to become one of the most popular programming languages in the world.

        Share on Twitter
        Follow us on GitHub
        Copyright © 2024 Apple Inc. All rights reserved.
        """
        let result = ContentCompactor.compact(simulatedExtract)
        #expect(result.contains("Swift is a powerful"))
        #expect(result.contains("first released in 2014"))
        #expect(!result.contains("Skip to main content"))
        #expect(!result.contains("Cookie Settings"))
        #expect(!result.contains("Share on Twitter"))
        #expect(!result.contains("Copyright ©"))
    }
}
