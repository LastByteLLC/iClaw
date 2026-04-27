import Foundation
import NaturalLanguage
import Vision
import os
#if canImport(AppKit)
import AppKit
#endif

/// ExtractedEntities represents the structured data pulled from raw user input.
public struct ExtractedEntities: Sendable {
    public let names: [String]
    public let places: [String]
    public let organizations: [String]
    public let urls: [URL]
    public let phoneNumbers: [String]
    public let emails: [String]
    public let ocrText: String?
    /// The spell-corrected input, or `nil` if no corrections were made.
    public let correctedInput: String?
    /// The detected language of the input (BCP 47 code, e.g. "en", "fr", "de").
    /// Populated by `NLLanguageRecognizer` on both macOS and iOS.
    /// Used by tools (e.g., CalculatorTool) and OutputFinalizer for language-aware processing.
    public let detectedLanguage: String?
    /// Structured payload from a widget interaction (e.g., podcast collectionId, article URL).
    /// Set when the user taps a widget button that carries a `WidgetAction`.
    /// Tools read this to skip re-parsing and use precise identifiers.
    public let widgetPayload: [String: String]?

    public init(
        names: [String],
        places: [String],
        organizations: [String],
        urls: [URL],
        phoneNumbers: [String],
        emails: [String],
        ocrText: String?,
        correctedInput: String? = nil,
        detectedLanguage: String? = nil,
        widgetPayload: [String: String]? = nil
    ) {
        self.names = names
        self.places = places
        self.organizations = organizations
        self.urls = urls
        self.phoneNumbers = phoneNumbers
        self.emails = emails
        self.ocrText = ocrText
        self.correctedInput = correctedInput
        self.detectedLanguage = detectedLanguage
        self.widgetPayload = widgetPayload
    }
}

