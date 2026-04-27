import Foundation

/// Shared URLSession factory with iClaw-appropriate timeouts.
///
/// Motivation: `URLSession.shared` uses the system default
/// `timeoutIntervalForRequest` of 60 seconds and
/// `timeoutIntervalForResource` of 7 days. Those are much longer than
/// any tool response we want to surface to a user, and during the 322-
/// turn manual session a slow network backend could stall the whole
/// daemon past its 30 s read timeout.
///
/// This factory exposes a single opinionated default that tools can
/// adopt by changing `init(session: URLSession = .shared)` to
/// `init(session: URLSession = .iClawDefault)`. The configuration is
/// `ephemeral` so no persistent cache leaks between users / runs.
extension URLSession {
    /// Shared session for iClaw tools that make outbound HTTP requests.
    /// - Request timeout: 15 s (a user-visible tool should never block
    ///   longer than this; the daemon's own read timeout is 30 s).
    /// - Resource timeout: 30 s (absolute ceiling per request including
    ///   redirects and retries).
    public static let iClawDefault: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Cookie handling matches StockTool's pre-existing session
        // config so migrating callers doesn't change behaviour.
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
