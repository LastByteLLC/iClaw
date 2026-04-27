import SwiftUI

/// Posted when the user taps a podcast episode to play it.
/// The notification's `object` is the query string (e.g. "#podcast play <title>").
extension Notification.Name {
    static let podcastEpisodeTapped = Notification.Name("iClaw.podcastEpisodeTapped")
}

/// Widget displaying a list of podcast episodes with play buttons.
struct PodcastEpisodesWidgetView: View {
    let data: PodcastEpisodesWidgetData

    var body: some View {
        if data.episodes.isEmpty {
            Text("No episodes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .glassContainer(hasShadow: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header with artwork
                HStack(spacing: 8) {
                    if let artworkUrl = data.artworkUrl, let url = URL(string: artworkUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            default:
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        Image(systemName: "headphones")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                            }
                        }
                    } else {
                        Image(systemName: "headphones")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(data.showName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(String(format: String(localized: "episode_count", bundle: .iClawCore), data.episodes.count))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .opacity(0.2)
                    .padding(.horizontal, 12)

                // Episode list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.episodes.prefix(6).enumerated()), id: \.offset) { index, episode in
                        PodcastEpisodeRow(episode: episode)

                        if index < min(data.episodes.count, 6) - 1 {
                            Divider()
                                .opacity(0.1)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .glassContainer(hasShadow: false)
            .frame(minWidth: 260, maxWidth: 380)
        }
    }
}

// MARK: - Episode Row

private struct PodcastEpisodeRow: View {
    let episode: PodcastEpisodeItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Play button
            Button {
                if episode.episodeUrl != nil {
                    var payload: [String: String] = ["title": episode.title]
                    if let url = episode.episodeUrl { payload["episodeUrl"] = url }
                    NotificationCenter.default.post(
                        name: .widgetActionTapped,
                        object: WidgetAction(
                            displayText: "#podcast play \(episode.title)",
                            payload: payload
                        )
                    )
                }
            } label: {
                Image(systemName: episode.episodeUrl != nil ? "play.circle.fill" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(episode.episodeUrl != nil ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(episode.episodeUrl == nil)
            .accessibilityLabel(String(localized: "Play episode", bundle: .iClawCore))

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if let date = episode.date {
                        Text(date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let duration = episode.duration {
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

#Preview("Podcast Episodes") {
    PodcastEpisodesWidgetView(data: PodcastEpisodesWidgetData(
        showName: "Lenny's Podcast",
        episodes: [
            PodcastEpisodeItem(title: "How I built a 1M+ subscriber newsletter", date: "Mar 12, 2026", duration: "1h 6m", episodeUrl: "https://example.com/ep1.mp3", showName: "Lenny's Podcast"),
            PodcastEpisodeItem(title: "The most successful AI company you've never heard of", date: "Mar 8, 2026", duration: "1h 24m", episodeUrl: "https://example.com/ep2.mp3", showName: "Lenny's Podcast"),
            PodcastEpisodeItem(title: "The design process is dead", date: "Mar 1, 2026", duration: "1h 17m", episodeUrl: nil, showName: "Lenny's Podcast"),
        ],
        artworkUrl: "https://is1-ssl.mzstatic.com/image/thumb/Podcasts116/v4/a1/c1/e1/a1c1e1a1-1234-5678-abcd-1234567890ab/mza_1234567890.jpg/100x100bb.jpg"
    ))
    .padding()
    .frame(width: 340)
}
