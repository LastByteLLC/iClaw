import XCTest
@testable import iClawCore

/// Unit tests for the Phase-5 wiring seams: the ladder primitives that
/// connect the classifiers + judge into the engine. Full engine E2E tests
/// are deferred because the engine initialization in tests is heavy and the
/// flag-based wiring is already exercised via the classifier and judge
/// suites — these tests cover the glue that specifically didn't exist before
/// Phase 5.

final class Phase5WiringTests: XCTestCase {

    // Reset relevant flags between tests so one test's defaults don't bleed
    // into the next.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierResponseCleaningKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierUserFactsKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierIntentRoutingKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useLLMJudgeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierResponseCleaningKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierUserFactsKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierIntentRoutingKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useLLMJudgeKey)
        super.tearDown()
    }

    // MARK: - ConversationState.userFacts (Phase 5b state plumbing)

    func testRecordUserFactStoresNewEntry() {
        var state = ConversationState()
        state.recordUserFact(category: "dietary", value: "I'm vegetarian")

        XCTAssertEqual(state.userFacts.count, 1)
        XCTAssertEqual(state.userFacts.first?.category, "dietary")
        XCTAssertEqual(state.userFacts.first?.value, "I'm vegetarian")
    }

    func testRecordUserFactReplacesSameCategory() {
        // Corrections win: "I'm 36" → "actually 37" should end at 37.
        var state = ConversationState()
        state.recordUserFact(category: "self_identity", value: "I'm 36")
        state.recordUserFact(category: "self_identity", value: "actually I turned 37")

        XCTAssertEqual(state.userFacts.count, 1)
        XCTAssertEqual(state.userFacts.first?.value, "actually I turned 37")
    }

    func testRecordUserFactPreservesDifferentCategories() {
        var state = ConversationState()
        state.recordUserFact(category: "self_identity", value: "my name is Jasmine")
        state.recordUserFact(category: "dietary", value: "I'm vegan")
        state.recordUserFact(category: "family", value: "my daughter Anna")

        XCTAssertEqual(state.userFacts.count, 3)
        let categories = Set(state.userFacts.map { $0.category })
        XCTAssertEqual(categories, ["self_identity", "dietary", "family"])
    }

    func testRecordUserFactTruncatesLongValues() {
        var state = ConversationState()
        let long = String(repeating: "x", count: 500)
        state.recordUserFact(category: "preference", value: long)

        XCTAssertLessThanOrEqual(state.userFacts.first?.value.count ?? 0, 120)
    }

    func testRecordUserFactIgnoresEmpty() {
        var state = ConversationState()
        state.recordUserFact(category: "dietary", value: "")
        state.recordUserFact(category: "dietary", value: "   ")

        XCTAssertEqual(state.userFacts.count, 0)
    }

    func testUserFactsCapAtEightEntries() {
        // The cap prevents the <ctx> block from ballooning.
        var state = ConversationState()
        for i in 0..<12 {
            state.recordUserFact(category: "cat_\(i)", value: "value \(i)")
        }

        XCTAssertEqual(state.userFacts.count, 8)
        // Oldest should be evicted — cat_4 should be the oldest surviving.
        XCTAssertEqual(state.userFacts.first?.category, "cat_4")
        XCTAssertEqual(state.userFacts.last?.category, "cat_11")
    }

    // MARK: - userFacts show up in prompt context

    func testAsPromptContextIncludesUserFacts() {
        var state = ConversationState(turnCount: 1)
        state.recordUserFact(category: "dietary", value: "vegetarian, no nuts")
        state.recordUserFact(category: "self_identity", value: "my name is Alex, age 34")

        let ctx = state.asPromptContext()
        XCTAssertTrue(ctx.contains("About user:"))
        XCTAssertTrue(ctx.contains("dietary"))
        XCTAssertTrue(ctx.contains("self_identity"))
        XCTAssertTrue(ctx.contains("Alex"))
    }

    func testAsPromptContextOmitsUserFactsWhenEmpty() {
        let state = ConversationState(turnCount: 1)
        let ctx = state.asPromptContext()
        XCTAssertFalse(ctx.contains("About user:"))
    }

    // MARK: - Placement: ConversationManager exposes recordUserFact

    func testManagerRecordUserFactReachesState() async {
        let manager = ConversationManager()
        await manager.recordUserFact(category: "dietary", value: "I eat halal")
        let state = await manager.state
        XCTAssertEqual(state.userFacts.count, 1)
        XCTAssertEqual(state.userFacts.first?.category, "dietary")
    }

    // MARK: - AppConfig flag plumbing

    func testAllPhase5FlagsDefaultOff() {
        // Contract: feature flags all default OFF so Phase 5 ships safe —
        // no behavior change until the flags are explicitly flipped.
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierResponseCleaningKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierUserFactsKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useClassifierIntentRoutingKey)
        UserDefaults.standard.removeObject(forKey: AppConfig.useLLMJudgeKey)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppConfig.useClassifierResponseCleaningKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppConfig.useClassifierUserFactsKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppConfig.useClassifierIntentRoutingKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppConfig.useLLMJudgeKey))
    }
}
