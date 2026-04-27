import CoreML
import Foundation
import NaturalLanguage

// Heuristic overrides for ML classifier decisions. Extracted from
// `ToolRouter+Helpers.swift` for file-size reasons (helpers was 1,408 lines).
// Behavior unchanged — the original file kept all of this in a single
// extension block. See `Docs/Routing.md` for the stage-by-stage map.

// MARK: - Heuristic Overrides

extension ToolRouter {

    // MARK: Configuration

    struct RouterHeuristicsConfig: Decodable {
        let unitKeywords: [String]
        let arithmeticPatterns: [String]
        let stockHintWords: [String]
        let podcastIndicators: [String]
        let localIndicators: [String]
        let contactIndicators: [String]
        let encodingFormats: [String]
        let randomKeywords: [String]?
        let entityLookupVerbs: [String]?
        let systemKeywords: [String]?
        let financialKeywords: [String]?
        let comparisonConnectors: [String]?
        let calculatorExcludeKeywords: [String]?
    }

    static var heuristicsConfig: RouterHeuristicsConfig? { _heuristicsConfig }

    /// Unit-related words that indicate a Convert intent, not Calculator.
    static var unitKeywords: Set<String> { _unitKeywords }

    /// Cryptocurrency symbols that should route to Convert, not Stocks.
    /// Shared with SkillWidgetParser via CryptoSymbolSet.
    static var cryptoSymbols: Set<String> { CryptoSymbolSet.symbols }

    /// Arithmetic operators/patterns that indicate Calculator, not Convert.
    static var arithmeticPatterns: [String] { _arithmeticPatterns }

    /// Pre-compiled arithmetic regexes for performance.
    static var compiledArithmeticPatterns: [NSRegularExpression] { _compiledArithmeticPatterns }

    static var stockHintWords: Set<String> { _stockHintWords }
    static var podcastIndicators: Set<String> { _podcastIndicators }
    static var localIndicators: Set<String> { _localIndicators }
    static var contactIndicators: Set<String> { _contactIndicators }
    static var randomKeywords: Set<String> { _randomKeywords }
    static var entityLookupVerbs: Set<String> { _entityLookupVerbs }
    static var systemKeywords: [String] { _systemKeywords }
    static var financialKeywords: [String] { _financialKeywords }
    static var comparisonConnectors: [String] { _comparisonConnectors }
    static var calculatorExcludeKeywords: [String] { _calculatorExcludeKeywords }

    // MARK: Compute Signals

    struct ComputeSignalsConfig: Decodable {
        let keywords: [String]
        let patterns: [String]
    }

    static var computeSignalsConfig: ComputeSignalsConfig? { _computeSignalsConfig }
    static var computeKeywords: Set<String> { _computeKeywords }
    static var computePatterns: [NSRegularExpression] { _computePatterns }

    /// Detects whether the input contains capitalized proper-noun-like words (brand names, entities)
    /// OR comparison connectors flanked by multi-word phrases (product names).
    static func containsEntitySignals(input: String) -> Bool {
        let tokens = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return false }

        // Signal 1: Mid-sentence capitalized words (skip first word)
        for i in 1..<tokens.count {
            let token = tokens[i]
            guard let first = token.unicodeScalars.first else { continue }
            if CharacterSet.uppercaseLetters.contains(first) && token.count > 1 {
                return true
            }
        }

        // Signal 2: Comparison connectors flanked by multi-word phrases
        // "Compare Tesla Model 3 and BMW i4 specs" — even without caps, "and" between product names
        let lower = input.lowercased()
        for connector in _comparisonConnectors {
            if let range = lower.range(of: connector) {
                let before = lower[lower.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let after = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // Both sides have at least 2 words → likely product names
                if before.split(separator: " ").count >= 2 && after.split(separator: " ").count >= 2 {
                    return true
                }
            }
        }

        return false
    }

    // MARK: Override Application

