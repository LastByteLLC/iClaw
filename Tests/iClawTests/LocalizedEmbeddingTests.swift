import XCTest
import NaturalLanguage
@testable import iClawCore

final class LocalizedEmbeddingTests: XCTestCase {

    // MARK: - English baseline

    func testEnglishSentenceEmbeddingLoads() async {
        let loaded = await LocalizedEmbedding.shared.sentence(for: .english)
        XCTAssertNotNil(loaded, "English sentence embedding must always load")
        XCTAssertEqual(loaded?.languageUsed, .english)
        XCTAssertFalse(loaded?.isFallback ?? true, "English shouldn't be a fallback case")
    }

    func testEnglishWordEmbeddingLoads() async {
        let loaded = await LocalizedEmbedding.shared.word(for: .english)
        XCTAssertNotNil(loaded, "English word embedding must always load")
    }

    // MARK: - Supported non-English languages

    /// NLEmbedding on macOS 26 supports several non-English languages; this
    /// test just confirms the helper ROUTES them correctly. If Apple drops
    /// support for a language, the helper should transparently fall back to
    /// English rather than crash.
    func testSpanishSentenceEmbeddingReturnsLoaded() async {
        let loaded = await LocalizedEmbedding.shared.sentence(for: .spanish)
        XCTAssertNotNil(loaded, "Spanish should load directly or via English fallback")
    }

    func testFrenchSentenceEmbeddingReturnsLoaded() async {
        let loaded = await LocalizedEmbedding.shared.sentence(for: .french)
        XCTAssertNotNil(loaded)
    }

    // MARK: - Unsupported language → fallback to English

    /// Esperanto isn't supported by NLEmbedding on macOS 26. The helper must
    /// return a Loaded with `languageUsed == .english` and `isFallback == true`.
    func testUnsupportedLanguageFallsBackToEnglish() async {
        let esperanto = NLLanguage(rawValue: "eo")
        let loaded = await LocalizedEmbedding.shared.sentence(for: esperanto)
        XCTAssertNotNil(loaded, "Fallback to English must succeed")
        XCTAssertEqual(loaded?.languageUsed, .english)
        XCTAssertEqual(loaded?.requestedLanguage, esperanto)
        XCTAssertTrue(loaded?.isFallback ?? false)
    }

    // MARK: - Caching

    func testRepeatedCallsReuseCachedModel() async {
        // Two consecutive calls should return "same" embedding (actor makes
        // literal identity hard to assert; we check performance as a proxy).
        let t0 = ContinuousClock.now
        _ = await LocalizedEmbedding.shared.sentence(for: .english)
        _ = await LocalizedEmbedding.shared.sentence(for: .english)
        _ = await LocalizedEmbedding.shared.sentence(for: .english)
        let elapsed = t0.duration(to: .now)
        // Three cached lookups on an actor should total under ~500ms even
        // including a cold load on the first call. No hard assert — if this
        // ever gets into multi-second territory it's regression signal.
        let ms = elapsed.components.seconds * 1000
        XCTAssertLessThan(ms, 10_000, "3 lookups shouldn't exceed 10s; got \(ms)ms")
    }

    // MARK: - Detection

    func testDetectLanguageEnglish() {
        let lang = LocalizedEmbedding.detectLanguage(from: "The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(lang, .english)
    }

    func testDetectLanguageSpanish() {
        let lang = LocalizedEmbedding.detectLanguage(from: "El rápido zorro marrón salta sobre el perro perezoso.")
        XCTAssertEqual(lang, .spanish)
    }

    func testDetectLanguageReturnsNilOnVeryShortInput() {
        XCTAssertNil(LocalizedEmbedding.detectLanguage(from: "hi"))
        XCTAssertNil(LocalizedEmbedding.detectLanguage(from: ""))
    }

    func testDetectLanguageFailsSoftOnGibberish() {
        // Gibberish — confidence should be low. A high minConfidence threshold
        // should reject it. (The helper's default 0.5 may or may not — we
        // test with 0.9 to be strict.)
        let lang = LocalizedEmbedding.detectLanguage(
            from: "xqz kpl mnb vcx zqw", minConfidence: 0.9
        )
        XCTAssertNil(lang)
    }

    // MARK: - Sentence-from-text convenience

    func testSentenceFromDetectedEnglishText() async {
        let loaded = await LocalizedEmbedding.shared.sentence(
            detectedFrom: "The quick brown fox jumps over the lazy dog."
        )
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.requestedLanguage, .english)
    }

    // MARK: - System language helper

    func testSystemLanguageReturnsSomething() {
        let lang = LocalizedEmbedding.systemLanguage()
        // System language varies per CI runner; we just confirm it returns
        // *something* and the getter doesn't crash.
        XCTAssertFalse(lang.rawValue.isEmpty)
    }
}
