import XCTest
@testable import iClawCore

/// Tests for the word-level token estimator that replaced char/4.
final class TokenEstimatorTests: XCTestCase {

    // MARK: - Basic Estimation

    func testEmptyString() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
    }

    func testSingleWord() {
        let result = TokenEstimator.estimate("hello")
        XCTAssertGreaterThanOrEqual(result, 1)
        XCTAssertLessThanOrEqual(result, 3)
    }

    func testShortEnglishSentence() {
        let result = TokenEstimator.estimate("What is the weather in San Francisco?")
        // ~8 words → ~10 tokens (1.3 per word + punctuation)
        XCTAssertGreaterThanOrEqual(result, 7)
        XCTAssertLessThanOrEqual(result, 15)
    }

    func testLongerParagraph() {
        let text = "The quick brown fox jumps over the lazy dog. This is a sample sentence for testing token estimation accuracy."
        let result = TokenEstimator.estimate(text)
        // ~20 words → ~26 tokens
        XCTAssertGreaterThanOrEqual(result, 15)
        XCTAssertLessThanOrEqual(result, 35)
    }

    // MARK: - CJK Content

    func testCJKCharacters() {
        // 5 CJK characters → should be ~5 tokens (not 5/4=1 like char/4)
        let result = TokenEstimator.estimate("東京の天気")
        XCTAssertGreaterThanOrEqual(result, 4)
        XCTAssertLessThanOrEqual(result, 7)
    }

    func testMixedCJKAndEnglish() {
        // "Tokyo weather is 25°C" in mixed content
        let result = TokenEstimator.estimate("Tokyo weather is 25°C 東京の天気")
        // 4 English words + 5 CJK chars ≈ 5+5 = 10 tokens
        XCTAssertGreaterThanOrEqual(result, 8)
        XCTAssertLessThanOrEqual(result, 15)
    }

    func testKoreanText() {
        // Korean syllables should count as individual tokens
        let result = TokenEstimator.estimate("서울의 날씨")
        XCTAssertGreaterThanOrEqual(result, 3)
    }

    // MARK: - Code Content

    func testCodeSnippet() {
        let code = "func fibonacci(_ n: Int) -> Int { return n <= 1 ? n : fibonacci(n-1) + fibonacci(n-2) }"
        let result = TokenEstimator.estimate(code)
        // Code has many punctuation tokens
        XCTAssertGreaterThanOrEqual(result, 15)
    }

    // MARK: - Punctuation Heavy

    func testURLString() {
        let url = "https://api.example.com/v2/users?page=1&limit=50"
        let result = TokenEstimator.estimate(url)
        XCTAssertGreaterThanOrEqual(result, 5)
    }

    func testMathExpression() {
        let math = "$47.50 * 0.15 = $7.13"
        let result = TokenEstimator.estimate(math)
        XCTAssertGreaterThanOrEqual(result, 5)
    }

    // MARK: - Comparison with char/4

    func testCJKBetterThanCharDiv4() {
        let cjk = "東京の天気は晴れです今日は暖かい"
        let wordLevel = TokenEstimator.estimate(cjk)
        let charDiv4 = max(1, cjk.count / 4)

        // CJK: char/4 massively underestimates (14 chars / 4 = 3)
        // Word-level should give ~14 tokens (one per character)
        XCTAssertGreaterThan(wordLevel, charDiv4,
            "Word-level (\(wordLevel)) should exceed char/4 (\(charDiv4)) for CJK text")
    }

    func testShortInputBetterThanCharDiv4() {
        let short = "hi"
        let wordLevel = TokenEstimator.estimate(short)
        let charDiv4 = max(1, short.count / 4)

        // "hi" = 1 token; char/4 = max(1, 0) = 1. Both should be 1.
        XCTAssertGreaterThanOrEqual(wordLevel, 1)
        XCTAssertEqual(charDiv4, 1)
    }

    // MARK: - AppConfig Integration

    func testAppConfigUsesTokenEstimator() {
        // Verify AppConfig.estimateTokens delegates to TokenEstimator
        let text = "東京の天気"
        let appConfigResult = AppConfig.estimateTokens(for: text)
        let directResult = TokenEstimator.estimate(text)
        XCTAssertEqual(appConfigResult, directResult,
            "AppConfig.estimateTokens should delegate to TokenEstimator")
    }
}