    func applyHeuristicOverrides(input: String, decision: RoutingResult) async -> RoutingResult {
        let lower = input.lowercased()
        let words = lower.wordTokenSet

        // CoreTool-specific overrides
        guard case .tools(let tools) = decision, let tool = tools.first else {
            return await applyFMHeuristicOverrides(input: lower, words: words, decision: decision)
        }

        // --- Removed: 5 Math-internal overrides (Calculator↔Convert↔Compute) ---
        // These are now handled by the Math category's within-category disambiguation.
        // The ML classifier distinguishes math.arithmetic / math.conversion / math.statistics,
        // eliminating the brittle "m" unit keyword + " to " false-positive pattern.

        // --- Removed: Email→ReadEmail override ---
        // Now handled by the Email category and email.read/email.compose ML labels.

        // Communication channel resolution (data-driven via CommunicationChannels.json).
        // Replaces hardcoded Email↔Messages heuristics. Handles:
        // - Definitive signals: "email" → Email, "text" → Messages, email address → Email
        // - Ambiguous input: "send a message" with both tools available → disambiguation pills
        // - Single-tool fallback: only one channel registered → route directly
        // - Non-communication tool with messaging intent → redirect to correct channel
        if CommunicationChannelResolver.isCommunicationTool(tool.name) {
            let toolNames = Set(availableTools.map(\.name))
            let resolution = CommunicationChannelResolver.resolve(
                input: input, routedToolOrLabel: tool.name, availableToolNames: toolNames
            )
            switch resolution {
            case .definitive(let channel):
                if channel.tool != tool.name, let target = availableTools.first(where: { $0.name == channel.tool }) {
                    Log.router.debug("Communication channel: \(tool.name) → \(channel.tool) (definitive signal)")
                    return .tools([target])
                }
            case .ambiguous(let channels):
                Log.router.debug("Communication channel ambiguous: \(channels.map(\.tool))")
                return .requiresDisambiguation(choices: channels.map(\.tool))
            case .notCommunication:
                break
            }
        } else if CommunicationChannelResolver.hasCommunicationIntent(input) {
            // Non-communication CoreTool (Reminders, Calendar, Notes) selected but
            // input has messaging intent ("tell Mike...", "send Sarah a message...").
            let toolNames = Set(availableTools.map(\.name))
            let resolution = CommunicationChannelResolver.resolveFromIntent(
                input: input, availableToolNames: toolNames
            )
            switch resolution {
            case .definitive(let channel):
                if let target = availableTools.first(where: { $0.name == channel.tool }) {
                    Log.router.debug("Communication intent override: \(tool.name) → \(channel.tool)")
                    return .tools([target])
                }
            case .ambiguous(let channels):
                Log.router.debug("Communication intent ambiguous: \(channels.map(\.tool))")
                return .requiresDisambiguation(choices: channels.map(\.tool))
            case .notCommunication:
                break
            }
        }

        // Stocks → Convert: cryptocurrency symbol detected
        if tool.name == ToolNames.stocks {
            let upperTokens = input.wordTokens
            if upperTokens.contains(where: { Self.cryptoSymbols.contains($0) }) {
                if let convertTool = availableTools.first(where: { $0.name == ToolNames.convert }) {
                    Log.router.debug("Heuristic override: Stocks → Convert (crypto symbol detected)")
                    return .tools([convertTool])
                }
            }
        }

        // Weather → Clock: bare time queries without weather keywords
        if tool.name == ToolNames.weather {
            let timeIndicators: Set<String> = ["time", "clock", "hour", "hours"]
            let weatherIndicators: Set<String> = [
                "weather", "temperature", "rain", "raining", "sunny", "cloudy", "forecast",
                "humidity", "wind", "snow", "storm", "uv", "sunrise", "sunset", "cold", "hot", "warm"
            ]
            let hasTimeWord = !words.intersection(timeIndicators).isEmpty
            let hasWeatherWord = !words.intersection(weatherIndicators).isEmpty
            if hasTimeWord && !hasWeatherWord {
                if let timeTool = availableTools.first(where: { $0.name == ToolNames.time }) {
                    Log.router.debug("Heuristic override: Weather → Time (time query, no weather keywords)")
                    return .tools([timeTool])
                }
            }
        }

        // Help → Conversational: ML classified as help/meta but meta-query
        // detection disagrees. Catches false positives like "what can
        // dolphins do" misclassified as meta.help. Uses the async variant
        // so non-English meta queries get a fair check via the classifier.
        let isActuallyMeta = await isMetaQueryAsync(input: input)
        if tool.name == ToolNames.help && !isActuallyMeta {
            Log.router.debug("Heuristic override: Help → Conversational (isMetaQuery disagrees with ML)")
            return .conversational
        }

        // Calculator → Conversational: symbolic math/calculus queries that Calculator can't handle
        if tool.name == ToolNames.calculator {
            let hasSymbolicKeyword = Self._calculatorExcludeKeywords.contains(where: { lower.contains($0) })
            if hasSymbolicKeyword {
                Log.router.debug("Heuristic override: Calculator → Conversational (symbolic math keyword detected)")
                return .conversational
            }
        }

        // Transcribe → Podcast: input mentions episode/podcast but has no file path
        if tool.name == ToolNames.transcribe {
            let hasFilePath = lower.contains("/") || lower.contains(".mp3") || lower.contains(".m4a")
                || lower.contains(".wav") || lower.contains(".mp4") || lower.contains(".aac")
            if !hasFilePath {
                if !words.intersection(Self._podcastIndicators).isEmpty {
                    if let podcastTool = availableTools.first(where: { $0.name == ToolNames.podcast }) {
                        Log.router.debug("Heuristic override: Transcribe → Podcast (no file path, podcast context)")
                        return .tools([podcastTool])
                    }
                }
            }
        }

        // Entity-aware suppression → WebSearch: entity-rich prompts with no domain keywords.
        // Catches "Compare specs of Ford Mustang GT" misrouted to Calculator because of numbers.
        let hasEntitySignals = Self.containsEntitySignals(input: input)
        let hasLookupVerbs = !words.intersection(Self._entityLookupVerbs).isEmpty
            || Self._entityLookupVerbs.contains(where: { lower.contains($0) })

        if hasEntitySignals && hasLookupVerbs {
            let hasArithmetic = Self._compiledArithmeticPatterns.contains { regex in
                regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)) != nil
            }
            let hasUnits = !words.intersection(Self._unitKeywords).isEmpty
            let hasRandomKeyword = !words.intersection(Self._randomKeywords).isEmpty
                || Self._randomKeywords.contains(where: { lower.contains($0) })
            let hasSystemKeyword = Self._systemKeywords.contains(where: { lower.contains($0) })
            let hasFinancialKeyword = Self._financialKeywords.contains(where: { lower.contains($0) })

