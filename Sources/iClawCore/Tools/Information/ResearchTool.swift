import Foundation
import SwiftSoup

/// A source citation from the research process.
public struct ResearchSource: Sendable {
    public let title: String
    public let url: String
    public let domain: String
    public let snippet: String

    public init(title: String, url: String, domain: String, snippet: String) {
        self.title = title
        self.url = url
        self.domain = domain
        self.snippet = snippet
    }
}

/// Widget data for the Research widget — carries citations as chip data.
public struct ResearchWidgetData: Sendable {
    public let topic: String
    public let sources: [ResearchSource]
    public let iterationCount: Int

    public init(topic: String, sources: [ResearchSource], iterationCount: Int) {
        self.topic = topic
        self.sources = sources
        self.iterationCount = iterationCount
    }
}

/// Multi-step research tool that searches the web and Wikipedia,
/// fetches content from multiple sources, evaluates sufficiency,
/// and returns structured results with citations.
public struct ResearchTool: CoreTool, Sendable {
    public let name = "Research"
    public let schema = "research topic learn understand deep dive explain"
    public let isInternal = false
    public let category = CategoryEnum.online

    private let searchBackend: any FetchBackend
    private let fetchBackend: any FetchBackend
    private let session: URLSession
    private let progressHandler: (@Sendable (String) -> Void)?

    /// Minimum sources required for sufficiency.
    private static let minSources = 3
    /// Minimum word count per source to count as substantive.
    private static let minWordsPerSource = 50
    /// Max research iterations (search → fetch → evaluate).
    private static let maxIterations = 2
    /// Per-source character limit for compacted content.
    private static let perSourceCharLimit = 2200

    // MARK: - Init

    /// Production init.
    public init(progressHandler: (@Sendable (String) -> Void)? = nil) {
        self.searchBackend = HTTPFetchBackend()
        self.fetchBackend = HTTPFetchBackend()
        self.session = .shared
        self.progressHandler = progressHandler
    }

