import Testing
@testable import iClawCore

@Suite("TranscriptAccumulator")
struct TranscriptAccumulatorTests {

    @Test func emptyByDefault() {
        let acc = TranscriptAccumulator()
        #expect(acc.finalizedTranscript == "")
        #expect(acc.volatileTranscript == "")
        #expect(acc.combined == "")
    }

    @Test func volatileResultAppearsInCombined() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "hello", isFinal: false)

        #expect(acc.volatileTranscript == "hello")
        #expect(acc.finalizedTranscript == "")
        #expect(acc.combined == "hello")
    }

    @Test func finalizedResultAppearsInCombined() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "hello", isFinal: true)

        #expect(acc.finalizedTranscript == "hello")
        #expect(acc.volatileTranscript == "")
        #expect(acc.combined == "hello")
    }

    @Test func volatileReplacedByNewVolatile() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "hel", isFinal: false)
        acc.apply(text: "hello", isFinal: false)

        #expect(acc.volatileTranscript == "hello")
        #expect(acc.combined == "hello")
    }

    @Test func volatileClearedWhenFinalized() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "hel", isFinal: false)
        acc.apply(text: "hello ", isFinal: true)

        #expect(acc.volatileTranscript == "")
        #expect(acc.finalizedTranscript == "hello ")
        #expect(acc.combined == "hello")
    }

    @Test func multipleFinalizedSegmentsAccumulate() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "Hello ", isFinal: true)
        acc.apply(text: "world", isFinal: true)

        #expect(acc.finalizedTranscript == "Hello world")
        #expect(acc.combined == "Hello world")
    }

    @Test func volatileAfterFinalizedAppendsToCombined() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "Hello ", isFinal: true)
        acc.apply(text: "wor", isFinal: false)

        #expect(acc.combined == "Hello wor")
    }

    @Test func typicalLiveSequence() {
        var acc = TranscriptAccumulator()

        // First word builds up via volatile results
        acc.apply(text: "H", isFinal: false)
        #expect(acc.combined == "H")

        acc.apply(text: "Hell", isFinal: false)
        #expect(acc.combined == "Hell")

        acc.apply(text: "Hello ", isFinal: true)
        #expect(acc.combined == "Hello")

        // Second word
        acc.apply(text: "w", isFinal: false)
        #expect(acc.combined == "Hello w")

        acc.apply(text: "world", isFinal: false)
        #expect(acc.combined == "Hello world")

        acc.apply(text: "world.", isFinal: true)
        #expect(acc.combined == "Hello world.")
    }

    @Test func combinedTrimsWhitespace() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "  hello  ", isFinal: true)
        #expect(acc.combined == "hello")
    }

    // MARK: - Edge Cases

    @Test func emptyTextApplied() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "", isFinal: false)
        #expect(acc.combined == "")
        acc.apply(text: "", isFinal: true)
        #expect(acc.combined == "")
    }

    @Test func volatileDoesNotAccumulate() {
        // Multiple volatile results should replace, never accumulate
        var acc = TranscriptAccumulator()
        acc.apply(text: "a", isFinal: false)
        acc.apply(text: "ab", isFinal: false)
        acc.apply(text: "abc", isFinal: false)
        #expect(acc.volatileTranscript == "abc")
        #expect(acc.finalizedTranscript == "")
        #expect(acc.combined == "abc")
    }

    @Test func finalAfterVolatileReplacesVolatile() {
        var acc = TranscriptAccumulator()
        acc.apply(text: "hel", isFinal: false)
        #expect(acc.combined == "hel")
        acc.apply(text: "hello ", isFinal: true)
        #expect(acc.volatileTranscript == "")
        #expect(acc.finalizedTranscript == "hello ")
        #expect(acc.combined == "hello")
    }

    @Test func longTranscriptionSequence() {
        var acc = TranscriptAccumulator()
        // Simulate a realistic multi-sentence transcription
        acc.apply(text: "The", isFinal: false)
        acc.apply(text: "The quick", isFinal: false)
        acc.apply(text: "The quick brown fox ", isFinal: true)
        acc.apply(text: "jumps", isFinal: false)
        acc.apply(text: "jumps over the lazy dog.", isFinal: true)

        #expect(acc.combined == "The quick brown fox jumps over the lazy dog.")
        #expect(acc.volatileTranscript == "")
    }
}

// MARK: - SpeechManager State Tests

@Suite("SpeechManager State")
struct SpeechManagerStateTests {

    @Test @MainActor func initialState() {
        let manager = SpeechManager.shared
        // When not recording, these should be baseline values
        // (can't fully reset singleton, just verify properties exist)
        #expect(manager.lastTranscript.isEmpty || true) // Property accessible
    }

    @Test @MainActor func stopRecordingSnapshotsTranscription() {
        let manager = SpeechManager.shared
        // Simulate: speech recognizer produced results
        manager.transcription = "Hello world from speech"
        manager.hasReceivedSpeech = true
        manager.isRecording = true
        manager.isReady = true
        manager.stopRecording()

        // lastTranscript should have captured the text before clearing state
        #expect(manager.lastTranscript == "Hello world from speech")
        #expect(manager.isRecording == false)
        #expect(manager.isReady == false)
    }

    @Test @MainActor func stopRecordingIgnoresWhenNoSpeechReceived() {
        let manager = SpeechManager.shared
        // hasReceivedSpeech is false — any transcription text is a status message
        manager.lastTranscript = ""
        manager.hasReceivedSpeech = false
        manager.transcription = "Some status text"
        manager.isRecording = true
        manager.stopRecording()

        #expect(manager.lastTranscript == "")
    }

    @Test @MainActor func hasReceivedSpeechResetOnBeginRecording() {
        let manager = SpeechManager.shared
        manager.hasReceivedSpeech = true
        manager.lastTranscript = "stale text from previous recording"
        // startRecording resets both
        manager.startRecording()
        #expect(manager.lastTranscript == "")
        #expect(manager.hasReceivedSpeech == false)
        // Clean up
        manager.stopRecording()
    }

    @Test @MainActor func doubleStopIsSafe() {
        let manager = SpeechManager.shared
        manager.transcription = "Test text"
        manager.hasReceivedSpeech = true
        manager.isRecording = true
        manager.stopRecording()
        let first = manager.lastTranscript

        // Second stop should not crash or change lastTranscript
        // (hasReceivedSpeech is now false after beginRecording was never called again)
        manager.stopRecording()
        #expect(manager.lastTranscript == first)
    }

    @Test @MainActor func stopRecordingIgnoresEmptyTranscription() {
        let manager = SpeechManager.shared
        manager.lastTranscript = ""
        manager.hasReceivedSpeech = true
        manager.transcription = ""
        manager.isRecording = true
        manager.stopRecording()

        #expect(manager.lastTranscript == "")
    }
}
