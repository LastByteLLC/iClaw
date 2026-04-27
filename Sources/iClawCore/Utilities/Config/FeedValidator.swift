import Foundation
import SwiftSoup

actor FeedValidator {
    enum ValidationResult: Sendable {
        case validFeed(url: URL, title: String?)
        case invalid(String)
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(_ urlString: String) async -> ValidationResult {
        // Normalize URL
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        guard let url = URL(string: normalized) else {
            return .invalid("Invalid URL.")
        }

        // Fetch with timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("iClaw/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .invalid("Could not reach URL: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return .invalid("Server returned an error.")
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        // Check if response is XML/RSS/Atom
        if contentType.contains("xml") || contentType.contains("rss") || contentType.contains("atom") {
            let title = parseFeedTitle(data: data)
            return .validFeed(url: url, title: title)
        }

        // Check if response is HTML — look for RSS auto-discovery link
        if contentType.contains("html") {
            guard let html = String(data: data, encoding: .utf8) else {
                return .invalid("No RSS or Atom feed found.")
            }
            return await discoverFeedFromHTML(html, baseURL: url)
        }

        return .invalid("No RSS or Atom feed found.")
    }

    // MARK: - Feed Title Parsing

    private func parseFeedTitle(data: Data) -> String? {
        let parser = FeedTitleParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.title
    }

    // MARK: - HTML Auto-Discovery

    private func discoverFeedFromHTML(_ html: String, baseURL: URL) async -> ValidationResult {
        do {
            let doc = try SwiftSoup.parse(html)
            let links = try doc.select("link[rel=alternate]")

            for link in links {
                let type = try link.attr("type").lowercased()
                guard type.contains("rss") || type.contains("atom") || type.contains("xml") else { continue }

                let href = try link.attr("href")
                guard !href.isEmpty else { continue }

                // Resolve relative URLs
                let feedURL: URL?
                if href.lowercased().hasPrefix("http") {
                    feedURL = URL(string: href)
                } else {
                    feedURL = URL(string: href, relativeTo: baseURL)?.absoluteURL
                }

                guard let resolvedURL = feedURL else { continue }

                // Fetch and validate the discovered feed
                var request = URLRequest(url: resolvedURL)
                request.timeoutInterval = 5
                request.setValue("iClaw/1.0", forHTTPHeaderField: "User-Agent")

                guard let (feedData, feedResponse) = try? await session.data(for: request),
                      let feedHTTP = feedResponse as? HTTPURLResponse,
                      (200...299).contains(feedHTTP.statusCode) else { continue }

                let title = parseFeedTitle(data: feedData) ?? (try? link.attr("title")).flatMap { $0.isEmpty ? nil : $0 }
                return .validFeed(url: resolvedURL, title: title)
            }
        } catch {
            // SwiftSoup parse failure — fall through
        }

        return .invalid("No RSS or Atom feed found at this URL.")
    }
}

// MARK: - Feed Title XML Parser

private final class FeedTitleParser: NSObject, XMLParserDelegate {
    var title: String?
    private var currentElement = ""
    private var currentText = ""
    private var foundTitle = false
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = name
        depth += 1
        if name == "title" && !foundTitle {
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "title" && !foundTitle {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        if name == "title" && !foundTitle {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                title = trimmed
                foundTitle = true
            }
        }
    }
}
