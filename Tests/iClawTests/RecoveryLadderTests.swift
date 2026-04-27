import XCTest
import os
@testable import iClawCore

/// Tests for the finalization recovery ladder (R1 + R3), pre-emptive
/// guardrail-collision routing (R4), manual retry hint (R5), ingredient
/// preservation across re-routing (R6), and temperature plumbing.
final class RecoveryLadderTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    // MARK: - R1: Ladder Escalation

    /// When Tier 1 returns empty-after-cleaning, the ladder must retry at Tier 2.
    /// The stub responder returns `""` on the first call and real text on the
    /// second, verifying that the engine attempts the second call at all.
    func testLadderEscalatesOnEmptyTier1() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "London: 15°C", status: .ok, isVerifiedData: true)
        )
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: { _, _ in
                let count = callCount.withLock { n -> Int in n += 1; return n }
                // First call → empty; cleanLLMResponse will strip to "".
                // Second call (Tier 2) → real answer.
                return count == 1 ? "" : "It is 15°C in London."
            }
        )

        let result = await engine.run(input: "#weather London")

        XCTAssertEqual(spy.invocations.count, 1, "Tool should run once")
        let finalCalls = callCount.withLock { $0 }
        XCTAssertGreaterThanOrEqual(finalCalls, 2, "Ladder should have issued at least 2 LLM calls")
        XCTAssertFalse(result.isError, "Recovery succeeded — not an error")
        XCTAssertTrue(result.text.contains("15°C"), "Final text should be the Tier 2 answer")
    }

    /// When Tier 1 returns a soft refusal ("I can't assist") the ladder must
    /// escalate rather than accept the refusal verbatim.
    func testLadderEscalatesOnSoftRefusal() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Paris: 20°C", status: .ok, isVerifiedData: true)
        )
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: { _, _ in
                let count = callCount.withLock { n -> Int in n += 1; return n }
                return count == 1 ? "I'm sorry, but I can't assist." : "Paris is 20°C."
            }
        )

        let result = await engine.run(input: "#weather Paris")
        let finalCalls = callCount.withLock { $0 }
        XCTAssertGreaterThanOrEqual(finalCalls, 2, "Soft refusal should escalate")
        XCTAssertTrue(result.text.contains("20°C"), "Recovered answer reaches the user")
    }

    /// A clean Tier 1 answer should accept without issuing a Tier 2 call.
    func testLadderAcceptsTier1Success() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Tokyo: 22°C", status: .ok)
        )
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: { _, _ in
                callCount.withLock { $0 += 1 }
                return "Tokyo is a comfortable 22°C."
            }
        )

        _ = await engine.run(input: "#weather Tokyo")
        XCTAssertEqual(callCount.withLock { $0 }, 1,
            "Clean Tier 1 should not escalate")
    }

    // MARK: - R4: Pre-emptive Tier 2 on Emotional Inputs

    func testEmotionalInputBypassesSoulDirectives() {
        XCTAssertTrue(ExecutionEngine.inputTriggersGuardrailCollision("you're useless"))
        XCTAssertTrue(ExecutionEngine.inputTriggersGuardrailCollision("I HATE you"))
        XCTAssertTrue(ExecutionEngine.inputTriggersGuardrailCollision("yeah you suck at this"))
        XCTAssertFalse(ExecutionEngine.inputTriggersGuardrailCollision("what's the weather"))
        XCTAssertFalse(ExecutionEngine.inputTriggersGuardrailCollision("hello"))
    }

    // MARK: - OutputFinalizer RecoveryLevel

    func testLadderFromFullCoversAllTiers() {
        XCTAssertEqual(ExecutionEngine.ladderFrom(.full), [.full, .minimal, .bare])
    }

    func testLadderFromMinimalSkipsTier1() {
        XCTAssertEqual(ExecutionEngine.ladderFrom(.minimal), [.minimal, .bare])
    }

    func testLadderFromBareIsSingleStep() {
        XCTAssertEqual(ExecutionEngine.ladderFrom(.bare), [.bare])
    }

    // MARK: - R5: Recovery Hint

    /// Passing `.minimal` as the recovery hint should cause the engine to skip
    /// Tier 1 entirely. We detect this by inspecting the captured prompt — at
    /// Tier 2, SOUL content should not appear in the prompt body.
    func testRecoveryHintMinimalSkipsFullTier() async throws {
        let spy = SpyTool(
            name: "Weather",
            schema: "weather forecast",
            result: ToolIO(text: "Berlin: 12°C", status: .ok)
        )
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(response: "Berlin is 12°C.", capture: captured)
        )

        _ = await engine.run(input: "#weather Berlin", recoveryHint: .minimal)

        let promptSent = captured.value
        XCTAssertFalse(promptSent.contains("<brain>"),
            "Tier 2 prompt should not wrap in <brain> full-envelope tags")
        XCTAssertTrue(promptSent.contains("Berlin"),
            "Request should still be present at Tier 2")
    }

    // MARK: - LLMTemperature

    func testTemperaturePresetsInRange() {
        for value in [
            LLMTemperature.deterministic,
            LLMTemperature.extraction,
            LLMTemperature.structured,
            LLMTemperature.validation,
            LLMTemperature.conversational,
            LLMTemperature.recovery,
            LLMTemperature.creative,
        ] {
            XCTAssertGreaterThanOrEqual(value, 0.0, "Temperature below Apple's [0, 1] range")
            XCTAssertLessThanOrEqual(value, 1.0, "Temperature above Apple's [0, 1] range")
        }
    }

    func testRecoveryTemperatureIsMaximallyNeutral() {
        XCTAssertEqual(LLMTemperature.recovery, 1.0,
            "Recovery uses 1.0 (no distribution sharpening) to break determinism")
    }

    func testStructuredTemperaturesFavorDeterminism() {
        XCTAssertLessThan(LLMTemperature.extraction, 0.3,
            "Schema-bound extraction must stay near deterministic")
        XCTAssertLessThan(LLMTemperature.validation, 0.3,
            "YES/NO classification must stay near deterministic")
    }
}
