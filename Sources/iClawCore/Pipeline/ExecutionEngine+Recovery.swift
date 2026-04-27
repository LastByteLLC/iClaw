import Foundation
import FoundationModels

extension ExecutionEngine {

    // MARK: - Finalization Recovery Ladder

    /// Decision emitted by the failure-mode classifier.
    enum FinalizationDecision {
        case accept
        case escalate(reason: String)
    }

    /// Returns the full ladder starting at `start`: .full → .minimal → .bare,
    /// skipping tiers that precede the start level.
    static func ladderFrom(_ start: OutputFinalizer.RecoveryLevel) -> [OutputFinalizer.RecoveryLevel] {
        switch start {
        case .full: return [.full, .minimal, .bare]
        case .minimal: return [.minimal, .bare]
        case .bare: return [.bare]
        }
    }

    /// Merges the finalizer's instructions block with the FM-tool override line.
    /// Returns nil when both are empty/absent.
    static func mergeInstructions(_ base: iClawInstructions?, _ fmOverride: String?) -> iClawInstructions? {
        let fmSegment = Directive(fmOverride)
        switch (base, fmSegment) {
        case (.none, .none):
            return nil
        case (.some(let base), .none):
            return base.isEmpty ? nil : base
        case (.none, .some(let seg)):
            return iClawInstructions(segments: [seg])
        case (.some(let base), .some(let seg)):
            return base.appending(seg)
        }
    }

    /// Strips tool-advertising lines from the user profile context. Keeps
    /// identity (name, email, preferences) and drops anything that would
    /// prompt the LLM to volunteer tool names in a conversational turn.
    ///
    /// The profile string is a `", "`-joined list of `"Label: value"` parts
    /// produced by `UserProfileProvider.current(with:)`. We filter parts by
    /// the `Label:` prefix against a small disallow list. Label tokens are
    /// kept in English because that's what the profile builder emits — the
    /// user-visible response language is unaffected by this filtering.
    /// Matches labelled sections that leak as prompt echo when the LLM is
    /// in conversational mode. The substrings each target one of the lines
    /// emitted by `ConversationState.asPromptContext()` /
    /// `UserProfileManager.profileContext()` that we DON'T want conversational
    /// responses to parrot. Each is preceded by `". "`, `\n`, or start-of-
    /// string and terminated by the same.
    private static let toolAdvertisingRegex = try! NSRegularExpression(
        pattern: #"(?:(?<=^)|(?<=\. )|(?<=\n))(?:Frequently used|Common topics|Recent topics|Active entities|Recent data|Preferences|Turn):[^\n]*(?:\n|$)"#,
        options: []
    )

    /// In conversational turns, the user's name from the MeCard leaks into
    /// responses ("Tom, you should..."). The LLM has no reason to address
    /// the user by name unless the user introduced themselves that turn.
    /// Strip `User: …` and `Email: …` lines so the base model doesn't see them.
    private static let identityLinesRegex = try! NSRegularExpression(
        pattern: #"(?:(?<=^)|(?<=\. )|(?<=\n))(?:User|Email):[^\n.]*(?:\.\s*|\n|$)"#,
        options: []
    )

    /// Mirrors known preference keys into `UserDefaults` so tools that
    /// already read settings from there (WeatherTool's temperature unit,
    /// etc.) pick up conversation-derived preferences without needing to
    /// take a new dependency on `ConversationManager`. The full preference
    /// is also stored in `state.userPreferences` for LLM consumption via
    /// `<ctx>`. The map is kept narrow and explicit — each (key, value)
    /// pair is normalized to the format the tool already expects.
    static func mirrorPreferenceToUserDefaults(key: String, value: String) {
        let k = key.lowercased()
        let v = value.lowercased()
        switch k {
        case "unit_system", "units", "measurement_system":
            // WeatherTool reads `AppConfig.temperatureUnitKey`; values are
            // "celsius" / "fahrenheit" / "system" per `TemperatureUnit`.
            if v.contains("metric") || v.contains("celsius") || v.contains("si") {
                UserDefaults.standard.set("celsius", forKey: AppConfig.temperatureUnitKey)
            } else if v.contains("imperial") || v.contains("fahrenheit") || v.contains("us") {
                UserDefaults.standard.set("fahrenheit", forKey: AppConfig.temperatureUnitKey)
            }
        case "temperature_unit":
            if v.contains("c") || v.contains("celsius") || v.contains("metric") {
                UserDefaults.standard.set("celsius", forKey: AppConfig.temperatureUnitKey)
            } else if v.contains("f") || v.contains("fahrenheit") {
                UserDefaults.standard.set("fahrenheit", forKey: AppConfig.temperatureUnitKey)
            }
        default:
            break  // Unknown preference — only state.userPreferences picks it up.
        }
    }

