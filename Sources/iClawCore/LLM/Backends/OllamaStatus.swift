import Foundation
import Network
import os
#if os(macOS)
import AppKit
#endif

/// Three-layer health check and auto-detection for Ollama.
///
/// Detection chain: installed → running → warm model (preferred) → best available model.
/// Uses direct HTTP calls to the Ollama REST API — no AnyLanguageModel dependency.
public actor OllamaStatus {

    public static let shared = OllamaStatus()

    /// Ollama server health state.
    public enum Health: Sendable, Equatable {
        case notInstalled
        case notRunning
        case running(version: String, models: [OllamaModel])
        case unreachable(reason: String)
    }

    /// Result of auto-detection: the best model to use and its context window.
    public struct DetectedModel: Sendable, Equatable {
        public let name: String
        public let contextWindow: Int
        public let isWarm: Bool // Already loaded in VRAM
    }

    /// A locally-installed Ollama model.
    public struct OllamaModel: Sendable, Identifiable, Equatable, Hashable {
        public var id: String { name }
        public let name: String          // e.g. "llama3.2:latest"
        public let parameterSize: String // e.g. "3.2B"
        public let family: String        // e.g. "llama"
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Runs the full three-layer health check against the given base URL.
    public func check(baseURL: URL) async -> Health {
        guard isInstalled() else { return .notInstalled }

        // Check if Ollama process is actually running before hitting the network.
        guard isProcessRunning() else { return .notRunning }

        // Quick TCP probe — avoids noisy URLSession connection-refused logs
        // when Ollama is installed but the server isn't running.
        let port = NWEndpoint.Port(rawValue: UInt16(baseURL.port ?? 11434)) ?? 11434
        guard await isServerListening(port: port) else { return .notRunning }

        let version: String
        do {
            version = try await fetchVersion(baseURL: baseURL)
        } catch {
            return .notRunning
        }

        do {
            let models = try await fetchModels(baseURL: baseURL)
            return .running(version: version, models: models)
        } catch {
            return .unreachable(reason: "Server running (v\(version)) but failed to list models: \(error.localizedDescription)")
        }
    }

    /// Auto-detects the best Ollama model to use.
    ///
    /// Priority: warm model in VRAM → best downloaded model by preference ranking.
    /// Returns `nil` if Ollama is not installed, not running, or has no models.
    public func autoDetect(baseURL: URL = URL(string: "http://localhost:11434")!) async -> DetectedModel? {
        let health = await check(baseURL: baseURL)
        guard case .running(_, let models) = health, !models.isEmpty else { return nil }

        // Prefer a model already loaded in VRAM (instant inference).
        if let warm = try? await fetchWarmModels(baseURL: baseURL), let first = warm.first {
            let ctx = (try? await fetchContextWindow(baseURL: baseURL, modelName: first)) ?? 8192
            return DetectedModel(name: first, contextWindow: ctx, isWarm: true)
        }

        // Fall back to the best downloaded model by preference ranking.
        let best = pickBestModel(from: models)
        let ctx = (try? await fetchContextWindow(baseURL: baseURL, modelName: best.name)) ?? 8192
        return DetectedModel(name: best.name, contextWindow: ctx, isWarm: false)
    }

    /// Whether Ollama is installed and its server process is currently running.
    /// Suitable for UI gating (e.g., disabling the Ollama option in Settings).
    public nonisolated var isAvailable: Bool {
        isInstalled() && isProcessRunning()
    }

    // MARK: - Layer 1: Installation Check

    /// Checks if Ollama is installed via Launch Services (sandbox-safe).
    private nonisolated func isInstalled() -> Bool {
        #if os(macOS)
        // NSWorkspace queries the Launch Services database — no filesystem access needed.
        // Detects Ollama.app regardless of install location.
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.ollama") != nil {
            return true
        }
        // Fallback: if the process is running, it's installed (covers CLI-only homebrew installs)
        return isProcessRunning()
        #else
        return false
        #endif
    }

    /// Checks if the Ollama app or CLI server process is currently running.
    private nonisolated func isProcessRunning() -> Bool {
        #if os(macOS)
        // Check for `ollama` CLI server process via process list.
        // This also detects Ollama.app since it spawns an `ollama` subprocess.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "ollama"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Quick TCP probe to check if a port is accepting connections.
    /// Uses NWConnection with a short timeout to avoid URLSession error noise.
    private nonisolated func isServerListening(port: NWEndpoint.Port) async -> Bool {
        await withCheckedContinuation { continuation in
            // Guard against double-resume from race between timeout and state handler.
            let resumed = OSAllocatedUnfairLock(initialState: false)

            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: port,
                using: .tcp
            )

            // DispatchWorkItem is not Sendable but must be captured by both
            // the state handler (to cancel on .ready/.failed) and the global
            // queue (to fire on timeout). The `resumed` lock serialises the
            // single continuation.resume(), so there is no race despite the
            // unsafe bridging.
            nonisolated(unsafe) let timeout = DispatchWorkItem { [connection] in
                connection.cancel()
                guard !resumed.withLock({ let v = $0; $0 = true; return v }) else { return }
                continuation.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: timeout)

            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    timeout.cancel()
                    connection.cancel()
                    guard !resumed.withLock({ let v = $0; $0 = true; return v }) else { return }
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    timeout.cancel()
                    connection.cancel()
                    guard !resumed.withLock({ let v = $0; $0 = true; return v }) else { return }
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    // MARK: - Layer 2: Version Check

    /// GET /api/version — confirms the server is responding.
    private func fetchVersion(baseURL: URL) async throws -> String {
        let url = baseURL.appendingPathComponent("api/version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError
        }
        let decoded = try JSONDecoder().decode(VersionResponse.self, from: data)
        return decoded.version
    }

    // MARK: - Layer 3: Model List

    /// GET /api/tags — returns installed models.
    private func fetchModels(baseURL: URL) async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError
        }
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { model in
            OllamaModel(
                name: model.name,
                parameterSize: model.details.parameterSize,
                family: model.details.family
            )
        }
    }

    // MARK: - Warm Model Detection

    /// GET /api/ps — returns models currently loaded in VRAM.
    private func fetchWarmModels(baseURL: URL) async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/ps")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError
        }
        let decoded = try JSONDecoder().decode(PsResponse.self, from: data)
        return decoded.models.map(\.name)
    }

    // MARK: - Context Window Detection

    /// POST /api/show — returns model metadata including context window size.
    private func fetchContextWindow(baseURL: URL, modelName: String) async throws -> Int {
        let url = baseURL.appendingPathComponent("api/show")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": modelName])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.serverError
        }
        let decoded = try JSONDecoder().decode(ShowResponse.self, from: data)
        // Parse num_ctx from the modelfile parameters, or use model_info context_length.
        return decoded.contextWindow ?? 8192
    }

    // MARK: - Model Preference Ranking

    /// Picks the best model from the downloaded list based on preference ranking.
    private nonisolated func pickBestModel(from models: [OllamaModel]) -> OllamaModel {
        let preferred = [
            "qwen2.5-coder", "qwen3", "codellama", "deepseek-coder",
            "codegemma", "qwen2.5", "llama3", "mistral", "gemma"
        ]
        for prefix in preferred {
            if let match = models.first(where: { $0.name.hasPrefix(prefix) }) {
                return match
            }
        }
        return models[0]
    }

    // MARK: - Response Types

    private struct VersionResponse: Decodable {
        let version: String
    }

    private struct TagsResponse: Decodable {
        let models: [TagModel]
    }

    private struct TagModel: Decodable {
        let name: String
        let details: TagModelDetails
    }

    private struct TagModelDetails: Decodable {
        let family: String
        let parameterSize: String

        enum CodingKeys: String, CodingKey {
            case family
            case parameterSize = "parameter_size"
        }
    }

    private struct PsResponse: Decodable {
        let models: [PsModel]
    }

    private struct PsModel: Decodable {
        let name: String
    }

    private struct ShowResponse: Decodable {
        let modelInfo: [String: ShowValue]?

        enum CodingKeys: String, CodingKey {
            case modelInfo = "model_info"
        }

        /// Extracts context window from model_info keys like
        /// "*.context_length" or "context_length".
        var contextWindow: Int? {
            guard let info = modelInfo else { return nil }
            for (key, value) in info {
                if key.hasSuffix("context_length"), case .int(let n) = value {
                    return n
                }
            }
            return nil
        }
    }

    /// Ollama model_info values can be strings, ints, floats, or bools.
    private enum ShowValue: Decodable {
        case int(Int)
        case string(String)
        case double(Double)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(Int.self) { self = .int(v) }
            else if let v = try? container.decode(Double.self) { self = .double(v) }
            else if let v = try? container.decode(Bool.self) { self = .bool(v) }
            else if let v = try? container.decode(String.self) { self = .string(v) }
            else { self = .string("") }
        }
    }

    private enum OllamaError: Error {
        case serverError
    }
}
