import Foundation

/// Structured arguments for LLM-extracted stock requests.
public struct StockArgs: ToolArguments {
    public let ticker: String
    public let intent: String?
}

public struct StockTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Stocks"
    public let schema = "Get current stock price quote quotes market ticker symbol shares equity AAPL MSFT TSLA NVDA Apple Microsoft Tesla Amazon Google stocks trading finance financial investment"
    public let isInternal = false
    public let category = CategoryEnum.online

    private static let companyTickerMap: [String: String] = {
        guard let url = Bundle.iClawCore.url(forResource: "CompanyTickers", withExtension: "json", subdirectory: "Config"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }()

    /// Search rawInput for known company names (case-insensitive) and return the mapped ticker.
    static func resolveCompanyName(from input: String) -> String? {
        resolveCompanyNames(from: input).first
    }

    /// Returns ALL tickers mentioned in `input`, in input order. Catches
    /// "Apple and Microsoft", "compare AAPL, TSLA, and MSFT", etc. Dedup'd
    /// while preserving first-seen order. Matches:
    ///   - Company names in `CompanyTickers.json`
    ///   - Bare uppercase ticker patterns ($AAPL / "AAPL" — 1-5 letters).
    static func resolveCompanyNames(from input: String) -> [String] {
        let lower = input.lowercased()
        var hits: [(ticker: String, offset: Int)] = []
        // Company-name matches, sorted longest-first so "Bank of America"
        // beats "America" on overlap.
        for (company, ticker) in companyTickerMap.sorted(by: { $0.key.count > $1.key.count }) {
            let key = company.lowercased()
            var searchStart = lower.startIndex
            while searchStart < lower.endIndex,
                  let r = lower.range(of: key, range: searchStart..<lower.endIndex) {
                let offset = lower.distance(from: lower.startIndex, to: r.lowerBound)
                hits.append((ticker.uppercased(), offset))
                searchStart = r.upperBound
            }
        }
        // Bare uppercase tickers: `\$?[A-Z]{2,5}\b`. Only in the ORIGINAL-case
        // string, so lowercase words don't match.
        if let re = try? NSRegularExpression(pattern: #"\$?([A-Z]{2,5})\b"#) {
            let range = NSRange(input.startIndex..., in: input)
            re.enumerateMatches(in: input, options: [], range: range) { match, _, _ in
                guard let m = match,
                      let tokenRange = Range(m.range(at: 1), in: input) else { return }
                let token = String(input[tokenRange]).uppercased()
                // Keep only recognized tickers to avoid picking up acronyms
                if TickerLookup.lookup(symbol: token) != nil {
                    let offset = input.distance(from: input.startIndex, to: tokenRange.lowerBound)
                    hits.append((token, offset))
                }
            }
        }
        // Sort by occurrence order, dedup preserving first-seen.
        hits.sort { $0.offset < $1.offset }
        var seen = Set<String>()
        return hits.compactMap { seen.insert($0.ticker).inserted ? $0.ticker : nil }
    }

    /// Safari-style User-Agent with the real macOS version.
    private static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(osVersion)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v.majorVersion - 8).0 Safari/605.1.15"
    }()

    private static let cache = TTLCache<StockWidgetData>(ttl: 300) // 5 min TTL
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        // Bound per-request time so a single slow Yahoo Finance call
        // cannot stall the daemon. Batch requests against 4+ symbols
        // were observed at 19s in the manual session; with this cap
        // each symbol is gated at 15s and the daemon remains responsive.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    // MARK: - ExtractableCoreTool

    public typealias Args = StockArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Stock", fallback: "{\"ticker\":\"string\"}"
    )

    public func execute(args: StockArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await timed {
            // Multi-ticker fast-path: if the input references ≥2 distinct
            // recognized tickers, fetch them all and return a combined
            // response. Avoids the "compare AAPL and MSFT" fabrication where
            // the single-ticker path lets the LLM fill in the second number.
            let tickers = Self.resolveCompanyNames(from: rawInput)
            if tickers.count >= 2 {
                return await fetchMultiple(symbols: Array(tickers.prefix(5)))
            }

            // Resolve company name from raw input first, falling back to extracted ticker.
            // CompanyTickers.json provides fast-path resolution for ~60 common names.
            // If that misses, use the LLM-extracted ticker directly — Yahoo Finance
            // can resolve many symbols beyond our local lookup table.
            let symbol: String
            if let widgetTicker = entities?.widgetPayload?["ticker"] {
                symbol = widgetTicker.uppercased()
            } else if let resolved = Self.resolveCompanyName(from: rawInput) {
                symbol = resolved
            } else {
                symbol = args.ticker.uppercased()
            }

            // Reject empty or obviously invalid symbols.
            guard !symbol.isEmpty, symbol.count <= 10,
                  symbol.rangeOfCharacter(from: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "."))) == nil else {
                return ToolIO(
                    text: "Invalid ticker symbol '\(symbol)'. Try using the exact ticker like '$AAPL'.",
                    status: .error
                )
            }

            // If the symbol is NOT a known stock ticker AND wasn't resolved from
            // a known company name, it might be a commodity (gold, oil), index,
            // or unrecognized entity. Return a helpful partial result instead of
            // querying Yahoo Finance (which would return an ETF price, not the
            // commodity spot price — e.g., GLD=$43 instead of gold=$3000).
            let isKnownTicker = TickerLookup.lookup(symbol: symbol) != nil
            let isKnownCompany = Self.resolveCompanyName(from: rawInput) != nil
            if !isKnownTicker && !isKnownCompany {
                return ToolIO(
                    text: "'\(symbol)' is not a recognized stock ticker. This may be a commodity, index, or unrecognized symbol. Search the web for current '\(rawInput)' pricing.",
                    status: .ok
                )
            }

            // Check cache
            if let cached = await Self.cache.get(symbol) {
                return buildResponse(for: cached)
            }

            // Refresh cookies and get crumb
            let crumb = try await getCrumb()

            // Fetch data concurrently
            async let quoteData = fetchQuote(symbol: symbol, crumb: crumb)
            async let typeData = fetchQuoteType(symbol: symbol)
            async let recommendationsData = fetchRecommendations(symbol: symbol)

            do {
                let quote = try await quoteData
                let type = try await typeData
                let recommendations = (try? await recommendationsData) ?? []

                let widgetData = StockWidgetData(
                    symbol: quote.symbol,
                    name: type ?? quote.name,
                    currentPrice: quote.price,
                    changeAmount: quote.change,
                    changePercent: quote.changePercent,
                    recommendations: recommendations
                )

                await Self.cache.set(symbol, value: widgetData)
                return buildResponse(for: widgetData)
            } catch {
                return ToolIO(
                    text: "Failed to fetch stock data for \(symbol). Error: \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    /// Fetches quotes for multiple tickers concurrently. Returns a combined
    /// response where each quote is either verified live data or an explicit
    /// failure note — never a fabrication.
    private func fetchMultiple(symbols: [String]) async -> ToolIO {
        let start = Date()
        let crumb = (try? await getCrumb()) ?? ""
        // Fetch each symbol concurrently with independent timeouts
        let results: [(symbol: String, widget: StockWidgetData?, error: String?)] = await withTaskGroup(of: (String, StockWidgetData?, String?).self) { group in
            for sym in symbols {
                group.addTask {
                    if let cached = await Self.cache.get(sym) {
                        return (sym, cached, nil)
                    }
                    do {
                        async let quoteData = self.fetchQuote(symbol: sym, crumb: crumb)
                        async let typeData = self.fetchQuoteType(symbol: sym)
                        let q = try await quoteData
                        let t = try? await typeData
                        let w = StockWidgetData(
                            symbol: q.symbol,
                            name: t ?? q.name,
                            currentPrice: q.price,
                            changeAmount: q.change,
                            changePercent: q.changePercent,
                            recommendations: []
                        )
                        await Self.cache.set(sym, value: w)
                        return (sym, w, nil)
                    } catch {
                        return (sym, nil, error.localizedDescription)
                    }
                }
            }
            var out: [(String, StockWidgetData?, String?)] = []
            for await item in group { out.append(item) }
            // Restore input order
            return symbols.compactMap { s in out.first(where: { $0.0 == s }) }
        }

        // Build response. Each line is [VERIFIED] so the finalizer's
        // isVerifiedData guard prevents paraphrase that would mangle numbers.
        var lines: [String] = []
        for r in results {
            if let w = r.widget {
                let pct = String(format: "%.2f", w.changePercent)
                let sign = w.changeAmount >= 0 ? "+" : ""
                lines.append("\(w.symbol) (\(w.name)): $\(String(format: "%.2f", w.currentPrice)) \(sign)\(String(format: "%.2f", w.changeAmount)) (\(sign)\(pct)%)")
            } else {
                lines.append("\(r.symbol): fetch failed — \(r.error ?? "no data")")
            }
        }
        let text = lines.joined(separator: "\n")
        let elapsed = Date().timeIntervalSince(start)
        // Reuse the StockWidget with the first successful result as the
        // primary payload; the ingredient text carries all rows.
        let primary = results.first(where: { $0.widget != nil })?.widget
        return ToolIO(
            text: text,
            status: .ok,
            timeTaken: elapsed,
            outputWidget: primary != nil ? "StockWidget" : nil,
            widgetData: primary,
            isVerifiedData: true
        )
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
            // Multi-ticker fast-path (same as the Extractable entry point).
            let tickers = Self.resolveCompanyNames(from: input)
            if tickers.count >= 2 {
                return await fetchMultiple(symbols: Array(tickers.prefix(5)))
            }

            // Resolve company name first, falling back to NL ticker extraction.
            // CompanyTickers.json provides fast-path resolution for common names.
            let finalSymbol: String
            if let resolved = Self.resolveCompanyName(from: input) {
                finalSymbol = resolved
            } else {
                finalSymbol = Self.extractTicker(from: input, entities: entities)
            }

            guard !finalSymbol.isEmpty, finalSymbol.count <= 10,
                  finalSymbol.rangeOfCharacter(from: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "."))) == nil else {
                return ToolIO(
                    text: "Couldn't determine a ticker symbol from '\(input)'. Try '$AAPL' or 'Apple stock'.",
                    status: .error
                )
            }

            // Unknown symbol check — same as ExtractableCoreTool path
            let isKnownTicker = TickerLookup.lookup(symbol: finalSymbol) != nil
            let isKnownCompany = Self.resolveCompanyName(from: input) != nil
            if !isKnownTicker && !isKnownCompany {
                return ToolIO(
                    text: "'\(finalSymbol)' is not a recognized stock ticker. This may be a commodity, index, or unrecognized symbol. Search the web for current '\(input)' pricing.",
                    status: .ok
                )
            }

            // 1. Check cache (5 min TTL)
            if let cached = await Self.cache.get(finalSymbol) {
                return buildResponse(for: cached)
            }

            // 2. Refresh cookies and get crumb
            let crumb = try await getCrumb()

            // 3. Fetch data concurrently
            async let quoteData = fetchQuote(symbol: finalSymbol, crumb: crumb)
            async let typeData = fetchQuoteType(symbol: finalSymbol)
            async let recommendationsData = fetchRecommendations(symbol: finalSymbol)

            do {
                let quote = try await quoteData
                let type = try await typeData
                let recommendations = (try? await recommendationsData) ?? []

                let widgetData = StockWidgetData(
                    symbol: quote.symbol,
                    name: type ?? quote.name, // Fallback to quote name if type name missing
                    currentPrice: quote.price,
                    changeAmount: quote.change,
                    changePercent: quote.changePercent,
                    recommendations: recommendations
                )

                await Self.cache.set(finalSymbol, value: widgetData)
                return buildResponse(for: widgetData)
            } catch {
                return ToolIO(
                    text: "Failed to fetch stock data for \(finalSymbol). Error: \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    /// Extract a ticker symbol from natural language input.
    /// Checks NER organizations first (tagger identifies tickers like "AAPL" as orgs),
    /// then searches for known phrases ("price of", "stock price for") anywhere in the input,
    /// then falls back to uppercase word patterns.
    private static func extractTicker(from input: String, entities: ExtractedEntities?) -> String {
        // 1. NER entities — tagger identifies short uppercase tickers as organizations
        if let org = entities?.organizations.first, org.count <= 5, org.allSatisfy(\.isLetter) {
            return org.uppercased()
        }

        // 2. Find ticker after known phrases (anywhere in input, not just prefix)
        let phrases = ["stock price for ", "stock price of ", "price of ", "price for ",
                       "quote for ", "#stocks ", "stock "]
        let lower = input.lowercased()
        for phrase in phrases {
            if let range = lower.range(of: phrase) {
                let after = String(input[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let word = after.components(separatedBy: .whitespaces).first ?? ""
                let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                if !cleaned.isEmpty {
                    return cleaned.uppercased()
                }
            }
        }

        // 3. Uppercase word pattern — 1-5 all-letter uppercase words, excluding common English
        // and financial meta-words that aren't tickers
        let commonUpper: Set<String> = [
            "I", "A", "THE", "IN", "FOR", "TO", "OF", "IS", "IT", "AT",
            "MY", "ME", "AM", "OR", "AN", "AND", "GET", "SET", "HAS", "DO",
            "BE", "ARE", "WAS", "CAN", "HOW", "NOT", "BUT", "ALL", "HIM",
            "HER", "ITS", "OUR", "WHO", "USE", "DID", "ANY", "NEW", "NOW",
            "SHOW", "CHECK", "WHAT", "GIVE", "ALSO",
            "STOCK", "STOCKS", "PRICE", "SHARE", "TRADE", "BUY", "SELL",
            "QUOTE", "MARKET", "VALUE", "WORTH",
        ]
        let words = input.components(separatedBy: .whitespaces)
        if let ticker = words.first(where: {
            let t = $0.trimmingCharacters(in: .punctuationCharacters)
            return t.count >= 1 && t.count <= 5 && t == t.uppercased()
                && t.allSatisfy(\.isLetter) && !commonUpper.contains(t)
        }) {
            return ticker.trimmingCharacters(in: .punctuationCharacters).uppercased()
        }

        // 4. Last word fallback — only if it looks like a ticker (1-5 uppercase letters,
        // not a common English word). Prevents "show the earnings breakdown" → "BREAKDOWN".
        for word in words.reversed() {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters).uppercased()
            if cleaned.count >= 1 && cleaned.count <= 5 && cleaned.allSatisfy(\.isLetter)
                && !commonUpper.contains(cleaned) {
                return cleaned
            }
        }
        return ""
    }

    private func buildResponse(for data: StockWidgetData) -> ToolIO {
        return ToolIO(
            text: "\(data.name) (\(data.symbol)): $\(data.currentPrice), \(data.changeAmount >= 0 ? "+" : "")\(String(format: "%.2f", data.changeAmount)) (\(String(format: "%.2f", data.changePercent))%)",
            status: .ok,
            outputWidget: "StockWidget",
            widgetData: data,
            isVerifiedData: true
        )
    }

    private func getCrumb() async throws -> String {
        // Step 1: Hit yahoo to get cookies
        let initialURL = APIEndpoints.Yahoo.cookieURL
        var req1 = URLRequest(url: initialURL)
        req1.timeoutInterval = 10
        req1.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req1.setValue("text/html", forHTTPHeaderField: "Accept")
        _ = try? await session.data(for: req1)

        // Step 2: Get crumb
        let crumbURL = APIEndpoints.Yahoo.crumbURL
        var req2 = URLRequest(url: crumbURL)
        req2.timeoutInterval = 10
        req2.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: req2)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let crumb = String(data: data, encoding: .utf8) else {
            return "" // Might still work without crumb for some endpoints
        }
        return crumb.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchQuote(symbol: String, crumb: String) async throws -> (symbol: String, name: String, price: Double, change: Double, changePercent: Double) {
        guard let url = APIEndpoints.Yahoo.quoteSummary(symbol: symbol, modules: "price,summaryDetail,defaultKeyStatistics", crumb: crumb) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            throw ToolError.apiError(service: "Yahoo Finance", code: 429, message: "Stock data temporarily unavailable for \(symbol)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quoteSummary = json["quoteSummary"] as? [String: Any],
              let result = (quoteSummary["result"] as? [[String: Any]])?.first,
              let priceData = result["price"] as? [String: Any],
              let currentPriceRaw = priceData["regularMarketPrice"] as? [String: Any], let price = currentPriceRaw["raw"] as? Double,
              let changeRaw = priceData["regularMarketChange"] as? [String: Any], let change = changeRaw["raw"] as? Double,
              let changePercentRaw = priceData["regularMarketChangePercent"] as? [String: Any], let changePercent = changePercentRaw["raw"] as? Double else {
            throw ToolError.apiError(service: "Yahoo Finance", code: nil, message: "Unable to parse stock data for \(symbol)")
        }
        let name = priceData["shortName"] as? String ?? symbol
        return (symbol, name, price, change, changePercent * 100)
    }

    private func fetchQuoteType(symbol: String) async throws -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v1/finance/quoteType/\(symbol)"
        components.queryItems = [
            URLQueryItem(name: "formatted", value: "true"),
            URLQueryItem(name: "enablePrivateCompany", value: "true"),
            URLQueryItem(name: "overnightPrice", value: "true"),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 { return nil }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quoteType = json["quoteType"] as? [String: Any],
              let result = (quoteType["result"] as? [[String: Any]])?.first,
              let name = result["shortName"] as? String else { return nil }
        
        return name
    }

    private func fetchRecommendations(symbol: String) async throws -> [String] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "query1.finance.yahoo.com"
        components.path = "/v6/finance/recommendationsbysymbol/\(symbol)"
        components.queryItems = [
            URLQueryItem(name: "fields", value: ""),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 { return [] }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let finance = json["finance"] as? [String: Any],
              let result = (finance["result"] as? [[String: Any]])?.first,
              let recs = result["recommendedSymbols"] as? [[String: Any]] else {
            return []
        }
        
        return recs.compactMap { $0["symbol"] as? String }.prefix(3).map { $0 }
    }
}
