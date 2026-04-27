import Foundation

/// Centralized registry of tool slots. Maps tool names to their declared slots.
///
/// Prefix lists for location and query slots are read from ToolManifest.json,
/// eliminating duplication. Custom extraction logic (regex, NER, special parsing)
/// stays as inline closures here.
public enum ToolSlotRegistry {

    /// All known tool→slots mappings, keyed by tool name (as registered in ToolRegistry).
    public static let slots: [String: [ToolSlot]] = [

        // MARK: - Location-Aware Tools

        "Weather": [
            ToolSlot(name: "location", type: .location, extractor: SlotExtractors.manifestLocation(toolName: "Weather")),
            ToolSlot(name: "date", type: .date, extractor: SlotExtractors.date),
        ],

        "Time": [
            ToolSlot(name: "location", type: .location, extractor: SlotExtractors.manifestLocation(toolName: "Time")),
        ],

        "Maps": [
            ToolSlot(name: "destination", type: .location, extractor: SlotExtractors.manifestLocation(toolName: "Maps")),
            ToolSlot(name: "origin", type: .location, extractor: { input, entities in
                let lower = input.lowercased()
                guard let fromRange = lower.range(of: "from ") else { return nil }
                let after = String(input[fromRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let toRange = after.lowercased().range(of: " to ") {
                    return String(after[after.startIndex..<toRange.lowerBound])
                }
                return after.isEmpty ? nil : after
            }),
        ],

        // Note: FM MapsTool ("maps") is defined but not registered in ToolRegistry.
        // Core MapsCoreTool ("Maps") handles map queries. Slots defined above.

        "News": [
            ToolSlot(name: "topic", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "News")),
        ],

        // MARK: - Entity-Specific Tools

        "Stocks": [
            ToolSlot(name: "ticker", type: .entity, extractor: SlotExtractors.ticker),
            ToolSlot(name: "company", type: .query, extractor: { _, entities in
                entities?.organizations.first
            }),
        ],

        "ReadEmail": [
            ToolSlot(name: "sender", type: .person, extractor: SlotExtractors.person),
            ToolSlot(name: "query", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "ReadEmail")),
            ToolSlot(name: "count", type: .number, extractor: SlotExtractors.number),
        ],

        "Email": [
            ToolSlot(name: "recipient", type: .person, extractor: SlotExtractors.person),
            ToolSlot(name: "subject", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "Email")),
        ],

        // MARK: - Text/Language Tools

        "Translate": [
            ToolSlot(name: "targetLanguage", type: .entity, extractor: { input, _ in
                // Language list lives in Resources/Config/TranslateLanguages.json —
                // shared with TranslateTool and kept out of source code per convention.
                let languages = ConfigLoader.loadStringArray("TranslateLanguages")
                let lower = input.lowercased()
                for lang in languages {
                    if lower.contains(lang) { return lang }
                }
                return nil
            }),
            ToolSlot(name: "text", type: .query, extractor: SlotExtractors.query),
        ],

        "Dictionary": [
            ToolSlot(name: "word", type: .query, extractor: { input, _ in
                let prefixes = ToolManifest.prefixes(for: "Dictionary")
                let lower = input.lowercased()
                for prefix in prefixes {
                    if lower.hasPrefix(prefix) {
                        let remainder = String(input.dropFirst(prefix.count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: " mean", with: "")
                            .trimmingCharacters(in: .punctuationCharacters)
                        if !remainder.isEmpty { return remainder }
                    }
                }
                // Fallback: single word input
                let words = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if words.count == 1 { return words.first }
                return nil
            }),
        ],

        // MARK: - Numeric Tools

        "Convert": [
            ToolSlot(name: "value", type: .number, extractor: SlotExtractors.number),
            ToolSlot(name: "fromUnit", type: .unit, extractor: { input, _ in
                let units = ["miles", "km", "kilometers", "feet", "meters", "inches", "yards",
                             "pounds", "kg", "kilograms", "oz", "ounces", "grams", "liters",
                             "gallons", "cups", "ml", "celsius", "fahrenheit", "usd", "eur",
                             "gbp", "jpy", "bitcoin", "btc"]
                let words = input.wordTokenSet
                return units.first { words.contains($0) }
            }),
        ],

        "Calculator": [
            ToolSlot(name: "expression", type: .query, extractor: { input, _ in
                let mathChars = CharacterSet(charactersIn: "+-*/^%")
                if input.unicodeScalars.contains(where: { mathChars.contains($0) }) {
                    return input
                }
                return nil
            }),
        ],

        "Timer": [
            ToolSlot(name: "duration", type: .time, extractor: { input, _ in
                let pattern = try? NSRegularExpression(pattern: "(\\d+)\\s*(minutes?|mins?|seconds?|secs?|hours?|hrs?)")
                let range = NSRange(input.startIndex..<input.endIndex, in: input)
                if let match = pattern?.firstMatch(in: input, options: [], range: range) {
                    return (input as NSString).substring(with: match.range)
                }
                return nil
            }),
        ],

        // MARK: - Search/Query Tools

        "Research": [
            ToolSlot(name: "topic", type: .query, extractor: SlotExtractors.manifestPrefixStripOrInput(toolName: "Research")),
        ],

        "web_search": [
            ToolSlot(name: "query", type: .query, extractor: SlotExtractors.manifestPrefixStripOrInput(toolName: "web_search")),
        ],

        "WikipediaSearch": [
            ToolSlot(name: "topic", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "WikipediaSearch")),
        ],

