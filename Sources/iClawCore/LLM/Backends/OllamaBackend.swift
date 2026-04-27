import Foundation
import os

/// Ollama backend using the Ollama REST API directly.
///
/// Calls `POST /api/chat` with `stream: false` for synchronous generation.
/// No external dependencies — uses `URLSession` for HTTP.
///
/// Note: AnyLanguageModel was evaluated but its `@Generable` macro conflicts
/// with Apple's FoundationModels `@Generable` at the module level. Direct HTTP
/// avoids the conflict entirely and gives us full control over the Ollama API.
public struct OllamaBackend: LLMBackend, Sendable {

    public let displayName: String
    public let contextWindowTokens: Int
    public let supportsToolCalling = false
    public let isAFM = false

    private let baseURL: URL
    private let modelName: String
    private let session: URLSession

    public init(
        baseURL: URL,
        modelName: String,
        contextWindow: Int,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.contextWindowTokens = contextWindow
        self.session = session
        let shortName = modelName.hasSuffix(":latest")
            ? String(modelName.dropLast(7))
            : modelName
        self.displayName = "Ollama/\(shortName)"
    }

    /// Convenience initializer from BackendConfig.
    public init(config: BackendConfig, session: URLSession = .shared) {
        self.init(
            baseURL: config.ollamaURL,
            modelName: config.ollamaModelName,
            contextWindow: config.ollamaContextWindow,
            session: session
        )
    }

    // MARK: - LLMBackend

    public func generate(
        prompt: String,
        instructions: String?,
        temperature: Double?,
        maxTokens: Int?,
        sampling: LLMSamplingMode?
    ) async throws -> String {
        var messages: [[String: String]] = []

        if let instructions {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(["role": "user", "content": prompt])

        return try await chat(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            sampling: sampling
        )
    }

    public func generateJSON(
        prompt: String,
        instructions: String?,
        jsonSchema: String,
        maxTokens: Int?
    ) async throws -> String {
        var messages: [[String: String]] = []

        let systemContent = [
            instructions,
            "You MUST respond with ONLY valid JSON matching this schema. No markdown, no explanation, just the JSON object.",
            "Schema: \(jsonSchema)"
        ].compactMap { $0 }.joined(separator: "\n\n")

        messages.append(["role": "system", "content": systemContent])
        messages.append(["role": "user", "content": prompt])

        // Parse the JSON Schema string and pass as the Ollama `format` param
        // for constrained generation. Falls back to "json" if parsing fails.
        let formatParam: Any
        if let data = jsonSchema.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            formatParam = parsed
        } else {
            formatParam = "json"
        }

        // Greedy + temperature 0 for deterministic, schema-compliant output.
        return try await chat(
            messages: messages,
            format: formatParam,
            temperature: 0,
            maxTokens: maxTokens,
            sampling: .greedy
        )
    }

    public func estimateTokens(for text: String) -> Int {
        AppConfig.estimateTokens(for: text)
    }

    public func prewarm(promptPrefix: String?) async {
        // No-op — Ollama models are loaded on first request.
    }

    // MARK: - Ollama REST API

    /// POST /api/chat — non-streaming chat completion.
    /// - Parameters:
    ///   - format: Ollama format constraint — either `"json"` string or a JSON Schema dict.
    ///   - temperature: Optional temperature override (0 for deterministic JSON, nil for default).
    ///   - maxTokens: Optional hard cap on generated tokens (maps to `num_predict`).
    ///   - sampling: Optional sampling strategy — `.greedy` pins `top_k=1`;
    ///     `.random(top:seed:)` sets `top_k` and `seed` accordingly.
    private func chat(
        messages: [[String: String]],
        format: Any? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        sampling: LLMSamplingMode? = nil
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // LLM generation can be slow

        var options: [String: Any] = ["num_ctx": contextWindowTokens]
        if let temperature {
            options["temperature"] = temperature
        }
        if let maxTokens {
            options["num_predict"] = maxTokens
        }
        switch sampling {
        case .none:
            break
        case .greedy:
            // top_k=1 + temperature forced to 0 gives argmax decoding on Ollama.
            options["top_k"] = 1
            options["temperature"] = 0
        case .random(let top, let seed):
            if let top {
                options["top_k"] = top
            }
            if let seed {
                // Ollama expects a signed int seed; narrow if needed.
                options["seed"] = Int(truncatingIfNeeded: seed)
            }
        }

        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": false,
            "options": options
        ]
        if let format {
            body["format"] = format
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMAdapterError.generationFailed("Ollama: invalid response")
        }

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            Log.model.warning("Ollama API error \(http.statusCode): \(errorBody)")
            throw LLMAdapterError.generationFailed("Ollama returned HTTP \(http.statusCode): \(errorBody)")
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message.content
    }

    // MARK: - Response Types

    private struct ChatResponse: Decodable {
        let message: ChatMessage
    }

    private struct ChatMessage: Decodable {
        let role: String
        let content: String
    }
}
