import CoreML
import Foundation
import NaturalLanguage


// MARK: - Meta-Query Detection

extension ToolRouter {

    /// Seed phrases representing meta-queries — includes filler-word variants.
    static let metaSeeds: [String] = [
        // Capabilities
        "what can you do", "what can you even do", "what do you do",
        "what exactly can you do", "so what can you do", "what all can you do",
        "what are your features", "what are you capable of",
        "list your features", "show me your tools",
        "what's your purpose", "what is your purpose",
        "what tools do you have", "tell me your capabilities",
        // Identity
        "what is iclaw", "tell me about iclaw", "who made iclaw",
        "describe iclaw", "how does iclaw work", "what does iclaw do",
        "who built iclaw", "what is this app", "about iclaw",
        "who are you", "what's your name", "introduce yourself",
        "are you an ai", "are you a bot",
        // Help
        "how do you work", "how does this work",
        "help me use this", "show me how to use this",
    ]

    /// Pre-computed embedding vectors for meta-query seeds. Computed once at class load.
    static let metaSeedVectors: [[Double]] = {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }
        return metaSeeds.compactMap { model.vector(for: $0) }
    }()

    /// Words that indicate the query is about the agent itself.
    /// Kept narrow to avoid false positives on entity queries like "what are the features of iPhone".
    static let selfReferentialWords: Set<String> = [
        "you", "your", "yourself", "iclaw",
    ]

    /// Cosine similarity threshold for embedding match.
    /// Lowered from 0.88 to 0.85 to catch filler-word variants ("what can you even do")
    /// while avoiding false positives on task queries ("can you find the weather").
    static let metaEmbeddingThreshold: Double = 0.85

    /// Synchronous meta-query detector. Layered:
    ///   1. Brand match ("iclaw") — universal across languages.
    ///   2. Phase 7b: when the classifier flag is on, prefer the
    ///      multilingual `ConversationIntentClassifier` verdict. (Implemented
    ///      via the async `isMetaQueryAsync` variant.)
    ///   3. Legacy fallback: English seed + English embedding + English
    ///      pronoun gate. Kept as last resort for flag-OFF and low-
    ///      confidence cases.
    ///
    /// Callers in async contexts should prefer `isMetaQueryAsync`, which
    /// consults the classifier when the flag is on. This sync variant now
    /// ONLY runs the legacy path — it's what gets called from the remaining
    /// sync call sites until they're migrated.
    func isMetaQuery(input: String) -> Bool {
        let lower = input.lowercased()

        // Explicit app name reference — universal across languages.
        if lower.contains("iclaw") || lower.contains("i-claw") { return true }

        return legacyIsMetaQueryEnglish(input: input)
    }

    /// Async meta-query detector with classifier ladder. When
    /// `useClassifierIntentRoutingKey` is ON and the classifier is confident
    /// (≥0.85) this turn is `.meta`, returns true regardless of language.
    /// Otherwise falls through to the legacy English path.
    func isMetaQueryAsync(input: String) async -> Bool {
        let lower = input.lowercased()
        if lower.contains("iclaw") || lower.contains("i-claw") { return true }

        if AppConfig.useClassifierIntentRouting,
           let probe = await ConversationIntentClassifier.shared.classify(input) {
            switch probe.confidenceTier {
            case .high:
                return probe.label == .meta
            case .medium where AppConfig.useLLMJudge:
                let judged = await LLMJudge.shared.judgeIntent(input: input, classifierHint: probe)
                return (judged ?? probe.label) == .meta
            default:
                break  // Fall through to legacy.
            }
        }

        return legacyIsMetaQueryEnglish(input: input)
    }

    /// The original English-only path — preserved for flag-OFF behavior and
    /// as a fallback when the classifier is low-confidence or absent.
    /// The body is unchanged from the pre-Phase-7b implementation.
    private func legacyIsMetaQueryEnglish(input: String) -> Bool {
        let lower = input.lowercased()
        let words = lower.wordTokenSet

        guard words.count <= 10 else { return false }

        let hasSelfRef = !words.isDisjoint(with: Self.selfReferentialWords)
        guard hasSelfRef else { return false }

        guard !Self.metaSeedVectors.isEmpty else { return false }
        guard let model = NLEmbedding.sentenceEmbedding(for: .english),
              let inputVector = model.vector(for: lower) else { return false }

        for seedVector in Self.metaSeedVectors {
            let sim = VectorMath.cosineSimilarity(inputVector, seedVector)
            if sim > Self.metaEmbeddingThreshold {
                Log.router.debug("Meta-query detected via embedding (sim=\(String(format: "%.3f", sim))): '\(input)'")
                return true
            }
        }
        return false
    }
}

