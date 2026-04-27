import SwiftUI

struct DWTableView: View {
    let block: TableBlock

    /// Proportional column widths based on content length.
    private var colWeights: [CGFloat] {
        let colCount = block.headers.count
        guard colCount > 0 else { return [] }

        var maxLengths = block.headers.map(\.count)
        for row in block.rows.prefix(5) {
            for (i, cell) in row.enumerated() where i < colCount {
                maxLengths[i] = max(maxLengths[i], cell.count)
            }
        }

        let totalChars = maxLengths.reduce(0) { $0 + max($1, 3) }
        guard totalChars > 0 else { return Array(repeating: .infinity, count: colCount) }
        return maxLengths.map { CGFloat(max($0, 3)) / CGFloat(totalChars) * 10000 }
    }

    var body: some View {
        let weights = colWeights

        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(block.headers.enumerated()), id: \.offset) { index, header in
                    Text(header)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: index < weights.count ? weights[index] : .infinity,
                               alignment: index == 0 ? .leading : .trailing)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)

            Divider().opacity(0.2)

            // Data rows
            ForEach(Array(block.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        Text(cell)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: colIndex < weights.count ? weights[colIndex] : .infinity,
                                   alignment: colIndex == 0 ? .leading : .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(.vertical, 3)
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.02))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(rowAccessibilityLabel(row: row)))
            }

            if let caption = block.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    /// Produces a "header1 value1, header2 value2, …" label so VoiceOver
    /// reads each table row as a single stop with headers contextualizing the cells.
    private func rowAccessibilityLabel(row: [String]) -> String {
        zip(block.headers, row)
            .map { "\($0) \($1)" }
            .joined(separator: ", ")
    }
}
