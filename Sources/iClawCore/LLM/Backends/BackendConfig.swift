import Foundation

/// Persisted configuration for the active LLM backend.
///
/// Auto-detection prefers Ollama when available, falling back to AFM.
/// The user can override via a toggle in Settings — their preference is
/// persisted and honored on subsequent launches if the chosen backend is available.
public struct BackendConfig: Codable, Sendable, Equatable {

    /// Available LLM backend types.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case appleIntelligence
        case ollama
    }

    /// The active backend.
    public var kind: Kind = .appleIntelligence

    /// Whether the user has explicitly chosen a backend.
    /// When `true`, auto-detection honors their choice if the backend is available.
    public var userOverride: Bool = false

    // MARK: - Ollama Settings (auto-detected)

    /// Base URL for the Ollama HTTP API.
    public var ollamaBaseURL: String = "http://localhost:11434"

    /// Auto-detected model name (e.g. "llama3.2", "qwen2.5-coder:latest").
    public var ollamaModelName: String = ""

    /// Auto-detected context window size in tokens.
    public var ollamaContextWindow: Int = 8192

    // MARK: - Persistence

    private static let defaultsKey = "backendConfig"

    /// Reads the current configuration from UserDefaults, or returns defaults.
    public static var current: BackendConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let config = try? JSONDecoder().decode(BackendConfig.self, from: data)
            else {
                return BackendConfig()
            }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// The parsed base URL for Ollama, or the default if invalid.
    public var ollamaURL: URL {
        URL(string: ollamaBaseURL) ?? URL(string: "http://localhost:11434")!
    }
}