// MARK: - Per-Tool Help Detection

extension ToolRouter {

    /// Words/phrases that signal the user wants help ABOUT a tool, not to USE it.
    /// Only unambiguous help words — no "?", "info", or empty string which
    /// could appear in normal tool queries.
    static let helpIntentExact: Set<String> = [
        "help", "usage", "guide", "tutorial", "examples",
    ]

    /// Prefix patterns that signal help intent when followed by minimal content.
    static let helpIntentPrefixes: [String] = [
        "how to use", "how to", "how does it work", "how does this work",
        "what does it do", "what does this do", "what can it do",
        "what can this do", "show me how",
    ]

    /// Returns true if the input (after chip stripping) is asking for help
    /// about a tool rather than trying to use it.
    func isHelpIntent(_ stripped: String) -> Bool {
        let lower = stripped.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact match: bare "help", "?", empty, etc.
        if Self.helpIntentExact.contains(lower) { return true }

        // Prefix match: "how to use", "what does it do", etc.
        if Self.helpIntentPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }

        return false
    }

    /// Stop words excluded from residual content checks.
    static let helpStopWords: Set<String> = [
        "the", "a", "an", "in", "on", "to", "for", "is", "it", "do",
        "does", "my", "me", "i", "can", "this", "that", "of", "with",
        "how", "what", "about", "tool", "feature",
    ]

    /// Help keyword patterns for natural language detection.
    static let helpKeywordPatterns: [String] = [
        "help", "how do i use", "how does .* work", "what does .* do",
        "what can .* do", "tell me about .* tool", "tell me about .* feature",
        "explain .*tool", "how to use",
    ]

    /// Checks if the input is a natural language help query about a specific tool.
    /// e.g., "weather help", "how do I use the calculator", "what does the timer do"
    /// Returns nil if the query is a task ("help me check the weather").
    func checkToolHelpQuery(input: String) -> RoutingResult? {
        let lower = input.lowercased()
        let words = lower.wordTokens

        // Must contain a help signal word
        let hasHelpSignal = words.contains("help")
            || lower.contains("how do i use")
            || lower.contains("how does")
            || lower.contains("what does")
            || lower.contains("what can")
            || lower.contains("tell me about")
            || lower.contains("how to use")
            || lower.contains("explain")

        guard hasHelpSignal else { return nil }

        // Must reference a known tool name or chip name
        guard let matchedToolName = ToolHelpProvider.toolName(matchingInput: input) else {
            return nil
        }

        // Guard: "help me [verb] ..." is a task query, not a help query.
        // After removing help keywords and tool name, check residual content.
        var residual = lower
        // Strip help keywords
        for keyword in ["help", "how do i use", "how does", "what does",
                        "what can", "tell me about", "how to use", "explain"] {
            residual = residual.replacingOccurrences(of: keyword, with: "")
        }
        // Strip tool name and chip name
        residual = residual.replacingOccurrences(of: matchedToolName.lowercased(), with: "")
        if let chip = ToolManifest.entry(for: matchedToolName)?.chipName {
            residual = residual.replacingOccurrences(of: chip.lowercased(), with: "")
        }

        // Count non-stopword residual tokens
        let residualWords = residual
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty && !Self.helpStopWords.contains($0) }

        // If significant task content remains, this is "help me [task]", not "tool help"
        if residualWords.count > 2 { return nil }

        helpContextToolName = matchedToolName
        if let helpTool = availableTools.first(where: { $0.name == ToolNames.help }) {
            Log.router.debug("Tool help query detected for '\(matchedToolName)'")
            return .tools([helpTool])
        }
        return nil
    }
}

