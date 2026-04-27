import Foundation

/// Internal tool to fetch and preprocess content from URLs.
/// Routes between a fast HTTP backend (for APIs) and a browser backend (for JS-rendered pages).
public struct WebFetchTool: CoreTool, Sendable {
    public let name = "WebFetch"
    public let schema = "fetch content from a specified URL"
    public let isInternal = true
    public let category = CategoryEnum.online

    private let httpBackend: any FetchBackend
    private let fetchChain: FallbackFetchChain

    /// Production init: HTTP for APIs, browser bridge → WKWebView fallback for web pages.
    public init() {
        let http = HTTPFetchBackend()
        self.httpBackend = http
        #if os(macOS)
        self.fetchChain = .standard(bridge: BrowserBridgeFetchBackend(), browser: BrowserFetchBackend(), http: http)
        #else
        self.fetchChain = .standard(browser: BrowserFetchBackend(), http: http)
        #endif
    }

    /// Test init: HTTP-only with injected URLSession.
    public init(session: URLSession) {
        let http = HTTPFetchBackend(session: session)
        self.httpBackend = http
        self.fetchChain = .standard(http: http)
    }

    /// Custom backend init.
    public init(backend: any FetchBackend) {
        self.httpBackend = backend
        self.fetchChain = .standard(http: backend)
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let urls = extractURLs(from: input, entities: entities)

            guard !urls.isEmpty else {
                // No URL found — return the input as a web search query.
                // The ExecutionEngine will inject web_search FM tool so the LLM
                // can search the web for this query during finalization.
                // This gracefully handles typo brand names ("amazn prime"),
                // unseen brands ("xiaome mi band"), and any non-URL input that
                // was misrouted to WebFetch instead of web_search.
                Log.tools.debug("WebFetch: no URL found, falling back to web search query")
                return ToolIO(
                    text: "Search the web for: \(input)",
                    status: .ok
                )
            }

            // Fetch all detected URLs (up to 3)
            var results: [String] = []
            for url in urls.prefix(3) {
                do {
                    let fetchResult = try await fetchWithFallback(url: url)

                    if fetchResult.statusCode >= 400 {
                        results.append("Error \(fetchResult.statusCode) fetching \(url.absoluteString)")
                        continue
                    }

                    var content = fetchResult.text
                    if let title = fetchResult.title, !title.isEmpty {
                        content = "# \(title)\n\n\(content)"
                    }
                    // Compact to fit token budget (split evenly across fetched URLs)
                    let perURLLimit = ContentCompactor.defaultLimit / min(urls.count, 3)
                    results.append(ContentCompactor.compact(content, limit: perURLLimit))
                } catch {
                    results.append("Error fetching \(url.absoluteString): \(error.localizedDescription)")
                }
            }

            let hasSuccess = results.contains(where: { !$0.hasPrefix("Error ") && !$0.hasPrefix("Error fetching") })
            return ToolIO(
                text: results.joined(separator: "\n\n---\n\n"),
                status: hasSuccess ? .ok : .error
            )
        }
    }

    // MARK: - Backend selection

    /// Fetch with automatic fallback through the backend chain.
    /// Known APIs → HTTP directly. Web pages → bridge → WKWebView → HTTP.
    private func fetchWithFallback(url: URL) async throws -> FetchResult {
        if Self.isKnownAPI(url) {
            return try await httpBackend.fetch(url: url)
        }
        return try await fetchChain.fetch(url: url)
    }

    /// Heuristic: is this URL a structured API endpoint (JSON, RSS, etc.)?
    static func isKnownAPI(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }

        // API subdomains (api.example.com)
        if host.hasPrefix("api.") { return true }

        // API path segments
        let path = url.path.lowercased()
        if path.contains("/api/") || path.contains("/v1/") || path.contains("/v2/") || path.contains("/v3/") {
            return true
        }

        // Structured data file extensions
        let ext = url.pathExtension.lowercased()
        if ["json", "xml", "rss", "atom", "csv", "txt"].contains(ext) { return true }

        // Known API hosts used by iClaw's other tools
        let apiHosts: Set<String> = [
            "query1.finance.yahoo.com",
            "query2.finance.yahoo.com",
            "itunes.apple.com",
        ]
        return apiHosts.contains(host)
    }

    // MARK: - URL extraction

    private func extractURLs(from input: String, entities: ExtractedEntities?) -> [URL] {
        // 1. Prefer URLs from preprocessed entities
        let entityURLs = entities?.urls.filter { $0.scheme == "http" || $0.scheme == "https" } ?? []
        if !entityURLs.isEmpty { return entityURLs }

        // 2. Fallback: parse URLs from raw input
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            let matches = detector.matches(in: input, options: [], range: range)
            let parsed = matches.compactMap { $0.url }.filter { $0.scheme == "http" || $0.scheme == "https" }
            if !parsed.isEmpty { return parsed }
        }

        // 3. Last resort: try entire input as a URL
        if let directURL = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
           directURL.scheme == "http" || directURL.scheme == "https" {
            return [directURL]
        }

        return []
    }
}
