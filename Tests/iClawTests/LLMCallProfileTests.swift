import Foundation
import Testing
@testable import iClawCore

/// Unit tests for `LLMCallProfile` and `LLMSamplingMode`.
///
/// These tests verify the knobs are set coherently per preset — they don't
/// invoke the real LLM. The AFM → `GenerationOptions` mapping is exercised
/// indirectly by the existing E2E tests; here we only validate the profile
/// surface so call-sites that pass `profile: .foo` get the intended values.
@Suite("LLMCallProfile presets")
struct LLMCallProfileTests {

    // MARK: - Greedy / deterministic profiles

    @Test("validation is deterministic, greedy, single-token-ish cap")
    func validationProfile() {
        let p = LLMCallProfile.validation
        #expect(p.temperature == LLMTemperature.deterministic)
        #expect(p.sampling == .greedy)
        #expect(p.maxTokens == 5)
    }

    @Test("scoring is deterministic, greedy, tightest cap")
    func scoringProfile() {
        let p = LLMCallProfile.scoring
        #expect(p.temperature == LLMTemperature.deterministic)
        #expect(p.sampling == .greedy)
        // Tightest cap of all profiles — only room for a 1-digit rating + trim.
        if let cap = p.maxTokens {
            #expect(cap <= 5)
        } else {
            Issue.record("scoring profile must set a maxTokens cap")
        }
    }

    @Test("extraction uses low temperature + greedy sampling")
    func extractionProfile() {
        let p = LLMCallProfile.extraction
        #expect(p.temperature == LLMTemperature.extraction)
        #expect(p.sampling == .greedy)
        #expect((p.maxTokens ?? 0) > 0)
    }

    @Test("normalization is greedy with a tight cap")
    func normalizationProfile() {
        let p = LLMCallProfile.normalization
        #expect(p.sampling == .greedy)
        #expect(p.temperature == LLMTemperature.deterministic)
        #expect((p.maxTokens ?? Int.max) <= 100)
    }

    @Test("healing is greedy structured with a short cap")
    func healingProfile() {
        let p = LLMCallProfile.healing
        #expect(p.sampling == .greedy)
        #expect(p.temperature == LLMTemperature.structured)
        #expect((p.maxTokens ?? Int.max) <= 120)
    }

    // MARK: - Low-variance profiles

    @Test("summarization caps tightly so summaries can't exceed source")
    func summarizationProfile() {
        let p = LLMCallProfile.summarization
        #expect(p.sampling == .greedy)
        #expect(p.temperature == LLMTemperature.structured)
        // 2–3 sentence ceiling.
        #expect((p.maxTokens ?? Int.max) <= 100)
    }

    @Test("planning is greedy with a compact plan cap")
    func planningProfile() {
        let p = LLMCallProfile.planning
        #expect(p.sampling == .greedy)
        #expect(p.temperature == LLMTemperature.extraction)
        #expect((p.maxTokens ?? 0) > 0)
    }

    @Test("widgetLayout is greedy and sized for compact DSL")
    func widgetLayoutProfile() {
        let p = LLMCallProfile.widgetLayout
        #expect(p.sampling == .greedy)
        #expect((p.maxTokens ?? Int.max) <= 500)
    }

    // MARK: - Sampled / creative profiles

    @Test("finalAnswer caps at the generation budget and samples randomly")
    func finalAnswerProfile() {
        let p = LLMCallProfile.finalAnswer
        #expect(p.temperature == LLMTemperature.conversational)
        #expect(p.maxTokens == AppConfig.generationSpace)
        // Must be random — greedy makes user-facing text stilted.
        switch p.sampling {
        case .random: break
        case .greedy, .none: Issue.record("finalAnswer must use random sampling")
        }
    }

    @Test("personalize is a short random-sampled rephrase")
    func personalizeProfile() {
        let p = LLMCallProfile.personalize
        #expect(p.temperature == LLMTemperature.conversational)
        // ≤10 words implies <40 tokens.
        #expect((p.maxTokens ?? Int.max) <= 40)
        switch p.sampling {
        case .random: break
        default: Issue.record("personalize must sample randomly")
        }
    }

    @Test("creative profiles (greeting/phrases/toolTip/feedbackSuggestions) all sample randomly")
    func creativeProfilesSampleRandomly() {
        for p in [LLMCallProfile.greeting, .phrases, .toolTip, .feedbackSuggestions] {
            switch p.sampling {
            case .random: break
            default: Issue.record("creative profile \(p) must sample randomly")
            }
            #expect(p.temperature == LLMTemperature.creative)
        }
    }

    @Test("recovery widens top and jumps temperature to break mode collapse")
    func recoveryProfile() {
        let p = LLMCallProfile.recovery
        #expect(p.temperature == LLMTemperature.recovery)
        switch p.sampling {
        case .random(let top, _):
            // Wider than the default 40 used by creative profiles — the point
            // of recovery is to actively explore a different neighborhood.
            #expect((top ?? 0) >= 80)
        default:
            Issue.record("recovery must use random sampling to escape greedy stalls")
        }
    }

    // MARK: - Sampling mode equality

    @Test("greedy equality")
    func greedyEquality() {
        #expect(LLMSamplingMode.greedy == .greedy)
    }

    @Test("random equality honors top and seed")
    func randomEquality() {
        #expect(LLMSamplingMode.random(top: 40, seed: nil) == .random(top: 40, seed: nil))
        #expect(LLMSamplingMode.random(top: 40, seed: 42) != .random(top: 40, seed: 7))
        #expect(LLMSamplingMode.random(top: 40) != .random(top: 80))
    }
}
