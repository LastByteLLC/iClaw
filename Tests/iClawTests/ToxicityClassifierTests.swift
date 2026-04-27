import XCTest
@testable import iClawCore

final class ToxicityClassifierTests: XCTestCase {

    // MARK: - Model Loading

    func testModelLoads() async {
        let classifier = ToxicityClassifier.shared
        let result = await classifier.check("hello world")
        // Should not crash, model loads lazily
        XCTAssertFalse(result.isToxic)
    }

    // MARK: - Safe Input Detection

    func testSafeInputs() async {
        let classifier = ToxicityClassifier.shared
        let safeInputs = [
            "what's the weather in New York",
            "convert 100 usd to eur",
            "set a timer for 5 minutes",
            "check my email",
            "directions to the airport",
            "translate hello to spanish",
            "UGH this is frustrating",
            "come on seriously",
            "oh my god",
            "whatever forget it",
            "are you kidding me",
            "hello there",
            "I need to assess this situation",
            "the class was fantastic",
            "let me pass through",
            "check my compass heading",
        ]

        for input in safeInputs {
            let result = await classifier.check(input)
            XCTAssertFalse(result.isToxic, "False positive on safe input: \"\(input)\"")
            XCTAssertEqual(result.cleanedText, input, "Safe input should not be modified: \"\(input)\"")
        }
    }

    // MARK: - Toxic Input Detection

    func testToxicInputs() async {
        let classifier = ToxicityClassifier.shared
        let toxicInputs = [
            "what the fuck is going on",
            "this is bullshit",
            "damn it just check my email",
            "where the hell is the airport",
            "OPEN MY INBOX AND READ THE LAST DAMN EMAIL NOW",
            "shit show me the weather",
            "what the hell are you doing",
            "goddammit set a timer",
        ]

        for input in toxicInputs {
            let result = await classifier.check(input)
            XCTAssertTrue(result.isToxic, "Missed toxic input: \"\(input)\"")
            // Cleaned text should not contain the profanity words
            let cleanedLower = result.cleanedText.lowercased()
            XCTAssertFalse(cleanedLower.contains("fuck"), "Cleaned text still contains profanity: \"\(result.cleanedText)\"")
            XCTAssertFalse(cleanedLower.contains("shit"), "Cleaned text still contains profanity: \"\(result.cleanedText)\"")
            XCTAssertFalse(cleanedLower.contains("damn"), "Cleaned text still contains profanity: \"\(result.cleanedText)\"")
            XCTAssertFalse(cleanedLower.contains("hell"), "Cleaned text still contains profanity: \"\(result.cleanedText)\"")
            XCTAssertFalse(cleanedLower.contains("bullshit"), "Cleaned text still contains profanity: \"\(result.cleanedText)\"")
        }
    }

    // MARK: - Profanity Removal Quality

    func testCleanedTextPreservesIntent() async {
        let classifier = ToxicityClassifier.shared
        let cases: [(input: String, shouldContain: String)] = [
            ("damn just convert 100 usd to eur", "convert 100 usd to eur"),
            ("where the hell is the airport", "where the is the airport"),
            ("shit show me the weather", "show me the weather"),
            ("fucking directions to the mall", "directions to the mall"),
            ("GODDAMN CHECK MY EMAIL", "CHECK MY EMAIL"),
        ]

        for (input, expected) in cases {
            let result = await classifier.check(input)
            XCTAssertTrue(result.cleanedText.lowercased().contains(expected.lowercased()),
                         "Cleaned text should preserve intent. Input: \"\(input)\", Cleaned: \"\(result.cleanedText)\", Expected to contain: \"\(expected)\"")
        }
    }

    // MARK: - Evasion Pattern Detection

    func testEvasionPatterns() async {
        let classifier = ToxicityClassifier.shared
        let evasions = [
            "f u c k this weather app",
            "s h i t check my email",
            "f*ck the timer",
            "sh!t convert this",
            "a$$ show me directions",
        ]

        for input in evasions {
            let result = await classifier.check(input)
            XCTAssertTrue(result.isToxic, "Missed evasion pattern: \"\(input)\"")
        }
    }

    // MARK: - False Positive Resistance (Scunthorpe Problem)

    func testFalsePositiveResistance() async {
        let classifier = ToxicityClassifier.shared
        let falsePositives = [
            "assess the situation",
            "open the shell terminal",
            "hello world",
            "the class starts at 10",
            "butterfly migration patterns",
            "compass heading north",
            "mass of the object",
            "classic rock music",
        ]

        for input in falsePositives {
            let result = await classifier.check(input)
            XCTAssertEqual(result.cleanedText, input,
                          "False positive — text was modified: \"\(input)\" → \"\(result.cleanedText)\"")
        }
    }

    // MARK: - Word-Level Removal (Static)

    func testRemoveProfanityStatic() {
        let cases: [(input: String, expected: String)] = [
            ("damn it check email", "it check email"),
            ("show me the fucking weather", "show me the weather"),
            ("SHIT what time is it", "what time is it"),
            ("convert this crap to euros", "convert this to euros"),
            ("hello world", "hello world"),
            ("assess the class situation", "assess the class situation"),
        ]

        for (input, expected) in cases {
            let cleaned = ToxicityClassifier.removeProfanity(from: input)
            XCTAssertEqual(cleaned, expected, "Input: \"\(input)\"")
        }
    }
}
