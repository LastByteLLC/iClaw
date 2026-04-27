import Foundation
#if canImport(AppKit)
import AppKit
#endif
@preconcurrency import Speech
@preconcurrency import AVFoundation

/// Accumulates volatile and finalized speech transcription results.
struct TranscriptAccumulator: Sendable {
    private(set) var finalizedTranscript: String = ""
    private(set) var volatileTranscript: String = ""

    var combined: String {
        (finalizedTranscript + volatileTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func apply(text: String, isFinal: Bool) {
        if isFinal {
            volatileTranscript = ""
            finalizedTranscript += text
        } else {
            volatileTranscript = text
        }
    }
}

@MainActor
class SpeechManager: NSObject, ObservableObject {
    static let shared = SpeechManager()

    /// Seconds of silence after the last result before auto-confirming.
    static let silenceTimeoutSeconds: TimeInterval = 2.0

    @Published var isRecording = false
    @Published var transcription = ""
    @Published var isReady = false

    /// Whether on-device speech transcription is available on this device.
    /// False if hardware, OS version, or Apple Intelligence speech models are missing.
    /// UI should hide the microphone button when this is false.
    @Published var isSpeechAvailable = false
    /// Snapshot of the last meaningful transcription, captured before cleanup.
    /// Use this in `confirmRecording()` instead of `transcription` to avoid races.
    var lastTranscript = ""
    /// True once the speech recognizer has produced at least one result.
    /// Used to distinguish real transcription from status messages in `stopRecording()`.
    internal var hasReceivedSpeech = false

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?

    private var recordingTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    private var audioConverter: AVAudioConverter?

    private override init() {
        super.init()
        // Check speech availability asynchronously at startup
        Task { @MainActor in
            await self.checkSpeechAvailability()
        }
    }

    /// Checks whether on-device speech transcription is available.
    /// Sets `isSpeechAvailable` which controls mic button visibility.
    private func checkSpeechAvailability() async {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            isSpeechAvailable = false
            return
        }
        guard SpeechTranscriber.isAvailable else {
            isSpeechAvailable = false
            return
        }
        let supportedLocales = await SpeechTranscriber.supportedLocales
        isSpeechAvailable = supportedLocales.contains { $0.identifier.hasPrefix("en") }
    }
    
    func startRecording() {
        // Pre-flight: request microphone permission before entering recording mode.
        // This avoids the system dialog stealing focus and hiding the HUD panel.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            setStatus("Need mic access. Hang on…")
            isRecording = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.setStatus("Mic denied. Fix it in System Settings → Privacy.")
                        self?.isRecording = false
                    }
                }
            }
        case .denied, .restricted:
            setStatus("Mic denied. Fix it in System Settings → Privacy.")
            isRecording = true
            // Auto-dismiss after 3 seconds
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.isRecording = false
            }
        @unknown default:
            beginRecording()
        }
    }

    private func beginRecording() {
        lastTranscript = ""
        hasReceivedSpeech = false
        setStatus("Warming up the speech engine…")
        if !isRecording { isRecording = true }

        guard #available(macOS 26.0, iOS 26.0, *) else {
            setStatus("On-device speech requires macOS 26 or iOS 26.")
            isRecording = false
            return
        }

        recordingTask = Task {
            guard SpeechTranscriber.isAvailable else {
                self.setStatus("On-device speech transcription is not available on this device.")
                self.isRecording = false
                return
            }

            let supportedLocales = await SpeechTranscriber.supportedLocales
            guard supportedLocales.contains(where: { $0.identifier.hasPrefix("en") }) else {
                self.setStatus("English speech model is not available. Check Apple Intelligence settings.")
                self.isRecording = false
                return
            }

            do {
                let locale = Locale(identifier: "en-US")

                // Configure offline SpeechTranscriber with volatile results enabled
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: []
                )

                // Ensure fully offline approach
                if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    self.setStatus("Downloading speech model. First time only…")
                    try await downloader.downloadAndInstall()
                }

                let a = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = a

                // Get the format SpeechAnalyzer expects
                guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber]
                ) else {
                    self.setStatus("No compatible audio format. Hardware issue?")
                    self.stopRecording()
                    return
                }

                let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                self.streamContinuation = continuation

                // Listen to results asynchronously
                self.resultsTask = Task.detached {
                    var accumulator = TranscriptAccumulator()
                    do {
                        for try await result in transcriber.results {
                            accumulator.apply(text: String(result.text.characters), isFinal: result.isFinal)
                            let combined = accumulator.combined

                            await MainActor.run {
                                SpeechManager.shared.hasReceivedSpeech = true
                                SpeechManager.shared.transcription = combined
                                SpeechManager.shared.resetSilenceTimer()
                            }
                        }
                    } catch {
                        await MainActor.run {
                            SpeechManager.shared.setStatus("Speech error: \(error.localizedDescription)")
                            SpeechManager.shared.isRecording = false
                        }
                    }
                }

                // Start the analyzer for live input
                try await Task.detached {
                    try await a.start(inputSequence: stream)
                }.value

                // Configure AudioEngine with format conversion
                let inputNode = self.audioEngine.inputNode
                let micFormat = inputNode.outputFormat(forBus: 0)

                // Create the converter once — reusing it across buffers avoids
                // the significant per-buffer overhead of AVAudioConverter allocation.
                let converter = AVAudioConverter(from: micFormat, to: requiredFormat)
                self.audioConverter = converter

                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { @Sendable buffer, _ in
                    guard let converter else { return }
                    let frameCount = AVAudioFrameCount(
                        Double(buffer.frameLength) * requiredFormat.sampleRate / buffer.format.sampleRate
                    )
                    guard let converted = AVAudioPCMBuffer(pcmFormat: requiredFormat, frameCapacity: frameCount) else { return }

                    var error: NSError?
                    converter.convert(to: converted, error: &error) { _, status in
                        status.pointee = .haveData
                        return buffer
                    }

                    if error == nil {
                        continuation.yield(AnalyzerInput(buffer: converted))
                    }
                }

                self.audioEngine.prepare()
                try self.audioEngine.start()

                self.setStatus("Listening…")
                self.isReady = true

            } catch {
                if !Task.isCancelled {
                    self.setStatus("Failed to start: \(error.localizedDescription)")
                    self.stopRecording()
                }
            }
        }
    }
    
    func stopRecording() {
        silenceTimer?.cancel()
        silenceTimer = nil

        // Only snapshot transcription if the recognizer actually produced speech.
        if hasReceivedSpeech, !transcription.isEmpty {
            lastTranscript = transcription
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioConverter = nil

        streamContinuation?.finish()
        streamContinuation = nil

        let localAnalyzer = analyzer
        analyzer = nil

        Task {
            if let a = localAnalyzer {
                try? await a.finalizeAndFinishThroughEndOfInput()
            }
        }

        recordingTask?.cancel()
        resultsTask?.cancel()

        isRecording = false
        isReady = false
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task {
            try? await Task.sleep(for: .seconds(Self.silenceTimeoutSeconds))
            guard !Task.isCancelled, self.isRecording else { return }
            self.stopRecording()
        }
    }

    /// Sets a status message, showing it immediately and asynchronously
    /// personalizing it through the shared Personalizer.
    func setStatus(_ message: String) {
        transcription = message
        Personalizer.shared.personalizeAsync(message) { [weak self] personalized in
            // Only update if we haven't moved on to actual speech
            if self?.hasReceivedSpeech == false {
                self?.transcription = personalized
            }
        }
    }
}
