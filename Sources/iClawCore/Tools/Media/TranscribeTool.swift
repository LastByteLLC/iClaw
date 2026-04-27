import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import AppIntents

/// Transcription tool using on-device SpeechTranscriber (macOS 26+/iOS 26+).
/// No data leaves the device — all recognition runs locally via Apple Intelligence models.
public struct TranscribeTool: CoreTool, Sendable {
    public let name = "Transcribe"
    public let schema = "Transcribe an audio file at the given file path into text."
    public let isInternal = false
    public let category = CategoryEnum.async

    public init() {}

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
            // Validate input looks like a file path
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("/") || trimmed.contains(".") else {
                return ToolIO(text: "Please provide a file path to an audio file (e.g. /path/to/audio.mp3).", status: .error)
            }

            let url = URL(fileURLWithPath: trimmed)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ToolIO(text: "File not found: \(trimmed)", status: .error)
            }

            guard #available(macOS 26.0, iOS 26.0, *) else {
                return ToolIO(text: "On-device transcription requires macOS 26 or iOS 26.", status: .error)
            }

            guard SpeechTranscriber.isAvailable else {
                return ToolIO(text: "On-device speech transcription is not available on this device.", status: .error)
            }

            let supportedLocales = await SpeechTranscriber.supportedLocales
            guard supportedLocales.contains(where: { $0.identifier.hasPrefix("en") }) else {
                return ToolIO(text: "English transcription model is not available.", status: .error)
            }

            let transcribedText = try await transcribeFile(at: url)
            return ToolIO(text: transcribedText, outputWidget: "TranscriptionWidget")
        }
    }

    /// Transcribes an audio file entirely on-device using SpeechTranscriber + SpeechAnalyzer.
    /// Reads the file into PCM buffers, feeds them through the analyzer stream, and
    /// collects the finalized transcript.
    @available(macOS 26.0, iOS 26.0, *)
    private func transcribeFile(at fileURL: URL) async throws -> String {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // Download model if needed (first-time only)
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscribeError.noCompatibleFormat
        }

        // Open the audio file
        let audioFile = try AVAudioFile(forReading: fileURL)
        let fileFormat = audioFile.processingFormat

        // Build an AsyncStream of converted audio buffers from the file
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Read and convert file buffers in a detached task
        Task.detached {
            let converter = AVAudioConverter(from: fileFormat, to: requiredFormat)
            let bufferSize: AVAudioFrameCount = 4096

            while audioFile.framePosition < audioFile.length {
                let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
                guard let readBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else { break }

                do {
                    try audioFile.read(into: readBuffer)
                } catch {
                    break
                }

                if let converter {
                    let outputFrames = AVAudioFrameCount(
                        Double(readBuffer.frameLength) * requiredFormat.sampleRate / fileFormat.sampleRate
                    )
                    guard let converted = AVAudioPCMBuffer(pcmFormat: requiredFormat, frameCapacity: outputFrames) else { break }

                    var convError: NSError?
                    converter.convert(to: converted, error: &convError) { _, status in
                        status.pointee = .haveData
                        return readBuffer
                    }
                    if convError == nil {
                        continuation.yield(AnalyzerInput(buffer: converted))
                    }
                } else {
                    // Formats already match
                    continuation.yield(AnalyzerInput(buffer: readBuffer))
                }
            }
            continuation.finish()
        }

        // Collect results
        let resultTask = Task.detached { () -> String in
            var accumulator = TranscriptAccumulator()
            for try await result in transcriber.results {
                accumulator.apply(text: String(result.text.characters), isFinal: result.isFinal)
            }
            return accumulator.combined
        }

        // Feed the stream to the analyzer
        try await Task.detached {
            try await analyzer.start(inputSequence: stream)
        }.value

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultTask.value
    }

    private enum TranscribeError: Error, LocalizedError {
        case noCompatibleFormat

        var errorDescription: String? {
            "No compatible audio format available for speech transcription."
        }
    }
}

/// AppIntent wrapping TranscribeTool for macOS integration.
public struct TranscribeIntent: AppIntent {
    public static var title: LocalizedStringResource { "Transcribe Audio" }
    public static var description: IntentDescription? { IntentDescription("Transcribes an audio file using the iClaw TranscribeTool.") }

    @Parameter(title: "Audio File Path")
    public var filePath: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = TranscribeTool()
        let result = try await tool.execute(input: filePath, entities: nil)
        return .result(value: result.text)
    }
}