// MARK: - Synonym Expansion

extension ToolRouter {

    struct SynonymEntry: Decodable {
        let pattern: String
        let expansion: String
    }

    /// Loaded from `Resources/Config/SynonymMap.json` with pre-compiled regexes.
    static let synonymMap: [(pattern: String, expansion: String, regex: NSRegularExpression?)] = {
        guard let entries = ConfigLoader.load("SynonymMap", as: [SynonymEntry].self) else { return [] }
        return entries.map { entry in
            let regex = entry.pattern.contains("(")
                ? try? NSRegularExpression(pattern: entry.pattern, options: .caseInsensitive)
                : nil
            return (pattern: entry.pattern, expansion: entry.expansion, regex: regex)
        }
    }()

    /// True when any synonym-map pattern matches the input. Used by the
    /// ExecutionEngine to decide whether a gate-conversational turn should
    /// be promoted to routing — a synonym match means the router has a
    /// specific tool mapping for this phrasing (e.g. "top stories" → News)
    /// that the gate's NER-driven hints can't see.
    public func matchesAnySynonym(input: String) -> Bool {
        let normalized = input.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        let lower = normalized.lowercased()
        for entry in Self.synonymMap {
            if let regex = entry.regex {
                let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                if regex.firstMatch(in: lower, range: range) != nil {
                    return true
                }
            } else if lower.contains(entry.pattern) {
                return true
            }
        }
        return false
    }

    func expandSynonyms(input: String) -> String {
        // Collapse multi-spaces before matching — perturbations like "distance  to  X" break substring matches
        let normalized = input.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        let lower = normalized.lowercased()

        for entry in Self.synonymMap {
            if let regex = entry.regex {
                let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                if regex.firstMatch(in: lower, range: range) != nil {
                    let expanded = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: entry.expansion)
                    Log.router.debug("Synonym expanded: '\(input)' → '\(expanded)'")
                    return expanded
                }
            } else if lower.contains(entry.pattern) {
                let expanded = normalized.replacingOccurrences(of: entry.pattern, with: entry.expansion, options: .caseInsensitive)
                Log.router.debug("Synonym expanded: '\(input)' → '\(expanded)'")
                return expanded
            }
        }
        return input
    }
}

// MARK: - Pattern-Based Routing (Tickers, URLs, Encoding)

extension ToolRouter {

    /// Checks for `$SYMBOL` ticker patterns and routes to StockTool.
    func checkTickerSymbols(input: String) -> RoutingResult? {
        let symbols = InputParsingUtilities.extractTickerSymbols(from: input)
        guard !symbols.isEmpty else { return nil }

        let hasKnownTicker = symbols.contains { TickerLookup.lookup(symbol: $0) != nil }
        guard hasKnownTicker else { return nil }

        if let stockTool = availableTools.first(where: { $0.name.lowercased() == "stocks" }) {
            return .tools([stockTool])
        }
        return nil
    }

    static let urlDetector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Checks if the input contains HTTP/HTTPS URLs and routes to WebFetchTool.
    func checkURLs(input: String) -> RoutingResult? {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = Self.urlDetector?.matches(in: input, options: [], range: range) ?? []

        let httpURLs = matches.compactMap { $0.url }.filter {
            ($0.scheme == "http" || $0.scheme == "https")
                && input.contains("://") // Require explicit scheme — don't route bare domains
        }
        guard !httpURLs.isEmpty else { return nil }

        if let fetchTool = availableTools.first(where: { $0.name == ToolNames.webFetch }) {
            Log.router.debug("Detected \(httpURLs.count) URL(s) — routing to WebFetch")
            return .tools([fetchTool])
        }
        return nil
    }