/// InputPreprocessor is a Swift 6 actor responsible for analyzing raw user input
/// to extract named entities and data patterns before LLM processing.
public actor InputPreprocessor {
    
    public init() {}

    /// Collapses spaced-out letters into words: "w e a t h e r" → "weather".
    /// Only triggers when 3+ consecutive single-letter tokens are found, preserving
    /// normal text like "I have a pen" where "I" and "a" are real words.
    /// Pre-compiled regex for spaced-letter detection (avoids recompilation every call).
    private static let spacedLettersRegex = try! NSRegularExpression(
        pattern: "(?<=^|\\s)([a-zA-Z] ){2,}[a-zA-Z](?=\\s|$)"
    )

    static func collapseSpacedLetters(_ input: String) -> String {
        let regex = spacedLettersRegex
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var result = input
        // Replace matches from end to start to preserve ranges
        let matches = regex.matches(in: input, range: range)
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let fragment = result[swiftRange]
            let collapsed = fragment.replacingOccurrences(of: " ", with: "")
            result.replaceSubrange(swiftRange, with: collapsed)
        }
        return result
    }

    // MARK: - Spellcheck

    /// Custom dictionary of app-specific words that should never be spell-corrected.
    /// Loaded from `Resources/Config/SpellcheckDictionary.json`.
    private struct SpellcheckDictionaryConfig: Decodable {
        let skipWords: [String]
    }

    private static let customDictionary: Set<String> = {
        guard let config = ConfigLoader.load("SpellcheckDictionary", as: SpellcheckDictionaryConfig.self) else { return [] }
        return Set(config.skipWords.map { $0.lowercased() })
    }()

    /// Common English words set loaded from `Resources/Config/CommonWords.json`.
    /// Spell corrections are only accepted when the suggestion is in this set,
    /// preventing brand-name overcorrections like "Rivian" → "Vivian".
    private struct CommonWordsConfig: Decodable {
        let words: [String]
    }

    private static let commonWords: Set<String> = {
        guard let config = ConfigLoader.load("CommonWords", as: CommonWordsConfig.self) else { return [] }
        return Set(config.words.map { $0.lowercased() })
    }()

    /// Cached NSDataDetector for link + phone number extraction (immutable, thread-safe).
    private static let linkPhoneDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType([.link, .phoneNumber]).rawValue)

    /// Corrects high-confidence spelling mistakes in the input.
    /// Skips chips (#weather), tickers ($AAPL), URLs, numbers, short words, NER proper nouns,
    /// and words in the custom dictionary (SpellcheckDictionary.json).
    ///
    /// Multi-signal guard prevents brand-name overcorrections:
    /// 1. **Capitalization heuristic** — mid-sentence uppercase signals a proper noun.
    /// 2. **NER adjacency** — words within ±1 position of an NER entity are protected.
    /// 3. **Common word filter** — corrections must land on a common English word.
    static func spellCorrect(_ input: String, nerNames: Set<String> = []) -> (corrected: String, didCorrect: Bool) {
        #if os(macOS)
        let checker = NSSpellChecker.shared

        // Detect language
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(input)
        let lang = recognizer.dominantLanguage?.rawValue ?? "en"
        checker.setLanguage(lang)

        let words = input.components(separatedBy: .whitespacesAndNewlines)
        var result = input
        var didCorrect = false

        // Build set of protected indices: NER-identified words and their ±1 neighbors
        var protectedIndices = Set<Int>()
        for (index, word) in words.enumerated() {
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)
            if nerNames.contains(word) || nerNames.contains(stripped) {
                protectedIndices.insert(max(0, index - 1))
                protectedIndices.insert(index)
                if index + 1 < words.count {
                    protectedIndices.insert(index + 1)
                }
            }
        }

        for (index, word) in words.enumerated().reversed() {
            // Strip trailing punctuation for matching but preserve it in the result
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)

            // Skip list
            if stripped.count < 3 { continue }
            if word.hasPrefix("#") || word.hasPrefix("$") { continue }
            if word.contains("@") { continue }
            if stripped.rangeOfCharacter(from: .decimalDigits) != nil { continue }
            if word.hasPrefix("http://") || word.hasPrefix("https://") { continue }
            if nerNames.contains(word) || nerNames.contains(stripped) { continue }
            if customDictionary.contains(stripped.lowercased()) { continue }

            // Guard 1: Capitalization heuristic — mid-sentence uppercase signals proper noun
            if index > 0, let first = stripped.first, first.isUppercase { continue }

            // Guard 2: NER adjacency — skip words near NER-identified entities
            if protectedIndices.contains(index) { continue }

            let wordCountPtr: UnsafeMutablePointer<Int>? = nil
            let misspelledRange = checker.checkSpelling(of: stripped, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: wordCountPtr)
            let range = NSRange(location: 0, length: (stripped as NSString).length)

            if misspelledRange.location != NSNotFound {
                var guesses = checker.guesses(forWordRange: range, in: stripped, language: lang, inSpellDocumentWithTag: 0) ?? []

                // Supplement: check adjacent-char transpositions that produce common words.
                // NSSpellChecker sometimes omits these (e.g., "teh" → "the").
                let strippedLower = stripped.lowercased()
                let chars = Array(strippedLower)
                for i in 0..<(chars.count - 1) {
                    var swapped = chars
                    swapped.swapAt(i, i + 1)
                    let candidate = String(swapped)
                    if commonWords.contains(candidate) && !guesses.map({ $0.lowercased() }).contains(candidate) {
                        guesses.insert(candidate, at: 0)
                    }
                }

                let candidates = guesses.prefix(10).enumerated().compactMap { idx, guess -> (word: String, dist: Int, prefixLen: Int, rank: Int)? in
                    let guessLower = guess.lowercased()
                    var dist = editDistance(strippedLower, guessLower)
                    // Transpositions are Levenshtein distance 2 but should count as 1
                    if dist == 2 && Self.isTransposition(strippedLower, guessLower) { dist = 1 }
                    guard dist <= 2 else { return nil }
                    guard commonWords.contains(guessLower) else { return nil }
                    let prefixLen = zip(strippedLower, guessLower).prefix(while: { $0 == $1 }).count
                    return (word: guess, dist: dist, prefixLen: prefixLen, rank: idx)
                }
                // Best candidate: shortest edit distance first.
                // Tiebreakers for equal edit distance:
                // 1. Transposition match: candidate differs by swapping two adjacent chars
                //    (e.g., "teh"→"the" is a swap of e↔h). Strong signal.
                // 2. Truncation match: misspelled word is a prefix of candidate
                //    (e.g., "quot"→"quote"). Strong signal.
                // 3. Fall back to NSSpellChecker's frequency-based ranking.
                if let best = candidates.min(by: { a, b in
                    if a.dist != b.dist { return a.dist < b.dist }
                    let aIsTransposition = Self.isTransposition(strippedLower, a.word.lowercased())
                    let bIsTransposition = Self.isTransposition(strippedLower, b.word.lowercased())
                    if aIsTransposition != bIsTransposition { return aIsTransposition }
                    let aIsTruncation = a.word.lowercased().hasPrefix(strippedLower)
                    let bIsTruncation = b.word.lowercased().hasPrefix(strippedLower)
                    if aIsTruncation != bIsTruncation { return aIsTruncation }
                    return a.rank < b.rank
                }) {
                    if let wordRange = result.range(of: stripped) {
                        result.replaceSubrange(wordRange, with: best.word)
                        didCorrect = true
                    }
                }
            }
        }

        return (corrected: result, didCorrect: didCorrect)
        #else
        return (corrected: input, didCorrect: false)
        #endif
    }

    /// Returns true if `b` can be produced from `a` by swapping exactly one pair of adjacent characters.
    private static func isTransposition(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        let ac = Array(a), bc = Array(b)
        var diffCount = 0
        var firstDiff = -1
        for i in ac.indices {
            if ac[i] != bc[i] {
                diffCount += 1
                if firstDiff == -1 { firstDiff = i }
            }
        }
        guard diffCount == 2, firstDiff + 1 < ac.count else { return false }
        return ac[firstDiff] == bc[firstDiff + 1] && ac[firstDiff + 1] == bc[firstDiff]
    }

    /// Simple Levenshtein edit distance.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }

    /// Extracts named entities, data patterns, and OCR text from raw user input.
    public func extractEntities(input: String) async -> ExtractedEntities {
        // Normalize spaced-out letters before NER
        let normalizedInput = Self.collapseSpacedLetters(input)

        // Use shared NER utility
        let ner = InputParsingUtilities.extractNamedEntities(from: normalizedInput)

        // Spellcheck after NER so we can skip proper nouns
        let nerNames = Set(ner.people + ner.places + ner.orgs)
        let spellResult = Self.spellCorrect(normalizedInput, nerNames: nerNames)

        // NSDataDetector for URLs, emails, and phone numbers (cached — thread-safe and immutable)
        let matches = Self.linkPhoneDetector?.matches(in: input, options: [], range: NSRange(input.startIndex..<input.endIndex, in: input)) ?? []

        var urls: [URL] = []
        var phoneNumbers: [String] = []
        var emails: [String] = []

        for match in matches {
            if match.resultType == .link, let url = match.url {
                if url.scheme == "mailto" {
                    emails.append(url.absoluteString.replacingOccurrences(of: "mailto:", with: ""))
                } else {
                    urls.append(url)
                }
            } else if match.resultType == .phoneNumber, let phoneNumber = match.phoneNumber {
                phoneNumbers.append(phoneNumber)
            }
        }

        // OCR processing
        let ocrText = await performOCR(input: input)

        // Detect input language (works on both macOS and iOS via NaturalLanguage framework).
        // Used by CalculatorTool for language-aware math normalization and by
        // OutputFinalizer to hint the LLM about the user's language.
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(normalizedInput)
        let trimmedForLang = normalizedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // NLLanguageRecognizer is unreliable on short inputs (e.g., "$AAPL" → Portuguese,
        // "quote of the day" → Indonesian). Require ≥25 characters AND ≥0.7 confidence.
        let detectedLang: String? = {
            guard trimmedForLang.count >= 25 else { return nil }
            let hypotheses = languageRecognizer.languageHypotheses(withMaximum: 1)
            guard let (topLang, confidence) = hypotheses.first,
                  confidence >= 0.7 else {
                return nil
            }
            return topLang.rawValue
        }()

        return ExtractedEntities(
            names: Array(Set(ner.people)),
            places: Array(Set(ner.places)),
            organizations: Array(Set(ner.orgs)),
            urls: Array(Set(urls)),
            phoneNumbers: Array(Set(phoneNumbers)),
            emails: Array(Set(emails)),
            ocrText: ocrText,
            correctedInput: spellResult.didCorrect ? spellResult.corrected : nil,
            detectedLanguage: detectedLang
        )
    }
    
    /// Uses Vision framework to extract text from image files found in the input.
    private func performOCR(input: String) async -> String? {
        let words = input.components(separatedBy: .whitespacesAndNewlines)
        
        for word in words {
            // Remove possible quotes
            let cleanedPath = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let url = URL(fileURLWithPath: cleanedPath)
            
            // Check if file exists and has an image extension
            let imageExtensions = ["png", "jpg", "jpeg", "heic", "tiff"]
            if imageExtensions.contains(url.pathExtension.lowercased()),
               FileManager.default.fileExists(atPath: url.path) {
                
                return await withCheckedContinuation { continuation in
                    let didResume = OSAllocatedUnfairLock(initialState: false)
                    let request = VNRecognizeTextRequest { request, error in
                        guard !didResume.withLock({ let v = $0; $0 = true; return v }) else { return }
                        guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        continuation.resume(returning: text.isEmpty ? nil : text)
                    }
                    request.recognitionLevel = .accurate

                    let handler = VNImageRequestHandler(url: url, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        guard !didResume.withLock({ let v = $0; $0 = true; return v }) else { return }
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return nil
    }
}
