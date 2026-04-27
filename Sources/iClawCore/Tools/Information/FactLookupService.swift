import Foundation
import os

/// Lightweight fact lookup service that fetches structured data from
/// DuckDuckGo Instant Answers and Wikidata before falling back to web search.
///
/// Returns compact key-value facts ideal for widget generation.
/// No API keys required — both endpoints are public.
public struct FactLookupService: Sendable {

    private let session: URLSession

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    /// Attempts to fetch structured facts for a query.
    /// Returns nil if no structured data is available (caller should fall back to web search).
    public func lookup(query: String) async -> FactResult? {
        // Try DDG Instant Answer first (fastest, most structured)
        if let ddgResult = await fetchDDGInstantAnswer(query: query) {
            return ddgResult
        }

        // Try Wikidata for structured property-value data
        if let wikidata = await fetchWikidataFacts(query: query) {
            return wikidata
        }

        return nil
    }

    // MARK: - DuckDuckGo Instant Answer API

    /// Fetches structured data from DuckDuckGo's Instant Answer API.
    /// Returns abstract text + infobox key-value pairs when available.
    /// Endpoint: https://api.duckduckgo.com/?q=QUERY&format=json&no_html=1
    private func fetchDDGInstantAnswer(query: String) async -> FactResult? {
        guard let url = APIEndpoints.DuckDuckGo.instantAnswer(query: query) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let abstractText = json["AbstractText"] as? String ?? ""
            let heading = json["Heading"] as? String ?? ""
            let abstractSource = json["AbstractSource"] as? String

            // Extract image URL if present (relative path → absolute)
            var imageURL: String?
            if let rawImage = json["Image"] as? String, !rawImage.isEmpty {
                if rawImage.hasPrefix("http") {
                    imageURL = rawImage
                } else {
                    imageURL = "https://duckduckgo.com" + rawImage
                }
            }

            // Parse Infobox if available — structured key-value facts
            var facts: [(key: String, value: String)] = []
            if let infobox = json["Infobox"] as? [String: Any],
               let content = infobox["content"] as? [[String: Any]] {
                for item in content {
                    if let label = item["label"] as? String,
                       let value = item["value"] as? String,
                       !label.isEmpty, !value.isEmpty {
                        facts.append((key: label, value: value))
                    }
                }
            }

            // Also parse RelatedTopics for additional context
            var relatedSnippets: [String] = []
            if let related = json["RelatedTopics"] as? [[String: Any]] {
                for topic in related.prefix(3) {
                    if let text = topic["Text"] as? String, !text.isEmpty {
                        relatedSnippets.append(text)
                    }
                }
            }

            // Need at least an abstract or infobox facts to be useful
            guard !abstractText.isEmpty || !facts.isEmpty else {
                return nil
            }

            Log.tools.debug("DDG Instant Answer: '\(heading)' — \(facts.count) infobox facts, \(abstractText.count) chars abstract")

            return FactResult(
                title: heading,
                abstract: abstractText,
                facts: facts,
                relatedSnippets: relatedSnippets,
                source: abstractSource,
                imageURL: imageURL
            )
        } catch {
            Log.tools.debug("DDG Instant Answer failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Wikidata Structured Facts

    /// Fetches structured property-value data from Wikidata for an entity.
    /// First resolves the entity via search, then fetches key claims.
    private func fetchWikidataFacts(query: String) async -> FactResult? {
        // Step 1: Search for the Wikidata entity
        guard let searchURL = APIEndpoints.Wikidata.searchEntities(query: query) else {
            return nil
        }

        var searchRequest = URLRequest(url: searchURL)
        searchRequest.timeoutInterval = 8

        do {
            let (searchData, _) = try await session.data(for: searchRequest)
            guard let searchJSON = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let results = searchJSON["search"] as? [[String: Any]],
                  let first = results.first,
                  let entityId = first["id"] as? String,
                  let entityLabel = first["label"] as? String else {
                return nil
            }

            let description = first["description"] as? String

            // Step 2: Fetch entity claims (properties)
            guard let claimsURL = APIEndpoints.Wikidata.entityClaims(entityId: entityId) else {
                return nil
            }

            var claimsRequest = URLRequest(url: claimsURL)
            claimsRequest.timeoutInterval = 8

            let (claimsData, _) = try await session.data(for: claimsRequest)
            guard let claimsJSON = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
                  let entities = claimsJSON["entities"] as? [String: Any],
                  let entity = entities[entityId] as? [String: Any],
                  let claims = entity["claims"] as? [String: Any] else {
                return nil
            }

            // Extract commonly useful properties
            let facts = extractWikidataFacts(from: claims)

            guard !facts.isEmpty else {
                return nil
            }

            Log.tools.debug("Wikidata: '\(entityLabel)' — \(facts.count) facts")

            return FactResult(
                title: entityLabel,
                abstract: description ?? "",
                facts: facts,
                relatedSnippets: [],
                source: "Wikidata",
                imageURL: nil
            )
        } catch {
            Log.tools.debug("Wikidata lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Maps well-known Wikidata property IDs to readable labels and extracts their values.
    private func extractWikidataFacts(from claims: [String: Any]) -> [(key: String, value: String)] {
        // Map of Wikidata property IDs to human-readable labels
        let propertyMap: [(id: String, label: String)] = [
            ("P1082", "Population"),
            ("P2131", "GDP (nominal)"),
            ("P2132", "GDP (PPP)"),
            ("P36", "Capital"),
            ("P37", "Official Language"),
            ("P38", "Currency"),
            ("P17", "Country"),
            ("P30", "Continent"),
            ("P2046", "Area"),
            ("P571", "Founded"),
            ("P169", "CEO"),
            ("P112", "Founder"),
            ("P2139", "Revenue"),
            ("P1128", "Employees"),
            ("P159", "Headquarters"),
            ("P856", "Website"),
            ("P569", "Date of Birth"),
            ("P570", "Date of Death"),
            ("P27", "Citizenship"),
            ("P106", "Occupation"),
            ("P166", "Award"),
            ("P2048", "Height"),
            ("P2067", "Mass"),
            ("P2044", "Elevation"),
            ("P1566", "GeoNames ID"),
        ]

        var facts: [(key: String, value: String)] = []

        for prop in propertyMap {
            guard let claimArray = claims[prop.id] as? [[String: Any]],
                  let firstClaim = claimArray.first,
                  let mainsnak = firstClaim["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any] else {
                continue
            }

            if let value = extractWikidataValue(from: datavalue, propertyId: prop.id) {
                facts.append((key: prop.label, value: value))
            }
        }

        return facts
    }

    /// Extracts a human-readable value from a Wikidata datavalue object.
    private func extractWikidataValue(from datavalue: [String: Any], propertyId: String) -> String? {
        let type = datavalue["type"] as? String ?? ""

        switch type {
        case "string":
            return datavalue["value"] as? String

        case "quantity":
            guard let valueObj = datavalue["value"] as? [String: Any],
                  let amount = valueObj["amount"] as? String else { return nil }
            // Strip leading "+" from amounts like "+8336817"
            let cleaned = amount.hasPrefix("+") ? String(amount.dropFirst()) : amount
            return formatLargeNumber(cleaned)

        case "time":
            guard let valueObj = datavalue["value"] as? [String: Any],
                  let time = valueObj["time"] as? String else { return nil }
            // Wikidata time format: "+2024-01-15T00:00:00Z" → "2024-01-15"
            return time
                .replacingOccurrences(of: "+", with: "")
                .components(separatedBy: "T").first

        case "wikibase-entityid":
            // This is a reference to another entity (e.g., a city, language)
            // Would need another API call to resolve — skip for now, return the label if available
            guard let valueObj = datavalue["value"] as? [String: Any] else { return nil }
            // The numeric-id is available but we'd need to resolve it
            // For now, return nil and let the caller fall back
            if let id = valueObj["id"] as? String {
                return "[\(id)]" // Placeholder — resolved in batch below
            }
            return nil

        case "monolingualtext":
            guard let valueObj = datavalue["value"] as? [String: Any],
                  let text = valueObj["text"] as? String else { return nil }
            return text

        default:
            return nil
        }
    }

    /// Formats large numbers with K/M/B suffixes for compact display.
    private func formatLargeNumber(_ str: String) -> String {
        guard let number = Double(str) else { return str }
        switch abs(number) {
        case 1_000_000_000_000...:
            return String(format: "%.2fT", number / 1_000_000_000_000)
        case 1_000_000_000...:
            return String(format: "%.1fB", number / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", number / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", number / 1_000)
        default:
            return str
        }
    }
}

// MARK: - Fact Result

/// Structured fact data returned by FactLookupService.
public struct FactResult: Sendable {
    /// Entity name/title
    public let title: String
    /// Summary text
    public let abstract: String
    /// Structured key-value pairs (e.g., "Population" → "38.9M")
    public let facts: [(key: String, value: String)]
    /// Additional context snippets
    public let relatedSnippets: [String]
    /// Data source attribution
    public let source: String?
    /// Thumbnail image URL (from DDG Instant Answer or Wikipedia)
    public let imageURL: String?

    /// Formats the fact result as compact text suitable for LLM ingredients.
    public func formatted(charLimit: Int = 1500) -> String {
        var parts: [String] = []

        if !title.isEmpty {
            parts.append(title)
        }
        if !abstract.isEmpty {
            parts.append(abstract)
        }
        if !facts.isEmpty {
            let kvText = facts.map { "\($0.key): \($0.value)" }.joined(separator: " | ")
            parts.append(kvText)
        }
        if !relatedSnippets.isEmpty {
            parts.append(relatedSnippets.joined(separator: " "))
        }
        if let source {
            parts.append("(Source: \(source))")
        }

        let combined = parts.joined(separator: "\n")
        return combined.count > charLimit ? String(combined.prefix(charLimit)) + "..." : combined
    }
}
