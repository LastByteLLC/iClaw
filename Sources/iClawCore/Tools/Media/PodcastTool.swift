import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Episode data for the PodcastEpisodesWidget.
public struct PodcastEpisodeItem: Sendable {
    public let title: String
    public let date: String?
    public let duration: String?
    public let episodeUrl: String?
    public let showName: String
    public let artworkUrl: String?

    public init(title: String, date: String? = nil, duration: String? = nil,
                episodeUrl: String? = nil, showName: String, artworkUrl: String? = nil) {
        self.title = title
        self.date = date
        self.duration = duration
        self.episodeUrl = episodeUrl
        self.showName = showName
        self.artworkUrl = artworkUrl
    }
}

/// Widget data for the PodcastEpisodesWidget.
public struct PodcastEpisodesWidgetData: Sendable {
    public let showName: String
    public let episodes: [PodcastEpisodeItem]
    public let artworkUrl: String?

    public init(showName: String, episodes: [PodcastEpisodeItem], artworkUrl: String? = nil) {
        self.showName = showName
        self.episodes = episodes
        self.artworkUrl = artworkUrl
    }
}

/// A podcast show result from search.
public struct PodcastShowItem: Sendable {
    public let name: String
    public let artist: String
    public let genre: String?
    public let episodeCount: Int?
    public let artworkUrl: String?
    public let collectionId: Int
}

/// Widget data for the PodcastSearchWidget.
public struct PodcastSearchWidgetData: Sendable {
    public let query: String
    public let shows: [PodcastShowItem]
}

/// Closure type for injecting a test LLM responder into PodcastTool.
public typealias PodcastLLMResponder = SimpleLLMResponder

/// Structured arguments for LLM-extracted podcast requests.
public struct PodcastArgs: ToolArguments {
    public let intent: String   // "search", "play", "episodes", "describe", "summarize"
    public let query: String
}

