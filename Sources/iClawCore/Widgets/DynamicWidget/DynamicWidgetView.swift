import SwiftUI

@MainActor
public struct DynamicWidgetView: View {
    public let data: DynamicWidgetData
    @Environment(\.dismissWidget) private var dismissWidget

    public init(data: DynamicWidgetData) {
        self.data = data
    }

    public var body: some View {
        let widget = data.validated()
        if !widget.blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(widget.blocks.enumerated()), id: \.offset) { index, block in
                    BlockRenderer(block: block, tint: widget.tint)
                        .padding(.horizontal, 14)
                        .padding(.top, topPadding(for: block, at: index, in: widget.blocks))
                        .padding(.bottom, bottomPadding(for: block, at: index, in: widget.blocks))
                }

            }
            .padding(.vertical, 12)
            .frame(minWidth: 200, maxWidth: 340)
            .glassContainer(cornerRadius: 16, hasShadow: false)
            .onAppear { Task { await TipDonations.donateWidgetShown() } }
        }
    }

    // MARK: - Spacing Logic

    /// Consistent vertical rhythm: tight within sections, breathing room between.
    private func topPadding(for block: WidgetBlock, at index: Int, in blocks: [WidgetBlock]) -> CGFloat {
        guard index > 0 else { return 0 }
        let prev = blocks[index - 1]

        // Dividers handle their own spacing
        if case .divider = block { return 8 }
        if case .divider = prev { return 8 }

        // Header → content: a bit of air
        if case .header = prev { return 10 }

        // Same-type adjacency: tight
        if block.isSameFamily(as: prev) { return 0 }

        // Different sections: moderate gap
        return 8
    }

    private func bottomPadding(for block: WidgetBlock, at index: Int, in blocks: [WidgetBlock]) -> CGFloat {
        // Last block gets no bottom padding (container handles it)
        guard index < blocks.count - 1 else { return 0 }
        return 0 // topPadding on the next block handles gaps
    }
}

// MARK: - Block Family Detection

extension WidgetBlock {
    /// Whether two blocks are the same visual family (for tight grouping).
    func isSameFamily(as other: WidgetBlock) -> Bool {
        switch (self, other) {
        case (.keyValue, .keyValue), (.itemList, .itemList),
             (.chipRow, .chipRow), (.statRow, .statRow),
             (.text, .text):
            return true
        default:
            return false
        }
    }
}

