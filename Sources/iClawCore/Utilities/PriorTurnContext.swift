import Foundation
import NaturalLanguage

/// Structured snapshot of the previous turn's results, used by ToolRouter
/// to detect follow-up references and route accordingly.
///
/// Carries structured data (widget data, entities, ingredients, tool names)
/// and uses NLP-based matching (embedding similarity, entity overlap, anaphora
/// detection) rather than hard-coded phrase lists.
public struct PriorTurnContext: Sendable {

    /// A titled link from a prior result (news article, search result, etc.).
    public struct Reference: Sendable {
        public let title: String
        public let url: String

        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    /// The result of follow-up matching — what was referenced and how to route it.
    public struct FollowUpMatch: Sendable {
        /// A URL to fetch (e.g., a news article link).
        public let url: String?
        /// An entity being referenced from the prior turn (location, person, etc.).
        public let entity: String?
        /// The tool that produced the prior result (for re-routing).
        public let priorToolName: String?
        /// The matched ingredient text for additional context.
        public let matchedIngredient: String?
        /// True when the match was based solely on entity overlap with no other
        /// follow-up signals (anaphora, action verbs, short input, etc.).
        /// The caller should cross-validate against the tool classifier before
        /// committing to a re-route — the input may be a new query that happens
        /// to mention the same entity (e.g., "history of London" after weather in London).
        public let isEntityOnlyMatch: Bool

        public init(url: String? = nil, entity: String? = nil, priorToolName: String? = nil,
                    matchedIngredient: String? = nil, isEntityOnlyMatch: Bool = false) {
            self.url = url
            self.entity = entity
            self.priorToolName = priorToolName
            self.matchedIngredient = matchedIngredient
            self.isEntityOnlyMatch = isEntityOnlyMatch
        }
    }

    // MARK: - Failure State

    /// Why the prior turn failed, if it did. Enables follow-up queries like
    /// "what were you going to do?" to get a meaningful answer instead of
    /// being re-routed to random tools.
    public enum FailureReason: Sendable {
        /// The user declined a consent prompt for the given tool.
        case consentDenied(toolName: String)
        /// A tool threw an error during execution.
        case toolError(toolName: String)
    }

    // MARK: - Stored Context

    /// The tool(s) that ran in the prior turn.
    public let toolNames: [String]

    /// The user's original input from the prior turn.
    public let userInput: String

    /// Entities extracted during the prior turn (from both input and output).
    public let entities: ExtractedEntities?

    /// Raw text ingredients from the prior turn's tool results.
    public let ingredients: [String]

    /// Titled references (URLs with context) extracted from results.
    public let references: [Reference]

    /// Widget type from the prior turn (e.g., "NewsWidget", "WeatherWidget").
    public let widgetType: String?

    /// Structured widget data — type-erased. Consumers cast to the expected type
    /// based on `widgetType` (e.g., `NewsWidgetData`, `WeatherWidgetData`).
    public let widgetData: (any Sendable)?

    /// Why the prior turn failed, if applicable.
    public let failureReason: FailureReason?

    public init(
        toolNames: [String] = [],
        userInput: String = "",
        entities: ExtractedEntities? = nil,
        ingredients: [String] = [],
        references: [Reference] = [],
        widgetType: String? = nil,
        widgetData: (any Sendable)? = nil,
        failureReason: FailureReason? = nil
    ) {
        self.toolNames = toolNames
        self.userInput = userInput
        self.entities = entities
        self.ingredients = ingredients
        self.references = references
        self.widgetType = widgetType
        self.widgetData = widgetData
        self.failureReason = failureReason
    }

    public var isEmpty: Bool {
        toolNames.isEmpty && ingredients.isEmpty && references.isEmpty
    }

    // MARK: - NLP Follow-Up Detection

