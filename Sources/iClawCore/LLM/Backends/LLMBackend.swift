import Foundation

/// Backend-agnostic sampling strategy.
///
/// Maps to Apple's `GenerationOptions.SamplingMode` for AFM and to Ollama
/// options (`top_k`, `seed`) for Ollama. Keeping this as a local enum avoids
/// leaking `FoundationModels` types into the protocol surface.
public enum LLMSamplingMode: Sendable, Equatable {
    /// Always pick the argmax token. Fully reproducible regardless of
    /// temperature. Use for schema-bound extraction, binary classification,
    /// and deterministic normalization where any variance is a bug.
    case greedy

    /// Sample from the top-`top` tokens, optionally seeded for reproducibility.
    /// Use for user-facing conversational output and creative generation.
    /// `top` defaults to the backend's own default when `nil`.
    case random(top: Int? = nil, seed: UInt64? = nil)
}

/// Abstraction over LLM inference backends.
///
/// `LLMAdapter` dispatches to the active backend. Apple Foundation Models is the
/// default; additional backends (Ollama, etc.) conform to the same protocol.
///
/// FM-specific concerns (tool calling via `LanguageModelSession`, guided generation
/// via `@Generable`) live in `AFMBackend` only. Non-AFM backends use text generation
/// with JSON-mode for structured output.
public protocol LLMBackend: Sendable {
    /// Human-readable name shown in chat UI (e.g. "Apple Intelligence", "Ollama/llama3.2").
    var displayName: String { get }

    /// Context window size in tokens for this backend.
    var contextWindowTokens: Int { get }

    /// Whether this backend supports FM-style tool calling via `LanguageModelSession`.
    var supportsToolCalling: Bool { get }

    /// Whether this backend is Apple Foundation Models.
    var isAFM: Bool { get }

    /// Generates a text response from the LLM.
    ///
    /// - Parameters:
    ///   - prompt: The user-facing prompt text.
    ///   - instructions: System-level instructions (personality, constraints).
    ///   - temperature: 0.0 = most deterministic, 1.0 = model default (no adjustment).
    ///     `nil` lets the backend pick its own default.
    ///   - maxTokens: Hard cap on response length. `nil` = backend default.
    ///   - sampling: Sampling strategy. `nil` = backend default.
    /// - Returns: The model's text response.
    func generate(
        prompt: String,
        instructions: String?,
        temperature: Double?,
        maxTokens: Int?,
        sampling: LLMSamplingMode?
    ) async throws -> String

    /// Generates a JSON-formatted response for structured output decoding.
    ///
    /// The backend should instruct the model to respond with valid JSON matching
    /// the provided schema. Used as a fallback for non-AFM backends that don't
    /// support guided generation. Always implicitly uses deterministic sampling.
    ///
    /// - Parameters:
    ///   - prompt: The user-facing prompt text.
    ///   - instructions: System-level instructions.
    ///   - jsonSchema: A JSON Schema string. For Ollama, parsed and passed to the `format`
    ///     parameter for constrained generation. Must be valid JSON.
    ///   - maxTokens: Hard cap on response length. `nil` = backend default.
    /// - Returns: A JSON string that can be decoded with `JSONDecoder`.
    func generateJSON(
        prompt: String,
        instructions: String?,
        jsonSchema: String,
        maxTokens: Int?
    ) async throws -> String

    /// Estimates the token count for a string.
    func estimateTokens(for text: String) -> Int

    /// Preloads model resources for faster first response.
    func prewarm(promptPrefix: String?) async

    /// Discards a prewarmed session without creating a new one.
    func invalidatePrewarm() async
}

// MARK: - Defaults

extension LLMBackend {
    public var isAFM: Bool { false }

    public func estimateTokens(for text: String) -> Int {
        AppConfig.estimateTokens(for: text)
    }

    public func prewarm(promptPrefix: String?) async {
        // No-op by default — only AFM benefits from prewarming.
    }

    public func invalidatePrewarm() async {
        // No-op by default.
    }

    // MARK: - Back-compat convenience shims

    /// Overload that preserves the pre-`maxTokens`/`sampling` call shape.
    public func generate(
        prompt: String,
        instructions: String?,
        temperature: Double? = nil
    ) async throws -> String {
        try await generate(
            prompt: prompt,
            instructions: instructions,
            temperature: temperature,
            maxTokens: nil,
            sampling: nil
        )
    }

    /// Overload that preserves the pre-`maxTokens` call shape.
    public func generateJSON(
        prompt: String,
        instructions: String?,
        jsonSchema: String
    ) async throws -> String {
        try await generateJSON(
            prompt: prompt,
            instructions: instructions,
            jsonSchema: jsonSchema,
            maxTokens: nil
        )
    }
}
