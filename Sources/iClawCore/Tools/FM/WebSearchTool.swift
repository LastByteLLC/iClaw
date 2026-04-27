import Foundation
import FoundationModels
import SwiftSoup

@Generable
struct WebSearchInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The search query")
    var query: String
}

struct WebSearchTool: Tool {
    typealias Arguments = WebSearchInput
    typealias Output = String

    let name = "web_search"
    let description = "Search the web for current information, facts, and news."
    var parameters: GenerationSchema { Arguments.generationSchema }

    private let httpBackend: any FetchBackend
    private let fetchChain: FallbackFetchChain
    private let factLookup: FactLookupService

    init(session: URLSession = .iClawDefault) {
        let http = HTTPFetchBackend(session: session)
        self.httpBackend = http
        #if os(macOS)
        self.fetchChain = .bridgeAndHTTP(bridge: BrowserBridgeFetchBackend(), http: http)
        #else
        self.fetchChain = .bridgeAndHTTP(http: http)
        #endif
        self.factLookup = FactLookupService(session: session)
    }

    init(backend: any FetchBackend) {
        self.httpBackend = backend
        self.fetchChain = .bridgeAndHTTP(http: backend)
        self.factLookup = FactLookupService()
    }

    init(backend: any FetchBackend, factLookup: FactLookupService) {
        self.httpBackend = backend
        self.fetchChain = .bridgeAndHTTP(http: backend)
        self.factLookup = factLookup
    }

    func call(arguments input: WebSearchInput) async throws -> String {
        // Stage 0: Try structured fact lookup (DDG Instant Answer + Wikidata)
        // These return compact, accurate data without HTML scraping
        if let facts = await factLookup.lookup(query: input.query) {
            Log.tools.debug("WebSearch: fact lookup succeeded for '\(input.query)' — \(facts.facts.count) facts")
            return "[VERIFIED] \(facts.formatted())"
        }

        // Stage 1: Web search with 10s tool-level timeout.
        // This prevents a slow fetch from consuming the entire 15s finalization budget.
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.performWebSearch(query: input.query)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            return "Web search timed out for '\(input.query)'. Try again."
        }
    }

    // MARK: - Web Search with Fallback

    /// Fetches a URL using BrowserBridge (if connected) with HTTP fallback.
    private func fetchWithFallback(url: URL) async throws -> FetchResult {
        try await fetchChain.fetch(url: url)
    }

    /// Performs the actual web search (DDG → Brave fallback).
    private func performWebSearch(query: String) async throws -> String {
        // Primary: DuckDuckGo HTML
        var results: [SearchResult] = []
        if let ddgURL = APIEndpoints.DuckDuckGo.htmlSearch(query: query) {
            do {
                let fetchResult = try await fetchWithFallback(url: ddgURL)
                results = try Self.parseDuckDuckGoResults(html: fetchResult.html ?? fetchResult.text)
                if !results.isEmpty {
                    Log.tools.debug("WebSearch: DuckDuckGo returned \(results.count) results")
                } else {
                    Log.tools.debug("WebSearch: DuckDuckGo returned 0 results, falling back to Brave")
                }
            } catch {
                Log.tools.debug("WebSearch: DuckDuckGo failed: \(error.localizedDescription), falling back to Brave")
            }
        }

        // Fallback 1: Brave Search
        if results.isEmpty {
            if let braveURL = APIEndpoints.Brave.search(query: query) {
                do {
                    let fetchResult = try await fetchWithFallback(url: braveURL)
                    results = try Self.parseBraveResults(html: fetchResult.html ?? fetchResult.text)
                    if !results.isEmpty {
                        Log.tools.debug("WebSearch: Brave returned \(results.count) results")
                    }
                } catch {
                    Log.tools.debug("WebSearch: Brave failed: \(error.localizedDescription)")
                }
            }
        }

        if results.isEmpty {
            return "No results found for '\(query)'."
        }

        // Format as compact structured text
        let formatted = results.prefix(5).enumerated().map { i, r in
            var entry = "\(i + 1). \(r.title)"
            if let snippet = r.snippet { entry += "\n   \(snippet)" }
            if let url = r.url { entry += "\n   \(url)" }
            return entry
        }.joined(separator: "\n")

        return ContentCompactor.clean("Search results for '\(query)':\n\(formatted)")
    }

    // MARK: - DuckDuckGo HTML parsing

    static func parseDuckDuckGoResults(html: String) throws -> [SearchResult] {
        let doc = try SwiftSoup.parse(html)
        let blocks = try doc.select("div.result")
        return try blocks.compactMap { block -> SearchResult? in
            guard let anchor = try block.select("a.result__a").first() else { return nil }
            let title = try anchor.text()
            guard !title.isEmpty else { return nil }

            var url: String? = try anchor.attr("href")
            if let rawURL = url, rawURL.contains("uddg="),
               let components = URLComponents(string: rawURL),
               let actual = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = actual
            }

            let snippet = try block.select("a.result__snippet").first()?.text()
            return SearchResult(title: title, snippet: snippet, url: url)
        }
    }

    // MARK: - Brave HTML parsing

    static func parseBraveResults(html: String) throws -> [SearchResult] {
        let doc = try SwiftSoup.parse(html)
        // Brave wraps results in div.snippet with heading + description
        let blocks = try doc.select("div.snippet")
        return try blocks.compactMap { block -> SearchResult? in
            guard let heading = try block.select("span.snippet-title").first()
                    ?? block.select("a.result-header").first() else { return nil }
            let title = try heading.text()
            guard !title.isEmpty else { return nil }

            let url: String? = try block.select("a.result-header").first().map { try $0.attr("href") }
                ?? block.select("a[href]").first().map { try $0.attr("href") }

            let snippet = try block.select("p.snippet-description").first()?.text()
                ?? block.select("div.snippet-description").first()?.text()

            return SearchResult(title: title, snippet: snippet, url: url)
        }
    }

    // MARK: - Search Result

    struct SearchResult {
        let title: String
        let snippet: String?
        let url: String?
    }
}
