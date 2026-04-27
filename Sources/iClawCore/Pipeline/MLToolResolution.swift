import CoreML
import Foundation
import NaturalLanguage

// MARK: - ML Classification Helpers

extension ToolRouter {

    /// Uses the trained CoreML MaxEnt text classifier for tool routing.
    /// Falls back to NLEmbedding similarity if the ML model isn't available.
    func classifyWithML(input: String) async -> [(label: String, confidence: Double)] {
        let classifier = MLToolClassifier.shared
        await classifier.loadModel()

        if let prediction = await classifier.predict(text: input) {
            let results = prediction.confidence.map { (label: $0.key, confidence: $0.value) }
                .sorted { $0.confidence > $1.confidence }
            if !results.isEmpty {
                return results
            }
        }

        return classifyWithEmbedding(input: input)
    }

    /// Original NLEmbedding-based similarity scoring, used as fallback.
    /// Note: deliberately English — tool names and `schema` strings are
    /// English by construction, so comparing with the English word
    /// embedding is what makes this path meaningful. A cross-lingual
    /// embedding would require both sides to live in the same vector space,
    /// which `NLEmbedding` doesn't provide. This is a rare case where
    /// "English by design" is correct rather than an audit finding.
    /// Short 3-char tokens worth considering in schema-token overlap.
    /// Structural math vocabulary — not English prose words.
    private static let shortSignalTokens: Set<String> = [
        "gcd", "lcm", "sum", "log", "exp", "sin", "cos", "tan", "new"
    ]

