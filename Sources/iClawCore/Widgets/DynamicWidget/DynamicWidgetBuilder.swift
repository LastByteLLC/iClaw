import Foundation

/// Fluent builder for tools that want to create pre-defined dynamic widget layouts.
public struct DynamicWidgetBuilder: Sendable {
    private var blocks: [WidgetBlock] = []
    private let tint: WidgetTint?

    public init(tint: WidgetTint? = nil) {
        self.tint = tint
    }

    // MARK: - Block Builders

    @discardableResult
    public mutating func header(icon: String, title: String, subtitle: String? = nil, badge: String? = nil) -> Self {
        blocks.append(.header(HeaderBlock(icon: icon, title: title, subtitle: subtitle, badge: badge)))
        return self
    }

    @discardableResult
    public mutating func image(url: String, caption: String? = nil, maxHeight: CGFloat? = nil) -> Self {
        blocks.append(.image(ImageBlock(url: url, caption: caption, maxHeight: maxHeight)))
        return self
    }

    @discardableResult
    public mutating func stat(value: String, label: String? = nil, icon: String? = nil, unit: String? = nil) -> Self {
        blocks.append(.stat(StatBlock(value: value, label: label, icon: icon, unit: unit)))
        return self
    }

    @discardableResult
    public mutating func statRow(_ items: [StatBlock]) -> Self {
        blocks.append(.statRow(StatRowBlock(items: items)))
        return self
    }

    @discardableResult
    public mutating func keyValue(_ pairs: [(String, String)]) -> Self {
        let kvPairs = pairs.map { KeyValuePair(key: $0.0, value: $0.1) }
        blocks.append(.keyValue(KeyValueBlock(pairs: kvPairs)))
        return self
    }

    @discardableResult
    public mutating func keyValueWithIcons(_ pairs: [(key: String, value: String, icon: String?)]) -> Self {
        let kvPairs = pairs.map { KeyValuePair(key: $0.key, value: $0.value, icon: $0.icon) }
        blocks.append(.keyValue(KeyValueBlock(pairs: kvPairs)))
        return self
    }

    @discardableResult
    public mutating func itemList(_ items: [ListItem]) -> Self {
        blocks.append(.itemList(ItemListBlock(items: items)))
        return self
    }

    @discardableResult
    public mutating func chipRow(_ chips: [Chip]) -> Self {
        blocks.append(.chipRow(ChipRowBlock(chips: chips)))
        return self
    }

    @discardableResult
    public mutating func text(_ content: String, style: TextBlockStyle = .body) -> Self {
        blocks.append(.text(TextBlock(content: content, style: style)))
        return self
    }

    @discardableResult
    public mutating func divider() -> Self {
        blocks.append(.divider)
        return self
    }

    @discardableResult
    public mutating func table(headers: [String], rows: [[String]], caption: String? = nil) -> Self {
        blocks.append(.table(TableBlock(headers: headers, rows: rows, caption: caption)))
        return self
    }

    @discardableResult
    public mutating func progress(value: Double, label: String? = nil, total: String? = nil) -> Self {
        blocks.append(.progress(ProgressBlock(value: value, label: label, total: total)))
        return self
    }

    // MARK: - Build

    /// Returns validated DynamicWidgetData ready for use in ToolIO.
    public func build() -> DynamicWidgetData {
        DynamicWidgetData(blocks: blocks, tint: tint).validated()
    }
}
