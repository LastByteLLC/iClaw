import SwiftUI

struct PodcastPlayerView: View {
    var player: PodcastPlayerManager
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            // Episode info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.episodeTitle)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if !player.showName.isEmpty {
                        Text(player.showName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Apple Podcasts Link
                if let externalURL = player.externalURL {
                    Button {
                        URLOpener.open(externalURL)
                    } label: {
                        Image(systemName: "apple.logo")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open in Apple Podcasts", bundle: .iClawCore))
                    .accessibilityLabel(String(localized: "Open in Apple Podcasts", bundle: .iClawCore))
                }

                // Stop / close button
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close player", bundle: .iClawCore))
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.15))
                        .frame(height: 4)

                    // Fill
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.6))
                        .frame(width: progressWidth(in: geo.size.width), height: 4)

                    // Scrub handle (visible on hover / drag)
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .offset(x: progressWidth(in: geo.size.width) - 5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            scrubValue = fraction * player.duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            let target = fraction * player.duration
                            player.seek(to: target)
                            isScrubbing = false
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Playback position", bundle: .iClawCore))
                .accessibilityValue(Text("\(formatTime(isScrubbing ? scrubValue : player.currentTime)) of \(formatTime(player.duration))"))
                .accessibilityAdjustableAction { direction in
                    let step = max(10, player.duration / 20)
                    let current = isScrubbing ? scrubValue : player.currentTime
                    switch direction {
                    case .increment:
                        player.seek(to: min(player.duration, current + step))
                    case .decrement:
                        player.seek(to: max(0, current - step))
                    @unknown default:
                        break
                    }
                }
            }
            .frame(height: 10)

            // Time labels + controls
            HStack {
                Text(formatTime(isScrubbing ? scrubValue : player.currentTime))
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)

                Spacer()

                // Skip back 15s
                Button {
                    player.skipBackward()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Skip back 15 seconds", bundle: .iClawCore))

                // Play / Pause
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? String(localized: "Pause", bundle: .iClawCore) : String(localized: "Play", bundle: .iClawCore))

                // Skip forward 15s
                Button {
                    player.skipForward()
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Skip forward 15 seconds", bundle: .iClawCore))

                Spacer()

                Text("-\(formatTime(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))")
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.black.opacity(0.25))
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard player.duration > 0 else { return 0 }
        let time = isScrubbing ? scrubValue : player.currentTime
        let fraction = time / player.duration
        return max(0, min(totalWidth, CGFloat(fraction) * totalWidth))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
