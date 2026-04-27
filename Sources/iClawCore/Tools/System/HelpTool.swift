import Foundation
import NaturalLanguage

/// Pseudo-tool that returns interactive help content about iClaw's capabilities.
/// Accessible via `#help` chip, natural language ("what can you do?"), or drill-down
/// from suggestion pills. Returns widgets for visual exploration and suggestedQueries
/// for interactive follow-up.
public struct HelpTool: CoreTool, Sendable {
    public let name = "Help"
    public let schema = "help what can you do features capabilities tools commands chips how to use guide tutorial iclaw about yourself who are you"
    public let isInternal = false
    public let category = CategoryEnum.offline

    public init() {}

    // MARK: - Topic Classification

    /// Help topics dispatched via embedding similarity, not string matching.
    enum HelpTopic: String, CaseIterable {
        case identity     // "who are you", "about iclaw"
        case overview     // "what can you do", "help" (default)
        case category     // "tell me about live tools", "search tools"
        case tool         // "tool:<Name>" (set by router)
        case tour         // "give me a tour", "tutorial", "walkthrough"
        case tourStep     // "tour:2" (internal routing)
        case modes        // "what modes are available"
        case chips        // "how do chips work"
        case limitations  // "what can't you do"
        case settings     // "help with settings"
        case search       // "search capabilities"

        /// Seed phrases for embedding-based classification.
        var seeds: [String] {
            switch self {
            case .identity: return ["who are you", "about iclaw", "what is this app", "introduce yourself"]
            case .overview: return ["what can you do", "help", "capabilities", "features", "what do you offer"]
            case .category: return ["tell me about the tools", "what tools are in", "explore category"]
            case .tool: return []  // Handled by structured prefix, not embedding
            case .tour: return ["give me a tour", "tutorial", "walkthrough", "show me around", "guided tour"]
            case .tourStep: return []  // Handled by structured prefix
            case .modes: return ["what modes are available", "modes", "research mode", "multi-turn sessions"]
            case .chips: return ["how do chips work", "what are chips", "hashtag commands", "chip system"]
            case .limitations: return ["what can't you do", "limitations", "what are you unable to do", "what doesn't work"]
            case .settings: return ["settings", "configuration", "preferences", "customize"]
            case .search: return ["search capabilities", "web search", "how to search"]
            }
        }
    }