            var shouldOverride = false

            // Math tools (Calculator/Convert) + Random: suppress if no arithmetic, units, or random keywords
            if [ToolNames.calculator, ToolNames.convert, ToolNames.random].contains(tool.name) {
                shouldOverride = !hasArithmetic && !hasUnits && !hasRandomKeyword
            }

            // SystemInfo: suppress if no system-specific keywords
            if tool.name == ToolNames.systemInfo {
                shouldOverride = !hasSystemKeyword
            }

            // Stocks: suppress if no financial keywords
            if tool.name == ToolNames.stocks {
                shouldOverride = !hasFinancialKeyword
            }

            if shouldOverride {
                if let webSearch = fmTools.first(where: { $0.name == ToolNames.webSearch }) {
                    Log.router.debug("Heuristic override: \(tool.name) → WebSearch (entity lookup, no domain keywords)")
                    return .fmTools([webSearch])
                }
            }
        }

        return decision
    }

    /// Heuristic overrides for FM tool routing decisions.
    func applyFMHeuristicOverrides(input: String, words: Set<String>, decision: RoutingResult) async -> RoutingResult {
        guard case .fmTools(let fmMatches) = decision, let fmTool = fmMatches.first else {
            return decision
        }

        // --- Removed: FM → Compute override ---
        // Now handled by the Math category's ML labels (math.statistics).

        // read_file → write_file: input has save/write/export signals
        if fmTool.name == ToolNames.readFile {
            let writeSignals: Set<String> = ["save", "write", "export", "create", "download", "dump"]
            if !words.intersection(writeSignals).isEmpty || input.contains("save as") || input.contains("to a file") || input.contains("to downloads") {
                if let writeTool = fmTools.first(where: { $0.name == ToolNames.writeFile }) {
                    Log.router.debug("Heuristic override: read_file → write_file (save/write signals detected)")
                    return .fmTools([writeTool])
                }
            }
        }

        // Spotlight → WebSearch: input lacks local file/app indicators
        if fmTool.name == ToolNames.spotlight {
            if words.intersection(Self._localIndicators).isEmpty {
                if let webSearch = fmTools.first(where: { $0.name == ToolNames.webSearch }) {
                    Log.router.debug("Heuristic override: Spotlight → WebSearch (no local indicators)")
                    return .fmTools([webSearch])
                }
            }
        }

        // WebSearch → Maps: use LLM to check if this is a location/place query
        if fmTool.name == ToolNames.webSearch {
            if let maps = fmTools.first(where: { $0.name == "maps" }) {
                if let override = await llmLocationCheck(input: input, maps: maps) {
                    return override
                }
            }
        }

        // system_control → SystemInfo: WiFi/Bluetooth queries are about reading state,
        // not controlling the system. Route to the CoreTool that gathers device info.
        if fmTool.name == ToolNames.systemControl {
            let infoIndicators: Set<String> = [
                "wifi", "wi-fi", "bluetooth", "bt", "network", "connected", "ssid",
                "signal", "battery", "disk", "storage", "memory", "ram", "cpu",
                "uptime", "bluetooth", "airpods", "paired"
            ]
            if !words.intersection(infoIndicators).isEmpty {
                if let systemInfo = availableTools.first(where: { $0.name == ToolNames.systemInfo }) {
                    Log.router.debug("Heuristic override: system_control → SystemInfo (device info query)")
                    return .tools([systemInfo])
                }
            }
        }

        // Non-communication FM tool with messaging intent → redirect via resolver.
        // "Send Shawn a message that I need to set up another meeting" misroutes to
        // shortcuts because "set up" biases the ML classifier toward automation.
        if CommunicationChannelResolver.hasCommunicationIntent(input) {
            let toolNames = Set(availableTools.map(\.name))
            let resolution = CommunicationChannelResolver.resolveFromIntent(
                input: input, availableToolNames: toolNames
            )
            switch resolution {
            case .definitive(let channel):
                if let target = availableTools.first(where: { $0.name == channel.tool }) {
                    Log.router.debug("FM communication override: \(fmTool.name) → \(channel.tool)")
                    return .tools([target])
                }
            case .ambiguous(let channels):
                Log.router.debug("FM communication ambiguous: \(channels.map(\.tool))")
                return .requiresDisambiguation(choices: channels.map(\.tool))
            case .notCommunication:
                break
            }
        }

        // Contacts → WebSearch: input is about searching for information, not contacts
        if fmTool.name == "contacts" {
            if words.intersection(Self._contactIndicators).isEmpty {
                if let webSearch = fmTools.first(where: { $0.name == ToolNames.webSearch }) {
                    Log.router.debug("Heuristic override: Contacts → WebSearch (no contact indicators)")
                    return .fmTools([webSearch])
                }
            }
        }

        return decision
    }

    // MARK: - LLM Location Check

    /// Uses a short LLM call to determine if a query routed to web_search
    /// is actually a location/place query that should go to Maps.
    func llmLocationCheck(input: String, maps: any FMToolDescriptor) async -> RoutingResult? {
        let prompt = """
        Is this a query about finding a physical place, location, or business nearby? Answer ONLY "maps" or "web_search".
        - "maps" = finding/navigating to places, restaurants, stores, directions, nearby businesses
        - "web_search" = looking up information, facts, how-to, news, people, concepts
        Query: \(input)
        """

        do {
            let answer: String
            if let responder = llmResponder {
                answer = try await responder(input, prompt)
            } else {
                answer = try await LLMAdapter.shared.generateWithInstructions(prompt: input, instructions: prompt)
            }

            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.contains("maps") {
                Log.router.debug("LLM location check: WebSearch → Maps")
                return .fmTools([maps])
            }
        } catch {
            Log.router.error("LLM location check failed: \(error)")
        }

        return nil
    }
}
