import SwiftUI

/// Dispatches each WidgetBlock to its corresponding sub-view.
struct BlockRenderer: View {
    let block: WidgetBlock
    let tint: WidgetTint?

    var body: some View {
        switch block {
        case .header(let h):
            DWHeaderView(block: h, tint: tint)
        case .image(let img):
            DWImageView(block: img)
        case .stat(let s):
            DWStatView(block: s)
        case .statRow(let sr):
            DWStatRowView(block: sr)
        case .keyValue(let kv):
            DWKeyValueView(block: kv)
        case .itemList(let list):
            DWItemListView(block: list)
        case .chipRow(let cr):
            DWChipRowView(block: cr)
        case .text(let t):
            DWTextView(block: t)
        case .divider:
            DWDividerView()
        case .table(let tb):
            DWTableView(block: tb)
        case .progress(let p):
            DWProgressView(block: p, tint: tint)
        }
    }
}

// MARK: - Simple Block Views

struct DWTextView: View {
    let block: TextBlock

    var body: some View {
        Text(block.content)
            .font(textFont)
            .foregroundStyle(textColor)
    }

    private var textFont: Font {
        switch block.style {
        case .body: return .callout
        case .caption: return .caption
        case .footnote: return .footnote
        }
    }

    private var textColor: HierarchicalShapeStyle {
        switch block.style {
        case .body: return .primary
        case .caption: return .secondary
        case .footnote: return .tertiary
        }
    }
}

struct DWDividerView: View {
    var body: some View {
        Divider().opacity(0.2)
    }
}