    /// Test init with injected URLSession.
    public init(session: URLSession, progressHandler: (@Sendable (String) -> Void)? = nil) {
        self.searchBackend = HTTPFetchBackend(session: session)
        self.fetchBackend = HTTPFetchBackend(session: session)
        self.session = session
        self.progressHandler = progressHandler
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let topic = InputParsingUtilities.stripToolChips(from: input)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var allSources: [ResearchSource] = []
            var allContent: [(source: ResearchSource, text: String)] = []
            var iteration = 0
            var searchQuery = topic

            // Reflexion loop: search → fetch → evaluate sufficiency → refine if needed
            while iteration < Self.maxIterations {
                iteration += 1

                // Step 1: Search the web
                emitProgress("Searching for \(shortTopic(topic))...")
                let searchResults = await searchWeb(query: searchQuery)

                // Step 2: Search Wikipedia (first iteration only)
                var wikiContent: (source: ResearchSource, text: String)?
                if iteration == 1 {
                    emitProgress("Checking Wikipedia...")
                    wikiContent = await fetchWikipedia(topic: topic)
                }

                // Step 3: Fetch top search results
                let urlsToFetch = searchResults
                    .compactMap { $0.url }
                    .filter { url in
                        // Skip already-fetched domains
                        let domain = Self.extractDomain(from: url)
                        return !allSources.contains(where: { $0.domain == domain })
                    }
                    .prefix(3)

                for (_, urlString) in urlsToFetch.enumerated() {
                    guard let url = URL(string: urlString) else { continue }
                    let domain = Self.extractDomain(from: urlString)
                    emitProgress("Reading source \(allContent.count + 1): \(domain)...")

                    do {
                        let result = try await fetchBackend.fetch(url: url)
                        guard result.statusCode < 400 else { continue }

                        let title = result.title ?? searchResults.first(where: { $0.url == urlString })?.title ?? domain
                        let compacted = ContentCompactor.compact(result.text, limit: Self.perSourceCharLimit)

                        // Only count substantive content
                        let wordCount = compacted.components(separatedBy: .whitespacesAndNewlines)
                            .filter { !$0.isEmpty }.count
                        guard wordCount >= Self.minWordsPerSource else { continue }

                        let snippet = String(compacted.prefix(200))
                        let source = ResearchSource(title: title, url: urlString, domain: domain, snippet: snippet)
                        allSources.append(source)
                        allContent.append((source: source, text: compacted))
                    } catch {
                        Log.tools.debug("Research fetch failed for \(urlString): \(error.localizedDescription)")
                    }
                }

                // Add Wikipedia content
                if let wiki = wikiContent {
                    // Insert Wikipedia first (high quality baseline)
                    if !allSources.contains(where: { $0.domain == "wikipedia.org" }) {
                        allSources.insert(wiki.source, at: 0)
                        allContent.insert(wiki, at: 0)
                    }
                }

                // Step 4: Reflexion — evaluate sufficiency
                emitProgress("Evaluating sources...")
                let assessment = assessSufficiency(sources: allContent, topic: topic)

                if assessment.sufficient {
                    Log.tools.debug("Research sufficient after \(iteration) iteration(s): \(assessment.reason)")
                    break
                }

                // Not sufficient — refine query for next iteration
                if iteration < Self.maxIterations {
                    searchQuery = refineQuery(original: topic, reason: assessment.reason, existingDomains: Set(allSources.map(\.domain)))
                    emitProgress("Refining search: \(shortTopic(searchQuery))...")
                    Log.tools.debug("Research reflexion: \(assessment.reason). Refined query: \(searchQuery)")
                }
            }

            // Step 5: Assemble final output with inline citations
            emitProgress("Compiling research...")
            let (text, sources) = assembleOutput(topic: topic, content: allContent)

            return ToolIO(
                text: text,
                status: .ok,
                outputWidget: "ResearchWidget",
                widgetData: ResearchWidgetData(topic: topic, sources: sources, iterationCount: iteration),
                isVerifiedData: true
            )
        }
    }

    // MARK: - Web Search (DuckDuckGo primary, Brave fallback)

    private func searchWeb(query: String) async -> [SearchResult] {
        // Primary: DuckDuckGo HTML
        if let ddgURL = APIEndpoints.DuckDuckGo.htmlSearch(query: query) {
            do {
                let result = try await searchBackend.fetch(url: ddgURL)
                let html = result.html ?? result.text
                let ddgResults = try Self.parseDuckDuckGoResults(html: html)
                if !ddgResults.isEmpty {
                    Log.tools.debug("DuckDuckGo returned \(ddgResults.count) results")
                    return ddgResults
                }
                Log.tools.debug("DuckDuckGo returned 0 results, falling back to Brave")
            } catch {
                Log.tools.debug("DuckDuckGo search failed: \(error.localizedDescription), falling back to Brave")
            }
        }

        // Fallback: Brave Search
        return await searchBrave(query: query)
    }

    /// Brave Search HTML fallback — separate method for clean separation.
    private func searchBrave(query: String) async -> [SearchResult] {
        guard let url = APIEndpoints.Brave.search(query: query) else { return [] }
        do {
            let result = try await searchBackend.fetch(url: url)
            let html = result.html ?? result.text
            let braveResults = try Self.parseBraveResults(html: html)
            Log.tools.debug("Brave fallback returned \(braveResults.count) results")
            return braveResults
        } catch {
            Log.tools.debug("Brave search failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Parses Brave Search HTML results.
    private static func parseBraveResults(html: String) throws -> [SearchResult] {
        let doc = try SwiftSoup.parse(html)
        let items = try doc.select("div.snippet")
        return try items.compactMap { item -> SearchResult? in
            guard let title = try item.select("a.result-header").first()?.text(),
                  !title.isEmpty else { return nil }
            let href = try item.select("a.result-header").first()?.attr("href")
            let snippet = try item.select("p.snippet-description").first()?.text()
            return SearchResult(title: title, snippet: snippet, url: href)
        }
    }

    // MARK: - Wikipedia Fetch

    private func fetchWikipedia(topic: String) async -> (source: ResearchSource, text: String)? {
        // Step 1: OpenSearch to find the article title (fetch 5 candidates, pick best match)
        guard let searchURL = APIEndpoints.Wikipedia.search(query: topic, limit: 5) else { return nil }

        do {
            let (searchData, _) = try await session.data(from: searchURL)
            guard let json = try JSONSerialization.jsonObject(with: searchData) as? [Any],
                  json.count > 3,
                  let titles = json[1] as? [String],
                  let urls = json[3] as? [String],
                  !titles.isEmpty else { return nil }

            // Pick best match: prefer exact title match, then shortest non-disambiguation title
            let topicLower = topic.lowercased()
            let bestIndex: Int
            if let exactIdx = titles.firstIndex(where: { $0.lowercased() == topicLower }) {
                bestIndex = exactIdx
            } else {
                bestIndex = titles.enumerated()
                    .filter { !$0.element.lowercased().contains("(disambiguation)") && !$0.element.lowercased().contains("(song)") }
                    .min(by: { $0.element.count < $1.element.count })?
                    .offset ?? 0
            }
            let title = titles[bestIndex]
            guard bestIndex < urls.count else { return nil }
            let articleURL = urls[bestIndex]

            // Step 2: Fetch article intro extract
            guard let extractURL = APIEndpoints.Wikipedia.extract(title: title) else { return nil }

            let (extractData, _) = try await session.data(from: extractURL)
            guard let extractJSON = try JSONSerialization.jsonObject(with: extractData) as? [String: Any],
                  let query = extractJSON["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any],
                  let page = pages.values.first as? [String: Any],
                  let extract = page["extract"] as? String else { return nil }

            let compacted = ContentCompactor.compact(extract, limit: Self.perSourceCharLimit)
            let wordCount = compacted.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            guard wordCount >= Self.minWordsPerSource else { return nil }

            let snippet = String(compacted.prefix(200))
            let source = ResearchSource(
                title: "Wikipedia: \(title)",
                url: articleURL,
                domain: "wikipedia.org",
                snippet: snippet
            )
            return (source: source, text: compacted)
        } catch {
            Log.tools.debug("Wikipedia fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Sufficiency Assessment (Reflexion)

    private struct SufficiencyAssessment {
        let sufficient: Bool
        let reason: String
    }

    private func assessSufficiency(sources: [(source: ResearchSource, text: String)], topic: String) -> SufficiencyAssessment {
        // Check minimum source count
        if sources.count < Self.minSources {
            return SufficiencyAssessment(
                sufficient: false,
                reason: "Only \(sources.count) source(s) found, need at least \(Self.minSources)"
            )
        }

        // Check domain diversity (at least 2 unique domains)
        let uniqueDomains = Set(sources.map(\.source.domain))
        if uniqueDomains.count < 2 {
            return SufficiencyAssessment(
                sufficient: false,
                reason: "All sources from same domain, need diversity"
            )
        }

        // Check total content volume (at least 500 words across all sources)
        let totalWords = sources.reduce(0) { total, item in
            total + item.text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
        }
        if totalWords < 500 {
            return SufficiencyAssessment(
                sufficient: false,
                reason: "Total content too thin (\(totalWords) words), need more depth"
            )
        }

        // Check topic relevance — at least half the sources should mention the topic
        let topicWords = topic.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
        let relevantCount = sources.filter { item in
            let lower = item.text.lowercased()
            return topicWords.contains(where: { lower.contains($0) })
        }.count
        if relevantCount < sources.count / 2 {
            return SufficiencyAssessment(
                sufficient: false,
                reason: "Sources not sufficiently relevant to topic"
            )
        }

        return SufficiencyAssessment(sufficient: true, reason: "Sufficient sources, diversity, and depth")
    }

    // MARK: - Query Refinement

    private func refineQuery(original: String, reason: String, existingDomains: Set<String>) -> String {
        // Add specificity based on the insufficiency reason
        if reason.contains("thin") || reason.contains("depth") {
            return "\(original) explained overview guide"
        }
        if reason.contains("diversity") {
            return "\(original) analysis perspectives"
        }
        if reason.contains("relevant") {
            return "\"\(original)\" comprehensive"
        }
        return "\(original) overview"
    }

    // MARK: - Output Assembly

    private func assembleOutput(topic: String, content: [(source: ResearchSource, text: String)]) -> (String, [ResearchSource]) {
        guard !content.isEmpty else {
            return ("No information found for '\(topic)'. Try rephrasing your query.", [])
        }

        var parts: [String] = []
        parts.append("Research on: \(topic)\n")

        // Add each source with inline citation number
        for (idx, item) in content.enumerated() {
            let citation = "[\(idx + 1)]"
            // Truncate each source to fit within overall budget
            let truncated = String(item.text.prefix(Self.perSourceCharLimit))
            parts.append("\(citation) From \(item.source.title) (\(item.source.domain)):\n\(truncated)")
        }

        // Add references section
        parts.append("\n--- Sources ---")
        for (idx, item) in content.enumerated() {
            parts.append("[\(idx + 1)] \(item.source.title): \(item.source.url)")
        }

        let sources = content.map(\.source)
        return (parts.joined(separator: "\n\n"), sources)
    }

    // MARK: - DuckDuckGo HTML Parsing

    static func parseDuckDuckGoResults(html: String) throws -> [SearchResult] {
        let doc = try SwiftSoup.parse(html)
        let blocks = try doc.select("div.result")
        return try blocks.compactMap { block -> SearchResult? in
            guard let anchor = try block.select("a.result__a").first() else { return nil }
            let title = try anchor.text()
            guard !title.isEmpty else { return nil }

            var url: String? = try anchor.attr("href")
            // DDG wraps URLs in a redirect — extract the actual URL
            if let rawURL = url, rawURL.contains("uddg="),
               let components = URLComponents(string: rawURL),
               let actual = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = actual
            }

            let snippet = try block.select("a.result__snippet").first()?.text()
            return SearchResult(title: title, snippet: snippet, url: url)
        }
    }

    // MARK: - Search Result Type

    struct SearchResult {
        let title: String
        let snippet: String?
        let url: String?
    }

    // MARK: - Helpers

    static func extractDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return urlString
        }
        // Strip www. prefix
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func shortTopic(_ topic: String) -> String {
        let words = topic.components(separatedBy: .whitespaces)
        if words.count <= 4 { return topic }
        return words.prefix(4).joined(separator: " ") + "..."
    }

    private func emitProgress(_ description: String) {
        progressHandler?(description)
    }
}
