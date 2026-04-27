import XCTest
@testable import iClawCore

/// Tests for LaTeXDetector: detection, parsing, edge cases, malformed input,
/// LaTeX embedded in markdown/plaintext, and complexity limits.
final class LaTeXDetectorTests: XCTestCase {

    // MARK: - containsLaTeX Detection

    func testDetectsInlineParenDelimiters() {
        XCTAssertTrue(LaTeXDetector.containsLaTeX(#"The equation \(E=mc^2\) is famous."#))
    }

    func testDetectsDisplayBracketDelimiters() {
        XCTAssertTrue(LaTeXDetector.containsLaTeX(#"Consider \[x^2 + y^2 = r^2\]"#))
    }

    func testDetectsDoubleDollarDelimiters() {
        XCTAssertTrue(LaTeXDetector.containsLaTeX("The formula is $$\\int_0^1 f(x)\\,dx$$"))
    }

    func testDetectsSingleDollarDelimiters() {
        XCTAssertTrue(LaTeXDetector.containsLaTeX("The value $x$ is positive."))
    }

    func testNoLaTeXInPlainText() {
        XCTAssertFalse(LaTeXDetector.containsLaTeX("This is just normal text with no math."))
    }

    func testNoLaTeXInMarkdown() {
        XCTAssertFalse(LaTeXDetector.containsLaTeX("**Bold** and *italic* text."))
    }

    func testDollarSignInCurrencyNotLaTeX() {
        // "$100" is a single $ followed by digits — the regex requires content between two $
        XCTAssertFalse(LaTeXDetector.containsLaTeX("The price is $100."))
    }

    func testDoubleDollarCurrencyNotLaTeX() {
        // "$$" with nothing between them shouldn't match
        XCTAssertFalse(LaTeXDetector.containsLaTeX("Save $$ on your next purchase!"))
    }

    func testEmptyStringNoLaTeX() {
        XCTAssertFalse(LaTeXDetector.containsLaTeX(""))
    }

    // MARK: - parse: Basic Delimiters

    func testParseInlineParentheses() {
        let segments = LaTeXDetector.parse(#"Einstein's \(E=mc^2\) equation."#)
        XCTAssertEqual(segments, [
            .text("Einstein's "),
            .latex("E=mc^2"),
            .text(" equation."),
        ])
    }

    func testParseDisplayBrackets() {
        let segments = LaTeXDetector.parse(#"Formula: \[a^2 + b^2 = c^2\]"#)
        XCTAssertEqual(segments, [
            .text("Formula: "),
            .latex("a^2 + b^2 = c^2"),
        ])
    }

    func testParseDoubleDollar() {
        let segments = LaTeXDetector.parse("Result: $$\\frac{1}{2}$$ done.")
        XCTAssertEqual(segments, [
            .text("Result: "),
            .latex("\\frac{1}{2}"),
            .text(" done."),
        ])
    }

    func testParseSingleDollar() {
        let segments = LaTeXDetector.parse("Let $x$ be a variable and $y$ be another.")
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments[0], .text("Let "))
        XCTAssertEqual(segments[1], .latex("x"))
        XCTAssertEqual(segments[2], .text(" be a variable and "))
        XCTAssertEqual(segments[3], .latex("y"))
        XCTAssertEqual(segments[4], .text(" be another."))
    }

    func testParsePlainTextOnly() {
        let segments = LaTeXDetector.parse("No math here.")
        XCTAssertEqual(segments, [.text("No math here.")])
    }

    func testParseLaTeXOnly() {
        let segments = LaTeXDetector.parse(#"\(E=mc^2\)"#)
        XCTAssertEqual(segments, [.latex("E=mc^2")])
    }

    func testParseEmptyString() {
        let segments = LaTeXDetector.parse("")
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - parse: Multiple Expressions

    func testParseMultipleInlineExpressions() {
        let segments = LaTeXDetector.parse(#"Given \(a\) and \(b\), find \(c\)."#)
        XCTAssertEqual(segments, [
            .text("Given "),
            .latex("a"),
            .text(" and "),
            .latex("b"),
            .text(", find "),
            .latex("c"),
            .text("."),
        ])
    }

    func testParseMixedDelimiters() {
        let text = #"Inline \(x\) and display $$y^2$$ here."#
        let segments = LaTeXDetector.parse(text)
        // Should parse both types
        let latexSegments = segments.filter { if case .latex = $0 { return true }; return false }
        XCTAssertEqual(latexSegments.count, 2)
    }

    // MARK: - parse: Malformed LaTeX

    func testUnclosedParenthesisDelimiter() {
        // Opening \( but no closing \) — should not crash, treat as text
        let segments = LaTeXDetector.parse(#"Unclosed \(E=mc^2 here."#)
        XCTAssertFalse(segments.isEmpty)
        // Should not produce a .latex segment since delimiter is unclosed
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 0, "Unclosed delimiter should not produce latex segment")
    }

    func testUnclosedDoubleDollar() {
        let segments = LaTeXDetector.parse("Start $$x^2 + y^2 and never close")
        XCTAssertFalse(segments.isEmpty)
    }

    func testEmptyDelimiters() {
        // \(\) — empty LaTeX content should be skipped
        let segments = LaTeXDetector.parse(#"Empty \(\) expression."#)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 0, "Empty delimiters should not produce latex segment")
    }

    func testWhitespaceOnlyInsideDelimiters() {
        let segments = LaTeXDetector.parse(#"Blank \(   \) inside."#)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 0, "Whitespace-only content should not produce latex segment")
    }

    func testNestedDelimiters() {
        // \( \( inner \) \) — should handle gracefully
        let segments = LaTeXDetector.parse(#"Nested \(\(inner\)\) end."#)
        XCTAssertFalse(segments.isEmpty, "Nested delimiters should not crash")
    }

    func testMismatchedDelimiters() {
        // Open with \( but close with \] — should not match
        let segments = LaTeXDetector.parse(#"Mismatched \(x^2\] here."#)
        XCTAssertFalse(segments.isEmpty, "Mismatched delimiters should not crash")
    }

    // MARK: - parse: LaTeX Inside Markdown

    func testLaTeXInsideBoldMarkdown() {
        let segments = LaTeXDetector.parse(#"**Energy**: \(E=mc^2\) is key."#)
        XCTAssertEqual(segments, [
            .text("**Energy**: "),
            .latex("E=mc^2"),
            .text(" is key."),
        ])
    }

    func testLaTeXInsideListMarkdown() {
        let text = #"- First item: \(a+b\)"# + "\n" + #"- Second item: \(c+d\)"#
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 2)
    }

    func testLaTeXWithMarkdownBulletPoints() {
        let text = """
        Key equations:
        * \\(E=mc^2\\) — energy-mass equivalence
        * \\(F=ma\\) — Newton's second law
        """
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 2)
    }

    // MARK: - parse: Complex LaTeX Expressions

    func testComplexFraction() {
        let segments = LaTeXDetector.parse(#"Result: \(\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}\)"#)
        XCTAssertEqual(segments.count, 2)
        if case .latex(let expr) = segments[1] {
            XCTAssertTrue(expr.contains("\\frac"))
            XCTAssertTrue(expr.contains("\\sqrt"))
        } else {
            XCTFail("Expected latex segment")
        }
    }

    func testIntegral() {
        let segments = LaTeXDetector.parse(#"Compute \(\int_0^\infty e^{-x^2}\,dx\)."#)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    func testSummation() {
        let segments = LaTeXDetector.parse(#"The sum \(\sum_{i=1}^{n} i = \frac{n(n+1)}{2}\) is well known."#)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    func testMatrix() {
        let latex = #"\(\begin{pmatrix} a & b \\ c & d \end{pmatrix}\)"#
        let segments = LaTeXDetector.parse(latex)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    // MARK: - parse: Size and Complexity Limits

    func testVeryLongLaTeXExpression() {
        // 10K character LaTeX expression should parse without hanging
        let longExpr = String(repeating: "x+", count: 5000) + "y"
        let text = "\\(" + longExpr + "\\)"
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    func testManyInlineExpressions() {
        // 100 inline expressions in one string
        var text = ""
        for i in 0..<100 {
            text += "x\\(\(i)\\) "
        }
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 100)
    }

    func testVeryLongPlainTextWithOneLaTeX() {
        let longText = String(repeating: "word ", count: 2000)
        let text = longText + #"\(x^2\)"# + longText
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    // MARK: - parse: Unicode and Special Characters

    func testLaTeXWithGreekLetters() {
        let segments = LaTeXDetector.parse(#"We have \(\alpha + \beta = \gamma\)."#)
        if case .latex(let expr) = segments[1] {
            XCTAssertTrue(expr.contains("\\alpha"))
        }
    }

    func testLaTeXWithUnicodeText() {
        let segments = LaTeXDetector.parse("日本語テキスト \\(x^2\\) more text")
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    func testLaTeXWithEmojiSurrounding() {
        let segments = LaTeXDetector.parse("🎓 The formula \\(E=mc^2\\) is 🔥")
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1], .latex("E=mc^2"))
    }

    // MARK: - parse: Real-World LLM Output Patterns

    func testEinsteinStyleResponse() {
        let text = """
        Albert Einstein's famous equation \\(E=mc^2\\) describes the relationship between energy (E) and mass (m), with C representing the speed of light.
        """
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    func testPhotosynthesisChemicalEquation() {
        let text = #"The equation is: \(6CO_2 + 6H_2O \rightarrow C_6H_{12}O_6 + 6O_2\)"#
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 1)
    }

    func testMultipleEquationsInResponse() {
        let text = """
        Newton's laws:
        1. \\(F = ma\\) — force equals mass times acceleration
        2. \\(p = mv\\) — momentum equals mass times velocity
        3. \\(F_{12} = -F_{21}\\) — action and reaction
        """
        let segments = LaTeXDetector.parse(text)
        let latexCount = segments.filter { if case .latex = $0 { return true }; return false }.count
        XCTAssertEqual(latexCount, 3)
    }

    // MARK: - Regression: Dollar Sign Edge Cases

    func testSingleDollarNotMatchedAtEndOfSentence() {
        // "costs $50." should NOT be detected as LaTeX
        XCTAssertFalse(LaTeXDetector.containsLaTeX("It costs $50."))
    }

    func testTwoDollarAmountsNotLaTeX() {
        // "$10 and $20" has two single $ signs but they're currency.
        // The regex requires non-$ chars between the two $ signs.
        let text = "Prices are $10 and $20."
        XCTAssertFalse(LaTeXDetector.containsLaTeX(text))
        let segments = LaTeXDetector.parse(text)
        // Currency should survive as plain text segment(s), never a .latex segment.
        for segment in segments {
            if case .latex = segment { XCTFail("currency should not be detected as LaTeX") }
        }
    }

    func testMortgageExplanationWithCommaSeparatedCurrencyIsNotLaTeX() {
        // Regression for false-positive LaTeX detection on the finalization fallback.
        // "$701,980.81" ... "$1,301,980.81" has two bare $ amounts. The old regex
        // matched everything between them and italicized the prose.
        let text = "The total interest paid over the life of the loan is $701,980.81, which is calculated by determining the total amount paid over the life of the loan ($1,301,980.81) and subtracting the principal ($600,000)."
        XCTAssertFalse(LaTeXDetector.containsLaTeX(text))
        let segments = LaTeXDetector.parse(text)
        for segment in segments {
            if case .latex = segment { XCTFail("currency prose should not be detected as LaTeX") }
        }
    }

    func testEscapedDollarSignInLaTeX() {
        // \$ inside LaTeX should be preserved
        let segments = LaTeXDetector.parse(#"Price: \(\$100\)"#)
        if case .latex(let expr) = segments.last {
            XCTAssertTrue(expr.contains("\\$"))
        }
    }
}