    /// Detects encoding format names (hex, binary, base64, etc.) or raw encoded data
    /// patterns (binary bytes, hex bytes, roman numerals) and routes to ConvertTool.
    func checkEncodingFormats(input: String) -> RoutingResult? {
        let lower = input.lowercased()

        // Encoding format names that indicate a text ↔ encoding conversion.
        // Use word-boundary matching to avoid false positives (e.g., "roman" in "Roman Empire").
        let formatNames: Set<String> = Set(Self._heuristicsConfig?.encodingFormats ?? [])

        let mentionsFormat = formatNames.contains { format in
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: format))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
        }

        // Also check for raw encoded data (binary bytes, hex bytes, roman numerals)
        let looksEncoded = !mentionsFormat && ConvertTool.looksLikeEncodedData(input)

        guard mentionsFormat || looksEncoded else { return nil }

        if let convertTool = availableTools.first(where: { $0.name == ToolNames.convert }) {
            if looksEncoded {
                Log.router.debug("Detected raw encoded data — routing to Convert")
            } else {
                Log.router.debug("Detected encoding format name — routing to Convert")
            }
            return .tools([convertTool])
        }
        return nil
    }
}

// MARK: - Attachment Hint Routing

extension ToolRouter {

    /// When the engine has stripped an `[Attached: ...]` tag, the remaining input
    /// may still contain natural-language cues. This method biases routing based on
    /// the file extension inferred from the input context. It is a soft hint — if
    /// the user's prompt clearly names a different tool via chip, that wins (chips
    /// are checked first).
    func checkAttachmentHint(input: String) -> RoutingResult? {
        // The engine prepends the file path before the user text, separated by newline
        let lines = input.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
        // Only act if the first line looks like a file path
        guard firstLine.hasPrefix("/") || firstLine.hasPrefix("~") else { return nil }

        let url = URL(fileURLWithPath: firstLine)
        let ext = url.pathExtension.lowercased()

        // iCal / vCard → ImportTool
        if ext == "ics" || ext == "vcf" || ext == "vcard" {
            if let tool = availableTools.first(where: { $0.name == ToolNames.importTool }) {
                Log.router.debug("Attachment hint: .\(ext) → Import")
                return .tools([tool])
            }
        }

        let category = FileAttachment.FileCategory.classify(url: url)
        let promptText = lines.dropFirst().joined(separator: "\n").lowercased()

        switch category {
        case .text, .code:
            if let fmTool = fmTools.first(where: { $0.name == ToolNames.readFile }) {
                Log.router.debug("Attachment hint: text/code → FM ReadFile")
                return .fmTools([fmTool])
            }

        case .pdf:
            if let fmTool = fmTools.first(where: { $0.name == ToolNames.readFile }) {
                Log.router.debug("Attachment hint: PDF → FM ReadFile")
                return .fmTools([fmTool])
            }

        case .audio:
            if let tool = availableTools.first(where: { $0.name == ToolNames.transcribe }) {
                Log.router.debug("Attachment hint: audio → Transcribe")
                return .tools([tool])
            }

        case .image:
            let genKeywords = ["create", "generate", "imagine", "remix", "transform",
                               "reimagine", "make", "draw", "illustrate", "design"]
            if genKeywords.contains(where: { promptText.contains($0) }) {
                if let tool = availableTools.first(where: { $0.name == ToolNames.create }) {
                    Log.router.debug("Attachment hint: image + generation keywords → Create")
                    return .tools([tool])
                }
            }
            if let fmTool = fmTools.first(where: { $0.name == ToolNames.readFile }) {
                Log.router.debug("Attachment hint: image → FM ReadFile")
                return .fmTools([fmTool])
            }

        case .folder:
            if let fmTool = fmTools.first(where: { $0.name == ToolNames.readFile }) {
                Log.router.debug("Attachment hint: folder → FM ReadFile")
                return .fmTools([fmTool])
            }

        case .binary:
            if let fmTool = fmTools.first(where: { $0.name == ToolNames.readFile }) {
                Log.router.debug("Attachment hint: binary → FM ReadFile")
                return .fmTools([fmTool])
            }
        }

        return nil
    }
}

// MARK: - Skill & Workflow Routing

extension ToolRouter {

