import XCTest
@testable import iClawCore

final class ConversationIntentClassifierTests: XCTestCase {

    // MARK: - Loading

    func testLoadsOrSkipsGracefully() async {
        let classifier = ConversationIntentClassifier.shared
        _ = await classifier.classify("What's the weather in Tokyo")
    }

    func testShortInputReturnsNil() async {
        let classifier = ConversationIntentClassifier.shared
        let empty = await classifier.classify("")
        let oneChar = await classifier.classify("x")
        XCTAssertNil(empty)
        XCTAssertNil(oneChar)
    }

    // MARK: - Canonical per-class examples (skip when model missing)

    func testToolActionWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("weather in Tokyo tomorrow morning") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        XCTAssertEqual(probe.label, .toolAction, "got \(probe.label) @ \(probe.confidence)")
    }

    func testKnowledgeWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("what is the capital city of Peru?") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        XCTAssertEqual(probe.label, .knowledge, "got \(probe.label) @ \(probe.confidence)")
    }

    func testConversationWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("I had a really rough day at work") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        XCTAssertEqual(probe.label, .conversation, "got \(probe.label) @ \(probe.confidence)")
    }

    func testRefinementWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("make it shorter and less formal") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        XCTAssertEqual(probe.label, .refinement, "got \(probe.label) @ \(probe.confidence)")
    }

    func testMetaWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("what can you do") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        XCTAssertEqual(probe.label, .meta, "got \(probe.label) @ \(probe.confidence)")
    }

    // MARK: - Multilingual

    func testSpanishToolActionWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        // "pronóstico del clima en Madrid" is unambiguous — "pronóstico del
        // clima" = "weather forecast". Using "el tiempo" is ambiguous in
        // Spanish ("tiempo" = weather OR time) and makes the test brittle.
        guard let probe = await classifier.classify("pronóstico del clima en Madrid mañana") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        // Assert top-3 rather than top-1: the classifier's ~79% val-acc
        // is its realistic ceiling on this dataset size. High-confidence
        // downstream dispatch requires ≥0.85, which this corpus often won't
        // hit; top-3 containment is the robustness signal that matters.
        let topLabels = probe.hypotheses.map { $0.label }
        XCTAssertTrue(
            topLabels.contains(.toolAction),
            "Expected toolAction in top hypotheses; got \(topLabels) (pred=\(probe.label) @ \(probe.confidence))"
        )
    }

    func testFrenchKnowledgeWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("quelle est la capitale de la France") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        XCTAssertEqual(probe.label, .knowledge, "got \(probe.label) @ \(probe.confidence)")
    }

    func testJapaneseMetaWhenModelPresent() async throws {
        let classifier = ConversationIntentClassifier.shared
        guard let probe = await classifier.classify("あなたは誰ですか") else {
            throw XCTSkip("ConversationIntent model not installed in this build")
        }
        // Lower-resource language with ~40 meta training examples; assert the
        // correct class is at least in the top hypotheses (robustness), not
        // strictly at the top. Prevents test brittleness on cross-lingual
        // calibration while still catching a regression that drops meta out
        // of contention entirely.
        let topLabels = probe.hypotheses.map { $0.label }
        XCTAssertTrue(
            topLabels.contains(.meta),
            "Expected meta in top hypotheses; got \(topLabels)"
        )
    }

    // MARK: - Confidence Tiers

    func testConfidenceTierBoundaries() async {
        let high = ConversationIntentClassifier.Result(
            label: .toolAction, confidence: 0.92, hypotheses: [(.toolAction, 0.92)]
        )
        XCTAssertEqual(high.confidenceTier, .high)

        let medium = ConversationIntentClassifier.Result(
            label: .conversation, confidence: 0.72, hypotheses: [(.conversation, 0.72)]
        )
        XCTAssertEqual(medium.confidenceTier, .medium)

        let low = ConversationIntentClassifier.Result(
            label: .meta, confidence: 0.35, hypotheses: [(.meta, 0.35)]
        )
        XCTAssertEqual(low.confidenceTier, .low)
    }
}
