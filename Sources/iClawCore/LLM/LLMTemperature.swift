import Foundation

/// Named temperature presets for LLM calls.
///
/// Apple's `GenerationOptions.temperature` is a value in `[0, 1]` where `1.0` is
/// "no adjustment" (model default distribution) and lower values sharpen the
/// distribution toward the most likely tokens. `nil` lets the backend pick.
///
/// Pick a preset per call-site purpose so we don't sprinkle magic numbers.
public enum LLMTemperature {
    /// Fully deterministic. Use for binary classification (YES/NO) and schema
    /// extraction where any creativity is a bug.
    public static let deterministic: Double = 0.0

    /// Low-variance structured output. JSON/DSL/@Generable argument extraction,
    /// fact compression, plan generation.
    public static let extraction: Double = 0.1

    /// Lightweight structured decisions (healing-input correction,
    /// summarization, widget layout, quality assessment).
    public static let structured: Double = 0.2

    /// Ingredient-relevance YES/NO validation. Deterministic but leaves a touch
    /// of room for the model to pick "yes" on partial matches.
    public static let validation: Double = 0.1

    /// Default personalization/phrasing. Conversational balance — neither
    /// locked-in nor off-the-rails.
    public static let conversational: Double = 0.7

    /// Break determinism on retry. At 1.0 Apple applies no sharpening, so the
    /// sampling distribution is as wide as the model permits — maximally likely
    /// to yield different tokens when Tier 1 produced a bad output.
    public static let recovery: Double = 1.0

    /// Creative generation (greetings, idle quips). Maximum variety.
    public static let creative: Double = 1.0
}

/// Named call-site profile bundling `(temperature, maxTokens, sampling)`.
///
/// Pick a profile per call-site purpose so the three `GenerationOptions` knobs
/// stay coherent. Profiles fall into three families:
/// - **Deterministic + greedy** — for extraction/validation/normalization
///   where reproducibility matters.
/// - **Low-variance + greedy** — for summarization and planning where outputs
///   should be stable but not locked to a single token path.
/// - **Sampled** — for user-facing conversational and creative text where
///   variety is a feature.
public struct LLMCallProfile: Sendable, Equatable {
    public let temperature: Double?
    public let maxTokens: Int?
    public let sampling: LLMSamplingMode?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.sampling = sampling
    }

    // MARK: - Deterministic / Greedy

    /// Binary YES/NO classification. Cap of 5 tokens leaves room for trailing
    /// whitespace while cutting off any rationale the model tries to append.
    public static let validation = LLMCallProfile(
        temperature: LLMTemperature.deterministic,
        maxTokens: 5,
        sampling: .greedy
    )

    /// Single-digit quality score (1–5). Tightest cap of all profiles.
    public static let scoring = LLMCallProfile(
        temperature: LLMTemperature.deterministic,
        maxTokens: 3,
        sampling: .greedy
    )

    /// @Generable/JSON argument extraction. Greedy + extraction temperature
    /// gives the most stable schema adherence.
    public static let extraction = LLMCallProfile(
        temperature: LLMTemperature.extraction,
        maxTokens: 150,
        sampling: .greedy
    )

    /// Deterministic natural-language normalization (calculator parser,
    /// translate parser). Short output, no creativity.
    public static let normalization = LLMCallProfile(
        temperature: LLMTemperature.deterministic,
        maxTokens: 50,
        sampling: .greedy
    )

    /// Healing retry for malformed tool inputs. Short corrected value or
    /// "UNFIXABLE".
    public static let healing = LLMCallProfile(
        temperature: LLMTemperature.structured,
        maxTokens: 60,
        sampling: .greedy
    )

    // MARK: - Low-Variance

    /// Text summarization and fact folding. Greedy keeps compressions stable
    /// across runs; 80 tokens enforces the 2–3 sentence ceiling.
    public static let summarization = LLMCallProfile(
        temperature: LLMTemperature.structured,
        maxTokens: 80,
        sampling: .greedy
    )

    /// Widget layout DSL emission. Compact structured output.
    public static let widgetLayout = LLMCallProfile(
        temperature: LLMTemperature.structured,
        maxTokens: 300,
        sampling: .greedy
    )

    /// Agent plan / continuation decision. Plans are compact and benefit from
    /// stable step ordering across identical queries.
    public static let planning = LLMCallProfile(
        temperature: LLMTemperature.extraction,
        maxTokens: 200,
        sampling: .greedy
    )

    // MARK: - Sampled

    /// Final user-facing answer (`OutputFinalizer`). Caps at the generation
    /// budget so overruns can't blow the context window.
    public static let finalAnswer = LLMCallProfile(
        temperature: LLMTemperature.conversational,
        maxTokens: AppConfig.generationSpace,
        sampling: .random(top: 40)
    )

    /// Personalizer: short status rephrase (≤10 words).
    public static let personalize = LLMCallProfile(
        temperature: LLMTemperature.conversational,
        maxTokens: 30,
        sampling: .random(top: 40)
    )

    /// Personalizer: human-readable error (2–3 sentences).
    public static let personalizeError = LLMCallProfile(
        temperature: LLMTemperature.conversational,
        maxTokens: 80,
        sampling: .random(top: 40)
    )

    /// Greeting generation. Creative, varies across launches.
    public static let greeting = LLMCallProfile(
        temperature: LLMTemperature.creative,
        maxTokens: 80,
        sampling: .random(top: 40)
    )

    /// Idle-time phrase batch (thinking/progress/greeting). Larger cap because
    /// it returns multiple phrases per call.
    public static let phrases = LLMCallProfile(
        temperature: LLMTemperature.creative,
        maxTokens: 300,
        sampling: .random(top: 40)
    )

    /// Tool-tip card copy (≤15 words).
    public static let toolTip = LLMCallProfile(
        temperature: LLMTemperature.creative,
        maxTokens: 40,
        sampling: .random(top: 40)
    )

    /// Feedback follow-up suggestions (3 short questions).
    public static let feedbackSuggestions = LLMCallProfile(
        temperature: LLMTemperature.creative,
        maxTokens: 120,
        sampling: .random(top: 40)
    )

    /// Retry after a failed deterministic pass. Wider `top` + recovery
    /// temperature actively explores a different token neighborhood.
    public static let recovery = LLMCallProfile(
        temperature: LLMTemperature.recovery,
        maxTokens: 200,
        sampling: .random(top: 80)
    )
}
