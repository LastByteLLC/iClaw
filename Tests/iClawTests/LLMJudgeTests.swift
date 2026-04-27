import XCTest
@testable import iClawCore

final class LLMJudgeTests: XCTestCase {

    // MARK: - Intent judge

    func testIntentJudgeParsesCleanAnswer() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "tool_action" }
        let label = await judge.judgeIntent(input: "weather in tokyo", responder: responder)
        XCTAssertEqual(label, .toolAction)
    }

    func testIntentJudgeParsesAnswerWithPunctuation() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "refinement." }
        let label = await judge.judgeIntent(input: "make it shorter", responder: responder)
        XCTAssertEqual(label, .refinement)
    }

    func testIntentJudgeParsesWithinSentence() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "This is meta." }
        let label = await judge.judgeIntent(input: "who are you", responder: responder)
        XCTAssertEqual(label, .meta)
    }

    func testIntentJudgeReturnsNilOnGarbage() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "banana" }
        let label = await judge.judgeIntent(input: "what's the capital of France", responder: responder)
        XCTAssertNil(label)
    }

    func testIntentJudgeReturnsNilOnThrow() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in throw NSError(domain: "test", code: 1) }
        let label = await judge.judgeIntent(input: "anything", responder: responder)
        XCTAssertNil(label)
    }

    // MARK: - Pathology judge

    func testPathologyJudgeMatchesLongestLabelFirst() async {
        // "meta_leak" contains the substring "meta" but is its own label —
        // parsePathologyLabel must prefer the longer match.
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "meta_leak" }
        let label = await judge.judgePathology(
            response: "Here's what I found: Paris", responder: responder
        )
        XCTAssertEqual(label, .metaLeak)
    }

    func testPathologyJudgeParsesOk() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "ok" }
        let label = await judge.judgePathology(
            response: "Paris is the capital of France.", responder: responder
        )
        XCTAssertEqual(label, .ok)
    }

    func testPathologyJudgeParsesEmptyStub() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "empty_stub." }
        let label = await judge.judgePathology(
            response: "Okay.", responder: responder
        )
        XCTAssertEqual(label, .emptyStub)
    }

    // MARK: - UserFact judge

    func testUserFactJudgeParsesDietary() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "dietary" }
        let label = await judge.judgeUserFact(input: "I'm vegetarian", responder: responder)
        XCTAssertEqual(label, .dietary)
    }

    func testUserFactJudgeParsesLocationFactLongest() async {
        let judge = LLMJudge(cacheCapacity: 16)
        // Must match "location_fact" (longer) not "location" or "fact".
        let responder: SimpleLLMResponder = { _ in "location_fact" }
        let label = await judge.judgeUserFact(input: "I live in Paris", responder: responder)
        XCTAssertEqual(label, .locationFact)
    }

    func testUserFactJudgeParsesNone() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "none" }
        let label = await judge.judgeUserFact(input: "what's the weather", responder: responder)
        // Explicit fully-qualified label — bare `.none` infers as Optional.none.
        XCTAssertEqual(label, UserFactClassifier.Label.none)
    }

    // MARK: - Cache

    func testCacheReturnsIdenticalResultWithoutSecondCall() async {
        actor CallCounter {
            var count = 0
            func inc() { count += 1 }
            var value: Int { count }
        }
        let counter = CallCounter()
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in
            await counter.inc()
            return "knowledge"
        }

        let first = await judge.judgeIntent(input: "what is photosynthesis", responder: responder)
        let second = await judge.judgeIntent(input: "what is photosynthesis", responder: responder)

        XCTAssertEqual(first, .knowledge)
        XCTAssertEqual(second, .knowledge)
        let callCount = await counter.value
        XCTAssertEqual(callCount, 1, "Second call should have been served from cache")
    }

    func testCacheEvictsOldestAfterCapacity() async {
        let judge = LLMJudge(cacheCapacity: 2)
        let responder: SimpleLLMResponder = { prompt in
            // Cycle through different labels so each prompt hashes uniquely.
            if prompt.contains("Alpha") { return "tool_action" }
            if prompt.contains("Beta") { return "knowledge" }
            if prompt.contains("Gamma") { return "conversation" }
            return "meta"
        }

        _ = await judge.judgeIntent(input: "Alpha", responder: responder)
        _ = await judge.judgeIntent(input: "Beta", responder: responder)
        let entriesAfter2 = await judge.cachedEntryCount
        XCTAssertEqual(entriesAfter2, 2)

        _ = await judge.judgeIntent(input: "Gamma", responder: responder)
        let entriesAfter3 = await judge.cachedEntryCount
        XCTAssertEqual(entriesAfter3, 2, "Capacity should cap at 2")
    }

    func testClearCacheEmptiesEntries() async {
        let judge = LLMJudge(cacheCapacity: 16)
        let responder: SimpleLLMResponder = { _ in "conversation" }
        _ = await judge.judgeIntent(input: "hey how's it going", responder: responder)
        var count = await judge.cachedEntryCount
        XCTAssertEqual(count, 1)

        await judge.clearCache()
        count = await judge.cachedEntryCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Classifier-hint in prompt

    func testIntentPromptIncludesHintWhenGiven() {
        let hint = ConversationIntentClassifier.Result(
            label: .toolAction,
            confidence: 0.7,
            hypotheses: [
                (.toolAction, 0.7),
                (.knowledge, 0.2),
                (.conversation, 0.1),
            ]
        )
        let prompt = LLMJudge.buildIntentPrompt(input: "weather in Tokyo", hint: hint)
        XCTAssertTrue(prompt.contains("Classifier hint:"))
        XCTAssertTrue(prompt.contains("tool_action"))
        XCTAssertTrue(prompt.contains("0.70"))
    }

    func testIntentPromptOmitsHintWhenAbsent() {
        let prompt = LLMJudge.buildIntentPrompt(input: "weather in Tokyo", hint: nil)
        XCTAssertFalse(prompt.contains("Classifier hint:"))
    }

    // MARK: - Parser edge cases

    func testParseIntentLabelIgnoresQuotesAndCase() {
        XCTAssertEqual(LLMJudge.parseIntentLabel("\"REFINEMENT\""), .refinement)
        XCTAssertEqual(LLMJudge.parseIntentLabel("'meta'."), .meta)
        XCTAssertEqual(LLMJudge.parseIntentLabel("  Knowledge.  "), .knowledge)
    }

    func testParsePathologyLabelPrefersExactTwoWord() {
        // "instruction_echo" contains "echo" — longest-match ordering
        // ensures we don't misread it as a short label.
        XCTAssertEqual(LLMJudge.parsePathologyLabel("instruction_echo"), .instructionEcho)
        XCTAssertEqual(LLMJudge.parsePathologyLabel("pure_ingredient_echo."), .pureIngredientEcho)
    }

    func testParseUserFactLabelIgnoresTrailingNewline() {
        XCTAssertEqual(LLMJudge.parseUserFactLabel("dietary\n"), .dietary)
        XCTAssertEqual(LLMJudge.parseUserFactLabel("self_identity"), .selfIdentity)
    }
}
