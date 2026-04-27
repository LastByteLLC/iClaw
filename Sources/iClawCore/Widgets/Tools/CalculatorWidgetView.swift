import SwiftUI

// MARK: - Widget Data

/// Rich data model for calculator results. Supports single values, formatted numbers
/// with units/symbols, and tabular data (amortization schedules, expense tracking, etc.).
public struct CalculationWidgetData: Sendable {
    /// The original expression or question (e.g., "25% of 300", "monthly payment on $200k loan").
    public let expression: String

    /// The computed result as a display string (e.g., "75", "$1,073.64").
    public let result: String

    /// Optional unit or symbol suffix (e.g., "km", "°F", "USD").
    public let unit: String?

    /// Optional prefix symbol (e.g., "$", "€", "£").
    public let symbol: String?

    /// Optional label describing the result (e.g., "Monthly Payment", "Simple Interest").
    public let label: String?

    /// Optional secondary results for multi-part answers (e.g., total interest, total paid).
    public let supplementary: [SupplementaryResult]

    /// Optional table rows for tabular results (amortization, tracking, etc.).
    public let table: TableData?

    public init(
        expression: String,
        result: String,
        unit: String? = nil,
        symbol: String? = nil,
        label: String? = nil,
        supplementary: [SupplementaryResult] = [],
        table: TableData? = nil
    ) {
        self.expression = expression
        self.result = result
        self.unit = unit
        self.symbol = symbol
        self.label = label
        self.supplementary = supplementary
        self.table = table
    }

    public struct SupplementaryResult: Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct TableData: Sendable {
        public let title: String
        public let columns: [String]
        public let rows: [[String]]

        public init(title: String, columns: [String], rows: [[String]]) {
            self.title = title
            self.columns = columns
            self.rows = rows
        }
    }
}

// Backwards compatibility — old CalculatorWidgetData still works
struct CalculatorWidgetData: Sendable {
    let equation: String
    let result: String
}

// MARK: - Widget View

public struct CalculatorWidgetView: View {
    public let data: CalculationWidgetData
    @Environment(\.parentMessageID) private var parentMessageID

    public init(data: CalculationWidgetData) {
        self.data = data
    }

    public var body: some View {
        richView(data)
    }

    // MARK: - Rich View

    @ViewBuilder
    private func richView(_ d: CalculationWidgetData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Expression
            Text(d.expression)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.bottom, 6)

            // Main result
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let sym = d.symbol {
                    Text(sym)
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(d.result)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                if let unit = d.unit {
                    Text(unit)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            if let label = d.label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            // Supplementary results
            if !d.supplementary.isEmpty {
                Divider()
                    .padding(.vertical, 6)

                ForEach(Array(d.supplementary.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.value)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }

            // Table
            if let table = d.table {
                tableView(table)
            }

            // Explain button
            Divider()
                .padding(.vertical, 6)

            Button {
                if let msgID = parentMessageID {
                    let prompt = "[Replying to: \"\(d.expression)\" → \"\(d.result)\"]\nExplain this calculation step by step"
                    let action = WidgetExplainAction(sourceMessageID: msgID, prompt: prompt)
                    NotificationCenter.default.post(name: .widgetExplainRequested, object: action)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.min")
                        .font(.caption2)
                    Text("Explain", bundle: .iClawCore)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Explain calculation", bundle: .iClawCore))
        }
        .padding(12)
        .frame(minWidth: 160)
        .glassContainer(hasShadow: false)
        .copyable([data.symbol, data.result, data.unit].compactMap { $0 }.joined())
    }

    // MARK: - Table View

    @ViewBuilder
    private func tableView(_ table: CalculationWidgetData.TableData) -> some View {
        // Compute proportional column widths based on header + content length.
        // Short columns (Mo, #) get minimal space; long columns (Balance, Payment) expand.
        let colWeights = Self.columnWeights(table)

        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 6)

            Text(table.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            // Column headers
            HStack(spacing: 0) {
                ForEach(Array(table.columns.enumerated()), id: \.offset) { i, col in
                    Text(col)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: colWeights[i], alignment: i == 0 ? .leading : .trailing)
                }
            }

            Divider()

            // Data rows (show up to 8, collapse rest)
            let visibleRows = table.rows.prefix(8)
            ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        Text(cell)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: i < colWeights.count ? colWeights[i] : .infinity,
                                   alignment: i == 0 ? .leading : .trailing)
                    }
                }
            }

            if table.rows.count > 8 {
                Text(String(format: String(localized: "more_rows", bundle: .iClawCore), table.rows.count - 8))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    /// Computes proportional maxWidth values for table columns based on content length.
    /// Short columns like "Mo" get narrow widths; long columns like "Balance" expand.
    private static func columnWeights(_ table: CalculationWidgetData.TableData) -> [CGFloat] {
        let colCount = table.columns.count
        guard colCount > 0 else { return [] }

        // Measure max character count per column (header + first 5 data rows)
        var maxLengths = table.columns.map(\.count)
        for row in table.rows.prefix(5) {
            for (i, cell) in row.enumerated() where i < colCount {
                maxLengths[i] = max(maxLengths[i], cell.count)
            }
        }

        // Convert to proportional weights with a floor of 3 chars
        let totalChars = maxLengths.reduce(0) { $0 + max($1, 3) }
        guard totalChars > 0 else { return Array(repeating: .infinity, count: colCount) }

        // Scale to a reference width (use .infinity as the total, let SwiftUI distribute)
        return maxLengths.map { charCount in
            let weight = CGFloat(max(charCount, 3)) / CGFloat(totalChars)
            return weight * 10000  // Large number → SwiftUI treats as proportional maxWidth
        }
    }

    // MARK: - Legacy View (backwards compatibility)

    private func legacyView(_ d: CalculatorWidgetData) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 4) {
                Text(d.equation)
                Text("=")
                    .foregroundStyle(.secondary)
                Text(d.result)
                    .fontWeight(.semibold)
            }
            .font(.system(.title3, design: .rounded))
        }
        .padding(12)
        .frame(minWidth: 140)
        .glassContainer(hasShadow: false)
    }
}