    /// Gate-level promotion signal: returns a tool name if the input's
    /// distinctive tokens overlap strongly with any tool's `schema`. Used
    /// when the structural gate short-circuits to conversational/clarification
    /// but the input contains tool-vocabulary signals the classifier missed.
    /// Thresholds: ≥2 distinctive tokens in common, OR ≥1 distinctive token
    /// with NO better-scoring competitor. No English word lists — just
    /// compares the input to each tool's declared `schema` metadata.
    /// Variant that returns both the winning tool name and its overlap
    /// score, so callers can make strength-sensitive decisions (override
    /// tier). Returns `(nil, 0)` when no viable candidate exists.
    func schemaTokenOverlapPromoteWithScore(input: String) -> (String?, Int) {
        let normalized = expandSynonyms(input: input)
        let lower = normalized.lowercased()
        var inputTokens = Set(
            lower.components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
        for tok in lower.components(separatedBy: .alphanumerics.inverted)
            where tok.count == 3 && Self.shortSignalTokens.contains(tok) {
            inputTokens.insert(tok)
        }
        guard !inputTokens.isEmpty else { return (nil, 0) }
        var scored: [(name: String, overlap: Int)] = []
        for tool in availableTools {
            let schemaTokens = Set(
                tool.schema.lowercased()
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )
            let overlap = inputTokens.intersection(schemaTokens).count
            if overlap > 0 { scored.append((tool.name, overlap)) }
        }
        for tool in fmTools {
            let kw = tool.routingKeywords.joined(separator: " ").lowercased()
            let schemaTokens = Set(
                kw.components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )
            let overlap = inputTokens.intersection(schemaTokens).count
            if overlap > 0 { scored.append((tool.name, overlap)) }
        }
        guard !scored.isEmpty else { return (nil, 0) }
        scored.sort { $0.overlap > $1.overlap }
        let top = scored[0]
        let second = scored.dropFirst().first?.overlap ?? 0
        if top.overlap >= 2 { return (top.name, top.overlap) }
        if top.overlap == 1 && second == 0 { return (top.name, top.overlap) }
        return (nil, 0)
    }

    func schemaTokenOverlapPromote(input: String) -> String? {
        // Expand synonyms first so "my notes" → "notes search list", "coin flip"
        // → "random coin flip", "times" → known math verb, etc. Gives the
        // schema-token matcher signals the raw input lacks.
        let normalized = expandSynonyms(input: input)

        // Token filter: length ≥ 4 eliminates most stopwords in any language
        // without maintaining a hand-curated list. Catches "define",
        // "synonyms", "etymology", "weather", "calendar" while skipping "the",
        // "and", "for", "is", etc. No English-specific vocabulary in code.
        // Also accept 3-char high-signal tokens (all-uppercase in original
        // like ticker symbols AAPL; numeric tokens; specific verbs the
        // schemas list).
        let lower = normalized.lowercased()
        var inputTokens = Set(
            lower.components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
        // Short high-signal tokens (3 chars) worth including when they match
        // likely tool vocab: "gcd", "lcm", "sum", "new", "old". Filtered by
        // an explicit vocabulary set so we don't accidentally match "the".
        for tok in lower.components(separatedBy: .alphanumerics.inverted)
            where tok.count == 3 && Self.shortSignalTokens.contains(tok) {
            inputTokens.insert(tok)
        }
        guard inputTokens.count >= 1 else { return nil }

        var scored: [(name: String, overlap: Int)] = []
        for tool in availableTools {
            let schemaTokens = Set(
                tool.schema.lowercased()
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )
            let overlap = inputTokens.intersection(schemaTokens).count
            if overlap > 0 { scored.append((tool.name, overlap)) }
        }
        for tool in fmTools {
            let kw = tool.routingKeywords.joined(separator: " ").lowercased()
            let schemaTokens = Set(
                kw.components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            )
            let overlap = inputTokens.intersection(schemaTokens).count
            if overlap > 0 { scored.append((tool.name, overlap)) }
        }

        guard !scored.isEmpty else { return nil }
        scored.sort { $0.overlap > $1.overlap }
        let top = scored[0]
        let second = scored.dropFirst().first?.overlap ?? 0
        // Accept if 2+ overlap tokens (strong), or single overlap with clear lead.
        if top.overlap >= 2 { return top.name }
        if top.overlap == 1 && second == 0 { return top.name }
        return nil
    }

    func classifyWithEmbedding(input: String) -> [(label: String, confidence: Double)] {
        // Detect the input's dominant language; Apple provides sentence
        // embeddings for a subset of languages. If a matching embedding
        // exists, use it — otherwise fall back to English. Input-side
        // embeddings rarely exist for non-Latin scripts, so we also run the
        // English embedding against a pre-translated form when available.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(input)
        let detected = recognizer.dominantLanguage
        let candidateLanguages: [NLLanguage] = {
            var langs: [NLLanguage] = []
            if let d = detected, d != .english { langs.append(d) }
            langs.append(.english)
            return langs
        }()

        // Pick the first language for which a sentence embedding is available.
        var sentenceEmbedding: NLEmbedding?
        var chosenLang: NLLanguage = .english
        for lang in candidateLanguages {
            if let emb = NLEmbedding.sentenceEmbedding(for: lang) {
                sentenceEmbedding = emb
                chosenLang = lang
                break
            }
        }
        guard let sentence = sentenceEmbedding else { return [("none", 0.0)] }
        _ = chosenLang

        let inputLower = input.lowercased()

        let coreResults = availableTools.map { tool -> (label: String, confidence: Double) in
            let distance = sentence.distance(between: inputLower, and: tool.schema.lowercased())
            let confidence = max(0.0, 1.0 - (distance / 2.0))
            return (tool.name, confidence)
        }

        let fmResults = fmTools.map { tool -> (label: String, confidence: Double) in
            let combinedKeywords = tool.routingKeywords.joined(separator: " ")
            let distance = sentence.distance(between: inputLower, and: combinedKeywords.lowercased())
            let confidence = max(0.0, 1.0 - (distance / 2.0))
            return (tool.name, confidence)
        }

        let allResults = coreResults + fmResults
        return allResults.isEmpty ? [("none", 0.0)] : allResults.sorted { $0.confidence > $1.confidence }
    }

    /// Evaluates the results from the ML classifier against AppConfig thresholds.
    /// Uses LabelRegistry for label→tool lookup with domain-level fallback disambiguation.
    func evaluateMLResults(_ results: [(label: String, confidence: Double)], input: String = "") -> RoutingResult? {
        // Filter out suppressed tools (from ingredient validation re-routing)
        let filteredResults: [(label: String, confidence: Double)]
        if !currentSuppressedTools.isEmpty {
            filteredResults = results.filter { result in
                guard let entry = LabelRegistry.lookup(result.label) else { return true }
                return !currentSuppressedTools.contains(entry.tool)
            }
        } else {
            filteredResults = results
        }

        // RouterFeedback adjustment: downweight tools that failed on a
        // semantically similar input earlier this session. Penalty lives in
        // [-0.20, 0]; large enough to break narrow-margin ties, small enough
        // to not flip a clear high-confidence decision.
        let adjusted: [(label: String, confidence: Double)] = filteredResults.map { result in
            let tool = LabelRegistry.lookup(result.label)?.tool ?? result.label
            let delta = RouterFeedback.shared.scoreAdjustment(for: tool, input: input)
            return (label: result.label, confidence: max(0, result.confidence + delta))
        }

        let sortedResults = adjusted.sorted { $0.confidence > $1.confidence }
        guard let topResult = sortedResults.first, topResult.label != "none" else {
            return nil
        }

        if topResult.confidence < AppConfig.mlMinimumConfidenceThreshold {
            // CoreML is unsure — try schema-token overlap as a rescue.
            // Deterministic, language-structured signal that works better than
            // sentence embedding for short tool queries.
            if let promoted = schemaTokenOverlapPromote(input: input) {
                Log.router.debug("CoreML low-confidence (\(String(format: "%.2f", topResult.confidence))) — schema-token rescue → \(promoted)")
                return resolveToolByNameAny(promoted)
            }
            return nil
        }

        // Override: CoreML sometimes picks a confidently wrong tool when a
        // different tool has STRONGER schema-token evidence. Two override
        // tiers based on schema-overlap strength:
        //   (1) top overlap ≥ 3 — strong structural signal, override even
        //       high-confidence classifier (training-data bias trumps).
        //   (2) top overlap = 2 with a clear margin — override when
        //       classifier confidence is below 0.85.
        let (schemaPick, overlapScore) = schemaTokenOverlapPromoteWithScore(input: input)
        if let schemaPick = schemaPick {
            let resolvedTopTool = LabelRegistry.lookup(topResult.label)?.tool ?? topResult.label
            if schemaPick != resolvedTopTool {
                let shouldOverride: Bool = {
                    if overlapScore >= 3 { return true }
                    if overlapScore >= 2 && topResult.confidence < 0.85 { return true }
                    return false
                }()
                if shouldOverride {
                    Log.router.debug("Schema-token override (overlap=\(overlapScore)): CoreML=\(resolvedTopTool)(\(String(format: "%.2f", topResult.confidence))) → schema=\(schemaPick)")
                    if let resolved = resolveToolByNameAny(schemaPick) {
                        return resolved
                    }
                }
            }
        }

        if sortedResults.count > 1 {
            let secondResult = sortedResults[1]
            let confidenceDelta = topResult.confidence - secondResult.confidence

            if confidenceDelta < AppConfig.mlDisambiguationConfidenceThreshold {
                // If the top label's absolute confidence is below the floor,
                // the classifier is guessing — fall through to LLM fallback
                // instead of disambiguating between two weak predictions.
                if topResult.confidence < AppConfig.mlDisambiguationAbsoluteFloor {
                    Log.router.debug("ML confidence too low for disambiguation (\(String(format: "%.2f", topResult.confidence)) < \(AppConfig.mlDisambiguationAbsoluteFloor)), falling through to LLM")
                    return nil
                }

                // Before disambiguating, check if the top candidates share a domain.
                // If so, use DomainDisambiguator to resolve within the domain.
                let topDomain = LabelRegistry.domain(of: topResult.label)
                let secondDomain = LabelRegistry.domain(of: secondResult.label)

                if topDomain == secondDomain, LabelRegistry.isCompoundDomain(topDomain) {
                    if let resolved = DomainDisambiguator.resolve(domain: topDomain, input: input) {
                        return resolveLabel(resolved)
                    }
                    // Couldn't disambiguate by keywords — use default action
                    if let defaultLabel = DomainDisambiguator.defaultAction(for: topDomain) {
                        return resolveLabel(defaultLabel)
                    }
                }

                let choices = sortedResults.prefix(3)
                    .filter { $0.confidence > MLThresholdsConfig.shared.routing.disambiguationGap }
                    .map { $0.label }
                return .requiresDisambiguation(choices: choices)
            }
        }

        return resolveLabel(topResult.label, input: input)
    }

    /// Resolves a label to a RoutingResult using the LabelRegistry, with domain fallback.
    func resolveLabel(_ label: String, input: String = "") -> RoutingResult? {
        lastRoutingLabel = label

        // 1. Try LabelRegistry lookup
        if let entry = LabelRegistry.lookup(label) {
            return resolveToolByName(entry.tool, type: entry.type)
        }

        // 2. Domain-level fallback: if the label is a compound label but not in
        //    the registry, try disambiguating within the domain.
        let domain = LabelRegistry.domain(of: label)
        if LabelRegistry.isCompoundDomain(domain) {
            if let resolved = DomainDisambiguator.resolve(domain: domain, input: input),
               let entry = LabelRegistry.lookup(resolved) {
                return resolveToolByName(entry.tool, type: entry.type)
            }
        }

        // 3. Legacy fallback: ToolNameNormalizer (for labels not yet in registry)
        if let tool = availableTools.first(where: {
            ToolNameNormalizer.matches($0.name, label)
        }) {
            return .tools([tool])
        } else if let fmTool = fmTools.first(where: {
            ToolNameNormalizer.matches($0.name, label)
        }) {
            return .fmTools([fmTool])
        }

        return nil
    }

    /// Finds a tool instance by name and type (core/fm).
    func resolveToolByName(_ toolName: String, type: String) -> RoutingResult? {
        if type == "core" {
            if let tool = availableTools.first(where: {
                ToolNameNormalizer.matches($0.name, toolName)
            }) {
                return .tools([tool])
            }
        } else if type == "fm" {
            if let fmTool = fmTools.first(where: {
                ToolNameNormalizer.matches($0.name, toolName)
            }) {
                return .fmTools([fmTool])
            }
        }

        // Try both if type doesn't match (defensive)
        if let tool = availableTools.first(where: {
            ToolNameNormalizer.matches($0.name, toolName)
        }) {
            return .tools([tool])
        }
        if let fmTool = fmTools.first(where: {
            ToolNameNormalizer.matches($0.name, toolName)
        }) {
            return .fmTools([fmTool])
        }
        return nil
    }

    /// Resolves a tool name to a RoutingResult, checking both core and FM tools.
    func resolveToolByNameAny(_ name: String) -> RoutingResult? {
        if let tool = availableTools.first(where: { ToolNameNormalizer.matches($0.name, name) }) {
            return .tools([tool])
        }
        if let fmTool = fmTools.first(where: { ToolNameNormalizer.matches($0.name, name) }) {
            return .fmTools([fmTool])
        }
        return nil
    }
}