        // MARK: - Media Tools

        "Podcast": [
            ToolSlot(name: "query", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "Podcast")),
        ],

        "Create": [
            ToolSlot(name: "prompt", type: .query, extractor: SlotExtractors.manifestPrefixStripOrInput(toolName: "Create")),
        ],

        // MARK: - People-Centric Tools

        "Contacts": [
            ToolSlot(name: "name", type: .person, extractor: SlotExtractors.person),
        ],

        "Messages": [
            ToolSlot(name: "recipient", type: .person, extractor: SlotExtractors.person),
            ToolSlot(name: "body", type: .query, extractor: { input, _ in
                if let colonIdx = input.firstIndex(of: ":") {
                    let after = String(input[input.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return after.isEmpty ? nil : after
                }
                return nil
            }),
        ],

        // MARK: - File Tools

        "read_file": [
            ToolSlot(name: "path", type: .entity, extractor: { input, _ in
                let lower = input.lowercased()
                let pathPatterns = ["~/", "/users/", "/tmp/", "/var/"]
                for pattern in pathPatterns {
                    if let range = lower.range(of: pattern) {
                        let pathStart = input[range.lowerBound...]
                        let path = String(pathStart.prefix(while: { !$0.isWhitespace }))
                        return path.isEmpty ? nil : path
                    }
                }
                let words = input.components(separatedBy: .whitespaces)
                for word in words {
                    let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                    if cleaned.contains(".") && cleaned.count > 2 {
                        let ext = (cleaned as NSString).pathExtension.lowercased()
                        let knownExts = ["txt", "json", "csv", "md", "swift", "py", "pdf", "html", "xml", "yaml", "yml", "log"]
                        if knownExts.contains(ext) { return cleaned }
                    }
                }
                return nil
            }),
        ],

        // MARK: - System Tools

        "system_control": [
            ToolSlot(name: "appName", type: .entity, extractor: { input, _ in
                let prefixes = ToolManifest.prefixes(for: "system_control")
                let lower = input.lowercased()
                for prefix in prefixes {
                    if lower.hasPrefix(prefix) {
                        let remainder = String(input.dropFirst(prefix.count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: " app", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !remainder.isEmpty { return remainder }
                    }
                }
                return nil
            }),
        ],

        // MARK: - Random Tool

        "Random": [
            ToolSlot(name: "type", type: .entity, extractor: { input, _ in
                let lower = input.lowercased()
                if lower.contains("coin") || lower.contains("heads") || lower.contains("tails") { return "coin" }
                if lower.contains("dice") || lower.contains("d20") || lower.contains("d6") { return "dice" }
                if lower.contains("card") { return "card" }
                if lower.contains("number") { return "number" }
                if lower.contains("date") { return "date" }
                if lower.contains("color") || lower.contains("colour") { return "color" }
                return nil
            }),
            ToolSlot(name: "range", type: .number, extractor: SlotExtractors.number),
        ],

        // MARK: - Reminder/Calendar Tools

        "Reminders": [
            ToolSlot(name: "text", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "Reminders")),
            ToolSlot(name: "date", type: .date, extractor: SlotExtractors.date),
        ],

        "CalendarEvent": [
            ToolSlot(name: "date", type: .date, extractor: SlotExtractors.date),
            ToolSlot(name: "title", type: .query, extractor: SlotExtractors.manifestPrefixStrip(toolName: "CalendarEvent")),
        ],
    ]

    /// Look up slots for a tool by name.
    public static func slotsForTool(named name: String) -> [ToolSlot] {
        slots[name] ?? []
    }

    /// Check if a tool has any declared slots.
    public static func hasSlots(toolNamed name: String) -> Bool {
        guard let toolSlots = slots[name] else { return false }
        return !toolSlots.isEmpty
    }

    /// All tool names that have slot declarations.
    public static var toolsWithSlots: [String] {
        Array(slots.keys)
    }
}
