import Foundation
import NaturalLanguage
import SwiftSoup

/// A news article parsed from an RSS feed.
public struct NewsArticle: Sendable {
    public let title: String
    public let link: String
    public let source: String
    public let domain: String
    public let pubDate: String?

    public init(title: String, link: String, source: String, domain: String, pubDate: String? = nil) {
        self.title = title
        self.link = link
        self.source = source
        self.domain = domain
        self.pubDate = pubDate
    }
}

/// Widget data for the NewsWidget.
public struct NewsWidgetData: Sendable {
    public let articles: [NewsArticle]
    public let category: String?

    public init(articles: [NewsArticle], category: String? = nil) {
        self.articles = articles
        self.category = category
    }
}

/// Structured arguments for LLM-extracted news requests.
public struct NewsArgs: ToolArguments {
    public let intent: String    // "headlines" or "summarize"
    public let category: String? // "tech", "sports", "business", etc.
    public let topic: String?    // free-text search query
}

/// Core tool that aggregates headlines from multiple RSS feeds, cross-compares, and
/// supports drill-down into individual articles via BrowserBridge/WebFetch.
public struct NewsTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "News"
    public let schema = "Get latest news headlines from multiple sources. Categories: tech, world, science, business. Drill down into articles for details."
    public let isInternal = false
    public let category = CategoryEnum.online

    private let session: URLSession
    private let httpBackend: any FetchBackend
    private let fetchChain: FallbackFetchChain

    // MARK: - RSS Feeds (loaded from JSON)

    public struct RSSFeed: Sendable {
        public let name: String
        public let url: String
        public let categories: Set<String> // empty = general/all
        public let iconDomain: String? // override domain for favicon when RSS URL differs from website
    }

    private struct NewsConfigJSON: Decodable {
        struct FeedEntry: Decodable {
            let name: String
            let url: String
            let categories: [String]
            let iconDomain: String?
        }
        let feeds: [FeedEntry]
        let categoryKeywords: [String: [String]]
        let noiseWords: [String]
    }

    private static let newsConfig: NewsConfigJSON? = ConfigLoader.load("NewsConfig", as: NewsConfigJSON.self)

    private static let noiseWordSet: Set<String> = Set(newsConfig?.noiseWords ?? [])

    static let builtInFeeds: [RSSFeed] = {
        guard let config = newsConfig else { return [] }
        return config.feeds.map { RSSFeed(name: $0.name, url: $0.url, categories: Set($0.categories), iconDomain: $0.iconDomain) }
    }()

    // MARK: - Init

    public init(session: URLSession = .iClawDefault) {
        self.session = session
        let http = HTTPFetchBackend(session: session)
        self.httpBackend = http
        self.fetchChain = .standard(bridge: BrowserBridgeFetchBackend(), browser: BrowserFetchBackend(), http: http)
    }

    /// Test init: HTTP-only, no browser backends.
    public init(session: URLSession, httpOnly: Bool) {
        self.session = session
        let http = HTTPFetchBackend(session: session)
        self.httpBackend = http
        self.fetchChain = .standard(http: http)
    }

    // MARK: - ExtractableCoreTool

    public typealias Args = NewsArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "News", fallback: "{\"intent\":\"headlines|summarize\",\"category\":\"string?\",\"topic\":\"string?\"}"
    )

    public func execute(args: NewsArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            // Fast path: widget provided article URL via WidgetAction payload
            if let urlStr = entities?.widgetPayload?["url"], let url = URL(string: urlStr) {
                return await drillDown(url: url)
            }

            let cleaned = rawInput
                .replacingOccurrences(of: "#news", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Drill-down: if user provides a URL, fetch the full article
            if let url = extractURL(from: cleaned) {
                return await drillDown(url: url)
            }

            let summarize = args.intent == "summarize"
            let category = args.category

            // Use topic as query terms if provided; otherwise back-fill from
            // the raw input so the filter still runs when the extractor
            // returned no topic (observed 2026-04 audit: "latest news on AI"
            // produced topic=nil, bypassing the filter and returning unrelated
            // headlines).
            let queryTerms: [String] = {
                if let topic = args.topic, !topic.isEmpty {
                    return topic.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                }
                return extractQueryTerms(from: rawInput.lowercased())
            }()

            // When there's a specific topic, cast a wider net by fetching from all feeds
            let fetchCategory = queryTerms.isEmpty ? category : nil

            // Fetch RSS headlines
            var articles = await fetchHeadlines(category: fetchCategory)

            guard !articles.isEmpty else {
                return ToolIO(
                    text: "Could not fetch news headlines. RSS feeds may be temporarily unavailable.",
                    status: .error
                )
            }

            // Filter by topic query if the user asked about something specific
            var topicLabel: String? = nil
            if !queryTerms.isEmpty {
                articles = filterByTopic(articles: articles, queryTerms: queryTerms)
                if !articles.isEmpty {
                    topicLabel = queryTerms.joined(separator: " ")
                } else {
                    // No RSS matches — fall back to Google News search
                    let query = queryTerms.joined(separator: " ")
                    let googleArticles = await searchGoogleNews(query: query)
                    if !googleArticles.isEmpty {
                        articles = googleArticles
                        topicLabel = query
                    } else {
                        // Both RSS and Google News failed — return honest empty result
                        let topic = queryTerms.joined(separator: " ")
                        return ToolIO(
                            text: "No news articles found matching \"\(topic)\". Try a broader search term.",
                            status: .ok
                        )
                    }
                }
            }

            // Summarize mode: fetch top articles' content and provide real summaries
            if summarize {
                return await fetchAndSummarize(
                    articles: Array(articles.prefix(5)),
                    category: category,
                    topicLabel: topicLabel
                )
            }

            return buildHeadlinesResult(
                articles: articles, category: category, topicLabel: topicLabel
            )
        }
    }

    // MARK: - Execute (Fallback)

    // MARK: - Summarize Detection

    private static let summarizeKeywords: Set<String> = [
        "summarize", "summary", "brief", "briefing", "digest",
        "recap", "round up", "roundup", "tldr", "tl;dr",
        "catch me up", "catch up", "fill me in"
    ]

    private func wantsSummary(input: String) -> Bool {
        let lower = input.lowercased()
        return Self.summarizeKeywords.contains(where: { lower.contains($0) })
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let cleaned = input
                .replacingOccurrences(of: "#news", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = cleaned.lowercased()

            // Drill-down: if user provides a URL, fetch the full article
            if let url = extractURL(from: cleaned) {
                return await drillDown(url: url)
            }

            let summarize = wantsSummary(input: lower)

            // Detect category
            let category = detectCategory(input: lower)

            // Extract topic query terms (everything that isn't a stop word or category keyword)
            let queryTerms = extractQueryTerms(from: lower)

            // When there's a specific topic, cast a wider net by fetching from all feeds
            let fetchCategory = queryTerms.isEmpty ? category : nil

            // Fetch RSS headlines
            var articles = await fetchHeadlines(category: fetchCategory)

            guard !articles.isEmpty else {
                return ToolIO(
                    text: "Could not fetch news headlines. RSS feeds may be temporarily unavailable.",
                    status: .error
                )
            }

            // Filter by topic query if the user asked about something specific
            var topicLabel: String? = nil
            if !queryTerms.isEmpty {
                articles = filterByTopic(articles: articles, queryTerms: queryTerms)
                if !articles.isEmpty {
                    topicLabel = queryTerms.joined(separator: " ")
                } else {
                    // No RSS matches — fall back to Google News search
                    let query = queryTerms.joined(separator: " ")
                    let googleArticles = await searchGoogleNews(query: query)
                    if !googleArticles.isEmpty {
                        articles = googleArticles
                        topicLabel = query
                    } else {
                        // Both RSS and Google News failed — return honest empty result
                        let topic = queryTerms.joined(separator: " ")
                        return ToolIO(
                            text: "No news articles found matching \"\(topic)\". Try a broader search term.",
                            status: .ok
                        )
                    }
                }
            }

            // Summarize mode: fetch top articles' content and provide real summaries
            if summarize {
                return await fetchAndSummarize(
                    articles: Array(articles.prefix(5)),
                    category: category,
                    topicLabel: topicLabel
                )
            }

            return buildHeadlinesResult(
                articles: articles, category: category, topicLabel: topicLabel
            )
        }
    }

    // MARK: - Summarize Mode

    /// Fetches the full content of top articles and returns compacted summaries
    /// so the LLM has real content to work with instead of just titles.
    private func fetchAndSummarize(
        articles: [NewsArticle],
        category: String?,
        topicLabel: String?
    ) async -> ToolIO {
        // Fetch article content concurrently (up to 5 articles, 1200 chars each)
        let summaries = await withTaskGroup(of: (Int, String, String).self) { group in
            for (i, article) in articles.enumerated() {
                group.addTask {
                    guard let url = URL(string: article.link) else {
                        return (i, article.title, "")
                    }
                    do {
                        let result = try await self.fetchWithFallback(url: url)
                        let compacted = ContentCompactor.compact(result.text, limit: 1200)
                        return (i, article.title, compacted)
                    } catch {
                        return (i, article.title, "")
                    }
                }
            }

            var results: [(Int, String, String)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }

        // Build rich text with actual content for each article
        let label = topicLabel ?? category ?? "top"
        var lines = ["News Summary (\(label)):"]
        for (i, (_, title, content)) in summaries.enumerated() {
            let source = articles[i].source
            let date = articles[i].pubDate.map { " (\($0))" } ?? ""
            if content.isEmpty {
                lines.append("\(i + 1). \(title) — \(source)\(date)")
            } else {
                lines.append("\(i + 1). \(title) — \(source)\(date)")
                lines.append("   \(content)")
            }
        }

        let widgetData = NewsWidgetData(
            articles: articles,
            category: category
        )

        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "NewsWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Topic Filtering

    /// Filters and ranks articles by keyword density. A title matching
    /// multiple distinct query terms outranks a title matching one. Uses
    /// word-boundary checks so "ai" matches "AI ethics" but not "main".
    /// Requires score ≥ 1 to include; results are sorted descending by score.
    private func filterByTopic(articles: [NewsArticle], queryTerms: [String]) -> [NewsArticle] {
        guard !queryTerms.isEmpty else { return articles }
        let scored: [(NewsArticle, Int)] = articles.map { article in
            (article, scoreArticle(article, terms: queryTerms))
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// Scores an article against query terms. 2 points per distinct whole-word
    /// match in the title, 1 point per substring match anywhere, dedup'd.
    private func scoreArticle(_ article: NewsArticle, terms: [String]) -> Int {
        let titleLower = article.title.lowercased()
        var score = 0
        for term in Set(terms) where term.count >= 2 {
            // Whole-word match (strong signal)
            let wholeWordPattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
            if let re = try? NSRegularExpression(pattern: wholeWordPattern, options: []) {
                let range = NSRange(titleLower.startIndex..., in: titleLower)
                if re.firstMatch(in: titleLower, options: [], range: range) != nil {
                    score += 2
                    continue
                }
            }
            // Substring fallback (weaker)
            if titleLower.contains(term) {
                score += 1
            }
        }
        return score
    }

    // MARK: - Result Building

    /// Builds the final ToolIO result for a headlines request.
    private func buildHeadlinesResult(
        articles: [NewsArticle],
        category: String?,
        topicLabel: String?
    ) -> ToolIO {
        let label = topicLabel ?? category ?? "top"
        var lines = ["Headlines (\(label)):"]
        let displayArticles = Array(articles.prefix(5))
        for (i, article) in displayArticles.enumerated() {
            var line = "\(i + 1). \(article.title) — \(article.source)"
            if let date = article.pubDate { line += " (\(date))" }
            lines.append(line)
            // Truncate Google News redirect URLs to reduce token bloat.
            // Full URLs are preserved in NewsWidgetData for drill-down.
            if article.link.count > 120, let url = URL(string: article.link), let host = url.host {
                lines.append("https://\(host)/...")
            } else {
                lines.append(article.link)
            }
        }

        let widgetData = NewsWidgetData(
            articles: Array(articles.prefix(10)),
            category: category
        )

        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "NewsWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Category Detection

    private static let categoryKeywordSets: [String: Set<String>] = {
        guard let config = newsConfig else { return [:] }
        return config.categoryKeywords.mapValues { Set($0) }
    }()

    private func detectCategory(input: String) -> String? {
        let words = Set(input.wordTokens)

        // Check categories in priority order
        for category in ["tech", "science", "world", "business"] {
            guard let keywords = Self.categoryKeywordSets[category] else { continue }
            if !words.intersection(keywords).isEmpty { return category }
            // Extra check for "tech" which also matches as a substring
            if category == "tech" && input.contains("tech") { return category }
        }
        return nil
    }

    // MARK: - Query Term Extraction

    /// Uses NLP tokenization to extract meaningful topic words from the user's input,
    /// filtering out stop words, category keywords, and common news-request phrasing.
    private func extractQueryTerms(from input: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = input

        // Collect all tokens
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: input.startIndex..<input.endIndex) { range, _ in
            tokens.append(String(input[range]).lowercased())
            return true
        }

        // Words that are part of the request framing, not the topic
        let noiseWords = Self.noiseWordSet

        let meaningful = tokens.filter { token in
            token.count > 1 && !noiseWords.contains(token)
        }

        return meaningful
    }

    // MARK: - RSS Fetching

    private func fetchHeadlines(category: String?) async -> [NewsArticle] {
        let allFeeds = await FeedRegistry.activeFeeds
        let selectedFeeds: [RSSFeed]
        if let category {
            // Category-specific feeds + general feeds
            selectedFeeds = allFeeds.filter { $0.categories.contains(category) || $0.categories.isEmpty }
        } else {
            // Diverse source selection: all general feeds + 1 feed per category
            // to ensure headlines aren't dominated by a few sources.
            let general = allFeeds.filter { $0.categories.isEmpty }
            var diverse = general

            // Add one feed from each category for broader coverage
            var seenCategories = Set<String>()
            for feed in allFeeds where !feed.categories.isEmpty {
                for cat in feed.categories where !seenCategories.contains(cat) {
                    seenCategories.insert(cat)
                    diverse.append(feed)
                    break
                }
            }
            selectedFeeds = diverse
        }

        // Fetch feeds concurrently
        let articles = await withTaskGroup(of: [NewsArticle].self) { group in
            for feed in selectedFeeds {
                group.addTask {
                    await self.fetchFeed(feed)
                }
            }

            var all: [NewsArticle] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        // Deduplicate by title similarity (strip source prefixes, compare lowercased)
        var seen = Set<String>()
        var unique: [NewsArticle] = []
        for article in articles {
            let key = article.title.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 3 }
                .prefix(5)
                .joined(separator: " ")
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(article)
            }
        }

        return unique
    }

    private func fetchFeed(_ feed: RSSFeed) async -> [NewsArticle] {
        guard let url = URL(string: feed.url) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("iClaw/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            return parseRSS(data: data, sourceName: feed.name)
        } catch {
            Log.tools.debug("Failed to fetch \(feed.name): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - RSS Parsing

    private func parseRSS(data: Data, sourceName: String) -> [NewsArticle] {
        let parser = RSSParser(sourceName: sourceName)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return Array(parser.articles.prefix(5))
    }

    // MARK: - Drill-Down (Full Article)

    private func drillDown(url: URL) async -> ToolIO {
        do {
            let result = try await fetchWithFallback(url: url)
            let compacted = ContentCompactor.compact(result.text)
            let title = result.title ?? url.host ?? "Article"

            return ToolIO(
                text: "[\(title)]\n\(compacted)",
                status: .ok,
                isVerifiedData: true
            )
        } catch {
            return ToolIO(
                text: "Could not fetch article: \(error.localizedDescription)",
                status: .error
            )
        }
    }

    /// Fetch article content: prefer BrowserBridge (real cookies/JS), then WKWebView, then HTTP.
    private func fetchWithFallback(url: URL) async throws -> FetchResult {
        try await fetchChain.fetch(url: url)
    }

    // MARK: - Google News Fallback

    /// Searches Google News RSS for a specific query when local RSS filtering finds no matches.
    private func searchGoogleNews(query: String) async -> [NewsArticle] {
        guard let url = APIEndpoints.GoogleNews.rssSearch(query: query) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("iClaw/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            return parseRSS(data: data, sourceName: "Google News")
        } catch {
            Log.tools.debug("Google News search failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - URL Extraction

    private func extractURL(from input: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = detector?.matches(in: input, options: [], range: range) ?? []
        return matches.compactMap { $0.url }.first { $0.scheme == "http" || $0.scheme == "https" }
    }
}

// MARK: - RSS XML Parser

final class RSSParser: NSObject, XMLParserDelegate {
    let sourceName: String
    private(set) var articles: [NewsArticle] = []

    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentPubDate = ""
    private var insideItem = false
    // Atom feeds use <entry> instead of <item>
    private var isAtom = false

    init(sourceName: String) {
        self.sourceName = sourceName
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = name

        if name == "item" || name == "entry" {
            insideItem = true
            currentTitle = ""
            currentLink = ""
            currentPubDate = ""
            if name == "entry" { isAtom = true }
        }

        // Atom <link href="...">
        if insideItem && name == "link" && isAtom, let href = attributes["href"] {
            currentLink = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title": currentTitle += string
        case "link": if !isAtom { currentLink += string }
        case "pubDate", "published", "updated": currentPubDate += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard (name == "item" || name == "entry") && insideItem else { return }
        insideItem = false

        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !link.isEmpty else { return }

        let domain = URL(string: link)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let date = formatPubDate(currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines))

        articles.append(NewsArticle(
            title: title, link: link, source: sourceName, domain: domain, pubDate: date
        ))
    }

    // MARK: - Cached Date Formatters

    private static let rfc822Formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z",
         "EEE, dd MMM yyyy HH:mm:ss zzz",
         "dd MMM yyyy HH:mm:ss Z"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    private nonisolated(unsafe) static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func formatPubDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        // Try RFC 822 (RSS standard)
        for formatter in Self.rfc822Formatters {
            if let date = formatter.date(from: raw) {
                return relativeDate(date)
            }
        }

        // Try ISO 8601 (Atom standard)
        if let date = Self.isoDateFormatter.date(from: raw) {
            return relativeDate(date)
        }

        return nil
    }

    private func relativeDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return Self.shortDateFormatter.string(from: date)
    }
}

// MARK: - PreFetchable

extension NewsTool: PreFetchable {
    /// Pre-fetch general headlines. Cache key matches the key derived from
    /// "#news" (which strips to empty input → "News:").
    public func preFetchEntries() async -> [PreFetchEntry] {
        [
            PreFetchEntry(
                cacheKey: ScratchpadCache.makeKey(toolName: "News", input: ""),
                label: "General headlines",
                ttl: 28800, // 8 hours
                toolName: "News",
                fetch: {
                    try await NewsTool().execute(input: "", entities: nil)
                }
            )
        ]
    }
}