/// Podcast tool for searching, describing, playing, and summarizing podcasts via iTunes Search API.
///
/// Design: Uses an LLM call to classify user intent (search/episodes/play/describe/summarize)
/// and extract the query. Falls back to simple keyword detection when no LLM is available.
/// Returns rich data (descriptions, episode counts, genres, durations) so the state blob
/// can carry context for follow-up turns.
public struct PodcastTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Podcast"
    public let schema = "Search and play podcasts: 'search for Lex Friedman', 'play latest episode of The Daily', 'play episode 12345'."
    public let isInternal = false
    public let category = CategoryEnum.online

    private let session: URLSession
    private let llmResponder: PodcastLLMResponder?

    public init(session: URLSession = .shared, llmResponder: PodcastLLMResponder? = nil) {
        self.session = session
        self.llmResponder = llmResponder
    }

    // MARK: - ExtractableCoreTool

    public typealias Args = PodcastArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Podcast", fallback: "{\"intent\":\"search|play|episodes|describe|summarize\",\"query\":\"string\"}"
    )

    public func execute(args: PodcastArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            let query = args.query

            // Correct intent: "latest/recent/newest" signals episodes, not describe/summarize
            let lower = rawInput.lowercased()
            var intent = args.intent
            if (intent == "describe" || intent == "summarize"),
               (lower.contains("latest") || lower.contains("recent") || lower.contains("newest")) {
                intent = "episodes"
            }

            do {
                switch intent {
                case "search": return try await searchShows(query: query)
                case "episodes": return try await listEpisodes(showName: query, entities: entities)
                case "play": return try await playEpisode(query: query, entities: entities)
                case "describe": return try await describeShow(showName: query)
                case "summarize": return try await summarizeEpisode(query: query)
                default: return try await searchShows(query: query)
                }
            } catch {
                return ToolIO(
                    text: "Podcast search failed: \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    // MARK: - Intent

    enum PodcastIntent {
        case search(query: String)
        case episodes(showName: String)
        case play(query: String)
        case describe(showName: String)
        case summarize(query: String)
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let intent = await classifyIntent(input: input)

            do {
                switch intent {
                case .search(let query):
                    return try await searchShows(query: query)
                case .episodes(let showName):
                    return try await listEpisodes(showName: showName)
                case .play(let query):
                    return try await playEpisode(query: query)
                case .describe(let showName):
                    return try await describeShow(showName: showName)
                case .summarize(let query):
                    return try await summarizeEpisode(query: query)
                }
            } catch {
                return ToolIO(
                    text: "Podcast search failed: \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    // MARK: - Intent Classification

    func classifyIntent(input: String) async -> PodcastIntent {
        let cleaned = input
            .replacingOccurrences(of: "#podcast", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // High-confidence keyword pre-check — keywords like "latest",
        // "episodes", "play", "summarize" are unambiguous signals.
        let keywordResult = keywordClassify(input: cleaned)
        if case .search = keywordResult {
            // Ambiguous — fall through to LLM for better classification
        } else {
            return keywordResult
        }

        // LLM classification for ambiguous inputs
        if let intent = await llmClassify(input: cleaned) {
            return intent
        }
        return keywordResult
    }

    private func llmClassify(input: String) async -> PodcastIntent? {
        let prompt = """
        Classify this podcast request. Output ONLY one line in this exact format:
        INTENT: search|episodes|play|describe|summarize QUERY: <the podcast or episode name>

        Rules:
        - "find/search podcasts about X" → INTENT: search QUERY: X
        - "latest episodes of X" / "episodes from X" → INTENT: episodes QUERY: X
        - "play X" / "listen to X" / "put on X" → INTENT: play QUERY: X
        - "what is X about" / "describe X" / "tell me about X" → INTENT: describe QUERY: X
        - "summarize X" / "summary of X" / "what was discussed in X" → INTENT: summarize QUERY: X
        - If no clear intent, default to: INTENT: search QUERY: <best guess>

        CRITICAL: The QUERY must be the EXACT podcast or episode name from the request.
        Preserve possessives and full names. Examples:
        - "latest episodes from Lenny's Podcast" → QUERY: Lenny's Podcast
        - "play The Tim Ferriss Show" → QUERY: The Tim Ferriss Show
        - "summarize the Zootopia episode of Imagineering Story" → QUERY: Zootopia Imagineering Story
        Do NOT paraphrase, shorten, or reword the name.

        Request: \(input)
        """

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(prompt)
            } else {
                response = try await LLMAdapter.shared.generateWithInstructions(
                    prompt: prompt,
                    instructions: makeInstructions {
                        Directive("You classify podcast requests. Output ONLY the intent line, nothing else.")
                    }
                )
            }

            return parseIntentResponse(response)
        } catch {
            Log.tools.debug("LLM classification failed: \(error)")
            return nil
        }
    }

    func parseIntentResponse(_ response: String) -> PodcastIntent? {
        let line = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.uppercased().hasPrefix("INTENT:") else { return nil }

        // Parse "INTENT: search QUERY: something"
        let afterIntent = line.dropFirst("INTENT:".count).trimmingCharacters(in: .whitespaces)

        let intentAndQuery: (String, String)
        if let queryRange = afterIntent.range(of: "QUERY:", options: .caseInsensitive) {
            let intentPart = afterIntent[afterIntent.startIndex..<queryRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let queryPart = afterIntent[queryRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            intentAndQuery = (intentPart.lowercased(), queryPart)
        } else {
            // No QUERY: found — treat entire remainder as query
            let parts = afterIntent.split(maxSplits: 1, whereSeparator: { $0 == " " })
            let intentPart = parts.first.map(String.init) ?? ""
            let queryPart = parts.count > 1 ? String(parts[1]) : ""
            intentAndQuery = (intentPart.lowercased(), queryPart)
        }

        let (intent, query) = intentAndQuery
        let cleanQuery = query.isEmpty ? "podcast" : query

        switch intent {
        case "search": return .search(query: cleanQuery)
        case "episodes": return .episodes(showName: cleanQuery)
        case "play": return .play(query: cleanQuery)
        case "describe": return .describe(showName: cleanQuery)
        case "summarize": return .summarize(query: cleanQuery)
        default: return .search(query: cleanQuery)
        }
    }

    private func keywordClassify(input: String) -> PodcastIntent {
        let lower = input.lowercased()
        let strippedQuery = Self.stripPrefixes(from: lower)

        // Multilingual intent table. Loaded lazily; falls back to English-only
        // matching via the JSON's `en` key when the detected language isn't
        // covered. Replaces the inline English `contains()` cascade.
        let kw = Self.intentKeywords

        if let kw, kw.matches(intent: "play_intent", in: input) {
            return .play(query: strippedQuery)
        }
        // "recency" must be checked BEFORE "describe" so "what's the latest
        // on X?" routes to episodes, not describe.
        if let kw, kw.matches(intent: "recency_intent", in: input) {
            return .episodes(showName: strippedQuery)
        }
        if let kw, kw.matches(intent: "summarize_intent", in: input) {
            return .summarize(query: strippedQuery)
        }
        if let kw, kw.matches(intent: "describe_intent", in: input) {
            return .describe(showName: strippedQuery)
        }
        return .search(query: strippedQuery)
    }

    private static let intentKeywords: MultilingualKeywords? = MultilingualKeywords.load("PodcastIntentKeywords")

    private static let queryPrefixes = [
        "play the latest ", "play latest ", "play ", "listen to ",
        "put on ", "search for ", "search ", "find ",
        "summarize the latest ", "summarize latest ", "summarize ",
        "summary of the latest ", "summary of ",
        "what was discussed in ", "what was discussed on ",
        "describe ", "tell me about ", "what is ", "what's ",
        "latest episodes of ", "latest episodes from ",
        "episodes of ", "episodes from ",
        "newest episodes of ", "recent episodes of ",
    ]

    private static func stripPrefixes(from input: String) -> String {
        for prefix in queryPrefixes {
            if input.hasPrefix(prefix) {
                let remainder = String(input.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty { return remainder }
            }
        }
        // Strip trailing noise
        return input
            .replacingOccurrences(of: " podcast", with: "")
            .replacingOccurrences(of: " episodes", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Search Shows

    private func searchShows(query: String) async throws -> ToolIO {
        // iTunes returns results in popularity order, not relevance. Fetch
        // a wider pool and re-rank by query-term density in title + genre.
        let results = try await fetchSearch(query: query, media: "podcast", limit: 20)

        guard !results.isEmpty else {
            return ToolIO(text: "No podcasts found for '\(query)'.", status: .ok)
        }

        // Score each result: +3 per whole-word term match in the show name,
        // +1 per match in genre or artist. Drop results with score 0 when
        // the top scorer clears threshold 3 (keeps topical focus without
        // returning zero results for fuzzy queries).
        let terms = query.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { $0.count >= 2 && !["the","a","an","of","about","for","on"].contains($0) }

        struct Scored { let data: [String: Any]; let score: Int }
        let scored: [Scored] = results.map { show in
            let name = (show["collectionName"] as? String ?? "").lowercased()
            let genre = (show["primaryGenreName"] as? String ?? "").lowercased()
            let artist = (show["artistName"] as? String ?? "").lowercased()
            var s = 0
            for t in terms where !t.isEmpty {
                if name.range(of: "\\b\(NSRegularExpression.escapedPattern(for: t))\\b", options: .regularExpression) != nil {
                    s += 3
                } else if name.contains(t) {
                    s += 1
                }
                if genre.contains(t) || artist.contains(t) { s += 1 }
            }
            return Scored(data: show, score: s)
        }
        let ranked = scored.sorted { $0.score > $1.score }
        let topScore = ranked.first?.score ?? 0
        let filtered: [[String: Any]]
        if topScore >= 3 {
            filtered = ranked.filter { $0.score >= 1 }.prefix(5).map { $0.data }
        } else {
            // Weak-match mode: trust iTunes popularity, top 5
            filtered = Array(ranked.prefix(5)).map { $0.data }
        }

        var lines: [String] = ["Podcasts matching '\(query)':"]
        var showItems: [PodcastShowItem] = []
        for show in filtered {
            let name = show["collectionName"] as? String ?? "Unknown"
            let artist = show["artistName"] as? String ?? ""
            let episodes = show["trackCount"] as? Int
            let genre = show["primaryGenreName"] as? String
            let artworkUrl = show["artworkUrl100"] as? String
            let collectionId = show["collectionId"] as? Int ?? 0
            var line = "- \(name) by \(artist)"
            if let episodes { line += " (\(episodes) episodes)" }
            if let genre { line += " [\(genre)]" }
            lines.append(line)

            showItems.append(PodcastShowItem(
                name: name, artist: artist, genre: genre,
                episodeCount: episodes, artworkUrl: artworkUrl,
                collectionId: collectionId
            ))
        }

        let widgetData = PodcastSearchWidgetData(query: query, shows: showItems)

        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "PodcastSearchWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - List Episodes

    private func listEpisodes(showName: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        // Fast path: widget provided collectionId via WidgetAction payload
        if let idStr = entities?.widgetPayload?["collectionId"],
           let collectionId = Int(idStr) {
            let resolvedName = entities?.widgetPayload?["showName"] ?? showName
            return try await listEpisodesById(collectionId: collectionId, showName: resolvedName)
        }

        // Slow path: search by name to resolve collectionId
        let shows = try await fetchSearch(query: showName, media: "podcast", limit: 1)
        guard let show = shows.first,
              let collectionId = show["collectionId"] as? Int else {
            return ToolIO(text: "Could not find podcast '\(showName)'.", status: .ok)
        }

        let resolvedName = show["collectionName"] as? String ?? showName
        return try await listEpisodesById(collectionId: collectionId, showName: resolvedName)
    }

    /// Shared episode listing logic used by both fast path (widget payload) and slow path (search).
    private func listEpisodesById(collectionId: Int, showName: String) async throws -> ToolIO {
        let episodes = try await fetchLookup(collectionId: collectionId, limit: 6)

        guard !episodes.isEmpty else {
            return ToolIO(text: "No episodes found for '\(showName)'.", status: .ok)
        }

        // Look up show artwork from the first result's collection info
        let showArtwork = episodes.first?["artworkUrl100"] as? String

        var lines: [String] = ["Recent episodes of \(showName):"]
        var widgetEpisodes: [PodcastEpisodeItem] = []

        for ep in episodes {
            let title = ep["trackName"] as? String ?? "Unknown"
            let date = formatDate(ep["releaseDate"] as? String)
            let duration = formatDuration(ep["trackTimeMillis"] as? Int)
            let epUrl = ep["episodeUrl"] as? String
            let epArtwork = ep["artworkUrl100"] as? String

            var line = "- \(title)"
            if let date { line += " (\(date))" }
            if let duration { line += " [\(duration)]" }
            lines.append(line)

            widgetEpisodes.append(PodcastEpisodeItem(
                title: title, date: date, duration: duration,
                episodeUrl: epUrl, showName: showName,
                artworkUrl: epArtwork
            ))
        }

        let widgetData = PodcastEpisodesWidgetData(
            showName: showName,
            episodes: widgetEpisodes,
            artworkUrl: showArtwork
        )

        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "PodcastEpisodesWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Play Episode

    private func playEpisode(query: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        // Fast path: widget provided direct episode URL via WidgetAction payload
        if let urlStr = entities?.widgetPayload?["episodeUrl"],
           let streamURL = URL(string: urlStr) {
            let title = entities?.widgetPayload?["title"] ?? query
            await MainActor.run {
                PodcastPlayerManager.shared.play(url: streamURL, title: title, show: "", externalURL: nil)
            }
            let widgetData = AudioPlayerWidgetData(id: urlStr, title: title, subtitle: "", duration: 0)
            return ToolIO(
                text: "Now playing \"\(title)\".",
                status: .ok,
                outputWidget: "AudioPlayerWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }

        // Slow path: search by title
        let results = try await fetchSearch(query: query, entity: "podcastEpisode", limit: 1)

        guard let ep = results.first else {
            return ToolIO(text: "No episodes found matching '\(query)'.", status: .ok)
        }

        let title = ep["trackName"] as? String ?? "Unknown"
        let show = ep["collectionName"] as? String ?? ""
        let trackViewUrlString = ep["trackViewUrl"] as? String
        let externalURL = trackViewUrlString.flatMap { URL(string: $0) }
        let durationMs = ep["trackTimeMillis"] as? Int ?? 0

        guard let streamURLString = ep["episodeUrl"] as? String,
              let streamURL = URL(string: streamURLString) else {
            return ToolIO(text: "No playable URL found for '\(title)'.", status: .error)
        }

        await MainActor.run {
            PodcastPlayerManager.shared.play(url: streamURL, title: title, show: show, externalURL: externalURL)
        }

        let widgetData = AudioPlayerWidgetData(
            id: streamURLString,
            title: title,
            subtitle: show,
            duration: Double(durationMs) / 1000.0
        )

        return ToolIO(
            text: "Now playing \"\(title)\" from \(show).",
            status: .ok,
            outputWidget: "AudioPlayerWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Describe Show

    private func describeShow(showName: String) async throws -> ToolIO {
        // Search for the show
        let shows = try await fetchSearch(query: showName, media: "podcast", limit: 1)
        guard let show = shows.first,
              let collectionId = show["collectionId"] as? Int else {
            return ToolIO(text: "Could not find podcast '\(showName)'.", status: .ok)
        }

        let name = show["collectionName"] as? String ?? showName
        let artist = show["artistName"] as? String ?? "Unknown"
        let genre = show["primaryGenreName"] as? String ?? "Unknown"
        let episodeCount = show["trackCount"] as? Int

        // Get recent episodes for richer context
        let episodes = try await fetchLookup(collectionId: collectionId, limit: 3)

        var lines: [String] = [
            "\(name) by \(artist)",
            "Genre: \(genre)",
        ]
        if let episodeCount { lines.append("Episodes: \(episodeCount)") }

        // Get description from the first episode (shows don't have descriptions in search)
        if let firstEp = episodes.first,
           let desc = firstEp["description"] as? String ?? firstEp["shortDescription"] as? String {
            let trimmed = String(desc.prefix(500))
            lines.append("Latest episode: \"\(firstEp["trackName"] as? String ?? "Unknown")\"")
            lines.append("Description: \(trimmed)")
        }

        if episodes.count > 1 {
            lines.append("Other recent episodes:")
            for ep in episodes.dropFirst() {
                let title = ep["trackName"] as? String ?? "Unknown"
                lines.append("- \"\(title)\"")
            }
        }

        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            isVerifiedData: true
        )
    }

    // MARK: - Summarize Episode

    private func summarizeEpisode(query: String) async throws -> ToolIO {
        // Search for the episode
        let results = try await fetchSearch(query: query, entity: "podcastEpisode", limit: 1)

        guard let ep = results.first else {
            return ToolIO(text: "No episodes found matching '\(query)'.", status: .ok)
        }

        let title = ep["trackName"] as? String ?? "Unknown"
        let show = ep["collectionName"] as? String ?? ""

        // Try transcription pipeline: download MP3 → transcribe → summarize
        if let episodeURLString = ep["episodeUrl"] as? String,
           let episodeURL = URL(string: episodeURLString) {
            do {
                let tmpFile = try await downloadAudio(url: episodeURL)
                defer { try? FileManager.default.removeItem(at: tmpFile) }

                let transcript = try await transcribeAudio(at: tmpFile)
                if !transcript.isEmpty {
                    let summary: String
                    if let responder = llmResponder {
                        summary = (try? await responder("Summarize this podcast episode transcript in 2-3 sentences:\n\n\(transcript)")) ?? transcript
                    } else {
                        summary = await SummarizationManager.shared.summarize(text: transcript)
                    }

                    return ToolIO(
                        text: "Episode: \"\(title)\" from \(show)\nSummary: \(summary)",
                        status: .ok,
                        isVerifiedData: true
                    )
                }
            } catch {
                Log.tools.debug("Transcription pipeline failed: \(error). Falling back to description.")
            }
        }

        // Fallback: summarize the episode description from iTunes metadata
        let description = ep["description"] as? String ?? ep["shortDescription"] as? String

        guard let description, !description.isEmpty else {
            return ToolIO(
                text: "No description available for \"\(title)\" from \(show). Episode show notes aren't provided by this podcast.",
                status: .ok
            )
        }

        let summary: String
        if let responder = llmResponder {
            summary = (try? await responder("Summarize this podcast episode description in 2-3 sentences:\n\n\(description)")) ?? description
        } else {
            summary = await SummarizationManager.shared.summarize(text: description)
        }

        return ToolIO(
            text: "Episode: \"\(title)\" from \(show)\nSummary: \(summary)",
            status: .ok,
            isVerifiedData: true
        )
    }

    // MARK: - Audio Download & Transcription

    /// Downloads an audio file to a temporary location via standard HTTP fetch.
    private func downloadAudio(url: URL) async throws -> URL {
        let (tmpURL, response) = try await session.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PodcastError.downloadFailed
        }

        // Move to a stable tmp path with proper extension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        return dest
    }

    /// Transcribes an audio file entirely on-device using SpeechTranscriber + SpeechAnalyzer.
    /// No data leaves the device — all recognition runs locally via Apple Intelligence models.
    private func transcribeAudio(at fileURL: URL) async throws -> String {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw PodcastError.speechUnavailable
        }

        guard SpeechTranscriber.isAvailable else {
            throw PodcastError.speechUnavailable
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier.hasPrefix("en") }) else {
            throw PodcastError.speechUnavailable
        }

        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw PodcastError.speechUnavailable
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let fileFormat = audioFile.processingFormat

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        Task.detached {
            let converter = AVAudioConverter(from: fileFormat, to: requiredFormat)
            let bufferSize: AVAudioFrameCount = 4096

            while audioFile.framePosition < audioFile.length {
                let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
                guard let readBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else { break }
                do { try audioFile.read(into: readBuffer) } catch { break }

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
                    continuation.yield(AnalyzerInput(buffer: readBuffer))
                }
            }
            continuation.finish()
        }

        let resultTask = Task.detached { () -> String in
            var accumulator = TranscriptAccumulator()
            for try await result in transcriber.results {
                accumulator.apply(text: String(result.text.characters), isFinal: result.isFinal)
            }
            return accumulator.combined
        }

        try await Task.detached {
            try await analyzer.start(inputSequence: stream)
        }.value

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultTask.value
    }

    private enum PodcastError: Error, LocalizedError {
        case downloadFailed
        case speechUnavailable

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "Failed to download episode audio"
            case .speechUnavailable: "Speech recognition is not available"
            }
        }
    }

    // MARK: - API Helpers

    private func fetchSearch(query: String, media: String? = nil, entity: String? = nil, limit: Int = 5) async throws -> [[String: Any]] {
        guard let url = APIEndpoints.iTunes.search(term: query, media: media, entity: entity, limit: limit) else { return [] }
        let (data, _) = try await session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }
        return results
    }

    private func fetchLookup(collectionId: Int, limit: Int = 5) async throws -> [[String: Any]] {
        guard let url = APIEndpoints.iTunes.lookup(collectionId: collectionId, entity: "podcastEpisode", limit: limit + 1) else { return [] }

        let (data, _) = try await session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        // First result is the show itself; episodes follow
        return results.filter { ($0["wrapperType"] as? String) == "podcastEpisode" }
    }

    // MARK: - Formatting

    private nonisolated(unsafe) static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func formatDate(_ isoDate: String?) -> String? {
        guard let isoDate else { return nil }
        guard let date = Self.isoDateFormatter.date(from: isoDate) else { return nil }
        return Self.mediumDateFormatter.string(from: date)
    }

    private func formatDuration(_ milliseconds: Int?) -> String? {
        guard let ms = milliseconds, ms > 0 else { return nil }
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
