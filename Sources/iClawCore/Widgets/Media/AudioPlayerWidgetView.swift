import SwiftUI

struct AudioPlayerWidgetData: Sendable {
    let id: String
    let title: String
    let subtitle: String
    let duration: Double
}

struct AudioPlayerWidgetView: View {
    let data: AudioPlayerWidgetData

    var body: some View {
        AudioPlayerInternalView(audioData: data)
    }
}

struct AudioPlayerInternalView: View {
    let audioData: AudioPlayerWidgetData
    var player = PodcastPlayerManager.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(audioData.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(audioData.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 20) {
                Button {
                    player.skipBackward()
                } label: {
                    Image(systemName: "gobackward.15")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)

                Button {
                    player.skipForward()
                } label: {
                    Image(systemName: "goforward.15")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }

            ProgressView(value: player.currentTime, total: effectiveDuration)
                .tint(.primary)

            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text(formatTime(max(0, effectiveDuration - player.currentTime), isRemaining: true))
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .padding()
        .frame(width: 220)
        .glassContainer()
    }

    private var effectiveDuration: Double {
        player.duration > 0 ? player.duration : audioData.duration > 0 ? audioData.duration : 1
    }

    private func formatTime(_ seconds: Double, isRemaining: Bool = false) -> String {
        guard seconds.isFinite && seconds >= 0 else { return isRemaining ? "-0:00" : "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            let formatted = String(format: "%d:%02d:%02d", h, m, s)
            return isRemaining ? "-\(formatted)" : formatted
        }
        let formatted = String(format: "%d:%02d", m, s)
        return isRemaining ? "-\(formatted)" : formatted
    }
}
