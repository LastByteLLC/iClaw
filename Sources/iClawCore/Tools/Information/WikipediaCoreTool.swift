import Foundation

/// Core tool that deterministically fetches Wikipedia article summaries.
///
/// Unlike the FM WikipediaTool (which the LLM decides whether to call),
/// this Core tool is routed by the ToolRouter and always fetches live data,
/// returning it as verified ingredients for the finalizer.
public struct WikipediaCoreTool: CoreTool, Sendable {
    public let name = "WikipediaSearch"
    public let schema = "Look up facts, people, places, history, science on Wikipedia."
    public let isInternal = false
    public let category = CategoryEnum.online

    private let session: URLSession
    private let factLookup: FactLookupService

    public init(session: URLSession = .iClawDefault) {
        self.session = session
        self.factLookup = FactLookupService(session: session)
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
            let query = extractQuery(from: input, entities: entities)
            guard !query.isEmpty else {
                return ToolIO(
                    text: "Could not determine what to look up on Wikipedia.",
                    status: .error
                )
            }

            // Run Wikipedia search and DDG/Wikidata fact lookup in parallel.
            // If Wikipedia finds nothing, the fact lookup may still have an answer.
            async let wikiTitle = searchTitle(for: query)
            async let factResult = factLookup.lookup(query: query)

            let title = try await wikiTitle
            let facts = await factResult

            // Build facts section if available
            var factsSection = ""
            if let facts, !facts.facts.isEmpty {
                let kvPairs = facts.facts.prefix(8).map { "\($0.key): \($0.value)" }.joined(separator: " | ")
                factsSection = "\n[FACTS] \(kvPairs)"
            }

            if let title {
                // Wikipedia found an article — fetch its extract + thumbnail
                let result = try await fetchExtract(for: title)
                guard let result, !result.text.isEmpty else {
                    // Article found but no content — fall back to facts if available
                    if let facts, !facts.abstract.isEmpty {
                        let thumbnailURL = facts.imageURL
                        let widget = buildWidget(title: facts.title, thumbnailURL: thumbnailURL, description: nil, facts: facts)
                        return ToolIO(
                            text: "[VERIFIED] [\(facts.title)] (DDG/Wikidata)\n\(facts.abstract)\(factsSection)",
                            status: .ok,
                            outputWidget: widget != nil ? "DynamicWidget" : nil,
                            widgetData: widget,
                            isVerifiedData: true
                        )
                    }
                    return ToolIO(
                        text: "Found '\(title)' but could not fetch content.",
                        status: .error
                    )
                }

                let trimmed = result.text.count > 1800 ? String(result.text.prefix(1800)) + "..." : result.text
                // Prefer Wikipedia thumbnail, fall back to DDG image
                let thumbnailURL = result.thumbnailURL ?? facts?.imageURL
                let widget = buildWidget(title: title, thumbnailURL: thumbnailURL, description: result.description, facts: facts)
                let suggestions = buildSuggestions(title: title, facts: facts)
                // Put the article title in-line with the body (not on a
                // metadata line) so the response-cleaner's [VERIFIED]
                // bracket-strip doesn't remove it. The finalizer now sees
                // the noun subject in a position it will preserve.
                return ToolIO(
                    text: "**\(title)** (Wikipedia). \(trimmed)\(factsSection)",
                    status: .ok,
                    outputWidget: widget != nil ? "DynamicWidget" : nil,
                    widgetData: widget,
                    isVerifiedData: true,
                    suggestedQueries: suggestions
                )
            }

            // Wikipedia found nothing — use fact lookup data if available
            if let facts, (!facts.abstract.isEmpty || !facts.facts.isEmpty) {
                var text = "**\(facts.title)**"
                if let source = facts.source { text += " (\(source))" }
                if !facts.abstract.isEmpty { text += ". \(facts.abstract)" }
                text += factsSection
                if !facts.relatedSnippets.isEmpty {
                    text += "\n" + facts.relatedSnippets.prefix(3).joined(separator: " ")
                }
                let widget = buildWidget(title: facts.title, thumbnailURL: facts.imageURL, description: nil, facts: facts)
                return ToolIO(
                    text: text,
                    status: .ok,
                    outputWidget: widget != nil ? "DynamicWidget" : nil,
                    widgetData: widget,
                    isVerifiedData: true
                )
            }

            return ToolIO(
                text: "No Wikipedia article found for '\(query)'.",
                status: .error
            )
        }
    }

    // MARK: - Widget Builder

    /// Builds a DynamicWidgetData with a thumbnail image when available.
    private func buildWidget(title: String, thumbnailURL: String?, description: String?, facts: FactResult?) -> DynamicWidgetData? {
        // Only build a widget if we have a thumbnail
        guard let thumbnailURL else { return nil }

        var builder = DynamicWidgetBuilder(tint: .blue)
        // Use pageterms description (short one-liner like "American actress") directly.
        // DWHeaderView already applies .lineLimit(2) with natural ellipsis.
        builder.header(icon: "book.fill", title: title, subtitle: description)
        builder.image(url: thumbnailURL)

        if let facts, !facts.facts.isEmpty {
            let pairs = facts.facts.prefix(4).map { ($0.key, $0.value) }
            builder.keyValue(pairs)
        }

        return builder.build()
    }

    /// Builds contextual follow-up suggestions from the article title and facts.
    private func buildSuggestions(title: String, facts: FactResult?) -> [String]? {
        var suggestions: [String] = []
        // Add fact-derived suggestions (e.g., "Where was X born?" if birth info exists)
        if let facts {
            let factKeys = Set(facts.facts.map { $0.key.lowercased() })
            if factKeys.contains("born") || factKeys.contains("date of birth") {
                suggestions.append("Where was \(title) born?")
            }
            if factKeys.contains("known for") || factKeys.contains("occupation") {
                suggestions.append("What is \(title) known for?")
            }
        }
        if suggestions.isEmpty {
            suggestions.append("Tell me more about \(title)")
        }
        return suggestions.isEmpty ? nil : Array(suggestions.prefix(3))
    }

    // MARK: - Wikipedia API

    /// Searches Wikipedia's opensearch endpoint and returns the best-matching title.
    private func searchTitle(for query: String) async throws -> String? {
        guard let url = APIEndpoints.Wikipedia.search(query: query) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1,
              let titles = json[1] as? [String],
              let title = titles.first else {
            return nil
        }

        return title
    }

    /// Result from the Wikipedia extract API including optional thumbnail and description.
    private struct ExtractResult {
        let text: String
        let thumbnailURL: String?
        let description: String?
    }

    /// Fetches the introductory extract, thumbnail, and description for a Wikipedia article.
    private func fetchExtract(for title: String) async throws -> ExtractResult? {
        guard let url = APIEndpoints.Wikipedia.extract(title: title) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let pageId = pages.keys.first,
              let page = pages[pageId] as? [String: Any],
              let extract = page["extract"] as? String else {
            return nil
        }

        // Parse thumbnail URL from pageimages prop
        var thumbnailURL: String?
        if let thumbnail = page["thumbnail"] as? [String: Any],
           let source = thumbnail["source"] as? String {
            thumbnailURL = source
        }

        // Parse short description from pageterms prop
        var description: String?
        if let terms = page["terms"] as? [String: Any],
           let descriptions = terms["description"] as? [String],
           let first = descriptions.first {
            description = first
        }

        return ExtractResult(text: extract, thumbnailURL: thumbnailURL, description: description)
    }

    // MARK: - Query Extraction

    /// Extracts a clean search query from the user's input and entities.
    ///
    /// Priority: named entity (person/org/place) > cleaned raw input.
    private func extractQuery(from input: String, entities: ExtractedEntities?) -> String {
        // Prefer entities — these are NER-extracted and usually the precise topic
        if let entities {
            if let name = entities.names.first { return name }
            if let org = entities.organizations.first { return org }
            if let place = entities.places.first { return place }
        }

        // Clean raw input: strip chip prefix, question words, and filler
        var cleaned = input
            .replacingOccurrences(of: "#wiki", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "#wikipedia", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common question prefixes
        cleaned = InputParsingUtilities.stripQuestionPrefix(from: cleaned)

        // Strip trailing question mark and trim
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "?").union(.whitespacesAndNewlines))

        // Strip leading article "the" — "the telephone" → "telephone"
        let cleanedLower = cleaned.lowercased()
        if cleanedLower.hasPrefix("the ") {
            cleaned = String(cleaned.dropFirst(4))
        }

        return cleaned
    }
}