    /// Pre-computed seed vectors for embedding-based topic classification.
    private static let topicVectors: [(HelpTopic, [Double])] = {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }
        var results: [(HelpTopic, [Double])] = []
        for topic in HelpTopic.allCases {
            for seed in topic.seeds {
                if let vec = model.vector(for: seed) {
                    results.append((topic, vec))
                }
            }
        }
        return results
    }()

    /// Classify input to a help topic using embedding similarity.
    private func classifyTopic(_ input: String) -> HelpTopic {
        let lowered = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Structured prefixes (from router or tour navigation)
        if lowered.hasPrefix("tool:") { return .tool }
        if lowered.hasPrefix("tour:") { return .tourStep }
        if lowered.contains("iclaw") || lowered.contains("i-claw") { return .identity }

        // Check if input names a category (e.g., "live", "math", "search tools")
        if matchCategory(lowered) != nil { return .category }

        // Keyword-based fast path (works without NLEmbedding)
        // Check if the input contains a distinctive keyword from any topic's seeds
        let keywordMap: [(topic: HelpTopic, keywords: [String])] = [
            (.modes, ["modes", "multi-turn"]),
            (.chips, ["chips", "hashtag", "chip"]),
            (.limitations, ["limitations", "unable", "can't do"]),
            (.settings, ["settings", "configuration", "preferences"]),
            (.search, ["search capabilities", "duckduckgo", "brave search", "help search"]),
            (.identity, ["who are you", "about yourself", "introduce yourself"]),
            (.tour, ["tour", "tutorial", "walkthrough"]),
        ]
        for (topic, keywords) in keywordMap {
            if keywords.contains(where: { lowered.contains($0) }) { return topic }
        }

        // Embedding-based classification. Seed vectors are English by
        // design (help topic names are internal product terms), so the
        // seed side uses English. The input side uses the user's language
        // so the embedding space for the input at least matches what the
        // user typed. Mismatched spaces produce lower similarity scores;
        // the `bestSim` threshold handles that naturally.
        let inputLang = LocalizedEmbedding.detectLanguage(from: lowered) ?? .english
        guard let model = LocalizedEmbedding.sentenceEmbeddingSync(forLanguage: inputLang),
              let inputVec = model.vector(for: lowered) else {
            return .overview
        }

        var bestTopic: HelpTopic = .overview
        var bestSim: Double = 0.0

        for (topic, seedVec) in Self.topicVectors {
            let sim = VectorMath.cosineSimilarity(inputVec, seedVec)
            if sim > bestSim {
                bestSim = sim
                bestTopic = topic
            }
        }

        // Require reasonable confidence; fall back to overview
        return bestSim > 0.75 ? bestTopic : .overview
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        let topic = classifyTopic(input)

        switch topic {
        case .identity:
            return identityHelp()
        case .overview:
            return overviewHelp()
        case .category:
            return categoryHelp(input)
        case .tool:
            let toolName = String(input.dropFirst(5))
            return toolSpecificHelp(toolName)
        case .tour:
            return tourStep(1)
        case .tourStep:
            let step = Int(String(input.dropFirst(5))) ?? 1
            return tourStep(step)
        case .modes:
            return modesHelp()
        case .chips:
            return chipsHelp()
        case .limitations:
            return limitationsHelp()
        case .settings:
            return settingsHelp()
        case .search:
            return searchHelp()
        }
    }

    // MARK: - Category Matching

    /// Match input to a tool category by name or chip.
    private func matchCategory(_ lowered: String) -> ToolCategory? {
        // Strip common filler words
        let cleaned = lowered
            .replacingOccurrences(of: "tell me about ", with: "")
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " tools", with: "")
            .replacingOccurrences(of: " category", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ToolCategoryRegistry.categories.first { cat in
            cat.name.lowercased() == cleaned
            || cat.chipName.lowercased() == cleaned
            || cat.chipAliases.contains(where: { $0.lowercased() == cleaned })
        }
    }

    // MARK: - Help Content Generators

    private func identityHelp() -> ToolIO {
        let text = """
        [HELP] iClaw is a native macOS AI assistant running entirely on-device via Apple Intelligence. \
        No data leaves the Mac. It lives in the menu bar as a floating HUD. \
        Type naturally and iClaw routes to the right tool using an ML classifier.
        """
        return ToolIO(
            text: text, status: .ok,
            isVerifiedData: true,
            suggestedQueries: [
                String(localized: "help_suggestion_capabilities", bundle: .iClawCore),
                String(localized: "help_suggestion_tour", bundle: .iClawCore),
                String(localized: "help_suggestion_limitations", bundle: .iClawCore),
            ]
        )
    }

    private func overviewHelp() -> ToolIO {
        let usedTools = Set(UserDefaults.standard.stringArray(forKey: "greetingUsedTools") ?? [])
        let disabledTools = ToolRegistry.loadDisabledToolNamesPublic()

        var categories = ToolCategoryRegistry.categories
            .filter { $0.name != "Help" }
            .filter { cat in
                // Hide categories where all tools are disabled
                cat.coreToolNames.contains(where: { !disabledTools.contains($0) })
            }
            .map { cat in
                let explored = cat.coreToolNames.contains(where: { usedTools.contains($0) })
                return HelpOverviewWidgetData.CategoryCard(
                    id: cat.chipName,
                    name: cat.name,
                    chipName: cat.chipName,
                    icon: cat.icon,
                    description: Self.categoryDescriptions[cat.chipName] ?? "",
                    isExplored: explored
                )
            }

        // Shuffle so the grid doesn't always show the same order
        categories.shuffle()

        let widgetData = HelpOverviewWidgetData(categories: categories)

        return ToolIO(
            text: "[HELP] Here's what I can help with. The widget below shows all tool categories. Briefly introduce them.",
            status: .ok,
            outputWidget: "HelpOverviewWidget",
            widgetData: widgetData,
            isVerifiedData: true,
            suggestedQueries: [
                String(localized: "help_suggestion_tour", bundle: .iClawCore),
                String(localized: "help_suggestion_modes", bundle: .iClawCore),
                String(localized: "help_suggestion_limitations", bundle: .iClawCore),
            ]
        )
    }

    private func categoryHelp(_ input: String) -> ToolIO {
        let lowered = input.lowercased()
        guard let category = matchCategory(lowered) else {
            return overviewHelp()
        }

        let disabledTools = ToolRegistry.loadDisabledToolNamesPublic()
        let tools = category.coreToolNames
            .filter { !disabledTools.contains($0) }
            .compactMap { toolName -> HelpCategoryWidgetData.ToolCard? in
            let help = ToolHelpProvider.help(for: toolName)
            let manifest = ToolManifest.entry(for: toolName)
            let displayName = manifest?.displayName ?? toolName
            let icon = manifest?.icon ?? "questionmark.circle"
            return HelpCategoryWidgetData.ToolCard(
                id: toolName,
                name: toolName,
                displayName: displayName,
                icon: icon,
                description: help?.description ?? "",
                exampleQuery: help?.examples.first ?? toolName.lowercased()
            )
        }

        let widgetData = HelpCategoryWidgetData(
            categoryName: category.name,
            categoryIcon: category.icon,
            tools: tools
        )

        // Suggest unexplored categories
        let usedTools = Set(UserDefaults.standard.stringArray(forKey: "greetingUsedTools") ?? [])
        let otherCategories = ToolCategoryRegistry.categories.filter { cat in
            cat.name != category.name && cat.name != "Help"
            && !cat.coreToolNames.contains(where: { usedTools.contains($0) })
        }
        var suggestions: [String] = []
        if let other = otherCategories.first {
            suggestions.append(String(localized: "help_suggestion_explore_category \(other.name)", bundle: .iClawCore))
        }
        suggestions.append(String(localized: "help_suggestion_capabilities", bundle: .iClawCore))

        return ToolIO(
            text: "[HELP] The user wants to explore the \(category.name) category. The widget below shows the tools.",
            status: .ok,
            outputWidget: "HelpCategoryWidget",
            widgetData: widgetData,
            isVerifiedData: true,
            suggestedQueries: suggestions
        )
    }

    private func toolSpecificHelp(_ toolName: String) -> ToolIO {
        // If this is a category name (set by router for category+help), route to category help
        if let _ = ToolCategoryRegistry.categories.first(where: { $0.name == toolName }) {
            return categoryHelp(toolName.lowercased())
        }

        guard let help = ToolHelpProvider.help(for: toolName) else {
            return overviewHelp()
        }

        let entry = ToolManifest.entry(for: toolName)
        let chipNote: String
        if let chip = entry?.chipName {
            chipNote = " — #\(chip)"
        } else {
            chipNote = ""
        }

        let examplesText = help.examples.map { "• \($0)" }.joined(separator: "\n")

        let text = """
        [HELP] The user is asking how the \(toolName) tool works. Explain this tool to them:

        \(toolName.uppercased())\(chipNote)

        \(help.description)

        EXAMPLE QUERIES:
        \(examplesText)
        """

        // Example queries as try-it suggestions
        return ToolIO(
            text: text, status: .ok,
            suggestedQueries: help.examples
        )
    }

    // MARK: - Tour

    private static let tourTotalSteps = 4

    private func tourStep(_ step: Int) -> ToolIO {
        let clamped = max(1, min(step, Self.tourTotalSteps))

        let (title, body, icon, suggestions): (String, String, String, [String])

        switch clamped {
        case 1:
            title = String(localized: "help_tour_step1_title", bundle: .iClawCore)
            body = String(localized: "help_tour_step1_body", bundle: .iClawCore)
            icon = "text.bubble"
            suggestions = [
                "weather in \(Self.randomCity())",
                String(localized: "help_tour_example_coin", bundle: .iClawCore),
                "what time is it in \(Self.randomCity())",
                "#help tour:2",
            ]
        case 2:
            title = String(localized: "help_tour_step2_title", bundle: .iClawCore)
            body = String(localized: "help_tour_step2_body", bundle: .iClawCore)
            icon = "number"
            suggestions = [
                "#math \(Self.randomMath())",
                "#live \(Self.randomNews())",
                "#help tour:3",
            ]
        case 3:
            title = String(localized: "help_tour_step3_title", bundle: .iClawCore)
            body = String(localized: "help_tour_step3_body", bundle: .iClawCore)
            icon = "arrow.triangle.2.circlepath"
            suggestions = [
                "#research \(Self.randomResearch())",
                "#techsupport my wifi is slow",
                "#help tour:4",
            ]
        default:
            title = String(localized: "help_tour_step4_title", bundle: .iClawCore)
            body = String(localized: "help_tour_step4_body", bundle: .iClawCore)
            icon = "sparkles"
            suggestions = [
                String(localized: "help_suggestion_limitations", bundle: .iClawCore),
                String(localized: "help_suggestion_explore_category \(String(localized: "help_category_search", bundle: .iClawCore))", bundle: .iClawCore),
                Self.randomTicker(),
            ]
        }

        let widgetData = HelpTourStepWidgetData(
            stepNumber: clamped,
            totalSteps: Self.tourTotalSteps,
            title: title,
            body: body,
            icon: icon
        )

        return ToolIO(
            text: "[HELP] Tour step \(clamped) of \(Self.tourTotalSteps): \(title). \(body)",
            status: .ok,
            outputWidget: "HelpTourStepWidget",
            widgetData: widgetData,
            isVerifiedData: true,
            suggestedQueries: suggestions
        )
    }

    // MARK: - Limitations

    private func limitationsHelp() -> ToolIO {
        let widgetData = HelpLimitationsWidgetData(
            limitations: [
                .init(
                    title: String(localized: "help_limit_no_images_title", bundle: .iClawCore),
                    detail: String(localized: "help_limit_no_images_detail", bundle: .iClawCore),
                    icon: "photo.badge.exclamationmark"
                ),
                .init(
                    title: String(localized: "help_limit_no_file_edit_title", bundle: .iClawCore),
                    detail: String(localized: "help_limit_no_file_edit_detail", bundle: .iClawCore),
                    icon: "doc.badge.ellipsis"
                ),
                .init(
                    title: String(localized: "help_limit_offline_title", bundle: .iClawCore),
                    detail: String(localized: "help_limit_offline_detail", bundle: .iClawCore),
                    icon: "wifi.slash"
                ),
                .init(
                    title: String(localized: "help_limit_context_title", bundle: .iClawCore),
                    detail: String(localized: "help_limit_context_detail", bundle: .iClawCore),
                    icon: "text.badge.minus"
                ),
                .init(
                    title: String(localized: "help_limit_no_calls_title", bundle: .iClawCore),
                    detail: String(localized: "help_limit_no_calls_detail", bundle: .iClawCore),
                    icon: "phone.badge.xmark"
                ),
            ],
            strengths: [
                .init(title: String(localized: "help_strength_private", bundle: .iClawCore), icon: "lock.shield"),
                .init(title: String(localized: "help_strength_fast", bundle: .iClawCore), icon: "bolt"),
                .init(title: String(localized: "help_strength_free", bundle: .iClawCore), icon: "infinity"),
            ]
        )

        return ToolIO(
            text: "[HELP] iClaw's limitations: no image generation (analysis only), no file editing yet, " +
                "weather/stocks/news/search need internet, focused questions work best (4K token context), " +
                "no phone calls or FaceTime. Strengths: fully private (on-device), fast, free, no rate limits. " +
                "The widget below shows details.",
            status: .ok,
            outputWidget: "HelpLimitationsWidget",
            widgetData: widgetData,
            isVerifiedData: true,
            suggestedQueries: [
                String(localized: "help_suggestion_capabilities", bundle: .iClawCore),
                String(localized: "help_suggestion_tour", bundle: .iClawCore),
            ]
        )
    }

    // MARK: - Modes, Chips, Search, Settings (text-based with suggestions)

    private func modesHelp() -> ToolIO {
        let text = """
        [HELP] MODES — multi-turn focused sessions:

        #research — Deep research with web search, Wikipedia, and page fetching. Exit: "done researching"
        #rewrite — Text editing. Paste text and iterate. Exit: "looks good"
        #rubberduck — Rubber duck debugging. Reflects thinking, asks clarifying questions. Exit: "done thinking"
        #techsupport — Interactive Mac diagnostics. Checks Wi-Fi, battery, storage. Exit: "problem solved"
        #automate — Design AppleScript automations step by step. Exit: "done automating"

        Modes restrict available tools to their domain and group messages into collapsible threads.
        """
        return ToolIO(
            text: text, status: .ok,
            isVerifiedData: true,
            suggestedQueries: [
                "#research \(Self.randomResearch())",
                "#techsupport my wifi is slow",
                String(localized: "help_suggestion_capabilities", bundle: .iClawCore),
            ]
        )
    }

    private func chipsHelp() -> ToolIO {
        let text = """
        [HELP] CHIPS — category-based routing via #name:

        #math — arithmetic, conversion, statistics
        #live — weather, stocks, news, podcasts
        #search — web search, Wikipedia, deep research
        #util — translate, dictionary, transcribe
        #schedule — calendar, timers, daily briefing
        #system — device info, diagnostics
        #email — compose or read email

        Type # in the input field to see autocomplete. Old tool names still work as aliases.
        """
        return ToolIO(
            text: text, status: .ok,
            isVerifiedData: true,
            suggestedQueries: [
                "#math \(Self.randomMath())",
                "#live weather in \(Self.randomCity())",
                String(localized: "help_suggestion_modes", bundle: .iClawCore),
            ]
        )
    }

    private func searchHelp() -> ToolIO {
        let text = """
        [HELP] SEARCH CAPABILITIES:

        Web Search — DuckDuckGo, Brave, Google fallbacks. "search for..." or #search.
        Wikipedia — Direct article lookup. "wiki [topic]" or #wiki.
        Research Mode — Multi-step search with synthesis. #research for deep dives.
        Web Fetch — Read any URL. Paste a link.
        News — 17 RSS sources (BBC, Reuters, Ars Technica). #news or "latest tech news".
        """
        return ToolIO(
            text: text, status: .ok,
            isVerifiedData: true,
            suggestedQueries: [
                "search for best Mac apps 2025",
                "wiki \(Self.randomWiki())",
                "#research \(Self.randomResearch())",
            ]
        )
    }

    private func settingsHelp() -> ToolIO {
        let text = """
        [HELP] SETTINGS — accessible via the gear icon or Cmd+,:

        General: Personality level, Browser Bridge, auto-approve actions.
        Permissions: Privacy permissions and default location fallback.
        History: Memory count, database size, clear conversations.
        Automations: Scheduled recurring queries.
        About: Version info and links.
        """
        return ToolIO(
            text: text, status: .ok,
            isVerifiedData: true,
            suggestedQueries: [
                String(localized: "help_suggestion_capabilities", bundle: .iClawCore),
                String(localized: "help_suggestion_tour", bundle: .iClawCore),
            ]
        )
    }

    // MARK: - Slot Filling

    /// Pools of varied values for common slots, so examples don't always show
    /// the same city/ticker/topic. Picks a random element each time.
    private static let cities = ["London", "Tokyo", "Paris", "Berlin", "Sydney", "Toronto", "Seoul", "Rome"]
    private static let tickers = ["$AAPL", "$TSLA", "$MSFT", "$GOOG", "$AMZN", "$NFLX", "$META"]
    private static let wikiTopics = ["Alan Turing", "black holes", "photosynthesis", "the Roman Empire", "Marie Curie"]
    private static let researchTopics = ["quantum computing", "climate policy", "gene therapy", "fusion energy"]
    private static let mathExamples = ["15% tip on $86", "sqrt(144) + 3^2", "72°F to celsius", "sin(45 degrees)"]
    private static let newsTopics = ["latest tech news", "AI news", "space news", "science headlines"]

    private static func randomCity() -> String { cities.randomElement()! }
    private static func randomTicker() -> String { tickers.randomElement()! }
    private static func randomWiki() -> String { wikiTopics.randomElement()! }
    private static func randomResearch() -> String { researchTopics.randomElement()! }
    private static func randomMath() -> String { mathExamples.randomElement()! }
    private static func randomNews() -> String { newsTopics.randomElement()! }

    // MARK: - Static Data

    /// Short descriptions for each category, used in the overview widget.
    private static let categoryDescriptions: [String: String] = [
        "math": String(localized: "help_cat_math", bundle: .iClawCore),
        "live": String(localized: "help_cat_live", bundle: .iClawCore),
        "search": String(localized: "help_cat_search", bundle: .iClawCore),
        "util": String(localized: "help_cat_util", bundle: .iClawCore),
        "schedule": String(localized: "help_cat_schedule", bundle: .iClawCore),
        "system": String(localized: "help_cat_system", bundle: .iClawCore),
        "email": String(localized: "help_cat_email", bundle: .iClawCore),
        "automate": String(localized: "help_cat_automate", bundle: .iClawCore),
    ]
}
