import SwiftUI

/// Data model for the horoscope skill widget.
public struct HoroscopeWidgetData: Sendable {
    public let sign: String
    public let symbol: String
    public let reading: String

    public init(sign: String, symbol: String, reading: String) {
        self.sign = sign
        self.symbol = symbol
        self.reading = reading
    }

    /// Maps zodiac sign names to their Unicode symbols (U+2648–U+2653).
    static let zodiacSymbols: [String: String] = [
        "aries": "\u{2648}",
        "taurus": "\u{2649}",
        "gemini": "\u{264A}",
        "cancer": "\u{264B}",
        "leo": "\u{264C}",
        "virgo": "\u{264D}",
        "libra": "\u{264E}",
        "scorpio": "\u{264F}",
        "sagittarius": "\u{2650}",
        "capricorn": "\u{2651}",
        "aquarius": "\u{2652}",
        "pisces": "\u{2653}"
    ]

    /// Returns the zodiac Unicode symbol for a sign name, or a star fallback.
    static func symbolFor(_ sign: String) -> String {
        zodiacSymbols[sign.lowercased()] ?? "⭐"
    }
}

/// Widget displaying a horoscope reading with zodiac symbol and sign name.
struct HoroscopeWidgetView: View {
    let data: HoroscopeWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: zodiac symbol + sign name
            HStack(spacing: 10) {
                Text(data.symbol)
                    .font(.largeTitle) // Zodiac symbol display element

                VStack(alignment: .leading, spacing: 2) {
                    Text(data.sign)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Daily Horoscope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()
                .opacity(0.2)

            // Reading text
            Text(data.reading)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .glassContainer()
        .frame(maxWidth: 360)
    }
}
