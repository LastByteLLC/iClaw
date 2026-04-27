import Foundation
import FoundationModels
import os
import Synchronization

/// Unified adapter wrapping on-device LLM access.
///
/// All LLM interactions go through this adapter, making it the single point to:
/// - Swap the underlying backend (Apple Foundation Models, Ollama, etc.)
/// - Queue and serialize prompts to avoid concurrent session contention
/// - Track token usage and estimate context window capacity
/// - Provide a consistent error type across all callers
///
/// Callers that previously used `LanguageModelSession` directly now call
/// `LLMAdapter.shared.generate(...)` or one of the convenience methods.
public actor LLMAdapter {
    public static let shared = LLMAdapter()

    /// Injected test responder. When set, bypasses the real model entirely.
    private let testResponder: TestResponder?

    /// Closure type for test injection — matches the most general responder signature.
    public typealias TestResponder = @Sendable (String, [any Tool]) async throws -> String

    /// The active LLM backend. Defaults to Apple Foundation Models.
    private var backend: any LLMBackend

    /// The AFM backend instance, kept separately for FM-specific operations
    /// (tool calling, guided generation) even when the active backend changes.
    private var afmBackend: AFMBackend

    public init(testResponder: TestResponder? = nil) {
        self.testResponder = testResponder
        let afm = AFMBackend()
        self.afmBackend = afm
        // Start with AFM; autoConfigureBackend() runs at launch to detect Ollama.
        self.backend = afm
    }

    /// Creates an adapter with a specific backend (for testing or custom init).
    public init(backend: any LLMBackend, testResponder: TestResponder? = nil) {
        self.testResponder = testResponder
        self.backend = backend
        self.afmBackend = AFMBackend()
    }

    // MARK: - Backend Management

    /// Switches to a different LLM backend. Settings UI calls this on backend change.
    public func switchBackend(_ newBackend: any LLMBackend) {
        backend = newBackend
        Log.model.info("LLMAdapter: switched to \(newBackend.displayName)")
    }

    /// The display name of the active backend (e.g. "Apple Intelligence", "Ollama").
    public nonisolated var activeBackendName: String {
        let config = BackendConfig.current
        switch config.kind {
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama: return "Ollama"
        }
    }

    /// Auto-detects the best LLM backend on launch.
    ///
    /// If the user has explicitly chosen a backend, that preference is honored
    /// (provided it's available). Otherwise, Ollama is preferred when running,
    /// falling back to Apple Intelligence.
    ///
    /// Called once from AppDelegate at startup.
    public func autoConfigureBackend() async {
        guard testResponder == nil else { return }

        let config = BackendConfig.current
        let afmAvailable = await afmBackend.isAvailable()
        let ollamaDetected = await OllamaStatus.shared.autoDetect()

        // Honor explicit user preference if the chosen backend is available.
        if config.userOverride {
            switch config.kind {
            case .ollama:
                if let detected = ollamaDetected {
                    activateOllama(detected)
                    return
                }
                // User wanted Ollama but it's gone — fall through to auto-detect.
            case .appleIntelligence:
                if afmAvailable {
                    Log.model.info("LLMAdapter: using Apple Intelligence (user preference)")
                    return
                }
                // User wanted AFM but it's unavailable — fall through to auto-detect.
            }
        }

        // Auto-detect: prefer Ollama, fall back to AFM.
        if let detected = ollamaDetected {
            activateOllama(detected)
            return
        }

        if afmAvailable {
            var newConfig = BackendConfig.current
            newConfig.kind = .appleIntelligence
            BackendConfig.current = newConfig
            Log.model.info("LLMAdapter: using Apple Intelligence (Ollama not available)")
            return
        }

        Log.model.warning("LLMAdapter: no backend available (AFM unavailable, Ollama not detected)")
    }

    /// Switches to the given Ollama model, persists the config, and clears any fallback state.
    private func activateOllama(_ detected: OllamaStatus.DetectedModel) {
        resetFallbackState()
        let ollamaBackend = OllamaBackend(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: detected.name,
            contextWindow: detected.contextWindow
        )
        backend = ollamaBackend
        var config = BackendConfig.current
        config.kind = .ollama
        config.ollamaModelName = detected.name
        config.ollamaContextWindow = detected.contextWindow
        BackendConfig.current = config
        Log.model.info("LLMAdapter: using Ollama (\(detected.name), ctx: \(detected.contextWindow), warm: \(detected.isWarm))")
    }

    /// Whether the active backend is Apple Foundation Models.
    public var isAFM: Bool {
        backend.isAFM
    }

    // MARK: - Core API

    /// Response from the adapter, wrapping the model's output.
    public struct Response: Sendable {
        public let content: String
    }

    /// Legacy error type — delegates to the shared `LLMAdapterError`.
    public typealias AdapterError = LLMAdapterError

    // MARK: - Ollama Heartbeat & AFM Fallback

    /// Thread-safe flag visible to the UI so message icons reflect the *actual*
    /// serving backend, not the user's configured preference.
    private static let _usingAFMFallback = Mutex(false)

    /// `true` when Ollama was configured but unreachable, and we silently
    /// fell back to Apple Intelligence. The UI reads this to pick the correct icon.
    public nonisolated static var isUsingAFMFallback: Bool {
        _usingAFMFallback.withLock { $0 }
    }

    /// Checks if an error indicates Ollama is unreachable (connection refused, timeout, etc.).
    private nonisolated func isOllamaConnectivityError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let connectivityCodes: Set<Int> = [
                NSURLErrorCannotConnectToHost,      // -1004
                NSURLErrorNetworkConnectionLost,     // -1005
                NSURLErrorNotConnectedToInternet,    // -1009
                NSURLErrorTimedOut,                  // -1001
                NSURLErrorCannotFindHost,            // -1003
            ]
            return connectivityCodes.contains(nsError.code)
        }
        // POSIX connection refused (ECONNREFUSED = 61 on macOS)
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 61 {
            return true
        }
        return false
    }

    /// Falls back to AFM when the active Ollama backend is unreachable.
    /// Updates the backend in-place so subsequent calls go directly to AFM.
    private func fallbackToAFM() {
        backend = afmBackend
        Self._usingAFMFallback.withLock { $0 = true }
        Log.model.warning("LLMAdapter: Ollama unreachable — falling back to Apple Intelligence")
    }

    /// Resets the fallback flag (called when Ollama is re-activated).
    private func resetFallbackState() {
        Self._usingAFMFallback.withLock { $0 = false }
    }

    /// Executes a closure against the active backend. If the backend is Ollama and
    /// the call fails with a connectivity error, transparently retries with AFM.
    private func withOllamaFallback<T>(_ body: () async throws -> T, afmFallback: () async throws -> T) async throws -> T {
        guard !backend.isAFM else {
            return try await body()
        }

        do {
            return try await body()
        } catch where isOllamaConnectivityError(error) {
            fallbackToAFM()
            return try await afmFallback()
        }
    }

    /// Sends a prompt to the active LLM backend and returns the response.
    ///
    /// - Parameters:
    ///   - prompt: The user-facing prompt text.
    ///   - tools: FM tools to make available to the model (empty for text-only).
    ///            Only used when the active backend is AFM.
    ///   - instructions: System-level instructions (personality, constraints).
    ///   - temperature: 0.0 = deterministic, 1.0 = model default (no adjustment).
    ///     `nil` = backend chooses. Use low values for structured/classification
    ///     calls, 1.0 to break determinism on retry.
    ///   - maxTokens: Hard cap on response length (maps to
    ///     `GenerationOptions.maximumResponseTokens`). `nil` = no cap.
    ///   - sampling: Sampling strategy. `.greedy` gives argmax decoding;
    ///     `.random(top:seed:)` enables top-k sampling with an optional seed
    ///     for reproducibility.
    /// - Returns: The model's text response.
    /// - Throws: `LLMAdapterError` on failure.
    public func generate(
        prompt: String,
        tools: [any Tool] = [],
        instructions: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> Response {
        let collector = TurnTraceCollector.current
        let site = TurnTraceCollector.currentSite ?? "unknown"
        let promptChars = prompt.count + (instructions?.count ?? 0)
        let start = ContinuousClock.now

        // Test injection path
        if let responder = testResponder {
            do {
                let text = try await responder(prompt, tools)
                await recordLLMCall(collector, site: site, kind: "generate",
                                    backend: "test", promptChars: promptChars,
                                    responseChars: text.count, start: start, error: nil)
                return Response(content: text)
            } catch {
                await recordLLMCall(collector, site: site, kind: "generate",
                                    backend: "test", promptChars: promptChars,
                                    responseChars: 0, start: start,
                                    error: String(describing: error))
                throw error
            }
        }

        let backendName = backend.isAFM ? "AFM" : "Ollama"
        do {
            // AFM path with tool support
            if backend.isAFM && !tools.isEmpty {
                let text = try await afmBackend.generateWithTools(
                    prompt: prompt,
                    tools: tools,
                    instructions: instructions,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    sampling: sampling
                )
                await recordLLMCall(collector, site: site, kind: "generate",
                                    backend: "AFM", promptChars: promptChars,
                                    responseChars: text.count, start: start, error: nil)
                return Response(content: text)
            }

            // General backend path — with Ollama→AFM fallback
            let response = try await withOllamaFallback({
                let text = try await self.backend.generate(
                    prompt: prompt,
                    instructions: instructions,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    sampling: sampling
                )
                return Response(content: text)
            }, afmFallback: {
                if !tools.isEmpty {
                    let text = try await self.afmBackend.generateWithTools(
                        prompt: prompt,
                        tools: tools,
                        instructions: instructions,
                        temperature: temperature,
                        maxTokens: maxTokens,
                        sampling: sampling
                    )
                    return Response(content: text)
                }
                let text = try await self.afmBackend.generate(
                    prompt: prompt,
                    instructions: instructions,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    sampling: sampling
                )
                return Response(content: text)
            })
            // Post-fallback backend name reflects what actually ran.
            let actualBackend = backend.isAFM ? "AFM" : backendName
            await recordLLMCall(collector, site: site, kind: "generate",
                                backend: actualBackend, promptChars: promptChars,
                                responseChars: response.content.count,
                                start: start, error: nil)
            return response
        } catch {
            await recordLLMCall(collector, site: site, kind: "generate",
                                backend: backendName, promptChars: promptChars,
                                responseChars: 0, start: start,
                                error: String(describing: error))
            throw error
        }
    }

    /// Records one LLMCall into the task-local `TurnTraceCollector` if one is
    /// installed. Nonisolated so it doesn't contend with the adapter actor.
    private nonisolated func recordLLMCall(
        _ collector: TurnTraceCollector?,
        site: String,
        kind: String,
        backend: String,
        promptChars: Int,
        responseChars: Int,
        start: ContinuousClock.Instant,
        error: String?
    ) async {
        guard let collector else { return }
        let d = start.duration(to: .now)
        let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        await collector.recordLLMCall(.init(
            site: site, kind: kind, backend: backend,
            promptChars: promptChars, responseChars: responseChars,
            ms: ms, error: error
        ))
    }

    // MARK: - Guarded Generation

    /// Estimated tokens per FM tool descriptor (conservative).
    private static let tokensPerTool = 150

    /// Reserved headroom for @Generable schemas in `generateStructured`.
    /// `countGuardTokens` doesn't see the schema — this cushion keeps the
    /// combined prompt + schema payload under the backend window.
    private static let structuredSchemaHeadroom = 200

    /// Validates that the prompt fits the context window before sending to the model.
    public func guardedGenerate(
        prompt: String,
        tools: [any Tool] = [],
        instructions: String? = nil,
        budget: Int? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> Response {
        try await enforceBudget(
            prompt: prompt, tools: tools, instructions: instructions, budget: budget,
            site: "generate"
        )
        return try await generate(
            prompt: prompt,
            tools: tools,
            instructions: instructions,
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
    }

    /// Shared budget gate used by `guardedGenerate` and `generateStructured`.
    /// Throws `LLMAdapterError.generationFailed` when the composed prompt
    /// (prompt + tools + instructions) exceeds the effective context budget.
    /// Emits a warning log so over-budget calls are visible in Console.
    private func enforceBudget(
        prompt: String,
        tools: [any Tool],
        instructions: String?,
        budget: Int?,
        site: String
    ) async throws {
        let effectiveBudget = budget ?? backend.contextWindowTokens
        let total = await countGuardTokens(prompt: prompt, tools: tools, instructions: instructions)
        guard total <= effectiveBudget else {
            Log.model.warning("LLM \(site) rejected: \(total) tokens exceeds \(effectiveBudget) budget")
            throw LLMAdapterError.generationFailed(
                "Prompt at \(total) tokens exceeds \(effectiveBudget) budget"
            )
        }
    }

    // MARK: - Convenience Methods

    /// Simple text generation with no tools and no instructions.
    public func generateText(
        _ prompt: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> String {
        let response = try await guardedGenerate(
            prompt: prompt,
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
        return response.content
    }

    /// Profile-based convenience: forwards the bundled
    /// `(temperature, maxTokens, sampling)` triple into `generateText`.
    public func generateText(
        _ prompt: String,
        profile: LLMCallProfile
    ) async throws -> String {
        try await generateText(
            prompt,
            temperature: profile.temperature,
            maxTokens: profile.maxTokens,
            sampling: profile.sampling
        )
    }

    /// Profile-based convenience for `generateWithInstructions`.
    public func generateWithInstructions(
        prompt: String,
        instructions: String,
        profile: LLMCallProfile
    ) async throws -> String {
        try await generateWithInstructions(
            prompt: prompt,
            instructions: instructions,
            temperature: profile.temperature,
            maxTokens: profile.maxTokens,
            sampling: profile.sampling
        )
    }

    /// Profile-based convenience for `generateStructured`.
    public func generateStructured<T: ConvertibleFromGeneratedContent & Generable & Sendable>(
        prompt: String,
        instructions: String? = nil,
        generating type: T.Type,
        profile: LLMCallProfile
    ) async throws -> T {
        try await generateStructured(
            prompt: prompt,
            instructions: instructions,
            generating: type,
            temperature: profile.temperature,
            maxTokens: profile.maxTokens,
            sampling: profile.sampling
        )
    }

    /// Text generation with system instructions but no tools.
    public func generateWithInstructions(
        prompt: String,
        instructions: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> String {
        let response = try await guardedGenerate(
            prompt: prompt,
            instructions: instructions,
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
        return response.content
    }

    /// JSON-optimized text generation for tool argument extraction.
    ///
    /// AFM: uses standard text generation (the model handles JSON natively).
    /// Non-AFM: uses the backend's JSON format mode with the tool schema for
    /// constrained output, ensuring valid JSON with the expected keys.
    public func generateForExtraction(
        prompt: String,
        instructions: String,
        toolSchema: String,
        maxTokens: Int? = nil
    ) async throws -> String {
        // Schema-bound extraction: greedy + low temperature for deterministic JSON.
        if backend.isAFM {
            return try await generateWithInstructions(
                prompt: prompt,
                instructions: instructions,
                temperature: LLMTemperature.extraction,
                maxTokens: maxTokens,
                sampling: .greedy
            )
        }
        // Non-AFM: use JSON format — with Ollama→AFM fallback.
        // OllamaBackend.generateJSON already hardcodes temperature=0 internally.
        return try await withOllamaFallback({
            try await self.backend.generateJSON(
                prompt: prompt,
                instructions: instructions,
                jsonSchema: toolSchema,
                maxTokens: maxTokens
            )
        }, afmFallback: {
            try await self.generateWithInstructions(
                prompt: prompt,
                instructions: instructions,
                temperature: LLMTemperature.extraction,
                maxTokens: maxTokens,
                sampling: .greedy
            )
        })
    }

    // MARK: - Structured Generation

    /// Generates a structured response using `@Generable` types.
    ///
    /// For AFM: uses Foundation Models' guided generation (type-safe, guaranteed structure).
    /// For non-AFM: uses JSON-mode generation + `JSONDecoder` (requires `Codable` conformance).
    ///
    /// - Parameters:
    ///   - prompt: The user-facing prompt text.
    ///   - instructions: System-level instructions.
    ///   - type: The `@Generable` type to produce.
    /// - Returns: A decoded instance of the requested type.
    /// - Throws: `LLMAdapterError` on failure.
    public func generateStructured<T: ConvertibleFromGeneratedContent & Generable & Sendable>(
        prompt: String,
        instructions: String? = nil,
        generating type: T.Type,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> T {
        let collector = TurnTraceCollector.current
        let site = TurnTraceCollector.currentSite ?? "unknown"
        let promptChars = prompt.count + (instructions?.count ?? 0)
        let start = ContinuousClock.now

        // Test injection path
        if testResponder != nil {
            let text = try await generateText(prompt)
            await recordLLMCall(collector, site: site, kind: "generateStructured",
                                backend: "test", promptChars: promptChars,
                                responseChars: text.count, start: start,
                                error: "test mode: structured not supported")
            throw LLMAdapterError.generationFailed("Structured generation not available in test mode. Got: \(text.prefix(100))")
        }

        // Budget gate — matches the guardedGenerate path. Structured callers
        // (AgentPlan, ToolVerifier, IntentSplitter, AgentRunner) can assemble
        // large prompts; without this check an over-budget call silently
        // truncates at the backend with unpredictable output.
        //
        // Schema headroom: @Generable schemas contribute tokens that
        // `countGuardTokens(tools: [])` does NOT count. Reserve a
        // conservative 200-token cushion so a prompt that just fits the
        // window doesn't push the actual payload (prompt + schema) over.
        let effectiveBudget = backend.contextWindowTokens - Self.structuredSchemaHeadroom
        try await enforceBudget(
            prompt: prompt, tools: [], instructions: instructions, budget: effectiveBudget,
            site: "generateStructured"
        )

        // AFM path — native guided generation. Default to greedy for maximally
        // stable schema output unless the caller has overridden sampling.
        let effectiveSampling = sampling ?? .greedy
        do {
            if backend.isAFM {
                let result = try await afmBackend.generateStructured(
                    prompt: prompt,
                    instructions: instructions,
                    generating: type,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    sampling: effectiveSampling
                )
                await recordLLMCall(collector, site: site, kind: "generateStructured",
                                    backend: "AFM", promptChars: promptChars,
                                    responseChars: String(describing: result).count,
                                    start: start, error: nil)
                return result
            }

            // Non-AFM path — JSON-mode generation + Codable decoding, with Ollama→AFM fallback.
            // JSON mode is always temperature 0 (schema-bound), so the temperature parameter
            // only applies to the AFM path.
            guard let decodableType = type as? any (Decodable & ConvertibleFromGeneratedContent & Generable).Type else {
                throw LLMAdapterError.generationFailed("Type \(type) does not conform to Codable for non-AFM backend")
            }
            do {
                let result = try await generateStructuredViaJSON(
                    prompt: prompt,
                    instructions: instructions,
                    type: decodableType,
                    maxTokens: maxTokens
                ) as! T
                await recordLLMCall(collector, site: site, kind: "generateStructured",
                                    backend: "Ollama", promptChars: promptChars,
                                    responseChars: String(describing: result).count,
                                    start: start, error: nil)
                return result
            } catch where isOllamaConnectivityError(error) {
                fallbackToAFM()
                let result = try await afmBackend.generateStructured(
                    prompt: prompt,
                    instructions: instructions,
                    generating: type,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    sampling: effectiveSampling
                )
                await recordLLMCall(collector, site: site, kind: "generateStructured",
                                    backend: "AFM", promptChars: promptChars,
                                    responseChars: String(describing: result).count,
                                    start: start, error: "fellback-from-ollama")
                return result
            }
        } catch {
            await recordLLMCall(collector, site: site, kind: "generateStructured",
                                backend: backend.isAFM ? "AFM" : "Ollama",
                                promptChars: promptChars, responseChars: 0,
                                start: start, error: String(describing: error))
            throw error
        }
    }

    /// JSON-mode structured generation for non-AFM backends.
    private func generateStructuredViaJSON<T: Decodable>(
        prompt: String,
        instructions: String?,
        type: T.Type,
        maxTokens: Int? = nil
    ) async throws -> T {
        // Build a proper JSON Schema string if the type provides one; fallback to type name.
        let schemaString: String
        if let providing = type as? any JSONSchemaProviding.Type {
            let dict = providing.jsonSchema
            schemaString = (try? String(data: JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)) ?? String(describing: type)
        } else {
            schemaString = "{\"type\":\"object\",\"description\":\"\(String(describing: type))\"}"
        }

        let jsonText = try await backend.generateJSON(
            prompt: prompt,
            instructions: instructions,
            jsonSchema: schemaString,
            maxTokens: maxTokens
        )

        // Extract JSON from potential markdown fences
        let cleaned = Self.extractJSON(from: jsonText)

        guard let data = cleaned.data(using: .utf8) else {
            throw LLMAdapterError.generationFailed("Failed to encode JSON response as UTF-8")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // One retry with error feedback
            Log.model.debug("JSON decode failed, retrying: \(error.localizedDescription)")
            let retryPrompt = "\(prompt)\n\nYour previous response was invalid JSON. Error: \(error.localizedDescription). Respond with ONLY valid JSON, no markdown fences."
            let retryText = try await backend.generateJSON(
                prompt: retryPrompt,
                instructions: instructions,
                jsonSchema: schemaString,
                maxTokens: maxTokens
            )
            let retryCleaned = Self.extractJSON(from: retryText)
            guard let retryData = retryCleaned.data(using: .utf8) else {
                throw LLMAdapterError.generationFailed("Failed to encode retry JSON response as UTF-8")
            }
            return try JSONDecoder().decode(T.self, from: retryData)
        }
    }

    /// Strips markdown code fences from a JSON response.
    private static func extractJSON(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prewarming

    /// Preloads model resources into memory and optionally caches a prompt prefix.
    public func prewarm(promptPrefix: String? = nil) async {
        guard testResponder == nil else { return }
        await backend.prewarm(promptPrefix: promptPrefix)
    }

    /// Discards any prewarmed session without creating a new one.
    public func invalidatePrewarm() async {
        guard testResponder == nil else { return }
        await backend.invalidatePrewarm()
    }

    /// Preloads resources and caches the brain+soul prompt prefix for finalization.
    public func prewarmForFinalization() async {
        guard testResponder == nil else { return }
        let brain = BrainProvider.current
        let soul = SoulProvider.current
        let prefix = "<brain>\(brain)</brain>\n<soul>\(soul)</soul>"
        await backend.prewarm(promptPrefix: prefix)
    }

    // MARK: - Context Window Estimation

    /// Estimates the token count for a string using the backend's estimator.
    public nonisolated func estimateTokens(for text: String) -> Int {
        AppConfig.estimateTokens(for: text)
    }

    /// The context window budget in tokens for the active backend.
    public var contextWindowTokens: Int {
        backend.contextWindowTokens
    }

    /// Estimates remaining tokens after accounting for a prompt and its components.
    public nonisolated func estimateRemainingTokens(
        prompt: String,
        instructions: String? = nil,
        existingIngredients: [String] = []
    ) -> Int {
        let promptTokens = estimateTokens(for: prompt)
        let instructionTokens = instructions.map { estimateTokens(for: $0) } ?? 0
        let ingredientTokens = existingIngredients.map { estimateTokens(for: $0) }.reduce(0, +)
        let used = promptTokens + instructionTokens + ingredientTokens + AppConfig.identityBudget
        return max(0, AppConfig.totalContextBudget - used)
    }

    // MARK: - Accurate Token Counting (macOS 26.4+)

    /// Returns the real token count using the on-device tokenizer when available.
    public func countTokens(for text: String) async -> Int {
        guard testResponder == nil else {
            return estimateTokens(for: text)
        }
        // Only AFM has a real tokenizer; other backends use heuristic.
        if backend.isAFM {
            return await afmBackend.countTokens(for: text)
        }
        return estimateTokens(for: text)
    }

    /// Counts tokens for the full pre-flight components of a generation call.
    public func countGuardTokens(
        prompt: String,
        tools: [any Tool] = [],
        instructions: String? = nil
    ) async -> Int {
        let promptTokens = estimateTokens(for: prompt)
        let instructionTokens: Int
        if let instructions {
            instructionTokens = await countTokens(for: instructions)
        } else {
            instructionTokens = 0
        }
        let toolTokens = tools.count * Self.tokensPerTool
        return promptTokens + instructionTokens + toolTokens
    }

    // MARK: - Typed Instructions Overloads
    //
    // Parallel API surface accepting `iClawInstructions?` instead of `String?`.
    // Phase 1 forwards through `renderAsSystemString()` to preserve behavior.
    // Later phases migrate callers and optionally add AFM-native routing.

    /// Typed-instructions overload of `generate`. See the String? version for
    /// full parameter docs.
    public func generate(
        prompt: String,
        tools: [any Tool] = [],
        instructions: iClawInstructions?,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> Response {
        try await generate(
            prompt: prompt,
            tools: tools,
            instructions: instructions?.renderAsSystemString(),
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
    }

    /// Typed-instructions overload of `guardedGenerate`.
    public func guardedGenerate(
        prompt: String,
        tools: [any Tool] = [],
        instructions: iClawInstructions?,
        budget: Int? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> Response {
        try await guardedGenerate(
            prompt: prompt,
            tools: tools,
            instructions: instructions?.renderAsSystemString(),
            budget: budget,
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
    }

    /// Typed-instructions overload of `generateWithInstructions`.
    public func generateWithInstructions(
        prompt: String,
        instructions: iClawInstructions,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> String {
        try await generateWithInstructions(
            prompt: prompt,
            instructions: instructions.renderAsSystemString(),
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
    }

    /// Profile-based typed-instructions convenience.
    public func generateWithInstructions(
        prompt: String,
        instructions: iClawInstructions,
        profile: LLMCallProfile
    ) async throws -> String {
        try await generateWithInstructions(
            prompt: prompt,
            instructions: instructions.renderAsSystemString(),
            profile: profile
        )
    }

    /// Typed-instructions overload of `generateStructured`.
    public func generateStructured<T: ConvertibleFromGeneratedContent & Generable & Sendable>(
        prompt: String,
        instructions: iClawInstructions?,
        generating type: T.Type,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> T {
        try await generateStructured(
            prompt: prompt,
            instructions: instructions?.renderAsSystemString(),
            generating: type,
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
    }

    /// Profile-based typed-instructions convenience for structured generation.
    public func generateStructured<T: ConvertibleFromGeneratedContent & Generable & Sendable>(
        prompt: String,
        instructions: iClawInstructions?,
        generating type: T.Type,
        profile: LLMCallProfile
    ) async throws -> T {
        try await generateStructured(
            prompt: prompt,
            instructions: instructions?.renderAsSystemString(),
            generating: type,
            profile: profile
        )
    }

    /// Typed-instructions overload of `generateForExtraction`.
    public func generateForExtraction(
        prompt: String,
        instructions: iClawInstructions,
        toolSchema: String,
        maxTokens: Int? = nil
    ) async throws -> String {
        try await generateForExtraction(
            prompt: prompt,
            instructions: instructions.renderAsSystemString(),
            toolSchema: toolSchema,
            maxTokens: maxTokens
        )
    }

    /// Typed-instructions overload of `countGuardTokens`. Sums the rendered
    /// system string for parity with the String? path.
    public func countGuardTokens(
        prompt: String,
        tools: [any Tool] = [],
        instructions: iClawInstructions?
    ) async -> Int {
        await countGuardTokens(
            prompt: prompt,
            tools: tools,
            instructions: instructions?.renderAsSystemString()
        )
    }

    /// Typed-instructions overload of `estimateRemainingTokens`.
    public nonisolated func estimateRemainingTokens(
        prompt: String,
        instructions: iClawInstructions?,
        existingIngredients: [String] = []
    ) -> Int {
        estimateRemainingTokens(
            prompt: prompt,
            instructions: instructions?.renderAsSystemString(),
            existingIngredients: existingIngredients
        )
    }
}