    /// Determines if the input is a follow-up to this prior turn.
    /// Uses a multi-signal NLP approach:
    /// 1. Anaphora detection (pronouns/demonstratives without referents)
    /// 2. Ordinal references ("the first one", "article #2")
    /// 3. Entity overlap with prior turn
    /// 4. Semantic similarity via NLEmbedding
    ///
    /// - Parameter allowDefault: When `true`, an unspecific default match (prior tool re-route)
    ///   is permitted. Set to `false` when searching deeper in the context stack so that
    ///   vague matches don't prevent reaching a more specific context further back.
    /// - Returns: A `FollowUpMatch` if the input references this context, or nil.
    public func detectFollowUp(input: String, allowDefault: Bool = true) -> FollowUpMatch? {
        guard !isEmpty else { return nil }

        let lower = input.lowercased()

        // Signal 1: Anaphora — pronouns/demonstratives that reference prior context
        let hasAnaphora = Self.containsAnaphora(lower)

        // Signal 2: Action verbs that imply operating on prior content
        let hasActionVerb = Self.containsActionVerb(lower)

        // Signal 2b: Multi-word follow-up phrases ("what about", "how about", etc.)
        let hasFollowUpPhrase = Self.containsFollowUpPhrase(lower)

        // Signal 3: Ordinal reference → specific item
        if let ordinalMatch = matchOrdinal(lower) {
            return ordinalMatch
        }

        // Language-agnostic structural signal: VERY short inputs (≤3 words) after a
        // tool execution are likely follow-ups ("and tomorrow?", "in celsius").
        // Must be conservative — "Netherlands vs Australia" (3 words) is a new query,
        // not a follow-up to "roll a dice". Only treat as follow-up when combined
        // with entity overlap or other signals below.
        let wordCount = input.split(separator: " ").count
        let isVeryShortInput = wordCount <= 3

        // Need at least one follow-up signal to proceed
        guard hasAnaphora || hasActionVerb || hasFollowUpPhrase || isVeryShortInput else {
            // No follow-up signal — check for entity overlap as last resort.
            // Mark as entity-only so the caller can cross-validate against the
            // tool classifier before committing to a re-route.
            if let entityMatch = matchEntityOverlap(input), entityMatch.entity != nil {
                return FollowUpMatch(
                    url: entityMatch.url,
                    entity: entityMatch.entity,
                    priorToolName: entityMatch.priorToolName,
                    matchedIngredient: entityMatch.matchedIngredient,
                    isEntityOnlyMatch: true
                )
            }
            return nil
        }

        // Signal 4: Entity overlap — input mentions an entity from the prior turn
        // Use original case for NER (NLTagger is case-sensitive)
        if let entityMatch = matchEntityOverlap(input) {
            return entityMatch
        }

        // Signal 5: Keyword overlap with references (article titles)
        if let refMatch = matchReferenceByKeywords(lower) {
            return refMatch
        }

        // Signal 6: Semantic similarity via NLEmbedding
        if let embeddingMatch = matchByEmbedding(lower) {
            return embeddingMatch
        }

        // Has follow-up signal but no specific match — default to first reference or prior tool.
        // Only fall through to the default when:
        // 1. The signal is strong (anaphora or follow-up phrase)
        // 2. The caller allows defaults (typically only the last context in the stack, or
        //    the most recent one when not searching a stack)
        guard allowDefault && (hasAnaphora || hasFollowUpPhrase) else { return nil }

        if !references.isEmpty {
            return FollowUpMatch(
                url: references.first?.url,
                entity: nil,
                priorToolName: toolNames.first,
                matchedIngredient: nil
            )
        }

        // No references but has prior tool — re-route to same tool
        if let tool = toolNames.first {
            return FollowUpMatch(url: nil, entity: nil, priorToolName: tool, matchedIngredient: ingredients.first)
        }

        return nil
    }

    // MARK: - Multilingual Lexicon (Phase 7a)

    /// Lazy-loaded lexicon. Falls back to English entries when detected
    /// language isn't present. Loaded once per process.
    private static let lexicon: MultilingualKeywords? = MultilingualKeywords.load("PriorTurnLexicon")

    /// Ordinal keys sorted by index (0..4) for `matchOrdinal`'s iteration.
    private static let ordinalIntents = [
        "ordinals_0", "ordinals_1", "ordinals_2", "ordinals_3", "ordinals_4",
    ]

    // MARK: - Anaphora Detection

