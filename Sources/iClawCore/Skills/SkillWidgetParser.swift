import Foundation

/// Parses LLM response text from specific skills to build custom widget data.
enum SkillWidgetParser {

    /// Known cryptocurrency symbols for ingredient-based detection.
    /// Shared with ToolRouter via CryptoSymbolSet.
    private static var cryptoSymbols: Set<String> { CryptoSymbolSet.symbols }

    /// Attempts to build a custom widget from the active skill name, routed tool names,
    /// ingredients (tool results), and LLM response text.
    /// Returns (widgetType, widgetData) or nil if no custom widget applies.
    static func buildWidget(
        skillName: String?,
        toolNames: [String],
        ingredients: [String],
        responseText: String
    ) -> (type: String, data: any Sendable)? {
        // Skill-based matching
        if let name = skillName {
            switch name.lowercased() {
            case "emoji", "emoji skill":
                return parseEmoji(from: responseText)
            case "horoscope", "horoscope skill":
                return parseHoroscope(from: responseText)
            case "crypto price", "crypto price skill":
                return parseCrypto(from: ingredients, responseText: responseText)
            default:
                break
            }
        }

        // Tool-based matching: detect crypto conversions from ConvertTool
        if toolNames.contains("Convert") {
            let tokens = Set(ingredients.joined().wordTokens)
            if !tokens.intersection(cryptoSymbols).isEmpty {
                return parseCrypto(from: ingredients, responseText: responseText)
            }
        }

        return nil
    }

    // MARK: - Emoji

    private static func parseEmoji(from text: String) -> (type: String, data: any Sendable)? {
        // Find the first emoji character in the text
        guard let mainEmoji = extractFirstEmoji(from: text) else { return nil }

        // Extract the name — look for text near the emoji or common patterns
        let name = extractEmojiName(from: text, emoji: mainEmoji)

        // Find related emoji (any emoji in the text other than the main one)
        let related = extractRelatedEmoji(from: text, excluding: mainEmoji)

        let data = EmojiWidgetData(
            emoji: mainEmoji,
            name: name,
            relatedEmoji: related
        )
        return ("EmojiWidget", data)
    }

