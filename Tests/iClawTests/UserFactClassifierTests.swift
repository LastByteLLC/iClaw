import XCTest
@testable import iClawCore

final class UserFactClassifierTests: XCTestCase {

    // MARK: - Loading

    func testLoadsOrSkipsGracefully() async {
        let classifier = UserFactClassifier.shared
        _ = await classifier.classify("I'm vegetarian")
    }

    func testShortInputReturnsNil() async {
        let classifier = UserFactClassifier.shared
        let empty = await classifier.classify("")
        let oneChar = await classifier.classify("x")
        XCTAssertNil(empty)
        XCTAssertNil(oneChar)
    }

    // MARK: - Canonical per-class examples (skip when model missing)

    func testNoneWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("what's the weather in Tokyo right now") else {
            throw XCTSkip("UserFact model not installed")
        }
        XCTAssertEqual(probe.label, .none, "got \(probe.label) @ \(probe.confidence)")
    }

    func testSelfIdentityWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        // Combine name + age for an unambiguous self-identity signal. A bare
        // "my name is X" where X is a proper noun may be borderline because
        // the name could belong to a family member in training distribution.
        guard let probe = await classifier.classify("I'm 37 years old and my name is Alex") else {
            throw XCTSkip("UserFact model not installed")
        }
        let topLabels = probe.hypotheses.map { $0.label }
        XCTAssertTrue(topLabels.contains(.selfIdentity), "got \(topLabels)")
    }

    func testDietaryWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("I'm vegetarian and allergic to peanuts") else {
            throw XCTSkip("UserFact model not installed")
        }
        XCTAssertEqual(probe.label, .dietary, "got \(probe.label) @ \(probe.confidence)")
    }

    func testFamilyWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("my daughter Anna is starting kindergarten") else {
            throw XCTSkip("UserFact model not installed")
        }
        XCTAssertEqual(probe.label, .family, "got \(probe.label) @ \(probe.confidence)")
    }

    func testLocationFactWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("I live in Berlin now, just moved last month") else {
            throw XCTSkip("UserFact model not installed")
        }
        // Accept top-3 containment — location_fact language can overlap with
        // small-talk ("I'm in Berlin right now") which is borderline.
        let topLabels = probe.hypotheses.map { $0.label }
        XCTAssertTrue(topLabels.contains(.locationFact), "got \(topLabels)")
    }

    func testWorkFactWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("I'm a software engineer at a startup") else {
            throw XCTSkip("UserFact model not installed")
        }
        XCTAssertEqual(probe.label, .workFact, "got \(probe.label) @ \(probe.confidence)")
    }

    func testPreferenceWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("please always reply in metric units") else {
            throw XCTSkip("UserFact model not installed")
        }
        XCTAssertEqual(probe.label, .preference, "got \(probe.label) @ \(probe.confidence)")
    }

    // MARK: - Multilingual

    func testSpanishDietaryWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("soy vegetariana y alérgica a los frutos secos") else {
            throw XCTSkip("UserFact model not installed")
        }
        // Accept top-3 — multilingual classifier with ~50 examples per
        // (class, language) cell may not always put the correct class at
        // top-1 (see Phase 2.5 learnings).
        let topLabels = probe.hypotheses.map { $0.label }
        XCTAssertTrue(topLabels.contains(.dietary), "got \(topLabels)")
    }

    func testFrenchSelfIdentityWhenModelPresent() async throws {
        let classifier = UserFactClassifier.shared
        guard let probe = await classifier.classify("je m'appelle Marie et j'ai 34 ans") else {
            throw XCTSkip("UserFact model not installed")
        }
        let topLabels = probe.hypotheses.map { $0.label }
        XCTAssertTrue(topLabels.contains(.selfIdentity), "got \(topLabels)")
    }

    // MARK: - High-confidence fact gate

    func testIsHighConfidenceFactSafeWithoutModel() async {
        let classifier = UserFactClassifier.shared
        let result = await classifier.isHighConfidenceFact("I'm vegetarian")
        // Without the model loaded, must be nil (engine falls through to
        // legacy heuristics).
        if await UserFactClassifier.shared.classify("The quick brown fox") == nil {
            XCTAssertNil(result)
        }
    }

    // MARK: - Confidence tiers

    func testConfidenceTierBoundaries() {
        let high = UserFactClassifier.Result(
            label: .dietary, confidence: 0.91, hypotheses: [(.dietary, 0.91)]
        )
        XCTAssertEqual(high.confidenceTier, .high)

        let medium = UserFactClassifier.Result(
            label: .family, confidence: 0.70, hypotheses: [(.family, 0.70)]
        )
        XCTAssertEqual(medium.confidenceTier, .medium)

        let low = UserFactClassifier.Result(
            label: .none, confidence: 0.40, hypotheses: [(.none, 0.40)]
        )
        XCTAssertEqual(low.confidenceTier, .low)
    }
}
