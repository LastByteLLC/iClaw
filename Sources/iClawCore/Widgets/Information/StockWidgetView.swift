import SwiftUI

public struct StockWidgetData: Codable, Sendable {
    public let symbol: String
    public let name: String
    public let currentPrice: Double
    public let changeAmount: Double
    public let changePercent: Double
    public let recommendations: [String]

    public init(symbol: String, name: String, currentPrice: Double, changeAmount: Double, changePercent: Double, recommendations: [String]) {
        self.symbol = symbol
        self.name = name
        self.currentPrice = currentPrice
        self.changeAmount = changeAmount
        self.changePercent = changePercent
        self.recommendations = recommendations
    }
}

/// Posted when the user taps a recommended ticker in the stock widget.
/// The notification's `object` is the query string (e.g. "#stocks AMZN").
extension Notification.Name {
    static let stockTickerTapped = Notification.Name("iClaw.stockTickerTapped")
}

public struct StockWidgetView: View {
    public let data: StockWidgetData

    private static let currencyFormatter = NumberFormatting.currency()

    public init(data: StockWidgetData) {
        self.data = data
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.symbol)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(data.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.currencyFormatter.string(from: NSNumber(value: data.currentPrice)) ?? String(format: "$%.2f", data.currentPrice))
                        .font(.title3.bold())
                        .foregroundStyle(.primary)

                    let isPositive = data.changeAmount >= 0
                    let directionIndicator = isPositive ? "\u{25B2}" : "\u{25BC}"
                    let changeText = String(format: "%@ %.2f (%.2f%%)", directionIndicator, abs(data.changeAmount), abs(data.changePercent))
                    HStack(spacing: 2) {
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                            .accessibilityHidden(true)
                        Text(changeText)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(isPositive ? .green : .red)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        String(
                            format: String(localized: isPositive ? "stock.a11y.change" : "stock.a11y.change.down", bundle: .iClawCore),
                            String(format: "%.2f", abs(data.changeAmount)),
                            String(format: "%.2f", abs(data.changePercent))
                        )
                    )
                }
            }

            HStack(spacing: 8) {
                Button {
                    openInStocksApp(symbol: data.symbol)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption2)
                        Text("Open in Stocks")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if !data.recommendations.isEmpty {
                    Spacer()
                    ForEach(data.recommendations, id: \.self) { ticker in
                        Button {
                            NotificationCenter.default.post(
                                name: .widgetActionTapped,
                                object: WidgetAction(
                                    displayText: "$\(ticker)",
                                    payload: ["ticker": ticker]
                                )
                            )
                        } label: {
                            Text(ticker)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(.white.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .glassContainer(hasShadow: false)
        .copyable("\(data.symbol): \(Self.currencyFormatter.string(from: NSNumber(value: data.currentPrice)) ?? String(format: "$%.2f", data.currentPrice))")
    }

    private func openInStocksApp(symbol: String) {
        if let url = URL(string: "stocks://symbol/\(symbol)") {
            URLOpener.open(url)
        }
    }
}
