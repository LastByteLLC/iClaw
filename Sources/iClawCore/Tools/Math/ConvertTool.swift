import Foundation
import AppIntents

/// Closure type for injecting a test LLM responder into the ConvertTool.
public typealias ConvertLLMResponder = SimpleLLMResponder

/// Structured arguments for LLM-extracted conversion requests.
public struct ConvertArgs: ToolArguments {
    public let intent: String       // "unit", "currency", "encoding", "color"
    public let value: Double?       // numeric value for unit/currency
    public let fromUnit: String?    // source unit/currency code
    public let toUnit: String?      // target unit/currency code
    public let text: String?        // text for encoding conversions
    public let sourceColor: String? // e.g. "#FF5733", "rgb(255,87,51)"
    public let targetFormat: String? // "hex", "rgb", "hsl", "cmyk"
}

/// Milestone 2.2c: Unit and currency conversion tool.
/// Implements CoreTool protocol and exposes an AppIntent for system-wide access.
public struct ConvertTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Convert"
    public let schema = "Convert units (e.g., '10 miles to km', '100 celsius to fahrenheit'), currency/crypto (e.g., '100 usd to eur', '1 btc to usd'), or text encoding (e.g., 'hello to binary', 'hello to nato', 'hello to morse', 'hello to base64', 'decode base64 SGVsbG8=')."
    public let isInternal = false
    public let category = CategoryEnum.online

    private let session: URLSession
    private let llmResponder: ConvertLLMResponder?

    // MARK: - Currency Rate Cache (12h TTL)

    private static let rateCache = TTLCache<[String: Double]>(ttl: 12 * 60 * 60)

    public init(session: URLSession = .shared, llmResponder: ConvertLLMResponder? = nil) {
        self.session = session
        self.llmResponder = llmResponder
    }

    // MARK: - ExtractableCoreTool

    public typealias Args = ConvertArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Convert", fallback: "{\"intent\":\"unit|currency|encoding|color\",\"value\":\"number?\",\"fromUnit\":\"string?\",\"toUnit\":\"string?\"}"
    )

    public func execute(args: ConvertArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await timed {
            // Self-gate: a conversion needs a numeric value in the current
            // input for unit/currency intents. Without one, the LLM
            // extractor has fabricated the value (e.g., "how tall is
            // Everest in meters?" — no user-supplied number, extractor
            // invents 8848 + swaps units). Refuse and let the engine fall
            // back to conversational. Encoding / color intents don't need
            // a number and are exempt.
            if args.intent == "unit" || args.intent == "currency" {
                let rawHasDigit = rawInput.contains(where: { $0.isNumber })
                if !rawHasDigit {
                    return ToolIO(
                        text: "",
                        status: .error
                    )
                }
            }
            switch args.intent {
            case "unit":
                if let value = args.value, let from = args.fromUnit, let to = args.toUnit {
                    if let result = performConversion(value: value, from: from.lowercased(), to: to.lowercased()) {
                        return ToolIO(
                            text: result,
                            status: .ok
                        )
                    }
                }
                // Fall through to raw input parsing
                return try await execute(input: rawInput, entities: entities)

            case "currency":
                if let value = args.value, let from = args.fromUnit, let to = args.toUnit {
                    let fromCode = resolveCurrencyCode(from)
                    let toCode = resolveCurrencyCode(to)
                    do {
                        let result = try await fetchCurrencyRate(amount: value, from: fromCode, to: toCode)
                        return ToolIO(
                            text: result,
                            status: .ok,
                            isVerifiedData: true
                        )
                    } catch {
                        return ToolIO(
                            text: error.localizedDescription,
                            status: .error
                        )
                    }
                }
                return try await execute(input: rawInput, entities: entities)

            case "encoding":
                if let text = args.text, let to = args.toUnit {
                    if let result = encode(text: text, to: to.lowercased()) {
                        return ToolIO(
                            text: result,
                            status: .ok
                        )
                    }
                }
                if let text = args.text, let from = args.fromUnit {
                    if let result = decode(data: text, from: from.lowercased()) {
                        return ToolIO(
                            text: result,
                            status: .ok
                        )
                    }
                }
                return try await execute(input: rawInput, entities: entities)

            case "color":
                if let sourceColor = args.sourceColor, let targetFormat = args.targetFormat {
                    let reconstructed = "\(sourceColor) to \(targetFormat)"
                    if let result = tryColorConversion(input: reconstructed) {
                        return ToolIO(
                            text: result,
                            status: .ok
                        )
                    }
                }
                return try await execute(input: rawInput, entities: entities)

            default:
                return try await execute(input: rawInput, entities: entities)
            }
        }
    }

    /// Implement actual unit conversion using Foundation's Measurement.
    /// - Parameters:
    ///   - input: A conversion request string.
    ///   - entities: The extracted entities from the input preprocessor.
    /// - Returns: A standardized `ToolIO` object.
    /// Currency/crypto name aliases → ISO codes used by the exchange rate API.
    /// Loaded from `Resources/Config/CurrencyAliases.json`.
    private static let currencyAliases: [String: String] = ConfigLoader.loadStringDict("CurrencyAliases")

    /// Resolve a user-facing currency string to an API code.
    private func resolveCurrencyCode(_ raw: String) -> String {
        let lower = raw.lowercased()
        return Self.currencyAliases[lower] ?? lower
    }

    /// Infer the user's local fiat currency from their locale/timezone.
    private static func localCurrencyCode() -> String {
        if #available(macOS 13, *), let code = Locale.current.currency?.identifier {
            return code.lowercased()
        }
        // Fallback: map timezone to common currency
        let tz = TimeZone.current.identifier
        if tz.hasPrefix("America/") { return "usd" }
        if tz.hasPrefix("Europe/London") { return "gbp" }
        if tz.hasPrefix("Europe/") { return "eur" }
        if tz.hasPrefix("Asia/Tokyo") { return "jpy" }
        if tz.hasPrefix("Asia/Shanghai") || tz.hasPrefix("Asia/Hong_Kong") { return "cny" }
        if tz.hasPrefix("Asia/Kolkata") || tz.hasPrefix("Asia/Calcutta") { return "inr" }
        return "usd"
    }

    // Pre-compiled regexes
    private static let conversionRegex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?) (\w+) to (\w+)"#, options: .caseInsensitive)
    private static let toPatternRegex = try! NSRegularExpression(pattern: #"^(.+?)\s+(?:to|in)\s+(\w+)$"#, options: .caseInsensitive)
    private static let decodePatternRegex = try! NSRegularExpression(pattern: #"(?:decode\s+(\w+)\s+(.+)|(\w+)\s+decode\s+(.+))"#, options: .caseInsensitive)
    /// Matches "how many X in (a/an) Y" and rewrites to "1 Y to X"
    private static let howManyRegex = try! NSRegularExpression(
        pattern: #"how many (\w+) (?:are )?in (?:a |an )?(\w+)"#,
        options: .caseInsensitive
    )

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            // Text encoding / color conversions — these don't need a number
            // and must run BEFORE the digit gate. Ordering: try encoding
            // first, then color, then (if neither matched) fall through to
            // the unit/currency path which requires a user-supplied number.
            if let encodingResult = tryTextEncoding(input: input) {
                return ToolIO(
                    text: encodingResult,
                    status: .ok
                )
            }
            if let colorResult = tryColorConversion(input: input) {
                return ToolIO(
                    text: colorResult,
                    status: .ok
                )
            }

            // Self-gate at the string-parsing entry point for unit/currency.
            // Without a user-supplied number the `llmNormalize` fallback
            // will hallucinate one ("how tall is Everest in meters?" →
            // extracted 8848 from training data, swapped units). Refuse
            // silently so the engine falls back to conversational.
            // "how many X in a Y" queries legitimately have no number and
            // are handled by the `howManyRegex` preprocessor below — those
            // are allowed through.
            // Word-number and explicit-convert-verb inputs ("about a hundred
            // clicks in miles", "convert vibes to chill") are also allowed
            // through so the LLM normalizer can try to interpret them.
            let hmRangeCheck = NSRange(input.startIndex..<input.endIndex, in: input)
            let isHowManyQuery = Self.howManyRegex.firstMatch(in: input, options: [], range: hmRangeCheck) != nil
            let lowered = input.lowercased()
            let hasConvertPrefix = lowered.hasPrefix("convert ")
            let wordNumbers: Set<String> = [
                "hundred", "thousand", "million", "billion", "dozen", "half", "quarter",
                "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
                "seventy", "eighty", "ninety"
            ]
            let hasWordNumber = !lowered.wordTokenSet.isDisjoint(with: wordNumbers)
            if !isHowManyQuery && !hasConvertPrefix && !hasWordNumber
                && !input.contains(where: { $0.isNumber }) {
                return ToolIO(text: "", status: .error)
            }

            // Pre-process "how many X in (a) Y" → "1 Y to X"
            var processedInput = input
            let hmRange = NSRange(input.startIndex..<input.endIndex, in: input)
            if let hmMatch = Self.howManyRegex.firstMatch(in: input, options: [], range: hmRange) {
                let toUnit = (input as NSString).substring(with: hmMatch.range(at: 1))
                let fromUnit = (input as NSString).substring(with: hmMatch.range(at: 2))
                processedInput = "1 \(fromUnit) to \(toUnit)"
            }

            let regex = Self.conversionRegex
            let range = NSRange(processedInput.startIndex..<processedInput.endIndex, in: processedInput)

            if let match = regex.firstMatch(in: processedInput, options: [], range: range) {
                let valueStr = (processedInput as NSString).substring(with: match.range(at: 1))
                let fromUnitStr = (processedInput as NSString).substring(with: match.range(at: 2)).lowercased()
                let toUnitStr = (processedInput as NSString).substring(with: match.range(at: 3)).lowercased()

                if let value = Double(valueStr) {
                    // Try unit conversion first
                    if let result = performConversion(value: value, from: fromUnitStr, to: toUnitStr) {
                        return ToolIO(
                            text: result,
                            status: .ok
                        )
                    }

                    // Not a unit — try currency/crypto conversion via API
                    let from = resolveCurrencyCode(fromUnitStr)
                    let to = resolveCurrencyCode(toUnitStr)
                    do {
                        let result = try await fetchCurrencyRate(amount: value, from: from, to: to)
                        return ToolIO(
                            text: result,
                            status: .ok,
                            isVerifiedData: true
                        )
                    } catch {
                        return ToolIO(
                            text: error.localizedDescription,
                            status: .error
                        )
                    }
                }
            }

            // Text encoding conversions: "hello to binary", "hello to hex", etc.
            if let encodingResult = tryTextEncoding(input: input) {
                return ToolIO(
                    text: encodingResult,
                    status: .ok
                )
            }

            // Fallback: try to parse "how much is X worth" / "price of X" style queries
            // with an implied target of USD and amount of 1
            switch await tryImpliedCurrencyQuery(input: input) {
            case .success(let result):
                return ToolIO(
                    text: result,
                    status: .ok,
                    isVerifiedData: true
                )
            case .failure(let error):
                return ToolIO(
                    text: error.localizedDescription,
                    status: .error
                )
            case nil:
                break
            }

            // Self-healing: use LLM to extract structured conversion from ambiguous input
            if let normalized = await llmNormalize(input: input) {
                // Re-run the regex parse on the LLM-normalized output
                if let match = regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)) {
                    let valueStr = (normalized as NSString).substring(with: match.range(at: 1))
                    let fromUnitStr = (normalized as NSString).substring(with: match.range(at: 2)).lowercased()
                    let toUnitStr = (normalized as NSString).substring(with: match.range(at: 3)).lowercased()

                    if let value = Double(valueStr) {
                        if let result = performConversion(value: value, from: fromUnitStr, to: toUnitStr) {
                            return ToolIO(
                                text: result,
                                status: .ok
                            )
                        }
                        // Try currency
                        let from = resolveCurrencyCode(fromUnitStr)
                        let to = resolveCurrencyCode(toUnitStr)
                        do {
                            let result = try await fetchCurrencyRate(amount: value, from: from, to: to)
                            return ToolIO(
                                text: result,
                                status: .ok,
                                isVerifiedData: true
                            )
                        } catch {
                            return ToolIO(
                                text: error.localizedDescription,
                                status: .error
                            )
                        }
                    }
                }
            }

            return ToolIO(
                text: "Could not parse conversion request: \(input)",
                status: .error
            )
        }
    }

    // MARK: - Currency API

    enum CurrencyError: LocalizedError {
        case invalidCode(String)
        case rateNotFound(from: String, to: String)
        case fetchFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidCode(let code): return "Invalid currency code '\(code)'."
            case .rateNotFound(let from, let to): return "Could not find exchange rate from \(from.uppercased()) to \(to.uppercased())."
            case .fetchFailed(let reason): return "Error fetching exchange rates: \(reason)"
            }
        }
    }

    private func fetchCurrencyRate(amount: Double, from: String, to: String) async throws -> String {
        // Check cache first
        if let cachedRates = await Self.rateCache.get(from), let rate = cachedRates[to] {
            return formatConversion(amount: amount, from: from, to: to, rate: rate)
        }

        guard let url = APIEndpoints.Currency.rates(base: from) else { throw CurrencyError.invalidCode(from) }

        let (data, _) = try await session.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json[from] as? [String: Any] else {
            throw CurrencyError.rateNotFound(from: from, to: to)
        }

        // Cache all rates for this base currency
        var rateMap: [String: Double] = [:]
        for (key, value) in rates {
            if let r = value as? Double { rateMap[key] = r }
        }
        await Self.rateCache.set(from, value: rateMap)

        guard let rate = rateMap[to] else {
            throw CurrencyError.rateNotFound(from: from, to: to)
        }

        return formatConversion(amount: amount, from: from, to: to, rate: rate)
    }

    private func formatConversion(amount: Double, from: String, to: String, rate: Double) -> String {
        let converted = amount * rate
        let formatter = NumberFormatting.decimal(fractionDigits: 2)

        let formattedAmount = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        let formattedResult = formatter.string(from: NSNumber(value: converted)) ?? "\(converted)"

        return "\(formattedAmount) \(from.uppercased()) = \(formattedResult) \(to.uppercased()) (rate: \(rate))"
    }

    /// Handles queries like "What is 1 BTC worth?" or "price of ethereum" where there's
    /// no explicit "X to Y" pattern. Defaults to USD as the target currency.
    private func tryImpliedCurrencyQuery(input: String) async -> Result<String, Error>? {
        let lower = input.lowercased()

        // Known currency/crypto codes and aliases
        let allKnown = Set(Self.currencyAliases.keys).union(Set(Self.currencyAliases.values))

        // Try to find a recognizable currency/crypto token in the input
        let words = lower.wordTokens
        var matchedCode: String?
        var amount: Double = 1.0

        for (i, word) in words.enumerated() {
            if allKnown.contains(word) {
                matchedCode = resolveCurrencyCode(word)
                // Check if the preceding word is a number
                if i > 0, let num = Double(words[i - 1]) {
                    amount = num
                }
                break
            }
        }

        guard let from = matchedCode else { return nil }
        let defaultTarget = Self.localCurrencyCode()
        // Don't convert a currency to itself
        let to = (from == defaultTarget) ? "usd" : defaultTarget
        if from == to { return nil }
        do {
            return .success(try await fetchCurrencyRate(amount: amount, from: from, to: to))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - LLM Self-Healing Normalizer

    /// Uses a short LLM call to extract a structured "<value> <fromUnit> to <toUnit>" string
    /// from ambiguous natural language input that the regex couldn't parse.
    private func llmNormalize(input: String) async -> String? {
        let prompt = """
        Extract the conversion from this request. Output ONLY in the format: <number> <unit> to <unit>
        Use short unit names: kg, lbs, km, mi, m, ft, cm, mm, oz, g, mg, celsius, fahrenheit, kelvin, liters, gallons, pints, cups, usd, eur, gbp, jpy, btc, eth.
        If no conversion can be extracted, output NONE.

        Request: \(input)
        """

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(prompt)
            } else {
                response = try await LLMAdapter.shared.generateText(prompt)
            }

            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased() == "NONE" || trimmed.isEmpty {
                return nil
            }
            Log.tools.debug("LLM normalized: '\(input)' → '\(trimmed)'")
            return trimmed
        } catch {
            Log.tools.debug("LLM normalization failed: \(error)")
            return nil
        }
    }

    // MARK: - Text Encoding Conversions

    /// Known encoding format names.
    private static let encodingFormats: Set<String> = [
        "binary", "hex", "hexadecimal", "base64", "nato", "morse",
        "text", "ascii", "decimal", "octal", "url", "rot13", "roman",
        "rgb", "hsl", "cmyk",
    ]

    /// Tries to match "X to binary", "hello to hex", "decode base64 SGVsbG8=", etc.
    /// Also auto-detects raw binary, hex, and roman numeral inputs.
    private func tryTextEncoding(input: String) -> String? {
        let lower = input.lowercased()
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Color format conversion: "#FF5733 to rgb", "rgb(255,87,51) to hex", "#FF5733 to hsl"
        if let colorResult = tryColorConversion(input: lower) {
            return colorResult
        }

        // Pattern 1: "<data> to/in <encoding>" — cross-conversion (e.g. "XXVIII in hex", "01000101 in base64")
        if let match = Self.toPatternRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)) {
            let text = (input as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let format = (lower as NSString).substring(with: match.range(at: 2))
            if Self.encodingFormats.contains(format) {
                // First decode the source data to plain text, then encode to target format
                if let decoded = autoDecodeToText(text) {
                    return encode(text: decoded, to: format)
                }
                return encode(text: text, to: format)
            }
        }

        // Pattern 2: "decode <encoding> <data>" / "<encoding> decode <data>"
        if let match = Self.decodePatternRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)) {
            let format: String
            let data: String
            if match.range(at: 1).location != NSNotFound {
                format = (lower as NSString).substring(with: match.range(at: 1))
                data = (input as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            } else {
                format = (lower as NSString).substring(with: match.range(at: 3))
                data = (input as NSString).substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
            }
            if Self.encodingFormats.contains(format) {
                return decode(data: data, from: format)
            }
        }

        // Pattern 3: Auto-detect raw formats (no explicit "to"/"decode" keyword)
        if let autoResult = tryAutoDetect(input: trimmed) {
            return autoResult
        }

        return nil
    }

    // MARK: - Auto-Detection

    /// Pre-compiled regexes for auto-detection patterns.
    private static let binaryRegex = try! NSRegularExpression(pattern: #"^[01]{8}(\s+[01]{8})+$"#)
    private static let hexRegex = try! NSRegularExpression(pattern: #"^[0-9a-fA-F]{2}(\s+[0-9a-fA-F]{2})+$"#)
    private static let romanRegex = try! NSRegularExpression(pattern: #"^[IVXLCDM]+$"#)

    /// Detects whether the input looks like raw binary, hex, or roman numeral data
    /// and returns it in the format the router's `checkEncodingFormats` detected.
    static func looksLikeEncodedData(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if matchesRegex(trimmed, regex: binaryRegex) { return true }
        if matchesRegex(trimmed, regex: hexRegex) { return true }
        if trimmed.count >= 2, trimmed.count <= 20, matchesRegex(trimmed.uppercased(), regex: romanRegex),
           romanToInt(trimmed.uppercased()) != nil { return true }
        return false
    }

    /// Attempts to auto-detect and decode raw binary, hex, or roman numeral input.
    private func tryAutoDetect(input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Raw binary: "01001000 01101001"
        if Self.matchesRegex(trimmed, regex: Self.binaryRegex) {
            return decode(data: trimmed, from: "binary")
        }

        // Raw hex: "48 69"
        if Self.matchesRegex(trimmed, regex: Self.hexRegex) {
            return decode(data: trimmed, from: "hex")
        }

        // Roman numeral: "XXVIII"
        let upper = trimmed.uppercased()
        if trimmed.count >= 2, trimmed.count <= 20,
           Self.matchesRegex(upper, regex: Self.romanRegex),
           let value = Self.romanToInt(upper) {
            return "Roman \(upper) → \(value)"
        }

        return nil
    }

    /// Tries to auto-decode the source data to plain text for cross-conversion.
    /// For example, "XXVIII in hex" → decode roman to "28", then encode "28" to hex.
    private func autoDecodeToText(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Binary → text
        if Self.matchesRegex(trimmed, regex: Self.binaryRegex) {
            let bytes = trimmed.split(separator: " ").compactMap { UInt8($0, radix: 2) }
            guard !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }

        // Hex → text
        if Self.matchesRegex(trimmed, regex: Self.hexRegex) {
            let cleaned = trimmed.replacingOccurrences(of: " ", with: "")
            var bytes: [UInt8] = []
            var i = cleaned.startIndex
            while i < cleaned.endIndex {
                guard let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) else { break }
                if let byte = UInt8(cleaned[i..<next], radix: 16) { bytes.append(byte) }
                i = next
            }
            guard !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }

        // Roman → decimal string
        let upper = trimmed.uppercased()
        if trimmed.count >= 2, trimmed.count <= 20,
           Self.matchesRegex(upper, regex: Self.romanRegex),
           let value = Self.romanToInt(upper) {
            return String(value)
        }

        return nil
    }

    private static func matchesRegex(_ input: String, regex: NSRegularExpression) -> Bool {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.firstMatch(in: input, range: range) != nil
    }

    // MARK: - Roman Numerals

    private static let romanValues: [(String, Int)] = [
        ("M", 1000), ("CM", 900), ("D", 500), ("CD", 400),
        ("C", 100), ("XC", 90), ("L", 50), ("XL", 40),
        ("X", 10), ("IX", 9), ("V", 5), ("IV", 4), ("I", 1),
    ]

    /// Converts a roman numeral string to an integer, or nil if invalid.
    static func romanToInt(_ roman: String) -> Int? {
        var result = 0
        var remaining = roman[roman.startIndex...]

        for (symbol, value) in romanValues {
            while remaining.hasPrefix(symbol) {
                result += value
                remaining = remaining.dropFirst(symbol.count)
            }
        }

        // Validate: must consume entire string and result must be > 0
        guard remaining.isEmpty, result > 0 else { return nil }
        // Round-trip check: converting back should produce the same string
        guard intToRoman(result) == roman else { return nil }
        return result
    }

    /// Converts an integer to a roman numeral string.
    static func intToRoman(_ value: Int) -> String {
        var result = ""
        var remaining = value
        for (symbol, val) in romanValues {
            while remaining >= val {
                result += symbol
                remaining -= val
            }
        }
        return result
    }

    private func encode(text: String, to format: String) -> String? {
        switch format {
        case "binary":
            let binary = text.utf8.map { String($0, radix: 2).leftPadded(to: 8) }.joined(separator: " ")
            return "\(text) → Binary: \(binary)"

        case "hex", "hexadecimal":
            let hex = text.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "\(text) → Hex: \(hex)"

        case "base64":
            guard let encoded = text.data(using: .utf8)?.base64EncodedString() else { return nil }
            return "\(text) → Base64: \(encoded)"

        case "nato":
            let result = text.uppercased().compactMap { Self.natoAlphabet[$0] }.joined(separator: " ")
            guard !result.isEmpty else { return nil }
            return "\(text) → NATO: \(result)"

        case "morse":
            let result = text.uppercased().compactMap { Self.morseCode[$0] }.joined(separator: " ")
            guard !result.isEmpty else { return nil }
            return "\(text) → Morse: \(result)"

        case "ascii", "decimal":
            let ascii = text.unicodeScalars.map { String($0.value) }.joined(separator: " ")
            return "\(text) → ASCII: \(ascii)"

        case "octal":
            let octal = text.utf8.map { String($0, radix: 8).leftPadded(to: 3) }.joined(separator: " ")
            return "\(text) → Octal: \(octal)"

        case "url":
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return "\(text) → URL: \(encoded)"

        case "rot13":
            let rot13 = String(text.map { Self.rot13($0) })
            return "\(text) → ROT13: \(rot13)"

        case "roman":
            guard let value = Int(text) ?? Self.romanToInt(text.uppercased()) else {
                return nil
            }
            guard value > 0, value <= 3999 else { return nil }
            let roman = Self.intToRoman(value)
            return "\(text) → Roman: \(roman)"

        default:
            return nil
        }
    }

    private func decode(data: String, from format: String) -> String? {
        switch format {
        case "binary":
            let bytes = data.split(separator: " ").compactMap { UInt8($0, radix: 2) }
            guard !bytes.isEmpty else { return nil }
            let text = String(bytes: bytes, encoding: .utf8) ?? "Invalid binary"
            return "Binary → Text: \(text)"

        case "hex", "hexadecimal":
            let cleaned = data.replacingOccurrences(of: " ", with: "")
            var bytes: [UInt8] = []
            var i = cleaned.startIndex
            while i < cleaned.endIndex {
                guard let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) else { break }
                if let byte = UInt8(cleaned[i..<next], radix: 16) { bytes.append(byte) }
                i = next
            }
            guard !bytes.isEmpty else { return nil }
            let text = String(bytes: bytes, encoding: .utf8) ?? "Invalid hex"
            return "Hex → Text: \(text)"

        case "base64":
            guard let decoded = Data(base64Encoded: data),
                  let text = String(data: decoded, encoding: .utf8) else {
                return "Invalid Base64 input"
            }
            return "Base64 → Text: \(text)"

        case "rot13":
            let text = String(data.map { Self.rot13($0) })
            return "ROT13 → Text: \(text)"

        case "url":
            guard let decoded = data.removingPercentEncoding else { return nil }
            return "URL → Text: \(decoded)"

        default:
            return nil
        }
    }

    // MARK: - Encoding Tables

    private static let natoAlphabet: [Character: String] = [
        "A": "Alpha", "B": "Bravo", "C": "Charlie", "D": "Delta",
        "E": "Echo", "F": "Foxtrot", "G": "Golf", "H": "Hotel",
        "I": "India", "J": "Juliet", "K": "Kilo", "L": "Lima",
        "M": "Mike", "N": "November", "O": "Oscar", "P": "Papa",
        "Q": "Quebec", "R": "Romeo", "S": "Sierra", "T": "Tango",
        "U": "Uniform", "V": "Victor", "W": "Whiskey", "X": "X-ray",
        "Y": "Yankee", "Z": "Zulu",
        "0": "Zero", "1": "One", "2": "Two", "3": "Three", "4": "Four",
        "5": "Five", "6": "Six", "7": "Seven", "8": "Eight", "9": "Nine",
        " ": "(space)",
    ]

    private static let morseCode: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".",
        "F": "..-.", "G": "--.", "H": "....", "I": "..", "J": ".---",
        "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---",
        "P": ".--.", "Q": "--.-", "R": ".-.", "S": "...", "T": "-",
        "U": "..-", "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--",
        "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        " ": "/",
    ]

    private static func rot13(_ c: Character) -> Character {
        guard let ascii = c.asciiValue else { return c }
        if ascii >= 65 && ascii <= 90 { // A-Z
            return Character(UnicodeScalar(((ascii - 65 + 13) % 26) + 65))
        }
        if ascii >= 97 && ascii <= 122 { // a-z
            return Character(UnicodeScalar(((ascii - 97 + 13) % 26) + 97))
        }
        return c
    }

    // MARK: - Color Format Conversion

    private static let hexColorRegex = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))#?([0-9a-fA-F]{6})(?:\s|$)"#)
    private static let rgbColorRegex = try! NSRegularExpression(pattern: #"rgb\s*\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)"#, options: .caseInsensitive)
    private static let hslColorRegex = try! NSRegularExpression(pattern: #"hsl\s*\(\s*(\d{1,3})\s*,\s*(\d{1,3})%?\s*,\s*(\d{1,3})%?\s*\)"#, options: .caseInsensitive)

    private func tryColorConversion(input: String) -> String? {
        let lower = input.lowercased()

        // Determine target format
        let targetFormats = ["hex", "rgb", "hsl", "cmyk"]
        guard let target = targetFormats.first(where: { lower.hasSuffix("to \($0)") || lower.hasSuffix("in \($0)") }) else {
            return nil
        }

        // Try to parse source color
        var r: Int = 0, g: Int = 0, b: Int = 0

        // Parse hex: #FF5733 or FF5733
        if let match = Self.hexColorRegex.firstMatch(in: input, range: NSRange(input.startIndex..<input.endIndex, in: input)) {
            let hex = (input as NSString).substring(with: match.range(at: 1))
            guard let rgb = UInt64(hex, radix: 16) else { return nil }
            r = Int((rgb >> 16) & 0xFF)
            g = Int((rgb >> 8) & 0xFF)
            b = Int(rgb & 0xFF)
        }
        // Parse rgb(255, 87, 51)
        else if let match = Self.rgbColorRegex.firstMatch(in: input, range: NSRange(input.startIndex..<input.endIndex, in: input)) {
            r = Int((input as NSString).substring(with: match.range(at: 1))) ?? 0
            g = Int((input as NSString).substring(with: match.range(at: 2))) ?? 0
            b = Int((input as NSString).substring(with: match.range(at: 3))) ?? 0
        }
        // Parse hsl(14, 100%, 60%)
        else if let match = Self.hslColorRegex.firstMatch(in: input, range: NSRange(input.startIndex..<input.endIndex, in: input)) {
            let h = Double(Int((input as NSString).substring(with: match.range(at: 1))) ?? 0) / 360.0
            let s = Double(Int((input as NSString).substring(with: match.range(at: 2))) ?? 0) / 100.0
            let l = Double(Int((input as NSString).substring(with: match.range(at: 3))) ?? 0) / 100.0
            let (cr, cg, cb) = hslToRGB(h: h, s: s, l: l)
            r = cr; g = cg; b = cb
        }
        else {
            return nil
        }

        // Convert to target
        switch target {
        case "hex":
            return "RGB(\(r), \(g), \(b)) → #\(String(format: "%02X%02X%02X", r, g, b))"
        case "rgb":
            return "#\(String(format: "%02X%02X%02X", r, g, b)) → RGB(\(r), \(g), \(b))"
        case "hsl":
            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            return "#\(String(format: "%02X%02X%02X", r, g, b)) → HSL(\(h), \(s)%, \(l)%)"
        case "cmyk":
            let (c, m, y, k) = rgbToCMYK(r: r, g: g, b: b)
            return "#\(String(format: "%02X%02X%02X", r, g, b)) → CMYK(\(c)%, \(m)%, \(y)%, \(k)%)"
        default:
            return nil
        }
    }

    private func rgbToHSL(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
        let l = (maxC + minC) / 2

        guard maxC != minC else { return (0, 0, Int(round(l * 100))) }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == rf { h = (gf - bf) / d + (gf < bf ? 6 : 0) }
        else if maxC == gf { h = (bf - rf) / d + 2 }
        else { h = (rf - gf) / d + 4 }
        h /= 6
        return (Int(round(h * 360)), Int(round(s * 100)), Int(round(l * 100)))
    }

    private func hslToRGB(h: Double, s: Double, l: Double) -> (Int, Int, Int) {
        guard s > 0 else {
            let v = Int(round(l * 255))
            return (v, v, v)
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2rgb(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return (
            Int(round(hue2rgb(p, q, h + 1/3) * 255)),
            Int(round(hue2rgb(p, q, h) * 255)),
            Int(round(hue2rgb(p, q, h - 1/3) * 255))
        )
    }

    private func rgbToCMYK(r: Int, g: Int, b: Int) -> (Int, Int, Int, Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let k = 1 - max(rf, gf, bf)
        guard k < 1 else { return (0, 0, 0, 100) }
        let c = (1 - rf - k) / (1 - k)
        let m = (1 - gf - k) / (1 - k)
        let y = (1 - bf - k) / (1 - k)
        return (Int(round(c * 100)), Int(round(m * 100)), Int(round(y * 100)), Int(round(k * 100)))
    }

    // MARK: - Unit Conversions

    private func performConversion(value: Double, from: String, to: String) -> String? {
        // Length
        let lengthUnits: [String: UnitLength] = [
            "mile": .miles, "miles": .miles, "mi": .miles,
            "km": .kilometers, "kilometers": .kilometers, "kilometer": .kilometers,
            "m": .meters, "meter": .meters, "meters": .meters,
            "foot": .feet, "feet": .feet, "ft": .feet,
            "inch": .inches, "inches": .inches, "in": .inches,
            "cm": .centimeters, "centimeters": .centimeters,
            "mm": .millimeters, "millimeters": .millimeters
        ]
        
        if let fromUnit = lengthUnits[from], let toUnit = lengthUnits[to] {
            let measurement = Measurement(value: value, unit: fromUnit)
            let converted = measurement.converted(to: toUnit)
            return "\(value) \(from) = \(String(format: "%.2f", converted.value)) \(to)"
        }
        
        // Mass
        let massUnits: [String: UnitMass] = [
            "kg": .kilograms, "kilogram": .kilograms, "kilograms": .kilograms,
            "lb": .pounds, "lbs": .pounds, "pound": .pounds, "pounds": .pounds,
            "g": .grams, "gram": .grams, "grams": .grams,
            "oz": .ounces, "ounce": .ounces, "ounces": .ounces,
            "mg": .milligrams, "milligrams": .milligrams
        ]
        
        if let fromUnit = massUnits[from], let toUnit = massUnits[to] {
            let measurement = Measurement(value: value, unit: fromUnit)
            let converted = measurement.converted(to: toUnit)
            return "\(value) \(from) = \(String(format: "%.2f", converted.value)) \(to)"
        }
        
        // Volume
        let volumeUnits: [String: UnitVolume] = [
            "liter": .liters, "liters": .liters, "l": .liters, "litre": .liters, "litres": .liters,
            "ml": .milliliters, "milliliter": .milliliters, "milliliters": .milliliters,
            "gallon": .gallons, "gallons": .gallons, "gal": .gallons,
            "cup": .cups, "cups": .cups,
            "pint": .pints, "pints": .pints, "pt": .pints,
            "quart": .quarts, "quarts": .quarts, "qt": .quarts,
            "floz": .fluidOunces, "fl oz": .fluidOunces,
            "tablespoon": .tablespoons, "tablespoons": .tablespoons, "tbsp": .tablespoons,
            "teaspoon": .teaspoons, "teaspoons": .teaspoons, "tsp": .teaspoons,
        ]

        // "ounces" in a volume context (when paired with a volume unit) → fluid ounces
        if let fromUnit = volumeUnits[from], let toUnit = volumeUnits[to] {
            let measurement = Measurement(value: value, unit: fromUnit)
            let converted = measurement.converted(to: toUnit)
            return "\(value) \(from) = \(String(format: "%.2f", converted.value)) \(to)"
        }
        // Handle "ounces" as fluid ounces when the other unit is a volume unit
        if (volumeUnits[from] != nil && to == "ounces") || (from == "ounces" && volumeUnits[to] != nil) {
            let fromVol = volumeUnits[from] ?? .fluidOunces
            let toVol = volumeUnits[to] ?? .fluidOunces
            let measurement = Measurement(value: value, unit: fromVol)
            let converted = measurement.converted(to: toVol)
            return "\(value) \(from) = \(String(format: "%.2f", converted.value)) \(to)"
        }

        // Temperature
        let tempUnits: [String: UnitTemperature] = [
            "c": .celsius, "celsius": .celsius, "centigrade": .celsius,
            "f": .fahrenheit, "fahrenheit": .fahrenheit,
            "k": .kelvin, "kelvin": .kelvin
        ]
        
        if let fromUnit = tempUnits[from], let toUnit = tempUnits[to] {
            let measurement = Measurement(value: value, unit: fromUnit)
            let converted = measurement.converted(to: toUnit)
            let result = String(format: "%.2f", converted.value)

            // Include correct formula to prevent LLM hallucination
            let fKeys: Set<String> = ["f", "fahrenheit"]
            let cKeys: Set<String> = ["c", "celsius", "centigrade"]
            let kKeys: Set<String> = ["k", "kelvin"]
            if fKeys.contains(from) && cKeys.contains(to) {
                return "(\(value) - 32) / 1.8 = \(result) \(to)"
            } else if fKeys.contains(from) && kKeys.contains(to) {
                return "(\(value) - 32) / 1.8 + 273.15 = \(result) \(to)"
            } else if cKeys.contains(from) && fKeys.contains(to) {
                return "\(value) * 1.8 + 32 = \(result) \(to)"
            } else if cKeys.contains(from) && kKeys.contains(to) {
                return "\(value) + 273.15 = \(result) \(to)"
            } else if kKeys.contains(from) && cKeys.contains(to) {
                return "\(value) - 273.15 = \(result) \(to)"
            } else if kKeys.contains(from) && fKeys.contains(to) {
                return "(\(value) - 273.15) * 1.8 + 32 = \(result) \(to)"
            }
            return "\(value) \(from) = \(result) \(to)"
        }
        
        return nil
    }
}

private extension String {
    func leftPadded(to width: Int, with char: Character = "0") -> String {
        if count >= width { return self }
        return String(repeating: char, count: width - count) + self
    }
}

/// AppIntent wrapping ConvertTool.
public struct ConvertIntent: AppIntent {
    public static var title: LocalizedStringResource { "Convert Currency" }
    public static var description: IntentDescription? { IntentDescription("Converts currency using the iClaw ConvertTool.") }

    @Parameter(title: "Request")
    public var request: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = ConvertTool()
        let result = try await tool.execute(input: request, entities: nil)
        return .result(value: result.text)
    }
}