    static func containsAnaphora(_ input: String) -> Bool {
        guard let lex = lexicon else { return false }
        let words = input.wordTokens

        // Fast path: any word-exact anaphora hit in the detected language.
        guard lex.containsAnyAsWord(intent: "anaphora", in: input) else { return false }

        // Build language-appropriate lists once per call (caching is inside
        // `MultilingualKeywords`).
        let anaphoricMarkers = Set(lex.keywords(for: "anaphora", in: input).map { $0.lowercased() })
        let contextWords = Set(lex.keywords(for: "anaphora_context", in: input).map { $0.lowercased() })
        let referentialNouns = Set(lex.keywords(for: "referential_nouns", in: input).map { $0.lowercased() })

        for (i, word) in words.enumerated() {
            guard anaphoricMarkers.contains(word) else { continue }

            // "about that", "sobre eso", "concernant ça"
            if i > 0 && contextWords.contains(words[i - 1]) {
                return true
            }
            // "that article", "ese artículo", "cet article"
            if i + 1 < words.count && referentialNouns.contains(words[i + 1]) {
                return true
            }
            // Bare terminal anaphora — any anaphora word at end of input.
            if i == words.count - 1 {
                return true
            }
        }
        return false
    }

    // MARK: - Action Verb Detection

    static func containsActionVerb(_ input: String) -> Bool {
        lexicon?.containsAnyAsWord(intent: "action_verbs", in: input) ?? false
    }

    // MARK: - Follow-Up Phrase Detection

    static func containsFollowUpPhrase(_ input: String) -> Bool {
        // Substring matching here — phrases are multi-word and require it.
        lexicon?.matches(intent: "follow_up_phrases", in: input) ?? false
    }

    func matchOrdinal(_ input: String) -> FollowUpMatch? {
        guard !references.isEmpty else { return nil }
        guard let lex = Self.lexicon else { return nil }

        // Find the best ordinal match — iterate the FULL ordinal list
        // (not bounded by references count) so that "third" still matches
        // when references has only 2 entries; we just don't return the
        // out-of-range index, we return nil so the caller falls through to
        // entity/keyword matching.
        for (index, intentKey) in Self.ordinalIntents.enumerated() {
            if lex.matches(intent: intentKey, in: input) {
                guard index < references.count else { return nil }
                let ref = references[index]
                return FollowUpMatch(
                    url: ref.url,
                    entity: nil,
                    priorToolName: toolNames.first,
                    matchedIngredient: ref.title
                )
            }
        }
        return nil
    }

    // MARK: - Entity Overlap

    private func matchEntityOverlap(_ input: String) -> FollowUpMatch? {
        guard let priorEntities = entities else { return nil }

        let inputNER = InputParsingUtilities.extractNamedEntities(from: input)
        let inputPlaces = Set(inputNER.places.map { $0.lowercased() })
        let inputPeople = Set(inputNER.people.map { $0.lowercased() })
        let inputOrgs = Set(inputNER.orgs.map { $0.lowercased() })

        // Check place overlap
        let priorPlaces = Set(priorEntities.places.map { $0.lowercased() })
        let placeOverlap = inputPlaces.intersection(priorPlaces)
        if let place = placeOverlap.first {
            let matchedRef = references.first { $0.title.lowercased().contains(place) }
            let matchedIngredient = ingredients.first { $0.lowercased().contains(place) }
            return FollowUpMatch(
                url: matchedRef?.url,
                entity: place,
                priorToolName: toolNames.first,
                matchedIngredient: matchedIngredient
            )
        }

        // Check person overlap
        let priorPeople = Set(priorEntities.names.map { $0.lowercased() })
        let personOverlap = inputPeople.intersection(priorPeople)
        if let person = personOverlap.first {
            let matchedRef = references.first { $0.title.lowercased().contains(person) }
            let matchedIngredient = ingredients.first { $0.lowercased().contains(person) }
            return FollowUpMatch(
                url: matchedRef?.url,
                entity: person,
                priorToolName: toolNames.first,
                matchedIngredient: matchedIngredient
            )
        }

        // Check organization overlap
        let priorOrgs = Set(priorEntities.organizations.map { $0.lowercased() })
        let orgOverlap = inputOrgs.intersection(priorOrgs)
        if let org = orgOverlap.first {
            let matchedRef = references.first { $0.title.lowercased().contains(org) }
            let matchedIngredient = ingredients.first { $0.lowercased().contains(org) }
            return FollowUpMatch(
                url: matchedRef?.url,
                entity: org,
                priorToolName: toolNames.first,
                matchedIngredient: matchedIngredient
            )
        }

        return nil
    }

