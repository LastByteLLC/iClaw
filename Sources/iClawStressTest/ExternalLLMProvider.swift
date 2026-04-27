import Foundation
import iClawCore

// MARK: - Provider Protocol

/// A text generation provider for the stress test. Apple Foundation is the default;
/// OpenAI and Gemini are optional alternatives requiring API keys.
protocol LLMProvider: Sendable {
    var displayName: String { get }
    func generateText(_ prompt: String) async throws -> LLMProviderResponse
    /// Quick validation — makes a minimal API call to confirm the key works.
    func validateKey() async throws
}

struct LLMProviderResponse: Sendable {
    let text: String
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

// MARK: - JSON-Backed Model Catalog

/// Decoded from Resources/Config/LLMProviders.json
private struct ProviderCatalog: Decodable {
    let providers: [ProviderEntry]
}

private struct ProviderEntry: Decodable {
    let kind: String
    let displayName: String
    let requiresAPIKey: Bool
    let keyPrefix: String?
    let keyMinLength: Int
    let keyFormatHint: String
    let models: [ModelEntry]
}

private struct ModelEntry: Decodable {
    let id: String
    let name: String
    let inputPricePer1M: Double
    let outputPricePer1M: Double
}

// MARK: - Provider Enum (UI-facing)

struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let inputPricePer1M: Double   // USD per 1M input tokens
    let outputPricePer1M: Double  // USD per 1M output tokens
}

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case appleFoundation = "Apple Foundation"
    case openAI = "OpenAI"
    case googleGemini = "Google Gemini"

    var id: String { rawValue }

    /// Map from enum case to JSON `kind` key.
    private var jsonKind: String {
        switch self {
        case .appleFoundation: "appleFoundation"
        case .openAI: "openAI"
        case .googleGemini: "googleGemini"
        }
    }

    private var entry: ProviderEntry? {
        ProviderCatalogLoader.catalog?.providers.first { $0.kind == jsonKind }
    }

    var requiresAPIKey: Bool {
        entry?.requiresAPIKey ?? (self != .appleFoundation)
    }

    var keyPrefix: String? {
        entry?.keyPrefix
    }

    var keyMinLength: Int {
        entry?.keyMinLength ?? 0
    }

    var keyFormatHint: String {
        entry?.keyFormatHint ?? ""
    }

    var models: [ModelOption] {
        guard let models = entry?.models else {
            // Fallback: single on-device option
            return [ModelOption(id: "default", name: "On-Device (default)", inputPricePer1M: 0, outputPricePer1M: 0)]
        }
        return models.map {
            ModelOption(id: $0.id, name: $0.name, inputPricePer1M: $0.inputPricePer1M, outputPricePer1M: $0.outputPricePer1M)
        }
    }
}

// MARK: - Catalog Loader

private enum ProviderCatalogLoader {
    static let catalog: ProviderCatalog? = {
        guard let url = Bundle.module.url(forResource: "LLMProviders", withExtension: "json", subdirectory: "Config"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProviderCatalog.self, from: data) else {
            return nil
        }
        return decoded
    }()
}

// MARK: - Apple Foundation Provider

struct AppleFoundationProvider: LLMProvider {
    let displayName = "Apple Foundation (on-device)"

    func generateText(_ prompt: String) async throws -> LLMProviderResponse {
        let text = try await LLMAdapter.shared.generateText(prompt)
        return LLMProviderResponse(text: text, promptTokens: nil, completionTokens: nil, totalTokens: nil)
    }

    func validateKey() async throws {
        // No key needed
    }
}

// MARK: - OpenAI Provider

struct OpenAIProvider: LLMProvider {
    let apiKey: String
    let model: String
    let displayName: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        self.displayName = "OpenAI (\(model))"
    }

    func generateText(_ prompt: String) async throws -> LLMProviderResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ProviderError.apiError(http.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError.parseError("Could not parse OpenAI response")
        }

        let usage = json["usage"] as? [String: Any]
        return LLMProviderResponse(
            text: content,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int,
            totalTokens: usage?["total_tokens"] as? Int
        )
    }

    func validateKey() async throws {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Say OK"]],
            "max_tokens": 3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError("No HTTP response")
        }
        if http.statusCode == 401 {
            throw ProviderError.invalidAPIKey
        }
        if http.statusCode == 403 {
            throw ProviderError.apiError(403, "Access denied — check API key permissions")
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ProviderError.apiError(http.statusCode, body)
        }
    }
}

// MARK: - Google Gemini Provider

struct GeminiProvider: LLMProvider {
    let apiKey: String
    let model: String
    let displayName: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        self.displayName = "Gemini (\(model))"
    }

    func generateText(_ prompt: String) async throws -> LLMProviderResponse {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            if http.statusCode == 400 && body.contains("API_KEY_INVALID") {
                throw ProviderError.invalidAPIKey
            }
            throw ProviderError.apiError(http.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw ProviderError.parseError("Could not parse Gemini response")
        }

        let usage = json["usageMetadata"] as? [String: Any]
        return LLMProviderResponse(
            text: text,
            promptTokens: usage?["promptTokenCount"] as? Int,
            completionTokens: usage?["candidatesTokenCount"] as? Int,
            totalTokens: usage?["totalTokenCount"] as? Int
        )
    }

    func validateKey() async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "contents": [["parts": [["text": "Say OK"]]]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 3]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError("No HTTP response")
        }
        if http.statusCode == 400 || http.statusCode == 403 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("API_KEY_INVALID") || body.contains("PERMISSION_DENIED") {
                throw ProviderError.invalidAPIKey
            }
            throw ProviderError.apiError(http.statusCode, body)
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ProviderError.apiError(http.statusCode, body)
        }
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError, Sendable {
    case invalidAPIKey
    case apiError(Int, String)
    case networkError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid API key"
        case .apiError(let code, let msg):
            return "API error \(code): \(msg.prefix(200))"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .parseError(let msg):
            return msg
        }
    }
}
