import Foundation
import FoundationModels
import os

/// Apple Foundation Models backend — the default on-device LLM.
///
/// Wraps `SystemLanguageModel` and `LanguageModelSession` with real token
/// counting (macOS 26.4+) and session prewarming. This is a pure extraction
/// of the production paths previously in `LLMAdapter`.
///
/// LoRA adapter support is intentionally not wired up — see
/// https://developer.apple.com/forums/thread/823001 for the blocking issue.
/// Until that is resolved, this backend uses the base `SystemLanguageModel`.
public actor AFMBackend: LLMBackend {

    public nonisolated let displayName = "Apple Intelligence"
    public nonisolated let contextWindowTokens = AppConfig.totalContextBudget
    public nonisolated let supportsToolCalling = true
    public nonisolated let isAFM = true

    /// Holds the prewarmed session so it isn't deallocated before use.
    /// Cleared when the next `generate` call creates a real session,
    /// preventing Apple's "Canceled state in response to PrewarmSession" log.
    private var prewarmedSession: LanguageModelSession?

    public init() {}

    // MARK: - Model Resolution

    /// Creates the base `SystemLanguageModel`. LoRA adapters are not wired up
    /// pending https://developer.apple.com/forums/thread/823001.
    func resolvedModel() -> SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    // MARK: - Generation Options

    /// Builds `GenerationOptions` from the adapter-level knobs. Returns `nil`
    /// when every field is defaulted, so callers can pass the bare-prompt form
    /// of `session.respond(...)`.
    private nonisolated func buildOptions(
        temperature: Double?,
        maxTokens: Int?,
        sampling: LLMSamplingMode?
    ) -> GenerationOptions? {
        if temperature == nil && maxTokens == nil && sampling == nil { return nil }

        let mappedSampling: GenerationOptions.SamplingMode?
        switch sampling {
        case .none:
            mappedSampling = nil
        case .greedy:
            mappedSampling = .greedy
        case .random(let top, let seed):
            if let top {
                mappedSampling = .random(top: top, seed: seed)
            } else {
                // Apple's default top is model-chosen; leave sampling unset
                // so the framework picks its own default distribution.
                mappedSampling = nil
            }
        }

        return GenerationOptions(
            sampling: mappedSampling,
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )
    }

    // MARK: - LLMBackend Conformance

    public func generate(
        prompt: String,
        instructions: String?,
        temperature: Double?,
        maxTokens: Int?,
        sampling: LLMSamplingMode?
    ) async throws -> String {
        // Clear any prewarmed session — we're creating the real one now.
        prewarmedSession = nil

        let model = resolvedModel()
        let session: LanguageModelSession
        if let instructions {
            session = LanguageModelSession(model: model, instructions: instructions)
        } else {
            session = LanguageModelSession(model: model)
        }

        do {
            let response: LanguageModelSession.Response<String>
            if let options = buildOptions(temperature: temperature, maxTokens: maxTokens, sampling: sampling) {
                response = try await session.respond(to: prompt, options: options)
            } else {
                response = try await session.respond(to: prompt)
            }
            return response.content
        } catch let genError as LanguageModelSession.GenerationError {
            throw LLMAdapterError.from(genError)
        } catch {
            throw LLMAdapterError.generationFailed(error.localizedDescription)
        }
    }

    /// Generates text with FM tools available to the model.
    /// This is AFM-specific and called directly by `LLMAdapter` for tool-bearing calls.
    public func generateWithTools(
        prompt: String,
        tools: [any Tool],
        instructions: String?,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> String {
        // Clear any prewarmed session — we're creating the real one now.
        prewarmedSession = nil

        let model = resolvedModel()
        let session: LanguageModelSession
        if let instructions {
            session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        } else {
            session = LanguageModelSession(model: model, tools: tools)
        }

        do {
            let response: LanguageModelSession.Response<String>
            if let options = buildOptions(temperature: temperature, maxTokens: maxTokens, sampling: sampling) {
                response = try await session.respond(to: prompt, options: options)
            } else {
                response = try await session.respond(to: prompt)
            }
            return response.content
        } catch let genError as LanguageModelSession.GenerationError {
            throw LLMAdapterError.from(genError)
        } catch {
            throw LLMAdapterError.generationFailed(error.localizedDescription)
        }
    }

    /// Structured generation using Foundation Models' guided generation.
    public func generateStructured<T: ConvertibleFromGeneratedContent & Generable & Sendable>(
        prompt: String,
        instructions: String?,
        generating type: T.Type,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> T {
        // Clear any prewarmed session — we're creating the real one now.
        prewarmedSession = nil

        let model = resolvedModel()
        let session: LanguageModelSession
        if let instructions {
            session = LanguageModelSession(model: model, instructions: instructions)
        } else {
            session = LanguageModelSession(model: model)
        }

        do {
            let response: LanguageModelSession.Response<T>
            if let options = buildOptions(temperature: temperature, maxTokens: maxTokens, sampling: sampling) {
                response = try await session.respond(to: prompt, generating: type, options: options)
            } else {
                response = try await session.respond(to: prompt, generating: type)
            }
            return response.content
        } catch let genError as LanguageModelSession.GenerationError {
            throw LLMAdapterError.from(genError)
        } catch {
            throw LLMAdapterError.generationFailed(error.localizedDescription)
        }
    }

    public func generateJSON(
        prompt: String,
        instructions: String?,
        jsonSchema: String,
        maxTokens: Int? = nil
    ) async throws -> String {
        // AFM: use text generation with JSON instructions embedded in the prompt.
        // Greedy + temperature 0 for schema-bound output — matches Ollama's JSON path.
        let jsonPrompt = "\(prompt)\n\nRespond with ONLY valid JSON matching this schema:\n\(jsonSchema)"
        return try await generate(
            prompt: jsonPrompt,
            instructions: instructions,
            temperature: 0.0,
            maxTokens: maxTokens,
            sampling: .greedy
        )
    }

    // MARK: - Token Counting

    public nonisolated func estimateTokens(for text: String) -> Int {
        AppConfig.estimateTokens(for: text)
    }

    /// Returns real token count via on-device tokenizer (macOS 26.4+), falling back to heuristic.
    public func countTokens(for text: String) async -> Int {
        #if compiler(>=6.2) && canImport(FoundationModels, _version: 26.4)
        if #available(macOS 26.4, iOS 26.4, *) {
            do {
                let model = SystemLanguageModel.default
                let count = try await model.tokenCount(for: Instructions(text))
                return count
            } catch {
                Log.model.debug("tokenCount API failed, using heuristic: \(error.localizedDescription)")
                return estimateTokens(for: text)
            }
        }
        #endif
        return estimateTokens(for: text)
    }

    // MARK: - Availability

    /// Checks whether Apple Intelligence is available on this device.
    public func isAvailable() async -> Bool {
        let model = SystemLanguageModel.default
        return model.availability == .available
    }

    // MARK: - Prewarming

    public func invalidatePrewarm() {
        prewarmedSession = nil
    }

    public func prewarm(promptPrefix: String?) {
        // Discard any prior prewarmed session before creating a new one.
        prewarmedSession = nil

        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model)
        if let prefix = promptPrefix {
            session.prewarm(promptPrefix: Prompt(prefix))
        } else {
            session.prewarm()
        }

        // Hold a strong reference so the session isn't deallocated immediately.
        // Without this, the session goes out of scope and Apple's framework logs
        // "Passing along Session ... in Canceled state in response to PrewarmSession".
        // The session is cleared when the next generate call creates a real session.
        prewarmedSession = session
        Log.model.debug("AFM session prewarmed\(promptPrefix != nil ? " with prompt prefix" : "")")
    }
}

// MARK: - Shared Error Type

/// Generation errors surfaced by LLM backends.
public enum LLMAdapterError: Error, Sendable {
    /// The model refused due to safety guardrails.
    case guardrailViolation
    /// The model assets are not available (Apple Intelligence disabled).
    case assetsUnavailable
    /// A generic generation error.
    case generationFailed(String)

    /// Maps from Apple's LanguageModelSession.GenerationError.
    static func from(_ error: LanguageModelSession.GenerationError) -> LLMAdapterError {
        switch error {
        case .guardrailViolation: return .guardrailViolation
        case .assetsUnavailable: return .assetsUnavailable
        default: return .generationFailed(error.localizedDescription)
        }
    }
}