    // MARK: - Keyword Reference Matching

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "in", "on", "at", "to", "for", "is", "are",
        "was", "it", "its", "and", "or", "but", "that", "this", "with", "from",
        "about", "can", "you", "me", "my", "more", "tell", "read", "get",
        "summarize", "summarise", "summary", "fetch", "open", "article", "story",
        "headline", "one",
    ]

    private static func contentWords(from text: String) -> Set<String> {
        Set(text.components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) })
    }

    private func matchReferenceByKeywords(_ input: String) -> FollowUpMatch? {
        guard !references.isEmpty else { return nil }

        let inputWords = Self.contentWords(from: input)
        guard !inputWords.isEmpty else { return nil }

        var bestMatch: (index: Int, score: Int) = (-1, 0)
        for (i, ref) in references.enumerated() {
            let titleWords = Self.contentWords(from: ref.title.lowercased())
            let overlap = inputWords.intersection(titleWords).count
            if overlap > bestMatch.score {
                bestMatch = (i, overlap)
            }
        }

        guard bestMatch.score >= 1 else { return nil }
        let ref = references[bestMatch.index]
        return FollowUpMatch(
            url: ref.url,
            entity: nil,
            priorToolName: toolNames.first,
            matchedIngredient: ref.title
        )
    }

    // MARK: - Embedding Similarity

    private func matchByEmbedding(_ input: String) -> FollowUpMatch? {
        guard let embedding = LocalizedEmbedding.sentenceEmbeddingSync(for: input) else { return nil }

        // Try matching against reference titles
        var bestDistance = Double.greatestFiniteMagnitude
        var bestRef: Reference?
        for ref in references {
            let dist = embedding.distance(between: input, and: ref.title.lowercased())
            if dist < bestDistance {
                bestDistance = dist
                bestRef = ref
            }
        }

        if bestDistance < 1.0, let ref = bestRef {
            return FollowUpMatch(
                url: ref.url,
                entity: nil,
                priorToolName: toolNames.first,
                matchedIngredient: ref.title
            )
        }

        // Try matching against ingredients
        var bestIngredientDist = Double.greatestFiniteMagnitude
        var bestIngredient: String?
        for ingredient in ingredients {
            // Use a compact version for embedding comparison
            let compact = String(ingredient.prefix(200))
            let dist = embedding.distance(between: input, and: compact)
            if dist < bestIngredientDist {
                bestIngredientDist = dist
                bestIngredient = ingredient
            }
        }

        if bestIngredientDist < 0.8, let ingredient = bestIngredient {
            return FollowUpMatch(
                url: nil,
                entity: nil,
                priorToolName: toolNames.first,
                matchedIngredient: ingredient
            )
        }

        return nil
    }

    // MARK: - Slot-Based Follow-Up Detection

    /// Result of slot-based follow-up analysis.
    public enum SlotSignal: Sendable {
        /// Input fills a slot of the prior tool → likely continuation/refinement.
        case continuation(toolName: String, slot: String, value: String)
        /// Input fills a slot belonging to a different tool → likely pivot.
        case pivot(toTool: String, slot: String)
        /// No slot signals detected.
        case indeterminate
    }

    /// Detects whether the input fills a slot of the prior tool (continuation)
    /// or a slot of a different tool (pivot).
    ///
    /// This supplements the NLP-based `detectFollowUp()` with structured
    /// parameter awareness. Short inputs like "London" or "tomorrow" that
    /// fill unfilled slots of the prior tool are strong continuation signals.
    public func detectSlotSignal(input: String, entities: ExtractedEntities?) -> SlotSignal {
        guard let priorToolName = toolNames.first else { return .indeterminate }

        let priorSlots = ToolSlotRegistry.slotsForTool(named: priorToolName)

        // 1. Check if input fills a slot of the prior tool
        for slot in priorSlots {
            if let value = slot.extractor(input, entities) {
                return .continuation(toolName: priorToolName, slot: slot.name, value: value)
            }
        }

        // 2. Check if input fills a slot of a different tool
        //    Only check tools with distinctive slot types (entity, location)
        //    to avoid false positives from generic query slots.
        for (toolName, slots) in ToolSlotRegistry.slots where toolName != priorToolName {
            for slot in slots where slot.type != .query {
                if let _ = slot.extractor(input, entities) {
                    return .pivot(toTool: toolName, slot: slot.name)
                }
            }
        }

        return .indeterminate
    }
}
