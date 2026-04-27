import Foundation

extension GreetingManager {
    // MARK: - Phase 2: Dynamic Tool Tip Card

    /// Example queries for tools, used in the "Try it" button.
    private static let toolExamples: [String: (query: String, icon: String)] = [
        "Weather": ("What's the weather in Tokyo?", "cloud.sun"),
        "Time": ("What time is it in London?", "clock"),
        "Calendar": ("What day is Christmas this year?", "calendar"),
        "Calculator": ("What's 15% tip on $85?", "function"),
        "Convert": ("Convert 100 miles to kilometers", "arrow.left.arrow.right"),
        "Random": ("Roll a d20", "dice"),
        "Stocks": ("$AAPL stock price", "chart.line.uptrend.xyaxis"),
        "Maps": ("Coffee shops near me", "map"),
        "News": ("Latest tech news", "newspaper"),
        "WikipediaSearch": ("Tell me about Marie Curie", "book.closed"),
        "Research": ("Research quantum computing", "magnifyingglass"),
        "Translate": ("Translate hello to Japanese", "globe"),
        "Podcast": ("Find a podcast about history", "headphones"),
        "Dictionary": ("Define serendipity", "text.book.closed"),
        "SystemInfo": ("What's my battery level?", "info.circle"),
        "Screenshot": ("Take a screenshot", "camera.viewfinder"),
    ]

    // MARK: - Tool Usage Tracking

    private static let usedToolsKey = "greetingUsedTools"

    /// Records that the user has used a tool (called by ExecutionEngine after successful execution).
    public static func recordToolUsage(_ toolName: String) {
        var used = Set(UserDefaults.standard.stringArray(forKey: usedToolsKey) ?? [])
        guard !used.contains(toolName) else { return }
        used.insert(toolName)
        UserDefaults.standard.set(Array(used), forKey: usedToolsKey)
    }

    /// Returns set of tool names the user has already used.
    private static var usedToolNames: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: usedToolsKey) ?? [])
    }

    // MARK: - Settings Feature Tips

    /// Tips that surface settings/features the user may not know about.
    /// Each tip has a text, icon, settings tab to open, and a button label.
    private static let settingsTips: [(text: String, icon: String, tab: SettingsTab, buttonLabel: String)] = [
        ("iClaw can read pages from Safari in real-time.", "safari", .general, "See Browser Bridge"),
        ("Customize iClaw's personality — make it formal, playful, or anything in between.", "theatermasks", .general, "Open Personality"),
        ("Set up recurring queries that run on a schedule.", "clock.arrow.2.circlepath", .automations, "See Automations"),
        ("Drop skill files into iClaw to teach it new tricks.", "doc.badge.gearshape", .skills, "Browse Skills"),
        ("Choose which apps iClaw can access.", "lock.shield", .permissions, "Review Permissions"),
        ("Get notified when iClaw has proactive updates for you.", "bell.badge", .notifications, "Notification Settings"),
        ("Auto-approve safe actions to skip permission prompts.", "checkmark.shield", .general, "See Auto-Approve"),
    ]

    /// Generates a tool discovery tip card with an example query.
    /// Prefers tools the user hasn't used yet. ~30% of the time, shows a settings tip instead.
    func generateTipCard() async -> ToolTipCardData? {
        // ~30% chance of a settings/feature tip instead of a tool tip
        if Int.random(in: 0..<10) < 3, let settingsTip = Self.settingsTips.randomElement() {
            return ToolTipCardData(
                toolName: settingsTip.tab.rawValue,
                tipText: settingsTip.text,
                exampleQuery: settingsTip.buttonLabel,
                icon: settingsTip.icon,
                settingsTab: settingsTip.tab
            )
        }

        let allTools = ToolRegistry.coreTools
            .filter { !$0.isInternal && ToolManifest.showsInUI(for: $0.name) }

        let usedNames = Self.usedToolNames
        // Prefer tools the user hasn't used yet; fall back to all if everything's been used
        let undiscovered = allTools.filter { !usedNames.contains($0.name) }
        let candidates = undiscovered.isEmpty ? allTools : undiscovered

        guard let tool = candidates.randomElement() else { return nil }

        let example = Self.toolExamples[tool.name]
        let icon = example?.icon ?? ToolManifest.icon(for: tool.name)
        let exampleQuery = example?.query ?? "#\(tool.name.lowercased())"

        let prompt = """
        Write a single casual tip (under 15 words) about this tool: \(tool.name) — \(tool.schema).
        Make it sound like a friendly discovery, not a manual.
        Terse, no filler. No quotes.
        """

        do {
            let text = try await LLMAdapter.shared.generateText(prompt, profile: .toolTip)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !text.isEmpty {
                return ToolTipCardData(
                    toolName: tool.name,
                    tipText: text,
                    exampleQuery: exampleQuery,
                    icon: icon
                )
            }
        } catch {
            Log.tools.debug("LLM tip card failed: \(error)")
        }

        // Fallback: static tip
        return ToolTipCardData(
            toolName: tool.name,
            tipText: "Try the \(tool.name) tool — it's built right in.",
            exampleQuery: exampleQuery,
            icon: icon
        )
    }

    // MARK: - Phase 3: Predicted Repeat

    func generatePredictedRepeat() async -> (text: String, widgetType: String?, widgetData: (any Sendable)?)? {
        let recentInputs = await DatabaseManager.shared.recentUserInputs(limit: 5)
        guard recentInputs.count >= 3 else { return nil }

        let numbered = recentInputs.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let prompt = """
        Which of these requests is most likely repeated regularly? Return ONLY the request text, or NONE.
        Requests:
        \(numbered)
        """

        do {
            let result = try await LLMAdapter.shared.generateText(prompt)

            guard !result.isEmpty,
                  result.uppercased() != "NONE",
                  result.count > 2 else { return nil }

            // Route the input to identify which tool would handle it, then
            // skip anything with side effects (consent-gated tools, audio playback, etc.).
            // This avoids hardcoding English verbs and instead checks the tool's actual policy.
            if await isSideEffecting(input: result) {
                return nil
            }

            // Run through ExecutionEngine with timeout (skipConsent: never prompt during greeting)
            let engineResult = await withTaskTimeout(seconds: 5) {
                await ExecutionEngine.shared.run(input: result, skipConsent: true)
            }

            guard let engineResult else { return nil }
            return (engineResult.text, engineResult.widgetType, engineResult.widgetData)
        } catch {
            Log.tools.debug("Predicted repeat failed: \(error)")
            return nil
        }
    }
}
