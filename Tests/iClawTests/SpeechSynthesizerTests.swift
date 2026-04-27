import XCTest
@testable import iClawCore

@MainActor
final class SpeechSynthesizerTests: XCTestCase {

    func testInitialState() {
        let synth = SpeechSynthesizer.shared
        // After stop, state should be clean
        synth.stop()
        XCTAssertNil(synth.speakingMessageID)
        XCTAssertFalse(synth.isPaused)
    }

    func testSpeakSetsMessageID() {
        let synth = SpeechSynthesizer.shared
        let id = UUID()
        synth.speak(text: "Hello world", messageID: id)
        XCTAssertEqual(synth.speakingMessageID, id)
        XCTAssertFalse(synth.isPaused)
        synth.stop()
    }

    func testStopClearsState() {
        let synth = SpeechSynthesizer.shared
        synth.speak(text: "Test", messageID: UUID())
        synth.stop()
        XCTAssertNil(synth.speakingMessageID)
        XCTAssertFalse(synth.isPaused)
    }

    func testToggleSameMessageCallsPauseOrRestarts() {
        let synth = SpeechSynthesizer.shared
        let id = UUID()
        synth.speak(text: "Test speech for toggle", messageID: id)
        XCTAssertEqual(synth.speakingMessageID, id)

        // Toggle on same ID: in a real environment this pauses, in headless CI
        // the synthesizer may have already finished, so toggleForMessage restarts.
        // Either way, the message ID should remain set.
        synth.toggleForMessage(id, text: "Test speech for toggle")
        XCTAssertEqual(synth.speakingMessageID, id, "Should still be tracking the same message")

        synth.stop()
    }

    func testToggleDifferentMessageSwitches() {
        let synth = SpeechSynthesizer.shared
        let id1 = UUID()
        let id2 = UUID()
        synth.speak(text: "First message", messageID: id1)
        XCTAssertEqual(synth.speakingMessageID, id1)

        // Speaking a different message should switch
        synth.toggleForMessage(id2, text: "Second message")
        XCTAssertEqual(synth.speakingMessageID, id2)
        XCTAssertFalse(synth.isPaused)

        synth.stop()
    }

    func testPauseWithoutSpeakingIsNoOp() {
        let synth = SpeechSynthesizer.shared
        synth.stop()
        synth.pause()
        XCTAssertFalse(synth.isPaused)
    }

    func testResumeWithoutPauseIsNoOp() {
        let synth = SpeechSynthesizer.shared
        synth.stop()
        synth.resume()
        XCTAssertFalse(synth.isPaused)
    }
}