    /// Checks if the input matches any of the parsed skill examples.
    /// Returns the matched skill and its word-coverage ratio (0.0–1.0).
    /// Coverage indicates how much of the input the example covers — used by the
    /// router to decide whether to accept immediately or defer to ML for disambiguation.
    func checkSkillExamples(input: String) async -> (skill: Skill, coverage: Double)? {
        let skills = await SkillLoader.shared.activeSkills
        let normalizedInput = input.lowercased().trimmingCharacters(in: .whitespaces)
        let inputWordCount = normalizedInput.split(separator: " ").count

        var bestMatch: (skill: Skill, coverage: Double)?

        for skill in skills {
            for example in skill.examples {
                let lowerExample = example.lowercased()
                guard normalizedInput.contains(lowerExample) else { continue }

                let exampleWordCount = lowerExample.split(separator: " ").count
                let coverage = Double(exampleWordCount) / Double(max(1, inputWordCount))
                guard coverage >= 0.5 else { continue }

                // Keep the highest-coverage match
                if bestMatch == nil || coverage > bestMatch!.coverage {
                    bestMatch = (skill: skill, coverage: coverage)
                }
            }
        }
        return bestMatch
    }

    func buildSkillRoutingResult(for skillMatch: Skill) -> RoutingResult? {
        var matchedCoreTools: [any CoreTool] = []
        var matchedFMTools: [any FMToolDescriptor] = []

        for toolDef in skillMatch.tools {
            let toolName = toolDef.name.lowercased()
            if let coreTool = availableTools.first(where: { $0.name.lowercased() == toolName }) {
                matchedCoreTools.append(coreTool)
            } else if let fmTool = fmTools.first(where: { $0.name.lowercased() == toolName }) {
                matchedFMTools.append(fmTool)
            }
        }

        if !matchedCoreTools.isEmpty || !matchedFMTools.isEmpty {
            if matchedCoreTools.isEmpty {
                return .fmTools(matchedFMTools)
            } else if matchedFMTools.isEmpty {
                return .tools(matchedCoreTools)
            } else {
                return .mixed(core: matchedCoreTools, fm: matchedFMTools)
            }
        }
        return nil
    }
}

// MARK: - LLM Fallback

extension ToolRouter {

    /// Fallback to LLM with enriched prompt including tool descriptions, location context, and examples.
    func llmFallback(input: String) async -> RoutingResult? {
        let coreDescriptions = availableTools.map { "- \($0.name): \($0.schema)" }
        let fmDescriptions = fmTools.map { "- \($0.name): \($0.routingKeywords.joined(separator: ", "))" }
        let skills = await SkillLoader.shared.activeSkills
        let skillDescriptions = skills.map { "- \($0.name): \($0.examples.prefix(3).joined(separator: ", "))" }

        let allDescriptions = (coreDescriptions + fmDescriptions + skillDescriptions).joined(separator: "\n")

        // Lightweight context — no async calls that can hang.
        // Location is intentionally omitted: resolveCurrentLocation() can deadlock
        // in headless/CLI mode. The LLM routes by intent, not by location.
        let contextBlock = "Timezone: \(TimeZone.current.identifier)\nLocale: \(Locale.current.identifier)"

        let systemInstruction = """
        You are a tool router for a macOS assistant. Given the user's request, identify the SINGLE most relevant tool.

        User context:
        \(contextBlock)

        Available tools:
        \(allDescriptions)

        Rules:
        - Output ONLY the tool name, nothing else.
        - If the request is conversational (greeting, opinion, joke, general question) and no tool applies, output "none".
        - Match based on the user's INTENT, not just keyword overlap.
        - "how far", "how long to drive", "directions", "ETA", "distance to", "nearby", "restaurants" → Maps
        - "installed", "battery", "wifi", "disk", "cpu", "uptime", "memory", "what apps" → SystemInfo
        - Questions about travel time, routes, or places are Maps, NOT Time.
        """

        do {
            let rawName: String
            if let responder = llmResponder {
                rawName = try await responder(input, systemInstruction)
            } else {
                rawName = try await LLMAdapter.shared.generateWithInstructions(prompt: input, instructions: systemInstruction)
            }

            Log.router.debug("LLM Fallback suggested: \"\(rawName)\"")

            if rawName.lowercased() == "none" {
                return nil
            }

            if let matchedSkill = skills.first(where: {
                ToolNameNormalizer.matches($0.name, rawName)
            }) {
                self.currentSkill = matchedSkill
                return buildSkillRoutingResult(for: matchedSkill)
            }

            if let tool = availableTools.first(where: {
                ToolNameNormalizer.matches($0.name, rawName)
            }) {
                return .tools([tool])
            } else if let fmTool = fmTools.first(where: {
                ToolNameNormalizer.matches($0.name, rawName)
            }) {
                return .fmTools([fmTool])
            }
        } catch {
            Log.router.error("LLM Fallback failed: \(error)")
        }

        return nil
    }
}


