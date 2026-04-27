import Foundation
import AVFoundation

/// On-device text-to-speech wrapper using AVSpeechSynthesizer.
/// Observable so SwiftUI views can react to speaking state changes.
@MainActor
public final class SpeechSynthesizer: NSObject, ObservableObject {
    public static let shared = SpeechSynthesizer()

    @Published public var speakingMessageID: UUID?
    @Published public var isPaused: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var delegateWrapper: SynthesizerDelegate?

    private override init() {
        super.init()
        delegateWrapper = SynthesizerDelegate(owner: self)
        synthesizer.delegate = delegateWrapper
    }

    /// Returns the voice matching the user's stored preference, falling back to system default.
    private func selectedVoice() -> AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: AppConfig.ttsVoiceIdentifierKey) ?? ""
        if !id.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
    }

    public func speak(text: String, messageID: UUID) {
        // Stop any current speech first
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let plainText = MarkdownStripper.plainText(from: text)
        let utterance = AVSpeechUtterance(string: plainText)
        utterance.voice = selectedVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        speakingMessageID = messageID
        isPaused = false
        synthesizer.speak(utterance)
    }

    public func pause() {
        guard synthesizer.isSpeaking, !isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    public func resume() {
        guard isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingMessageID = nil
        isPaused = false
    }

    /// Toggle speech for a specific message. If already speaking this message, pause/resume.
    /// If speaking a different message, stop and start the new one.
    public func toggleForMessage(_ messageID: UUID, text: String) {
        if speakingMessageID == messageID {
            if isPaused {
                resume()
            } else {
                pause()
            }
        } else {
            speak(text: text, messageID: messageID)
        }
    }

    /// Lists available voices for the current locale language, sorted by quality (best first) then name.
    public static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
    }

    fileprivate func didFinishSpeaking() {
        speakingMessageID = nil
        isPaused = false
    }
}

// MARK: - AVSpeechSynthesizerDelegate (nonisolated wrapper for Swift 6.2 concurrency)

private final class SynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    private let owner: SpeechSynthesizer

    init(owner: SpeechSynthesizer) {
        self.owner = owner
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            owner.didFinishSpeaking()
        }
    }
}