    private static func extractFirstEmoji(from text: String) -> String? {
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmoji && scalar.properties.isEmojiPresentation {
                // Find the full grapheme cluster containing this scalar
                if let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: String(scalar))) {
                    let startIndex = range.lowerBound
                    // Get the full grapheme cluster (handles compound emoji like 👨‍👩‍👧)
                    let endIndex = text.index(after: startIndex)
                    return String(text[startIndex..<endIndex])
                }
            }
        }
        // Fallback: scan character by character
        for char in text {
            if char.unicodeScalars.first?.properties.isEmoji == true &&
               char.unicodeScalars.first?.value ?? 0 > 0x23F {
                return String(char)
            }
        }
        return nil
    }

    private static func extractEmojiName(from text: String, emoji: String) -> String {
        // Look for patterns like "Name: X", "called X", "officially named X", or text in quotes
        let patterns = [
            #"(?:name|called|known as|officially)[:\s]+["""]?([^"""\n,]+)["""]?"#,
            #"(?:the\s+)?([A-Z][a-z]+(?: [A-Z][a-z]+)*)\s+emoji"#,
            #"emoji[:\s]+(?:the\s+)?([A-Z][a-z]+(?: [A-Za-z]+)*)"#
        ]

        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression, range: text.startIndex..<text.endIndex) {
                let matched = String(text[match])
                // Extract the captured group content
                let cleaned = matched
                    .replacingOccurrences(of: #"^(?:name|called|known as|officially)[:\s]+["""]?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"["""]$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: " emoji", with: "")
                    .replacingOccurrences(of: "emoji: ", with: "")
                    .replacingOccurrences(of: "emoji:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty && cleaned.count < 60 {
                    return cleaned
                }
            }
        }

        // Fallback: use the first line that doesn't start with the emoji
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix(emoji) && trimmed.count > 3 && trimmed.count < 60 {
                return trimmed
            }
        }

        return "Emoji"
    }

    private static func extractRelatedEmoji(from text: String, excluding main: String) -> [(emoji: String, name: String)] {
        var result: [(emoji: String, name: String)] = []
        var seen = Set<String>([main])

        for char in text {
            let str = String(char)
            if str == main || seen.contains(str) { continue }
            if char.unicodeScalars.first?.properties.isEmoji == true &&
               char.unicodeScalars.first?.value ?? 0 > 0x23F {
                seen.insert(str)
                let name = str.unicodeScalars.first
                    .flatMap { Unicode.Scalar($0.value)?.properties.name?.capitalized } ?? ""
                result.append((emoji: str, name: name))
                if result.count >= 3 { break }
            }
        }

        return result
    }

    // MARK: - Horoscope

    private static func parseHoroscope(from text: String) -> (type: String, data: any Sendable)? {
        let signs = HoroscopeWidgetData.zodiacSymbols.keys
        let lower = text.lowercased()

        // Find which sign is mentioned
        var detectedSign: String?
        for sign in signs {
            if lower.contains(sign) {
                detectedSign = sign
                break
            }
        }

        guard let sign = detectedSign else { return nil }
        let symbol = HoroscopeWidgetData.symbolFor(sign)

        // The reading is the full response text (the LLM generates the horoscope)
        let data = HoroscopeWidgetData(
            sign: sign.capitalized,
            symbol: symbol,
            reading: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return ("HoroscopeWidget", data)
    }

    // MARK: - Crypto Price

    private static func parseCrypto(from ingredients: [String], responseText: String) -> (type: String, data: any Sendable)? {
        // Look for conversion result in ingredients: "1 BTC = 87,432.15 USD"
        let combined = ingredients.joined(separator: "\n") + "\n" + responseText

        // Pattern: "NUMBER SYMBOL = NUMBER CURRENCY" or "SYMBOL: $NUMBER"
        let patterns = [
            #"(\d+(?:\.\d+)?)\s+([A-Z]{2,5})\s*=\s*([\d,]+(?:\.\d+)?)\s+([A-Z]{3})"#,
            #"([A-Z]{2,5})\s*(?:is|:|=)\s*\$?([\d,]+(?:\.\d+)?)\s*([A-Z]{3})?"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsString = combined as NSString
            if let match = regex.firstMatch(in: combined, range: NSRange(location: 0, length: nsString.length)) {
                if match.numberOfRanges >= 5 {
                    let symbol = nsString.substring(with: match.range(at: 2))
                    let priceStr = nsString.substring(with: match.range(at: 3)).replacingOccurrences(of: ",", with: "")
                    let currency = nsString.substring(with: match.range(at: 4))

                    if let price = Double(priceStr) {
                        let name = cryptoName(for: symbol)
                        let data = CryptoWidgetData(symbol: symbol, name: name, price: price, currency: currency)
                        return ("CryptoWidget", data)
                    }
                } else if match.numberOfRanges >= 3 {
                    let symbol = nsString.substring(with: match.range(at: 1))
                    let priceStr = nsString.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: "")
                    let currency = match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound
                        ? nsString.substring(with: match.range(at: 3))
                        : "USD"

                    if let price = Double(priceStr) {
                        let name = cryptoName(for: symbol)
                        let data = CryptoWidgetData(symbol: symbol, name: name, price: price, currency: currency)
                        return ("CryptoWidget", data)
                    }
                }
            }
        }

        return nil
    }

    private static let cryptoNames: [String: String] = [
        "BTC": "Bitcoin", "ETH": "Ethereum", "DOGE": "Dogecoin",
        "SOL": "Solana", "ADA": "Cardano", "XRP": "Ripple",
        "AVAX": "Avalanche", "DOT": "Polkadot", "SHIB": "Shiba Inu",
        "LTC": "Litecoin", "LINK": "Chainlink"
    ]

    private static func cryptoName(for symbol: String) -> String {
        cryptoNames[symbol.uppercased()] ?? symbol.uppercased()
    }
}
