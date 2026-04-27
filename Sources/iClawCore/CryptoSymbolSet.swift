import Foundation

/// Single source of truth for cryptocurrency symbol lookup.
/// Used by ToolRouter (Stocks → Convert override) and SkillWidgetParser (crypto widget detection).
enum CryptoSymbolSet {
    static let symbols: Set<String> = {
        guard let symbols: [String] = ConfigLoader.load("CryptoSymbols", as: [String].self) else {
            return ["BTC", "ETH", "DOGE", "SOL", "XRP", "AVAX", "SHIB", "LTC", "LINK"]
        }
        return Set(symbols)
    }()
}
