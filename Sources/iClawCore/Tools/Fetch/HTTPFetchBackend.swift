import Foundation
import SwiftSoup

/// Plain URLSession fetch backend. Best for known APIs and simple HTML pages.
/// Strips HTML to readable text via SwiftSoup when the response is HTML.
public struct HTTPFetchBackend: FetchBackend {
    private let session: URLSession

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    public func fetch(url: URL) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard data.count < 5_000_000 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? "Unable to decode content."
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""

        // If it's HTML, extract readable text
        if contentType.contains("html") || raw.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
            let doc = try SwiftSoup.parse(raw)

            // Remove non-content elements
            try doc.select("script, style, nav, header, footer, noscript, iframe, svg").remove()

            let title = try? doc.title()
            let text = try doc.body()?.text() ?? raw

            return FetchResult(text: text, html: raw, title: title, statusCode: statusCode)
        }

        // Non-HTML (JSON, plain text, etc.) — return as-is
        return FetchResult(text: raw, statusCode: statusCode)
    }
}