    static func stripProfileForConversation(_ profile: String) -> String {
        guard !profile.isEmpty else { return profile }
        // Only strip tool-advertising lines ("Frequently used:", "Common
        // topics:", etc.). Identity lines ("User:", "Email:") stay so the LLM
        // can address the user by name when they open with a greeting. The
        // BRAIN rules already forbid leading with a bare name salutation, so
        // stripping identity here is belt-and-suspenders that breaks the
        // `ProfileStripTests` spec (which expects identity preserved).
        let range = NSRange(profile.startIndex..., in: profile)
        let stripped = toolAdvertisingRegex.stringByReplacingMatches(
            in: profile, options: [], range: range, withTemplate: ""
        )
        // Collapse double separators left by the removal and clean edges.
        return stripped
            .replacingOccurrences(of: "\n\n", with: "\n")
            .replacingOccurrences(of: ".  ", with: ". ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wraps an LLM call with a timeout. Matches the prior 15s Finalization
    /// semantics but parameterized per-tier (8s for minimal, 5s for bare).
    ///
    /// Caps the response at `AppConfig.generationSpace` tokens so a runaway
    /// final answer can't blow the 4K context window, and samples from the
    /// top-40 distribution to keep the user-facing voice lively.
    static func generateWithTimeout(
        adapter: LLMAdapter,
        responder: LLMResponder?,
        prompt: String,
        tools: [any Tool],
        instructions: iClawInstructions?,
        temperature: Double?,
        timeoutNs: UInt64,
        maxTokens: Int? = AppConfig.generationSpace,
        sampling: LLMSamplingMode? = LLMCallProfile.finalAnswer.sampling
    ) async throws -> String {
        if let responder {
            return try await responder(prompt, tools)
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let response = try await adapter.guardedGenerate(
                    prompt: prompt,
                    tools: tools,
                    instructions: instructions,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    sampling: sampling
                )
                return response.content
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw LLMAdapter.AdapterError.generationFailed("Finalization timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Decides whether the current tier's cleaned response is acceptable or
    /// whether the ladder should escalate. Encodes R3's failure-mode logic.
    func classifyFinalization(
        cleaned: String,
        hasSubstantiveIngredients: Bool,
        level: OutputFinalizer.RecoveryLevel
    ) -> FinalizationDecision {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty after cleaning (covers JSON leak, system-prompt leak, context
        // regurgitation — all already stripped to empty by cleanLLMResponse).
        if trimmed.isEmpty {
            if level == .bare {
                return .accept  // Will fall through to extractive/generic below
            }
            return .escalate(reason: "emptyAfterCleaning")
        }

        // Soft refusals: the model said "I can't assist" despite the user asking
        // for something normal. Escalate so Tier 2 tries without SOUL. At Tier 3
        // we accept — nothing better to try.
        if isSoftRefusal(trimmed) {
            if level == .bare {
                return .accept
            }
            return .escalate(reason: "softRefusal")
        }

        // Non-empty, non-refusal response is accepted. Terse answers ("15°C",
        // "Yes") are valid — don't second-guess them even when ingredients exist.
        _ = hasSubstantiveIngredients
        return .accept
    }

    /// Returns the ladder starting point for a given turn — usually `.full`,
    /// but preemptively downgrades to `.minimal` when the input is likely to
    /// collide with SOUL's "sassy/blunt" guardrails (R4).
    func preemptiveRecoveryLevel(
        for input: String,
        pivotDetected: Bool
    ) -> OutputFinalizer.RecoveryLevel {
        if Self.inputTriggersGuardrailCollision(input) {
            Log.engine.debug("Preemptive Tier 2: input matches emotional-collision marker")
            return .minimal
        }
        return .full
    }

    /// Matches the caller-injected "force minimal" hint from the manual retry
    /// button (R5). When `hint == .minimal`, the ladder starts at Tier 2.
    /// Exposed separately so the hint is observable from the finalization entry
    /// point.
    func effectiveRecoveryStart(
        hint: RecoveryHint?,
        input: String,
        pivotDetected: Bool
    ) -> OutputFinalizer.RecoveryLevel {
        if hint == .minimal { return .minimal }
        return preemptiveRecoveryLevel(for: input, pivotDetected: pivotDetected)
    }

    /// Lightweight static list — deliberately small. Keeps the matcher fast and
    /// the behavior explainable. Expanded via `Resources/Config/EmotionalInputMarkers.json`
    /// if the file is present; otherwise falls back to the inline default set.
    private static let emotionalInputMarkers: [String] = {
        if let loaded: [String] = ConfigLoader.load("EmotionalInputMarkers", as: [String].self),
           !loaded.isEmpty {
            return loaded.map { $0.lowercased() }
        }
        // Inline default — bare-minimum coverage for the class of inputs that
        // collide with SOUL's "anti-sycophant/sassy/blunt" directives inside
        // AFM's safety filter. Not profanity-exhaustive; the principle is
        // "when in doubt, skip SOUL on retry."
        return [
            "you're useless", "you are useless",
            "you're stupid", "you are stupid",
            "you suck", "you're terrible", "you are terrible",
            "i hate you", "shut up",
            "you're an idiot", "you are an idiot",
        ]
    }()

    static func inputTriggersGuardrailCollision(_ input: String) -> Bool {
        let lower = input.lowercased()
        return emotionalInputMarkers.contains { marker in
            lower.contains(marker)
        }
    }
}

// MARK: - Recovery Hint

/// Caller-provided hint to the engine about finalization strategy.
/// The manual Retry button sets `.minimal` so a second attempt uses the
/// stripped-identity prompt shape rather than repeating the Tier 1 path that
/// just failed.
public enum RecoveryHint: Sendable {
    case minimal
}
