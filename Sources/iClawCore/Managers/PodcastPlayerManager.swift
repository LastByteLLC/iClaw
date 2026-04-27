import Foundation
import AVFoundation
import CoreMedia
import Observation

@MainActor
@Observable
class PodcastPlayerManager {
    static let shared = PodcastPlayerManager()

    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var episodeTitle: String = ""
    var showName: String = ""
    var isActive = false
    var externalURL: URL? = nil

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    private init() {}
    
    private var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "iClaw/\(version)"
    }

    func play(url: URL, title: String, show: String, externalURL: URL? = nil) {
        stop()

        episodeTitle = title
        showName = show
        self.externalURL = externalURL
        isActive = true

        let options = ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)

        // Observe duration once the item is ready
        loadItemDuration(item)

        // Periodic time observer for progress
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.currentTime = seconds
                }
                // Update duration if it wasn't available initially
                if self.duration <= 0, let item = self.player?.currentItem {
                    let dur = CMTimeGetSeconds(item.duration)
                    if dur.isFinite && dur > 0 {
                        self.duration = dur
                    }
                }
            }
        }

        // Observe when playback ends (store token for proper removal)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }

        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        episodeTitle = ""
        showName = ""
        externalURL = nil
        isActive = false
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    private func loadItemDuration(_ item: AVPlayerItem) {
        Task<Void, Never> { @MainActor in
            do {
                let asset = item.asset
                let dur = try await asset.load(.duration)
                let seconds = dur.seconds
                if seconds.isFinite && seconds > 0 {
                    self.duration = seconds
                }
            } catch {
                Log.tools.error("Failed to load duration: \(error)")
            }
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func skipForward(_ seconds: Double = 15) {
        let target = min(currentTime + seconds, duration)
        seek(to: target)
    }

    func skipBackward(_ seconds: Double = 15) {
        let target = max(currentTime - seconds, 0)
        seek(to: target)
    }
}
