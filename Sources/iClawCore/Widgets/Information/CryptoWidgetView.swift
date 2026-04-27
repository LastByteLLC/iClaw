import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Data model for the crypto price skill widget.
public struct CryptoWidgetData: Sendable {
    public let symbol: String
    public let name: String
    public let price: Double
    public let currency: String
    public let formattedPrice: String

    public init(symbol: String, name: String, price: Double, currency: String) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.currency = currency
        self.formattedPrice = Self.formatPrice(price, currency: currency)
    }

    /// Formats a crypto price: > $100 rounds to dollar, < $1 shows 5 sig figs, else 2 decimals.
    static func formatPrice(_ price: Double, currency: String) -> String {
        NumberFormatting.formatAdaptivePrice(price, currencyCode: currency)
    }
}

/// Widget displaying a cryptocurrency price prominently with copy support.
struct CryptoWidgetView: View {
    let data: CryptoWidgetData

    var body: some View {
        VStack(spacing: 10) {
            // Crypto symbol badge
            Text(data.symbol.uppercased())
                .font(.caption.weight(.bold))
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary)
                .clipShape(Capsule())

            // Large formatted price
            Text(data.formattedPrice)
                .font(.title.bold())
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            // Crypto name
            if !data.name.isEmpty {
                Text(data.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Copy button
            Button {
                ClipboardHelper.copy(data.formattedPrice)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Copy price", bundle: .iClawCore))
        }
        .padding(16)
        .glassContainer()
    }
}