// MARK: - Chip Routing

extension ToolRouter {

    /// Checks for tool names prefixed with '#' in the input string.
    ///
    /// Routing priority:
    /// 1. Category chips (`#math`, `#live`, `#search`, etc.) — returns all tools in the category
    /// 2. Individual tool chips (`#calculator`, `#weather`) via category alias lookup
    /// 3. Skill handles (`#crypto`, `#emoji`)
    ///
    /// Category chips scope routing to the category's tools. The ML classifier
    /// or extraction schema then disambiguates within the category. If no tool
    /// in the category matches, the escape hatch falls through to full routing.
    func checkToolChips(input: String) async -> RoutingResult? {
        let chipNames = InputParsingUtilities.extractToolChipNames(from: input)
        guard !chipNames.isEmpty else { return nil }

        // 1. Check category chips (primary name or alias).
        // Aliases (#calculator, #weather) resolve to their specific tool.
        // Primary chips (#math, #live) use ML to disambiguate within the category.
        // Multi-chip inputs (#weather #stocks) accumulate tools before returning.
        var categoryMatchedCore: [any CoreTool] = []
        var categoryMatchedFM: [any FMToolDescriptor] = []

        for chipName in chipNames {
            guard let category = ToolCategoryRegistry.category(forChip: chipName) else { continue }

            let stripped = InputParsingUtilities.stripToolChips(from: input)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Intercept category+help (only if this is the sole chip)
            if chipNames.count == 1 && isHelpIntent(stripped) {
                // Resolve alias to specific tool name (e.g., #weather → "Weather")
                // Falls back to category name for primary chips (e.g., #live → "Live")
                let aliasLower = chipName.lowercased()
                let isPrimary = aliasLower == category.chipName.lowercased()
                if !isPrimary, let directTool = availableTools.first(where: {
                    $0.name.lowercased() == aliasLower
                    || ToolManifest.entry(for: $0.name)?.chipName?.lowercased() == aliasLower
                }) {
                    helpContextToolName = directTool.name
                } else {
                    helpContextToolName = category.name
                }
                if let helpTool = availableTools.first(where: { $0.name == ToolNames.help }) {
                    Log.router.debug("Category+help detected — redirecting to Help for '\(self.helpContextToolName ?? category.name)'")
                    return .tools([helpTool])
                }
            }

            let aliasLower = chipName.lowercased()
            let isPrimaryChip = aliasLower == category.chipName.lowercased()

            if !isPrimaryChip {
                // Alias: resolve to the specific tool it names.
                // e.g., #compute → Compute, #weather → Weather
                if let directTool = availableTools.first(where: {
                    $0.name.lowercased() == aliasLower
                    || ToolManifest.entry(for: $0.name)?.chipName?.lowercased() == aliasLower
                }) {
                    Log.router.debug("Category alias #\(chipName) → direct tool \(directTool.name)")
                    categoryMatchedCore.append(directTool)
                    continue
                }
                if let directFM = fmTools.first(where: {
                    $0.name.lowercased() == aliasLower
                    || $0.chipName.lowercased() == aliasLower
                }) {
                    Log.router.debug("Category alias #\(chipName) → direct FM tool \(directFM.name)")
                    categoryMatchedFM.append(directFM)
                    continue
                }
            } else {
                // Primary category chip (#math, #live): disambiguate within category.
                let coreCat = availableTools.filter { category.coreToolNames.contains($0.name) }
                let fmCat = fmTools.filter { category.fmToolNames.contains($0.name) }

                if coreCat.isEmpty && fmCat.isEmpty {
                    Log.router.debug("Category #\(chipName) matched but no tools available — falling through")
                    continue
                }

                if coreCat.count + fmCat.count == 1 {
                    if let tool = coreCat.first { categoryMatchedCore.append(tool) }
                    else if let fm = fmCat.first { categoryMatchedFM.append(fm) }
                    continue
                }

                // Use ML classifier on the stripped input to pick the best tool
                if !stripped.isEmpty {
                    let mlResults = await classifyWithML(input: stripped)
                    if let topLabel = mlResults.first?.label,
                       let entry = LabelRegistry.lookup(topLabel) {
                        if let match = coreCat.first(where: { $0.name == entry.tool }) {
                            Log.router.debug("Category #\(chipName) → ML disambiguated to \(match.name)")
                            categoryMatchedCore.append(match)
                            continue
                        }
                        if let match = fmCat.first(where: { $0.name == entry.tool }) {
                            Log.router.debug("Category #\(chipName) → ML disambiguated to FM \(match.name)")
                            categoryMatchedFM.append(match)
                            continue
                        }
                    }
                }

                // ML didn't resolve — default to first tool in category
                if let tool = coreCat.first { categoryMatchedCore.append(tool) }
                else if let fm = fmCat.first { categoryMatchedFM.append(fm) }
            }
        }

        // Return accumulated category matches
        if !categoryMatchedCore.isEmpty || !categoryMatchedFM.isEmpty {
            let core = Array(categoryMatchedCore.prefix(maxToolsToReturn))
            let fm = Array(categoryMatchedFM.prefix(max(0, maxToolsToReturn - core.count)))
            if fm.isEmpty {
                return .tools(core)
            } else if core.isEmpty {
                return .fmTools(fm)
            } else {
                return .mixed(core: core, fm: fm)
            }
        }

        // 2. Legacy individual tool chip matching (for any chips not covered by categories)
        var matchedCoreTools: [any CoreTool] = []
        var matchedFMTools: [any FMToolDescriptor] = []

        for chipName in chipNames {
            if let tool = availableTools.first(where: {
                ToolNameNormalizer.matches($0.name, chipName)
                || ToolManifest.entry(for: $0.name)?.chipName?.lowercased() == chipName.lowercased()
            }) {
                matchedCoreTools.append(tool)
            } else if let fmTool = fmTools.first(where: {
                ToolNameNormalizer.matches($0.chipName, chipName)
            }) {
                matchedFMTools.append(fmTool)
            }
        }

        // Intercept chip+help
        if !matchedCoreTools.isEmpty || !matchedFMTools.isEmpty {
            let stripped = InputParsingUtilities.stripToolChips(from: input)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isHelpIntent(stripped) {
                let toolName = matchedCoreTools.first?.name
                    ?? matchedFMTools.first?.chipName ?? ""
                helpContextToolName = toolName
                if let helpTool = availableTools.first(where: { $0.name == ToolNames.help }) {
                    Log.router.debug("Chip+help detected — redirecting to Help for '\(toolName)'")
                    return .tools([helpTool])
                }
            }
        }

        // 3. Check skill handles if no tool matched
        if matchedCoreTools.isEmpty && matchedFMTools.isEmpty {
            let skills = await SkillLoader.shared.activeSkills
            for chipName in chipNames {
                if let skill = skills.first(where: { $0.handle?.lowercased() == chipName.lowercased() }) {
                    self.currentSkill = skill
                    Log.router.debug("Chip #\(chipName) matched skill handle: \(skill.name)")
                    return buildSkillRoutingResult(for: skill) ?? .conversational
                }
            }
            return nil
        }

        if matchedCoreTools.count + matchedFMTools.count <= maxToolsToReturn {
            if matchedCoreTools.isEmpty {
                return .fmTools(matchedFMTools)
            } else if matchedFMTools.isEmpty {
                return .tools(matchedCoreTools)
            } else {
                return .mixed(core: matchedCoreTools, fm: matchedFMTools)
            }
        } else {
            let coreToTake = min(matchedCoreTools.count, maxToolsToReturn)
            let fmToTake = maxToolsToReturn - coreToTake

            let finalCore = Array(matchedCoreTools.prefix(coreToTake))
            let finalFM = Array(matchedFMTools.prefix(fmToTake))

            if finalFM.isEmpty {
                return .tools(finalCore)
            } else if finalCore.isEmpty {
                return .fmTools(finalFM)
            } else {
                return .mixed(core: finalCore, fm: finalFM)
            }
        }
    }
}

