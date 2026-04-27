import SwiftUI

/// Widget displaying podcast search results with artwork thumbnails.
struct PodcastSearchWidgetView: View {
    let data: PodcastSearchWidgetData

    var body: some View {
        if data.shows.isEmpty {
            Text("No podcasts found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .glassContainer(hasShadow: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Podcasts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "result_count", bundle: .iClawCore), data.shows.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .opacity(0.2)
                    .padding(.horizontal, 12)

                // Show list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.shows.prefix(5).enumerated()), id: \.offset) { index, show in
                        PodcastShowRow(show: show)

                        if index < min(data.shows.count, 5) - 1 {
                            Divider()
                                .opacity(0.1)
                                .padding(.leading, 56)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .glassContainer(hasShadow: false)
            .frame(minWidth: 280, maxWidth: 380)
        }
    }
}

// MARK: - Show Row

private struct PodcastShowRow: View {
    let show: PodcastShowItem

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .widgetActionTapped,
                object: WidgetAction(
                    displayText: "#podcast episodes \(show.name)",
                    payload: ["collectionId": String(show.collectionId), "showName": show.name]
                )
            )
        } label: {
            HStack(alignment: .center, spacing: 10) {
                // Podcast artwork
                if let artworkUrl = show.artworkUrl, let url = URL(string: artworkUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        default:
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    Image(systemName: "headphones")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "headphones")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(show.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(show.artist)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let count = show.episodeCount {
                            Text("\u{00B7}")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("\(count) eps")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Drill-down arrow
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(show.name) by \(show.artist)")
    }
}

#Preview("Podcast Search") {
    PodcastSearchWidgetView(data: PodcastSearchWidgetData(
        query: "tech",
        shows: [
            PodcastShowItem(name: "Lex Fridman Podcast", artist: "Lex Fridman", genre: "Technology", episodeCount: 494, artworkUrl: nil, collectionId: 1),
            PodcastShowItem(name: "The Vergecast", artist: "The Verge", genre: "Technology", episodeCount: 780, artworkUrl: nil, collectionId: 2),
            PodcastShowItem(name: "Accidental Tech Podcast", artist: "Marco Arment, Casey Liss, John Siracusa", genre: "Technology", episodeCount: 620, artworkUrl: nil, collectionId: 3),
        ]
    ))
    .padding()
    .frame(width: 360)
}
