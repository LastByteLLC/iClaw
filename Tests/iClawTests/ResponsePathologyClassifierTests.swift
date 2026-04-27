import XCTest
@testable import iClawCore

final class ResponsePathologyClassifierTests: XCTestCase {

    // MARK: - Model Loading

    func testLoadsOrSkipsGracefully() async {
        let classifier = ResponsePathologyClassifier.shared
        // If the .mlmodelc isn't installed yet (Phase 1 is ship-the-model-optional),
        // classify() returns nil. That's a valid state — the engine falls back
        // to heuristic cleaning. No crash.
        _ = await classifier.classify("The capital of France is Paris.")
    }

    func testShortInputReturnsNil() async {
        let classifier = ResponsePathologyClassifier.shared
        let empty = await classifier.classify("")
        let space = await classifier.classify(" ")
        let oneChar = await classifier.classify("x")
        XCTAssertNil(empty)
        XCTAssertNil(space)
        XCTAssertNil(oneChar)
    }

    // MARK: - Functional (skip-on-missing-model)

    /// Checks that OK-class examples classify as `ok`. Skipped entirely when
    /// the bundle doesn't ship the model (Phase 1 flag-gated state).
    func testOkClassificationWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        // Use a substantive conversational answer that's unambiguously in the
        // `ok` class — long, informative, no preamble, no refusal signal.
        let input = "Photosynthesis converts sunlight, water, and carbon dioxide into glucose and oxygen. It happens mainly in the chloroplasts of plant cells, where the pigment chlorophyll absorbs light and drives the chemical reactions that store solar energy as chemical bonds in sugar."
        guard let probe = await classifier.classify(input) else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .ok, "Expected ok, got \(probe.label) @ \(probe.confidence)")
        // 6-class baseline is 1/6 ≈ 0.17. A solid `ok` example should clear
        // 0.3 comfortably; set the floor there to catch true regressions
        // without being brittle to individual-example calibration drift.
        XCTAssertGreaterThanOrEqual(probe.confidence, 0.3)
    }

    func testRefusalClassificationWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        guard let probe = await classifier.classify("I cannot fulfill that request.") else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .refusal, "Expected refusal, got \(probe.label) @ \(probe.confidence)")
    }

    func testMetaLeakClassificationWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        guard let probe = await classifier.classify("Here's what I found:\n\nParis is the capital of France.") else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .metaLeak)
    }

    func testEmptyStubClassificationWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        guard let probe = await classifier.classify("Okay.") else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .emptyStub)
    }

    func testPureIngredientEchoClassificationWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        let input = "Recent topics: weather in Paris. Active entities: Paris, France. Turn: 3"
        guard let probe = await classifier.classify(input) else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .pureIngredientEcho)
    }

    // MARK: - Multilingual

    func testSpanishRefusalWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        guard let probe = await classifier.classify("Lo siento, pero no puedo ayudar con eso.") else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .refusal)
    }

    func testFrenchOkWhenModelPresent() async throws {
        let classifier = ResponsePathologyClassifier.shared
        guard let probe = await classifier.classify("La capitale de la France est Paris, une ville fondée il y a plus de 2000 ans.") else {
            throw XCTSkip("ResponsePathology model not installed in this build")
        }
        XCTAssertEqual(probe.label, .ok)
    }

    // MARK: - Confidence Tiers

    func testConfidenceTierBoundaries() async {
        // Pure unit test, no model required.
        let high = ResponsePathologyClassifier.Result(
            label: .ok, confidence: 0.91, hypotheses: [(.ok, 0.91)]
        )
        XCTAssertEqual(high.confidenceTier, .high)

        let medium = ResponsePathologyClassifier.Result(
            label: .ok, confidence: 0.70, hypotheses: [(.ok, 0.70)]
        )
        XCTAssertEqual(medium.confidenceTier, .medium)

        let low = ResponsePathologyClassifier.Result(
            label: .ok, confidence: 0.40, hypotheses: [(.ok, 0.40)]
        )
        XCTAssertEqual(low.confidenceTier, .low)
    }

    // MARK: - High-Confidence Refusal Gate

    func testHighConfidenceRefusalIsSafeWithoutModel() async {
        // Without the model, the gate MUST return false — engine should
        // fall through to the legacy heuristic path unchanged.
        let classifier = ResponsePathologyClassifier.shared
        let isRefusal = await classifier.isHighConfidenceRefusal("I cannot fulfill that request.")
        // Without a model loaded, always false.
        if await !Self.modelIsLoaded() {
            XCTAssertFalse(isRefusal)
        }
    }

    // MARK: - Helpers

    /// Quick introspection: did the classifier actually load a model? Used by
    /// the safe-fallback test above to skip its assertion when the model IS
    /// present (because then the gate's behavior is expected to be true).
    private static func modelIsLoaded() async -> Bool {
        await ResponsePathologyClassifier.shared.classify("The quick brown fox jumps over the lazy dog.") != nil
    }
}