// MARK: - Reply Prefix Stripping

extension ToolRouter {

    /// Strips `[Replying to: "..." → "..."]` prefix from user input.
    /// The prefix is added by ChatView when the user replies to a message.
    /// It must be removed before routing so classifiers see clean input.
    /// The reply context is already captured in conversation state for follow-up detection.
    static func stripReplyPrefix(_ input: String) -> String {
        guard input.hasPrefix("[Replying to:") else { return input }
        // Find the closing bracket, then take everything after it
        guard let closingBracket = input.firstIndex(of: "]") else { return input }
        let afterBracket = input[input.index(after: closingBracket)...]
        let stripped = afterBracket.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? input : stripped
    }
}

// MARK: - Retry Phrases

extension ToolRouter {

    static let retryPhrases: Set<String> = [
        "try again", "retry", "again", "do it again", "one more time",
        "redo that", "do it over", "again please", "try once more",
        "try that again", "run it again", "do that again", "once more",
        "go again", "give it another shot", "another attempt",
        "let's try that again", "repeat that", "re-run that",
    ]

    static func containsRetryIntent(_ input: String) -> Bool {
        retryPhrases.contains(input.trimmingCharacters(in: .whitespacesAndNewlines))
            || retryPhrases.contains(where: { input.hasPrefix($0) })
    }
}

