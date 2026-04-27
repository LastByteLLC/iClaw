import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Tint

public enum WidgetTint: String, Sendable, Codable, CaseIterable {
    case blue, green, orange, red, purple, yellow, mint, indigo, teal
}

// MARK: - Sub-Structs

public struct HeaderBlock: Sendable, Codable, Equatable {
    public let icon: String
    public let title: String
    public let subtitle: String?
    public let badge: String?

    public init(icon: String, title: String, subtitle: String? = nil, badge: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
    }
}

public struct ImageBlock: Sendable, Codable, Equatable {
    public let url: String
    public let caption: String?
    public let maxHeight: CGFloat?

    public init(url: String, caption: String? = nil, maxHeight: CGFloat? = nil) {
        self.url = url
        self.caption = caption
        self.maxHeight = maxHeight
    }

    static let defaultMaxHeight: CGFloat = 200
}

public struct StatBlock: Sendable, Codable, Equatable {
    public let value: String
    public let label: String?
    public let icon: String?
    public let unit: String?

    public init(value: String, label: String? = nil, icon: String? = nil, unit: String? = nil) {
        self.value = value
        self.label = label
        self.icon = icon
        self.unit = unit
    }
}

public struct StatRowBlock: Sendable, Codable, Equatable {
    public let items: [StatBlock]

    public init(items: [StatBlock]) {
        self.items = items
    }
}

public struct KeyValuePair: Sendable, Codable, Equatable {
    public let key: String
    public let value: String
    public let icon: String?

    public init(key: String, value: String, icon: String? = nil) {
        self.key = key
        self.value = value
        self.icon = icon
    }
}

public struct KeyValueBlock: Sendable, Codable, Equatable {
    public let pairs: [KeyValuePair]

    public init(pairs: [KeyValuePair]) {
        self.pairs = pairs
    }
}

public struct ListItem: Sendable, Codable, Equatable {
    public let icon: String?
    public let title: String
    public let subtitle: String?
    public let trailing: String?
    public let url: String?

    public init(icon: String? = nil, title: String, subtitle: String? = nil, trailing: String? = nil, url: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.url = url
    }
}

public struct ItemListBlock: Sendable, Codable, Equatable {
    public let items: [ListItem]

    public init(items: [ListItem]) {
        self.items = items
    }
}

public struct Chip: Sendable, Codable, Equatable {
    public let label: String
    public let icon: String?
    public let url: String?

    public init(label: String, icon: String? = nil, url: String? = nil) {
        self.label = label
        self.icon = icon
        self.url = url
    }
}

public struct ChipRowBlock: Sendable, Codable, Equatable {
    public let chips: [Chip]

    public init(chips: [Chip]) {
        self.chips = chips
    }
}

public enum TextBlockStyle: String, Sendable, Codable, Equatable {
    case body, caption, footnote
}

public struct TextBlock: Sendable, Codable, Equatable {
    public let content: String
    public let style: TextBlockStyle

    public init(content: String, style: TextBlockStyle = .body) {
        self.content = content
        self.style = style
    }
}

public struct TableBlock: Sendable, Codable, Equatable {
    public let headers: [String]
    public let rows: [[String]]
    public let caption: String?

    public init(headers: [String], rows: [[String]], caption: String? = nil) {
        self.headers = headers
        self.rows = rows
        self.caption = caption
    }
}

public struct ProgressBlock: Sendable, Codable, Equatable {
    public let value: Double
    public let label: String?
    public let total: String?

    public init(value: Double, label: String? = nil, total: String? = nil) {
        self.value = value
        self.label = label
        self.total = total
    }
}

// MARK: - WidgetBlock

public enum WidgetBlock: Sendable, Codable, Equatable {
    case header(HeaderBlock)
    case image(ImageBlock)
    case stat(StatBlock)
    case statRow(StatRowBlock)
    case keyValue(KeyValueBlock)
    case itemList(ItemListBlock)
    case chipRow(ChipRowBlock)
    case text(TextBlock)
    case divider
    case table(TableBlock)
    case progress(ProgressBlock)
}

// MARK: - DynamicWidgetData

public struct DynamicWidgetData: Sendable, Codable, Equatable {
    public let blocks: [WidgetBlock]
    public let tint: WidgetTint?

