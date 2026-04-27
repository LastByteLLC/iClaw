import SwiftUI

/// Posted when the user taps a news article link to drill down.
/// The notification's `object` is the query string (e.g. "#news https://...").
extension Notification.Name {
    static let newsArticleTapped = Notification.Name("iClaw.newsArticleTapped")
}

/// Widget displaying aggregated news headlines with source favicons and clickable links.
struct NewsWidgetView: View {
    let data: NewsWidgetData

    var body: some View {
        if data.articles.isEmpty {
            Text("No articles available")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .glassContainer(hasShadow: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "newspaper.fill")
                        .font(.caption) // SF Symbol sizing
                        .foregroundStyle(.secondary)
                    Text(data.category?.capitalized ?? "Headlines")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "article_count", bundle: .iClawCore), data.articles.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .opacity(0.2)
                    .padding(.horizontal, 12)

                // Article list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.articles.prefix(8).enumerated()), id: \.offset) { index, article in
                        NewsArticleRow(article: article)

                        if index < min(data.articles.count, 8) - 1 {
                            Divider()
                                .opacity(0.1)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.vertical, 4)

                // Offer web search when results are sparse
                if data.articles.count < 3 {
                    Divider()
                        .opacity(0.2)
                        .padding(.horizontal, 12)

                    Button {
                        let query = data.category ?? "latest news"
                        NotificationCenter.default.post(
                            name: .widgetActionTapped,
                            object: WidgetAction(
                                displayText: "search for \(query) news",
                                payload: ["query": "\(query) news"]
                            )
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption) // SF Symbol sizing
                            Text("Search through web")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassContainer(hasShadow: false)
            .frame(minWidth: 280, maxWidth: 380)
        }
    }
}

// MARK: - Article Row

private struct NewsArticleRow: View {
    let article: NewsArticle

    var body: some View {
        Button {
            // Open in browser
            if let url = URL(string: article.link) {
                URLOpener.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Favicon via Google's service
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    default:
                        Image(systemName: "globe")
                            .font(.caption) // SF Symbol sizing
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.top, 2)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(article.source)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

                        if let date = article.pubDate {
                            Text("\u{00B7}")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Drill-down icon (not a nested button — exposed as accessibilityAction below).
                Image(systemName: "arrow.right.circle")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(rowAccessibilityLabel))
        .accessibilityAction(named: Text("Ask about this article", bundle: .iClawCore)) {
            NotificationCenter.default.post(
                name: .widgetActionTapped,
                object: WidgetAction(
                    displayText: "#news \(article.title)",
                    payload: ["url": article.link, "title": article.title, "source": article.source]
                )
            )
        }
    }

    private var rowAccessibilityLabel: String {
        var parts = [article.title, article.source]
        if let date = article.pubDate { parts.append(date) }
        return parts.joined(separator: ", ")
    }

    private var faviconURL: URL? {
        guard !article.domain.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(article.domain).ico")
    }
}

#Preview("News Widget") {
    NewsWidgetView(data: NewsWidgetData(
        articles: [
            NewsArticle(title: "Major climate agreement reached at UN summit", link: "https://bbc.com/news/1", source: "BBC News", domain: "bbc.com", pubDate: "2h ago"),
            NewsArticle(title: "Apple announces new AI features for macOS", link: "https://theverge.com/2", source: "The Verge", domain: "theverge.com", pubDate: "4h ago"),
            NewsArticle(title: "Scientists discover high-temperature superconductor", link: "https://nature.com/3", source: "Nature", domain: "nature.com", pubDate: "6h ago"),
            NewsArticle(title: "Markets rally on positive economic data", link: "https://cnbc.com/4", source: "CNBC", domain: "cnbc.com", pubDate: "1h ago"),
        ],
        category: nil
    ))
    .padding()
    .frame(width: 360)
}
