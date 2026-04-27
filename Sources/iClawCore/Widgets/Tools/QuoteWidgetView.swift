import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Data for the quote widget shown in greetings and quote skill results.
public struct QuoteWidgetData: Sendable {
    public let quote: String
    public let author: String

    public init(quote: String, author: String) {
        self.quote = quote
        self.author = author
    }
}

/// Displays a quote with author attribution and copy-to-clipboard.
struct QuoteWidgetView: View {
    let data: QuoteWidgetData
    @State private var showCopyConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\u{201C}\(data.quote)\u{201D}")
                .font(.callout)
                .italic()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("— \(data.author)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    ClipboardHelper.copy("\(data.quote) — \(data.author)")
                    withAnimation(.snappy) {
                        showCopyConfirmation = true
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.snappy) {
                            showCopyConfirmation = false
                        }
                    }
                } label: {
                    Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(showCopyConfirmation ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Copy quote", bundle: .iClawCore))
            }
        }
        .padding(14)
        .glassContainer(cornerRadius: 16)
    }
}