    static let maxBlocks = 10
    static let maxListItems = 8
    static let maxTableRows = 8
    static let maxChips = 8
    static let maxStatRowItems = 4

    public init(blocks: [WidgetBlock], tint: WidgetTint? = nil) {
        self.blocks = blocks
        self.tint = tint
    }

    /// Returns a validated copy with safety limits and sanitization enforced.
    public func validated() -> DynamicWidgetData {
        var result: [WidgetBlock] = []

        for block in blocks {
            if result.count >= Self.maxBlocks {
                result.append(.text(TextBlock(content: "\u{2026} truncated", style: .caption)))
                break
            }

            switch block {
            case .header(let h):
                guard !h.title.isEmpty else { continue }
                let icon = Self.validatedSymbol(h.icon)
                result.append(.header(HeaderBlock(icon: icon, title: h.title, subtitle: h.subtitle, badge: h.badge)))

            case .image(let img):
                // Strip placeholder/example URLs
                guard let url = URL(string: img.url),
                      let host = url.host?.lowercased(),
                      !host.contains("example.com"),
                      !host.contains("placeholder"),
                      !host.contains("lorem") else { continue }
                result.append(.image(img))

            case .stat(let s):
                guard !s.value.isEmpty else { continue }
                // Strip placeholder "0" values
                guard s.value != "0" else { continue }
                // Reject stat blocks where value is a title/label, not a number
                let statWords = s.value.split(separator: " ").count
                let statHasDigit = s.value.contains(where: \.isNumber)
                if statWords > 3 && !statHasDigit { continue }
                // Strip markdown formatting from values
                let cleanStatValue = s.value.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
                let icon = s.icon.map { Self.validatedSymbol($0) }
                result.append(.stat(StatBlock(value: cleanStatValue, label: s.label, icon: icon, unit: s.unit)))

            case .statRow(let sr):
                // Filter out placeholder "0" and "unknown" values
                let cleaned = sr.items.filter { !$0.value.isEmpty && $0.value != "0" && $0.value.lowercased() != "unknown" }
                let capped = Array(cleaned.prefix(Self.maxStatRowItems))
                guard !capped.isEmpty else { continue }
                // Reject statRows used as table headers (all text, no digits)
                let allTextOnly = capped.allSatisfy { !$0.value.contains(where: \.isNumber) }
                if allTextOnly { continue }
                // Strip markdown from values
                let sanitized = capped.map { item in
                    StatBlock(value: item.value.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression),
                              label: item.label, icon: item.icon, unit: item.unit)
                }
                // Collapse duplicate statRows: skip if previous block is also a statRow
                if case .statRow = result.last { continue }
                result.append(.statRow(StatRowBlock(items: sanitized)))

            case .keyValue(let kv):
                let filtered = kv.pairs.filter { pair in
                    !pair.key.isEmpty && !pair.value.isEmpty &&
                    pair.value.lowercased() != "unknown" &&
                    pair.value != "0" &&
                    // Strip KV pairs where icon field contains non-symbol values like "tint:blue"
                    !(pair.icon?.hasPrefix("tint:") ?? false)
                }.map { pair in
                    // Clean icons from KV pairs — strip invalid icon values
                    let cleanIcon = pair.icon.flatMap { icon in
                        icon.contains(".") || icon.allSatisfy({ $0.isLetter || $0 == "." }) ? icon : nil
                    }
                    return KeyValuePair(key: pair.key, value: pair.value, icon: cleanIcon)
                }
                guard !filtered.isEmpty else { continue }
                result.append(.keyValue(KeyValueBlock(pairs: filtered)))

            case .itemList(let list):
                let filtered = list.items.filter { item in
                    !item.title.isEmpty &&
                    // Strip list items where subtitle is a tint directive
                    !(item.subtitle?.hasPrefix("tint:") ?? false)
                }
                guard !filtered.isEmpty else { continue }
                if filtered.count > Self.maxListItems {
                    let capped = Array(filtered.prefix(Self.maxListItems))
                    let remaining = filtered.count - Self.maxListItems
                    var items = capped
                    items.append(ListItem(title: "\(remaining) more\u{2026}"))
                    result.append(.itemList(ItemListBlock(items: items)))
                } else {
                    result.append(.itemList(ItemListBlock(items: filtered)))
                }

            case .chipRow(let cr):
                let filtered = cr.chips.filter { !$0.label.isEmpty }
                guard !filtered.isEmpty else { continue }
                let capped = Array(filtered.prefix(Self.maxChips))
                result.append(.chipRow(ChipRowBlock(chips: capped)))

            case .text(let t):
                guard !t.content.isEmpty else { continue }
                result.append(.text(t))

            case .divider:
                // Don't allow consecutive dividers or divider as first/last block
                if result.isEmpty { continue }
                if case .divider = result.last { continue }
                result.append(.divider)

            case .table(let tb):
                guard !tb.headers.isEmpty, !tb.rows.isEmpty else { continue }
                // Filter out rows that are all empty or all "0"
                let cleanRows = tb.rows.filter { row in
                    row.contains { $0 != "0" && !$0.isEmpty && $0.lowercased() != "unknown" }
                }
                guard !cleanRows.isEmpty else { continue }
                let cappedRows = Array(cleanRows.prefix(Self.maxTableRows))
                result.append(.table(TableBlock(headers: tb.headers, rows: cappedRows, caption: tb.caption)))

            case .progress(let p):
                // Strip meaningless progress (exactly 0.5 with no real label)
                if p.value == 0.5 && p.total == nil { continue }
                result.append(.progress(p))
            }
        }