// MARK: - Private Static Storage (underscored to avoid redeclaration conflicts)

extension ToolRouter {

    // These use underscored names because Swift doesn't allow stored properties
    // in extensions. They're accessed via computed properties above.

    static let _heuristicsConfig: RouterHeuristicsConfig? = ConfigLoader.load("RouterHeuristics", as: RouterHeuristicsConfig.self)
    static let _unitKeywords: Set<String> = Set(_heuristicsConfig?.unitKeywords ?? [])
    static let _arithmeticPatterns: [String] = _heuristicsConfig?.arithmeticPatterns ?? []
    static let _compiledArithmeticPatterns: [NSRegularExpression] = {
        _arithmeticPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
    static let _stockHintWords: Set<String> = Set(_heuristicsConfig?.stockHintWords ?? [])
    static let _podcastIndicators: Set<String> = Set(_heuristicsConfig?.podcastIndicators ?? [])
    static let _localIndicators: Set<String> = Set(_heuristicsConfig?.localIndicators ?? [])
    static let _contactIndicators: Set<String> = Set(_heuristicsConfig?.contactIndicators ?? [])
    static let _randomKeywords: Set<String> = Set(_heuristicsConfig?.randomKeywords ?? [])
    static let _entityLookupVerbs: Set<String> = Set(_heuristicsConfig?.entityLookupVerbs ?? [])
    static let _systemKeywords: [String] = _heuristicsConfig?.systemKeywords ?? []
    static let _financialKeywords: [String] = _heuristicsConfig?.financialKeywords ?? []
    static let _comparisonConnectors: [String] = _heuristicsConfig?.comparisonConnectors ?? []
    static let _calculatorExcludeKeywords: [String] = _heuristicsConfig?.calculatorExcludeKeywords ?? []

    static let _computeSignalsConfig: ComputeSignalsConfig? = ConfigLoader.load("ComputeSignals", as: ComputeSignalsConfig.self)
    static let _computeKeywords: Set<String> = Set(_computeSignalsConfig?.keywords ?? [])
    static let _computePatterns: [NSRegularExpression] = {
        (_computeSignalsConfig?.patterns ?? []).compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static let _toolDomainKeywords: [String: [String]] = {
        ConfigLoader.load("ToolDomainKeywords", as: [String: [String]].self) ?? [:]
    }()

    /// Checks if input contains an email address, reusing the existing NSDataDetector.
    static func containsEmailAddress(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..., in: input)
        let matches = urlDetector?.matches(in: input, options: [], range: range) ?? []
        return matches.contains { $0.url?.scheme == "mailto" }
    }
}
