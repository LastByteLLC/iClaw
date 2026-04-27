import Foundation

/// Centralized number formatting utilities.
public enum NumberFormatting {
    /// Decimal formatter with specified fraction digits and optional grouping separators.
    public static func decimal(fractionDigits: Int, grouping: Bool = false) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        if grouping { f.usesGroupingSeparator = true }
        return f
    }

    /// Currency formatter with specified code and fraction digits.
    public static func currency(code: String = "USD", fractionDigits: Int = 2) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        return f
    }

    /// Format a price adaptively (crypto-style): 0 decimals >100, 2 for 1-100, 5 for <1.
    public static func formatAdaptivePrice(_ price: Double, currencyCode: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currencyCode.uppercased()
        if price > 100 {
            f.maximumFractionDigits = 0
        } else if price < 1 {
            f.maximumFractionDigits = 5
            f.minimumSignificantDigits = 3
        } else {
            f.maximumFractionDigits = 2
        }
        return f.string(from: NSNumber(value: price)) ?? "\(currencyCode) \(price)"
    }
}