        // Strip trailing divider
        if case .divider = result.last {
            result.removeLast()
        }

        return DynamicWidgetData(blocks: result, tint: tint).hoistTableUnits().qualityFiltered()
    }

    // MARK: - Table Unit Hoisting

    /// Suffix units ordered longest-first so longer matches win over shorter prefixes.
    private static let suffixUnits: [(suffix: String, abbrev: String)] = [
        (" km/h", "km/h"), (" lb-ft", "lb-ft"), (" miles", "mi"), (" inches", "in"),
        (" mph", "mph"), (" mpg", "mpg"), (" kWh", "kWh"),
        (" lbs", "lb"), (" lb", "lb"), (" kg", "kg"), (" hp", "hp"),
        (" ft", "ft"), (" mi", "mi"), (" km", "km"), (" mm", "mm"),
        (" cm", "cm"), (" in", "in"), (" sec", "s"), (" ms", "ms"),
        (" m", "m"), (" s", "s"),
        ("%", "%"), ("\u{00B0}F", "\u{00B0}F"), ("\u{00B0}C", "\u{00B0}C"),
    ]

    /// Prefix units checked in order.
    private static let prefixUnits: [(prefix: String, abbrev: String)] = [
        ("$", "$"), ("\u{00A3}", "\u{00A3}"), ("\u{20AC}", "\u{20AC}"),
    ]

    /// Minimum fraction of non-empty cells that must share a unit for hoisting.
    private static let hoistThreshold = 0.8

    /// Detects shared unit suffixes/prefixes in table columns, hoists them to headers,
    /// and strips them from cell values.
    private func hoistTableUnits() -> DynamicWidgetData {
        let newBlocks = blocks.map { block -> WidgetBlock in
            guard case .table(let tb) = block else { return block }
            guard tb.headers.count >= 2, !tb.rows.isEmpty else { return block }

            var headers = tb.headers
            var rows = tb.rows

            // Process columns starting at index 1 (skip label column)
            for col in 1..<headers.count {
                let cells = rows.compactMap { row -> String? in
                    guard col < row.count else { return nil }
                    let val = row[col].trimmingCharacters(in: .whitespaces)
                    return val.isEmpty ? nil : val
                }
                guard !cells.isEmpty else { continue }

                // Try suffix units
                if let (suffix, abbrev) = Self.detectSuffixUnit(in: cells) {
                    headers[col] = "\(headers[col]) (\(abbrev))"
                    rows = rows.map { row in
                        var r = row
                        guard col < r.count else { return r }
                        let val = r[col].trimmingCharacters(in: .whitespaces)
                        if val.hasSuffix(suffix) {
                            r[col] = String(val.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                        }
                        return r
                    }
                    continue
                }

                // Try prefix units
                if let (prefix, abbrev) = Self.detectPrefixUnit(in: cells) {
                    headers[col] = "\(headers[col]) (\(abbrev))"
                    rows = rows.map { row in
                        var r = row
                        guard col < r.count else { return r }
                        let val = r[col].trimmingCharacters(in: .whitespaces)
                        if val.hasPrefix(prefix) {
                            r[col] = String(val.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                        }
                        return r
                    }
                }
            }

            return .table(TableBlock(headers: headers, rows: rows, caption: tb.caption))
        }

        return DynamicWidgetData(blocks: newBlocks, tint: tint)
    }

    private static func detectSuffixUnit(in cells: [String]) -> (suffix: String, abbrev: String)? {
        for (suffix, abbrev) in suffixUnits {
            let matchCount = cells.filter { $0.hasSuffix(suffix) }.count
            if Double(matchCount) / Double(cells.count) >= hoistThreshold {
                return (suffix, abbrev)
            }
        }
        return nil
    }

    private static func detectPrefixUnit(in cells: [String]) -> (prefix: String, abbrev: String)? {
        for (prefix, abbrev) in prefixUnits {
            let matchCount = cells.filter { $0.hasPrefix(prefix) }.count
            if Double(matchCount) / Double(cells.count) >= hoistThreshold {
                return (prefix, abbrev)
            }
        }
        return nil
    }

    // MARK: - Quality Filter

    private static let placeholderValues: Set<String> = [
        "", "0", "n/a", "not available", "not specified", "unknown", "-",
    ]

    /// Removes low-quality blocks that would produce a useless widget.
    private func qualityFiltered() -> DynamicWidgetData {
        let empty = DynamicWidgetData(blocks: [], tint: tint)

        // (a) Minimum content blocks — at least one block that is not header/divider
        let contentBlocks = blocks.filter { block in
            if case .header = block { return false }
            if case .divider = block { return false }
            return true
        }
        guard !contentBlocks.isEmpty else { return empty }

        // (b) Table quality + (c) Stat quality — filter individual blocks
        var filtered = blocks.filter { block in
            switch block {
            case .table(let tb):
                let allCells = tb.rows.flatMap { $0 }
                guard !allCells.isEmpty else { return false }
                let placeholderCount = allCells.filter {
                    Self.placeholderValues.contains($0.lowercased().trimmingCharacters(in: .whitespaces))
                }.count
                return Double(placeholderCount) / Double(allCells.count) <= 0.5

            case .stat(let s):
                return !Self.placeholderValues.contains(s.value.lowercased().trimmingCharacters(in: .whitespaces))

            default:
                return true
            }
        }

        // Strip trailing divider after filtering
        if case .divider = filtered.last {
            filtered.removeLast()
        }

        // (d) Minimum data content — join all text content, reject if < 50 chars
        var textContent = ""
        for block in filtered {
            switch block {
            case .header(let h):
                textContent += h.title
                textContent += h.subtitle ?? ""
            case .stat(let s):
                textContent += s.value
                textContent += s.label ?? ""
            case .statRow(let sr):
                for item in sr.items {
                    textContent += item.value
                    textContent += item.label ?? ""
                }
            case .keyValue(let kv):
                for pair in kv.pairs {
                    textContent += pair.key
                    textContent += pair.value
                }
            case .itemList(let list):
                for item in list.items {
                    textContent += item.title
                    textContent += item.subtitle ?? ""
                    textContent += item.trailing ?? ""
                }
            case .text(let t):
                textContent += t.content
            case .table(let tb):
                textContent += tb.headers.joined()
                for row in tb.rows { textContent += row.joined() }
            case .chipRow(let cr):
                for chip in cr.chips { textContent += chip.label }
            case .progress(let p):
                textContent += p.label ?? ""
                textContent += p.total ?? ""
            case .image(let img):
                textContent += img.caption ?? ""
            case .divider:
                break
            }
        }

        guard textContent.count >= 20 else { return empty }

        return DynamicWidgetData(blocks: filtered, tint: tint)
    }

    /// Validates an SF Symbol name, falling back to a generic icon if invalid.
    static func validatedSymbol(_ name: String) -> String {
        #if canImport(AppKit)
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return "questionmark.circle"
        #else
        return name
        #endif
    }
}
