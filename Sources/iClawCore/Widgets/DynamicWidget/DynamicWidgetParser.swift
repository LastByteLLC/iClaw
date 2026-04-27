import Foundation

/// Parses `<dw>...</dw>` blocks from LLM output into `DynamicWidgetData`.
///
/// DSL format: pipe-delimited lines with type codes.
/// Consecutive same-type lines auto-group (multiple KV → one keyValue block, etc.).
///
/// Type codes: H=header, IMG=image, S=stat, SR=stat row, KV=key-value,
/// L=list item, C=chip, T=text, D=divider, TB=table header, TR=table row, P=progress.
struct DynamicWidgetParser {

    /// Extracts and parses a `<dw>` block from text.
    /// Returns the text with the block removed and the parsed widget (or nil on failure).
    static func parse(_ text: String) -> (cleanedText: String, widget: DynamicWidgetData?) {
        guard let startRange = text.range(of: "<dw>", options: .caseInsensitive),
              let endRange = text.range(of: "</dw>", options: .caseInsensitive),
              startRange.upperBound < endRange.lowerBound else {
            return (text, nil)
        }

        let dslContent = String(text[startRange.upperBound..<endRange.lowerBound])
        let cleanedText = text.replacingCharacters(
            in: startRange.lowerBound..<endRange.upperBound,
            with: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let widget = parseDSL(dslContent) else {
            return (text, nil)
        }

        return (cleanedText, widget)
    }

    // MARK: - Internal

    private static func parseDSL(_ dsl: String) -> DynamicWidgetData? {
        let lines = dsl.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        var tint: WidgetTint?
        var blocks: [WidgetBlock] = []

        // Accumulators for consecutive same-type lines
        var kvAccum: [KeyValuePair] = []
        var listAccum: [ListItem] = []
        var chipAccum: [Chip] = []
        var tableHeaders: [String]?
        var tableRows: [[String]] = []

        func flushAccumulators() {
            if !kvAccum.isEmpty {
                blocks.append(.keyValue(KeyValueBlock(pairs: kvAccum)))
                kvAccum = []
            }
            if !listAccum.isEmpty {
                blocks.append(.itemList(ItemListBlock(items: listAccum)))
                listAccum = []
            }
            if !chipAccum.isEmpty {
                blocks.append(.chipRow(ChipRowBlock(chips: chipAccum)))
                chipAccum = []
            }
            if let headers = tableHeaders {
                blocks.append(.table(TableBlock(headers: headers, rows: tableRows)))
                tableHeaders = nil
                tableRows = []
            }
        }

        for line in lines {
            // Parse tint directive
            if line.lowercased().hasPrefix("tint:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased()
                tint = WidgetTint(rawValue: value)
                continue
            }

            let parts = splitPipe(line)
            guard let code = parts.first else { continue }

            switch code.uppercased() {
            case "H":
                flushAccumulators()
                guard parts.count >= 2 else { continue }
                // Support both H|icon|title|sub and H|title|sub formats.
                // Detect: if first field looks like an SF Symbol name (lowercase, contains dot or no spaces)
                // and there are 3+ parts, treat it as icon|title|subtitle.
                let hasIconField = parts.count >= 3 && !parts[1].contains(" ") && parts[1].contains(".")
                let icon: String?
                let title: String
                let subtitle: String?
                let badge: String?
                if hasIconField {
                    icon = parts[1]
                    title = parts[2]
                    subtitle = parts.count > 3 ? parts[3] : nil
                    badge = parts.count > 4 ? parts[4] : nil
                } else {
                    icon = nil
                    title = parts[1]
                    subtitle = parts.count > 2 ? parts[2] : nil
                    badge = parts.count > 3 ? parts[3] : nil
                }
                let resolvedIcon = icon ?? Self.inferIcon(for: title)
                blocks.append(.header(HeaderBlock(icon: resolvedIcon, title: title, subtitle: subtitle, badge: badge)))

            case "IMG":
                flushAccumulators()
                guard parts.count >= 2 else { continue }
                let url = parts[1]
                let caption = parts.count > 2 ? parts[2] : nil
                let maxHeight: CGFloat? = parts.count > 3 ? CGFloat(Double(parts[3]) ?? 0) : nil
                blocks.append(.image(ImageBlock(url: url, caption: caption, maxHeight: maxHeight != 0 ? maxHeight : nil)))

            case "S":
                flushAccumulators()
                guard parts.count >= 2 else { continue }
                let value = parts[1]
                let label = parts.count > 2 ? parts[2] : nil
                let icon = parts.count > 3 ? parts[3] : nil
                let unit = parts.count > 4 ? parts[4] : nil
                blocks.append(.stat(StatBlock(value: value, label: label, icon: icon, unit: unit)))

            case "SR":
                flushAccumulators()
                // Semicolon-separated stats: SR|val1;label1|val2;label2|...
                guard parts.count >= 2 else { continue }
                var items: [StatBlock] = []
                for i in 1..<parts.count {
                    let sub = parts[i].components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    let value = sub[0]
                    let label = sub.count > 1 ? sub[1] : nil
                    let unit = sub.count > 2 ? sub[2] : nil
                    items.append(StatBlock(value: value, label: label, unit: unit))
                }
                blocks.append(.statRow(StatRowBlock(items: items)))

            case "KV":
                // Flush non-KV accumulators
                if !listAccum.isEmpty || !chipAccum.isEmpty || tableHeaders != nil {
                    flushAccumulators()
                }
                guard parts.count >= 3 else { continue }
                let icon = parts.count > 3 ? parts[3] : nil
                kvAccum.append(KeyValuePair(key: parts[1], value: parts[2], icon: icon))

            case "L":
                if !kvAccum.isEmpty || !chipAccum.isEmpty || tableHeaders != nil {
                    flushAccumulators()
                }
                guard parts.count >= 2 else { continue }
                let title = parts[1]
                let subtitle = parts.count > 2 ? parts[2] : nil
                let trailing = parts.count > 3 ? parts[3] : nil
                let url = parts.count > 4 ? parts[4] : nil
                listAccum.append(ListItem(title: title, subtitle: subtitle, trailing: trailing, url: url))

            case "C":
                if !kvAccum.isEmpty || !listAccum.isEmpty || tableHeaders != nil {
                    flushAccumulators()
                }
                guard parts.count >= 2 else { continue }
                let label = parts[1]
                let icon = parts.count > 2 ? parts[2] : nil
                let url = parts.count > 3 ? parts[3] : nil
                chipAccum.append(Chip(label: label, icon: icon, url: url))

            case "T":
                flushAccumulators()
                guard parts.count >= 2 else { continue }
                let content = parts[1]
                let style: TextBlockStyle
                if parts.count > 2 {
                    style = TextBlockStyle(rawValue: parts[2].lowercased()) ?? .body
                } else {
                    style = .body
                }
                blocks.append(.text(TextBlock(content: content, style: style)))

            case "D":
                flushAccumulators()
                blocks.append(.divider)

            case "TB":
                // Table header — flush prior table if any
                if tableHeaders != nil { flushAccumulators() }
                if !kvAccum.isEmpty || !listAccum.isEmpty || !chipAccum.isEmpty {
                    flushAccumulators()
                }
                tableHeaders = Array(parts.dropFirst())

            case "TR":
                // Table row — appends to current table
                tableRows.append(Array(parts.dropFirst()))

            case "P":
                flushAccumulators()
                guard parts.count >= 2, let value = Double(parts[1]) else { continue }
                let label = parts.count > 2 ? parts[2] : nil
                let total = parts.count > 3 ? parts[3] : nil
                blocks.append(.progress(ProgressBlock(value: value, label: label, total: total)))

            default:
                continue
            }
        }

        flushAccumulators()

        guard !blocks.isEmpty else { return nil }
        return DynamicWidgetData(blocks: blocks, tint: tint).validated()
    }

    /// Splits a line on unescaped `|` characters.
    /// `\|` is treated as a literal pipe.
    private static func splitPipe(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false

        for char in line {
            if escaped {
                if char == "|" {
                    current.append("|")
                } else {
                    current.append("\\")
                    current.append(char)
                }
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "|" {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }

        if escaped {
            current.append("\\")
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))

        return parts
    }

    // MARK: - Icon Inference

    /// Icon keyword rules loaded from `WidgetIconKeywords.json`.
    /// Externalized from code so they can be translated for multi-lingual support
    /// without modifying Swift source.
    private static let iconRules: [(icon: String, keywords: [String])] = {
        guard let url = Bundle.iClawCore.url(forResource: "WidgetIconKeywords", withExtension: "json", subdirectory: "Config"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = json["rules"] as? [[String: Any]] else {
            return []
        }
        return rules.compactMap { rule in
            guard let icon = rule["icon"] as? String,
                  let keywords = rule["keywords"] as? [String] else { return nil }
            return (icon, keywords)
        }
    }()

    private static let defaultIcon: String = {
        guard let url = Bundle.iClawCore.url(forResource: "WidgetIconKeywords", withExtension: "json", subdirectory: "Config"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icon = json["defaultIcon"] as? String else {
            return "info.circle"
        }
        return icon
    }()

    /// Infers an appropriate SF Symbol for a header title based on keyword matching.
    /// Keywords are loaded from `Resources/Config/WidgetIconKeywords.json`.
    static func inferIcon(for title: String) -> String {
        let lower = title.lowercased()
        for (icon, keywords) in iconRules {
            if keywords.contains(where: { lower.contains($0) }) {
                return icon
            }
        }
        return defaultIcon
    }
}
