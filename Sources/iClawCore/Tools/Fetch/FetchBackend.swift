import Foundation

/// Result of a fetch operation from any backend.
public struct FetchResult: Sendable {
    public let text: String
    public let html: String?
    public let title: String?
    public let statusCode: Int

    public init(text: String, html: String? = nil, title: String? = nil, statusCode: Int = 200) {
        self.text = text
        self.html = html
        self.title = title
        self.statusCode = statusCode
    }
}

/// Abstraction over different fetch strategies (plain HTTP, WKWebView, browser bridge).
public protocol FetchBackend: Sendable {
    func fetch(url: URL) async throws -> FetchResult
}

/// Tries an ordered list of backends, falling through on `BridgeError` or any error
/// depending on configuration. The last backend's errors propagate.
public struct FallbackFetchChain: FetchBackend, Sendable {
    private let backends: [(any FetchBackend, Bool)]  // (backend, catchAllErrors)

    /// Creates a fallback chain. Each backend is tried in order.
    /// - Parameter backends: Tuples of (backend, catchAll). When `catchAll` is true,
    ///   any error triggers fallback. When false, only `BridgeError` triggers fallback.
    public init(backends: [(any FetchBackend, Bool)]) {
        self.backends = backends
    }

    /// Convenience: bridge (BridgeError only) → browser (any error) → HTTP.
    public static func standard(
        bridge: (any FetchBackend)? = nil,
        browser: (any FetchBackend)? = nil,
        http: any FetchBackend
    ) -> FallbackFetchChain {
        var chain: [(any FetchBackend, Bool)] = []
        if let bridge { chain.append((bridge, false)) }
        if let browser { chain.append((browser, true)) }
        chain.append((http, true))
        return FallbackFetchChain(backends: chain)
    }

    /// Convenience: bridge (BridgeError only) → HTTP.
    public static func bridgeAndHTTP(
        bridge: (any FetchBackend)? = nil,
        http: any FetchBackend
    ) -> FallbackFetchChain {
        var chain: [(any FetchBackend, Bool)] = []
        if let bridge { chain.append((bridge, false)) }
        chain.append((http, true))
        return FallbackFetchChain(backends: chain)
    }

    /// Total timeout across all backends in the chain. Prevents 3 × 15s = 45s waits.
    private static let totalTimeoutSeconds: TimeInterval = 20

    public func fetch(url: URL) async throws -> FetchResult {
        let deadline = Date().addingTimeInterval(Self.totalTimeoutSeconds)

        for (index, (backend, catchAll)) in backends.enumerated() {
            let isLast = index == backends.count - 1

            // Check total timeout before trying next backend
            if !isLast && Date() >= deadline {
                Log.tools.debug("FallbackFetchChain: total timeout reached, skipping to last backend")
                return try await backends.last!.0.fetch(url: url)
            }

            if isLast {
                return try await backend.fetch(url: url)
            }
            do {
                return try await backend.fetch(url: url)
            } catch is BridgeError {
                continue
            } catch {
                if catchAll { continue }
                throw error
            }
        }
        // Unreachable — backends is never empty.
        fatalError("FallbackFetchChain requires at least one backend")
    }
}
