import Foundation
import CoreLocation
import MapKit
import os

/// Weather tool for fetching current, forecast, and detailed weather data using Open-Meteo.
///
/// Design: The tool detects the query intent from the input and fetches the appropriate
/// level of data. All computation (unit formatting, forecast summaries, comparisons)
/// happens here — the LLM only personalizes phrasing.
///
/// Intent detection uses simple prefix/keyword checks — no regex hacking.
/// Routing (synonym expansion) handles getting the query to this tool in the first place.
/// Structured arguments for LLM-extracted weather requests.
public struct WeatherArgs: ToolArguments {
    public let intent: String           // "current", "forecast", "detail", "comparison", "search"
    public let location: String?
    public let detailField: String?     // "humidity", "wind", "uv", etc.
    public let forecastDays: Int?
    public let comparisonCity: String?
    public let temperatureUnit: String? // "celsius" or "fahrenheit" — overrides system default
    public let date: String?            // "tomorrow", "next friday", "March 25", etc.
    public let searchCondition: String? // "full moon", "sunny day", etc.
}

public struct WeatherTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Weather"
    public let schema = "Get the current weather: 'weather in London', 'how's the weather today?', 'temperature in Tokyo'."
    public let isInternal = false
    public let category = CategoryEnum.online

    private let session: URLSession

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    // MARK: - Cached Date Formatters

    /// "yyyy-MM-dd" for API date parameters and parsing.
    private static let apiDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "yyyy-MM-dd'T'HH:mm" for Open-Meteo ISO timestamps (no seconds).
    private static let isoNoSecondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Medium date style for date labels.
    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// Short day-of-week abbreviation ("Mon", "Tue", ...) for forecast entries.
    private static let shortWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    /// Short time style for display.
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: - ExtractableCoreTool

    public typealias Args = WeatherArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Weather", fallback: "{\"intent\":\"current|forecast|detail|comparison\",\"location\":\"string?\"}"
    )

    public func execute(args: WeatherArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            let city = Self.sanitizeCity(args.location)

            // Apply explicit unit override if the user asked "in celsius" or "in fahrenheit"
            if let unitPref = args.temperatureUnit?.lowercased() {
                if unitPref == "celsius" {
                    Self._unitOverride.withLock { $0 = false }
                } else if unitPref == "fahrenheit" {
                    Self._unitOverride.withLock { $0 = true }
                }
            }
            defer { Self._unitOverride.withLock { $0 = nil } }

            // Resolve optional date parameter
            let targetDate: Date?
            if let dateStr = args.date {
                targetDate = DateResolver.resolve(dateStr)
            } else {
                targetDate = nil
            }

            // Safety net: keyword-based intent detection on the raw (un-garbled) input.
            // The LLM extraction can be confused by synonym-expanded text; deterministic
            // keyword matching is more reliable for specific intents like search/detail.
            let keywordIntent = detectIntent(input: rawInput, entities: entities)
            let effectiveIntent: String
            switch keywordIntent {
            case .search:
                effectiveIntent = "search"
            case .detail:
                if args.intent == "current" { effectiveIntent = "detail" } else { effectiveIntent = args.intent }
            default:
                effectiveIntent = args.intent
            }

            do {
                switch effectiveIntent {
                case "search":
                    // Prefer LLM-extracted condition, fall back to keyword-detected condition
                    let condition: String
                    if let llmCondition = args.searchCondition {
                        condition = llmCondition
                    } else if case .search(let kw) = keywordIntent {
                        condition = kw
                    } else {
                        return try await fetchCurrent(city: city)
                    }
                    return try await searchCondition(condition, city: city)
                case "forecast":
                    return try await fetchForecast(city: city, days: args.forecastDays ?? 3)
                case "detail":
                    let fieldStr = args.detailField ?? {
                        if case .detail(let f) = keywordIntent { return f.rawValue }
                        return nil
                    }()
                    if let fieldStr, let field = DetailField(rawValue: fieldStr) {
                        if field == .moon {
                            return try await fetchMoonPhase(city: city, date: targetDate)
                        }
                        if field == .sunrise || field == .sunset {
                            return try await fetchSunTimes(city: city, field: field, date: targetDate)
                        }
                        if field == .airQuality {
                            return try await fetchAirQuality(city: city)
                        }
                        return try await fetchDetail(city: city, field: field)
                    }
                    return try await fetchCurrent(city: city)
                case "comparison":
                    if let otherCity = args.comparisonCity {
                        return try await fetchComparison(city1: city, city2: otherCity)
                    }
                    return try await fetchCurrent(city: city)
                default:
                    return try await fetchCurrent(city: city)
                }
            } catch {
                return ToolIO(
                    text: "Failed to fetch weather for \(city ?? "your location"): \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    // MARK: - Intent Detection

    /// What kind of weather data the user wants.
    enum WeatherIntent {
        case current                        // default: temp + condition
        case detail(DetailField)            // specific field: wind, humidity, UV, etc.
        case forecast(days: Int)            // 3 or 7-day forecast
        case comparison(otherCity: String)  // compare two locations
        case search(condition: String)      // "next full moon", "next sunny day"
    }

    /// Specific detail fields the user can ask about.
    enum DetailField: String {
        case wind, humidity, uv, feelsLike, pressure, visibility, dewPoint, clouds, precipitation, moon, sunrise, sunset, airQuality
    }

    // MARK: - Keyword Config (loaded from JSON)

    private struct WeatherKeywordsConfig: Decodable {
        struct DetailEntry: Decodable {
            let keywords: [String]
            let field: String
        }
        struct SearchEntry: Decodable {
            let keywords: [String]
            let condition: String
        }
        let detailKeywords: [DetailEntry]
        let forecastKeywords: [String]
        let sevenDayKeywords: [String]
        let comparisonKeywords: [String]
        let searchKeywords: [SearchEntry]?
    }

    private static let keywordsConfig: WeatherKeywordsConfig? = ConfigLoader.load("WeatherKeywords", as: WeatherKeywordsConfig.self)

    /// Keywords that map to specific detail fields.
    private static let detailKeywords: [(keywords: [String], field: DetailField)] = {
        guard let config = keywordsConfig else { return [] }
        return config.detailKeywords.compactMap { entry in
            guard let field = DetailField(rawValue: entry.field) else { return nil }
            return (keywords: entry.keywords, field: field)
        }
    }()

    private static let forecastKeywords: [String] = keywordsConfig?.forecastKeywords ?? []
    private static let sevenDayKeywords: [String] = keywordsConfig?.sevenDayKeywords ?? []
    private static let comparisonKeywords: [String] = keywordsConfig?.comparisonKeywords ?? []

    /// Search keywords loaded from WeatherKeywords.json (structured entries).
    private static let searchKeywords: [(keywords: [String], condition: String)] = {
        keywordsConfig?.searchKeywords?.map { (keywords: $0.keywords, condition: $0.condition) } ?? []
    }()

    /// All weather keyword phrases (from JSON), sorted longest-first.
    /// Used by `sanitizeCity` to prevent detail/search keywords from being geocoded as locations.
    private static let allWeatherKeywords: [String] = {
        var phrases = detailKeywords.flatMap { $0.keywords }
        phrases.append(contentsOf: searchKeywords.flatMap { $0.keywords })
        return phrases.sorted { $0.count > $1.count }
    }()

    func detectIntent(input: String, entities: ExtractedEntities?) -> WeatherIntent {
        let lower = input.lowercased()

        // Check for "next X" search queries first — these are unambiguous
        for entry in Self.searchKeywords {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                return .search(condition: entry.condition)
            }
        }

        // Check for comparison: needs two locations
        if Self.comparisonKeywords.contains(where: { lower.contains($0) }) {
            if let otherCity = extractComparisonCity(from: lower, entities: entities) {
                return .comparison(otherCity: otherCity)
            }
        }

        // Check for forecast
        if Self.forecastKeywords.contains(where: { lower.contains($0) }) {
            let days = Self.sevenDayKeywords.contains(where: { lower.contains($0) }) ? 7 : 3
            return .forecast(days: days)
        }

        // Check for specific detail
        for entry in Self.detailKeywords {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                return .detail(entry.field)
            }
        }

        return .current
    }

    /// Tries to extract a second city from comparison queries like "weather London vs Paris".
    private func extractComparisonCity(from lower: String, entities: ExtractedEntities?) -> String? {
        // If NER found 2+ places, the second is the comparison target
        if let places = entities?.places, places.count >= 2 {
            return places[1]
        }

        // Try splitting on comparison keywords
        let separators = [" vs ", " versus ", " compared to ", " or ", " and "]
        for sep in separators {
            if let range = lower.range(of: sep) {
                let after = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip trailing weather noise
                let cleaned = after
                    .replacingOccurrences(of: "weather", with: "")
                    .replacingOccurrences(of: "forecast", with: "")
                    .replacingOccurrences(of: "?", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    // MARK: - City Sanitization

    /// Strips weather keywords from a city candidate so detail/search terms
    /// (e.g. "moon phase", "next full moon") are not geocoded as locations.
    /// "moon phase" → nil, "moon phase in London" → "London", "London" → "London".
    /// All keyword data comes from WeatherKeywords.json — nothing is hardcoded.
    /// Cached NSDataDetector for temporal expression detection in location fields.
    private static let dateDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    }()

    /// Temporal words that NSDataDetector won't recognise as date expressions.
    /// Kept intentionally small — NSDataDetector handles the vast majority of cases.
    private static let temporalAdverbs: Set<String> = [
        "now", "currently", "right now", "soon", "later", "recently",
        "this weekend", "this week", "next week",
        "this morning", "this afternoon", "this evening",
    ]

    /// Returns true if the candidate string is a temporal expression, not a location.
    static func isTemporal(_ candidate: String) -> Bool {
        let lower = candidate.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return false }

        // Fast path: check small set of temporal adverbs
        if temporalAdverbs.contains(lower) { return true }

        // NSDataDetector: if a date match covers the entire (or nearly entire) string, it's temporal
        if let detector = dateDetector {
            let range = NSRange(lower.startIndex..., in: lower)
            let matches = detector.matches(in: lower, options: [], range: range)
            for match in matches {
                if match.range.length >= range.length - 2 {
                    return true
                }
            }
        }

        return false
    }

    static func sanitizeCity(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // Reject temporal expressions the LLM may misplace into the location field
        if isTemporal(lower) { return nil }

        // Sorted longest-first for greedy matching
        for keyword in allWeatherKeywords {
            guard lower.hasPrefix(keyword) else { continue }

            let rest = String(lower.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)

            // Entire candidate is just the keyword → no city
            if rest.isEmpty { return nil }

            // Keyword followed by preposition + city → extract the city using original case
            let originalRest = String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
            for prep in ["in ", "for ", "at ", "near "] {
                if rest.hasPrefix(prep) {
                    let city = String(originalRest.dropFirst(prep.count)).trimmingCharacters(in: .whitespaces)
                    return city.isEmpty ? nil : city
                }
            }

            // Leftover text with no preposition — likely temporal noise ("tonight", "tomorrow")
            // not a location, so discard
            return nil
        }

        return trimmed
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let prefixes = [
                "compare weather ", "compare weather in ",
                "weather forecast for ", "weather forecast ",
                "forecast for ", "forecast ",
                "weather in ", "weather ",
            ]
            let rawCity = InputParsingUtilities.extractLocation(from: input, entities: entities, strippingPrefixes: prefixes)
            let intent = detectIntent(input: input, entities: entities)
            let cleanedCity = Self.sanitizeCity(rawCity)

            do {
                switch intent {
                case .search(let condition):
                    return try await searchCondition(condition, city: cleanedCity)

                case .current:
                    return try await fetchCurrent(city: cleanedCity)

                case .detail(.moon):
                    return try await fetchMoonPhase(city: cleanedCity)

                case .detail(.sunrise), .detail(.sunset):
                    let field = if case .detail(let f) = intent { f } else { DetailField.sunrise }
                    return try await fetchSunTimes(city: cleanedCity, field: field)

                case .detail(.airQuality):
                    return try await fetchAirQuality(city: cleanedCity)

                case .detail(let field):
                    return try await fetchDetail(city: cleanedCity, field: field)

                case .forecast(let days):
                    return try await fetchForecast(city: cleanedCity, days: days)

                case .comparison(let otherCity):
                    return try await fetchComparison(city1: cleanedCity, city2: otherCity)
                }
            } catch {
                return ToolIO(
                    text: "Failed to fetch weather for \(cleanedCity ?? "your location"): \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    // MARK: - Current Weather

    private func fetchCurrent(city: String?) async throws -> ToolIO {
        let (location, name) = try await resolveLocation(city: city)
        let params = "current=temperature_2m,weather_code&wind_speed_unit=ms&timezone=auto"
        let data = try await fetchAPI(lat: location.coordinate.latitude, lon: location.coordinate.longitude, params: params)
        let response = try JSONDecoder().decode(CurrentResponse.self, from: data)

        let temp = response.current.temperature_2m
        let code = response.current.weather_code
        let condition = Self.mapWeatherCode(code)
        let iconName = Self.mapWeatherIcon(code)
        let tempString = formatTemp(temp)

        let widgetData = WeatherWidgetData(city: name, temperature: tempString, condition: condition, iconName: iconName)

        return ToolIO(
            text: "Current weather for \(name): \(tempString), \(condition).",
            status: .ok,
            outputWidget: "WeatherWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Detail Weather

    private func fetchDetail(city: String?, field: DetailField) async throws -> ToolIO {
        let (location, name) = try await resolveLocation(city: city)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        // Build parameter list based on field
        let currentParams: String
        let dailyParams: String?

        switch field {
        case .wind:
            currentParams = "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
            dailyParams = nil
        case .humidity:
            currentParams = "temperature_2m,weather_code,relative_humidity_2m"
            dailyParams = nil
        case .uv:
            currentParams = "temperature_2m,weather_code"
            dailyParams = "uv_index_max"
        case .feelsLike:
            currentParams = "temperature_2m,weather_code,apparent_temperature"
            dailyParams = nil
        case .pressure:
            currentParams = "temperature_2m,weather_code,pressure_msl"
            dailyParams = nil
        case .visibility:
            // visibility is hourly-only; use cloud_cover as proxy from current
            currentParams = "temperature_2m,weather_code,cloud_cover"
            dailyParams = nil
        case .dewPoint:
            currentParams = "temperature_2m,weather_code,relative_humidity_2m"
            dailyParams = nil
        case .clouds:
            currentParams = "temperature_2m,weather_code,cloud_cover"
            dailyParams = nil
        case .precipitation:
            currentParams = "temperature_2m,weather_code,precipitation"
            dailyParams = "precipitation_probability_max"
        case .moon, .sunrise, .sunset, .airQuality:
            // Handled by dedicated methods; unreachable, but compiler requires exhaustiveness
            currentParams = "temperature_2m,weather_code"
            dailyParams = nil
        }

        var apiParams = "current=\(currentParams)&wind_speed_unit=ms&timezone=auto"
        if let daily = dailyParams {
            apiParams += "&daily=\(daily)&forecast_days=1"
        }

        let data = try await fetchAPI(lat: lat, lon: lon, params: apiParams)

        // Parse into generic dictionaries since fields vary
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else {
            throw WeatherError.parseError
        }
        let daily = json["daily"] as? [String: Any]

        let temp = (current["temperature_2m"] as? Double) ?? 0
        let code = (current["weather_code"] as? Int) ?? 0
        let condition = Self.mapWeatherCode(code)
        let iconName = Self.mapWeatherIcon(code)
        let tempString = formatTemp(temp)

        // Build detail text
        let detailText: String
        switch field {
        case .wind:
            let speed = (current["wind_speed_10m"] as? Double) ?? 0
            let gusts = (current["wind_gusts_10m"] as? Double) ?? 0
            let dir = (current["wind_direction_10m"] as? Double) ?? 0
            let compassDir = compassDirection(from: dir)
            let useMph = useFahrenheit
            let speedDisplay = useMph ? String(format: "%.0f mph", speed * 2.237) : String(format: "%.1f m/s", speed)
            let gustDisplay = useMph ? String(format: "%.0f mph", gusts * 2.237) : String(format: "%.1f m/s", gusts)
            detailText = "Wind: \(speedDisplay) \(compassDir). Gusts: \(gustDisplay)."

        case .humidity:
            let humidity = (current["relative_humidity_2m"] as? Int) ?? 0
            detailText = "Humidity: \(humidity)%."

        case .uv:
            if let uvArray = daily?["uv_index_max"] as? [Double], let uv = uvArray.first {
                let level = uvLevel(uv)
                detailText = "UV Index: \(String(format: "%.1f", uv)) (\(level))."
            } else {
                detailText = "UV index data is not available for this location."
            }

        case .feelsLike:
            let apparent = (current["apparent_temperature"] as? Double) ?? temp
            detailText = "Feels like: \(formatTemp(apparent))."

        case .pressure:
            let pressure = (current["pressure_msl"] as? Double) ?? 0
            detailText = "Pressure: \(Int(pressure)) hPa."

        case .visibility:
            let clouds = (current["cloud_cover"] as? Int) ?? 0
            detailText = "Cloud cover: \(clouds)%."

        case .dewPoint:
            let humidity = (current["relative_humidity_2m"] as? Int) ?? 0
            // Approximate dew point: Td ≈ T - ((100 - RH) / 5)
            let dewPoint = temp - Double(100 - humidity) / 5.0
            detailText = "Dew point: \(formatTemp(dewPoint))."

        case .clouds:
            let clouds = (current["cloud_cover"] as? Int) ?? 0
            detailText = "Cloud cover: \(clouds)%."

        case .precipitation:
            let precip = (current["precipitation"] as? Double) ?? 0
            let probArray = daily?["precipitation_probability_max"] as? [Int]
            let prob = probArray?.first
            var precipText = "Current precipitation: \(String(format: "%.1f", precip)) mm."
            if let prob { precipText += " Chance of rain today: \(prob)%." }
            detailText = precipText
        case .moon, .sunrise, .sunset, .airQuality:
            detailText = "" // Unreachable — handled by dedicated methods
        }

        let widgetData = WeatherWidgetData(city: name, temperature: tempString, condition: condition, iconName: iconName)

        return ToolIO(
            text: "Weather for \(name): \(tempString), \(condition). \(detailText)",
            status: .ok,
            outputWidget: "WeatherWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Air Quality

    /// Fetches current air quality data from Open-Meteo's Air Quality API.
    /// Returns AQI (European), PM2.5, PM10, and a health advisory.
    private func fetchAirQuality(city: String?) async throws -> ToolIO {
        let (location, name) = try await resolveLocation(city: city)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        guard let url = APIEndpoints.OpenMeteo.airQuality(lat: lat, lon: lon) else {
            throw WeatherError.invalidURL
        }

        let (data, _) = try await session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else {
            throw WeatherError.parseError
        }

        let aqi = (current["european_aqi"] as? Int) ?? (current["european_aqi"] as? Double).map { Int($0) } ?? 0
        let pm25 = (current["pm2_5"] as? Double) ?? 0
        let pm10 = (current["pm10"] as? Double) ?? 0
        let no2 = (current["nitrogen_dioxide"] as? Double) ?? 0
        let o3 = (current["ozone"] as? Double) ?? 0

        let (level, advisory, iconName) = Self.aqiLevel(aqi)

        var text = "Air quality in \(name): AQI \(aqi) (\(level)). "
        text += "PM2.5: \(String(format: "%.1f", pm25)) µg/m³. "
        text += "PM10: \(String(format: "%.1f", pm10)) µg/m³. "
        if no2 > 0 { text += "NO₂: \(String(format: "%.1f", no2)) µg/m³. " }
        if o3 > 0 { text += "O₃: \(String(format: "%.1f", o3)) µg/m³. " }
        text += advisory

        let widgetData = WeatherWidgetData(
            city: name,
            temperature: "AQI \(aqi)",
            condition: level,
            iconName: iconName
        )

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "WeatherWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    /// Maps European AQI value to a human-readable level, health advisory, and SF Symbol.
    private static func aqiLevel(_ aqi: Int) -> (level: String, advisory: String, icon: String) {
        switch aqi {
        case 0...20:
            return ("Good", "Air quality is excellent. Enjoy outdoor activities.", "aqi.low")
        case 21...40:
            return ("Fair", "Air quality is acceptable for most people.", "aqi.low")
        case 41...60:
            return ("Moderate", "Sensitive individuals should limit prolonged outdoor exertion.", "aqi.medium")
        case 61...80:
            return ("Poor", "Everyone may begin to experience health effects. Limit outdoor activity.", "aqi.medium")
        case 81...100:
            return ("Very Poor", "Health warnings for everyone. Avoid outdoor activity.", "aqi.high")
        default:
            return ("Extremely Poor", "Health alert: serious risk. Stay indoors.", "aqi.high")
        }
    }

    // MARK: - Moon Phase

    private func fetchMoonPhase(city: String?, date targetDate: Date? = nil) async throws -> ToolIO {
        let (_, name) = try await resolveLocation(city: city)
        let dateToUse = targetDate ?? Date()

        var phase = Self.computeMoonPhase(for: dateToUse)
        let illumination = Self.moonIllumination(for: dateToUse)
        let illuminationPct = Int(round(illumination * 100))

        // Override phase at illumination boundaries for coherence
        if illuminationPct <= 1 {
            phase = MoonPhaseInfo(name: "New Moon", icon: "moonphase.new.moon", emoji: "🌑")
        } else if illuminationPct >= 99 {
            phase = MoonPhaseInfo(name: "Full Moon", icon: "moonphase.full.moon", emoji: "🌕")
        }

        let dateLabel = Self.formatDateLabel(for: dateToUse)

        let widgetData = MoonWidgetData(
            phaseName: phase.name,
            phaseIcon: phase.icon,
            illumination: illuminationPct,
            location: name,
            emoji: phase.emoji,
            dateLabel: dateLabel,
            isSearch: false
        )

        return ToolIO(
            text: "Moon phase for \(name): \(phase.name) (\(illuminationPct)% illuminated). \(phase.emoji)",
            status: .ok,
            outputWidget: "MoonWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Sunrise / Sunset

    private func fetchSunTimes(city: String?, field: DetailField, date targetDate: Date? = nil) async throws -> ToolIO {
        let (location, name) = try await resolveLocation(city: city)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let dateToUse = targetDate ?? Date()

        let unitParam: String? = useFahrenheit ? "fahrenheit" : nil
        let startDate: String?
        let endDate: String?
        let forecastDays: Int?
        if targetDate != nil {
            let dateStr = Self.apiDateFormatter.string(from: dateToUse)
            startDate = dateStr
            endDate = dateStr
            forecastDays = nil
        } else {
            startDate = nil
            endDate = nil
            forecastDays = 1
        }

        guard let url = APIEndpoints.OpenMeteo.sunriseSunset(lat: lat, lon: lon, startDate: startDate, endDate: endDate, forecastDays: forecastDays, temperatureUnit: unitParam) else {
            throw WeatherError.invalidURL
        }

        let (data, _) = try await session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let sunriseArr = daily["sunrise"] as? [String],
              let sunsetArr = daily["sunset"] as? [String],
              let sunriseStr = sunriseArr.first,
              let sunsetStr = sunsetArr.first else {
            throw WeatherError.parseError
        }

        // Parse ISO times (Open-Meteo returns "2024-03-17T06:30" — no seconds)
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        // Use the location's timezone if available from the API response
        if let tzString = (json["timezone"] as? String), let tz = TimeZone(identifier: tzString) {
            timeFormatter.timeZone = tz
            isoFormatter.timeZone = tz
        }

        let sunriseTime = isoFormatter.date(from: sunriseStr).map { timeFormatter.string(from: $0) } ?? sunriseStr
        let sunsetTime = isoFormatter.date(from: sunsetStr).map { timeFormatter.string(from: $0) } ?? sunsetStr

        // Calculate daylight duration
        var daylightText = ""
        if let rise = isoFormatter.date(from: sunriseStr), let set = isoFormatter.date(from: sunsetStr) {
            let interval = set.timeIntervalSince(rise)
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            daylightText = "\(hours)h \(minutes)m of daylight"
        }

        // Calculate golden hour windows
        let goldenMorning = isoFormatter.date(from: sunriseStr).map { timeFormatter.string(from: $0.addingTimeInterval(3600)) }
        let goldenEvening = isoFormatter.date(from: sunsetStr).map { timeFormatter.string(from: $0.addingTimeInterval(-3600)) }

        let widgetData = SunWidgetData(
            city: name,
            sunrise: sunriseTime,
            sunset: sunsetTime,
            daylight: daylightText,
            goldenMorningEnd: goldenMorning,
            goldenEveningStart: goldenEvening,
            dateLabel: Self.formatDateLabel(for: dateToUse)
        )

        let focusField = field == .sunrise ? "Sunrise" : "Sunset"
        let focusTime = field == .sunrise ? sunriseTime : sunsetTime
        var text = "\(focusField) in \(name): \(focusTime)."
        if field == .sunrise {
            text += " Sunset: \(sunsetTime)."
        } else {
            text += " Sunrise: \(sunriseTime)."
        }
        if !daylightText.isEmpty {
            text += " \(daylightText)."
        }

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "SunWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    /// Moon phase computed algorithmically from the date.
    /// Uses the synodic month (29.53059 days) with a known new moon reference.
    struct MoonPhaseInfo: Sendable {
        let name: String
        let icon: String   // SF Symbol
        let emoji: String
    }

    static func computeMoonPhase(for date: Date) -> MoonPhaseInfo {
        let age = moonAge(for: date)
        let phase = age / 29.53059

        switch phase {
        case 0..<0.0335:     return MoonPhaseInfo(name: "New Moon", icon: "moonphase.new.moon", emoji: "🌑")
        case 0.0335..<0.216: return MoonPhaseInfo(name: "Waxing Crescent", icon: "moonphase.waxing.crescent", emoji: "🌒")
        case 0.216..<0.283:  return MoonPhaseInfo(name: "First Quarter", icon: "moonphase.first.quarter", emoji: "🌓")
        case 0.283..<0.466:  return MoonPhaseInfo(name: "Waxing Gibbous", icon: "moonphase.waxing.gibbous", emoji: "🌔")
        case 0.466..<0.533:  return MoonPhaseInfo(name: "Full Moon", icon: "moonphase.full.moon", emoji: "🌕")
        case 0.533..<0.716:  return MoonPhaseInfo(name: "Waning Gibbous", icon: "moonphase.waning.gibbous", emoji: "🌖")
        case 0.716..<0.783:  return MoonPhaseInfo(name: "Last Quarter", icon: "moonphase.last.quarter", emoji: "🌗")
        case 0.783..<0.966:  return MoonPhaseInfo(name: "Waning Crescent", icon: "moonphase.waning.crescent", emoji: "🌘")
        default:             return MoonPhaseInfo(name: "New Moon", icon: "moonphase.new.moon", emoji: "🌑")
        }
    }

    /// Approximate moon illumination fraction (0.0 = new, 1.0 = full).
    static func moonIllumination(for date: Date) -> Double {
        let age = moonAge(for: date)
        let phase = age / 29.53059
        // Illumination follows a cosine curve peaking at full moon (phase 0.5)
        return (1.0 - cos(phase * 2.0 * .pi)) / 2.0
    }

    /// Days since the last new moon (moon age), using a known reference.
    /// Reference: January 6, 2000 00:18 UTC was a new moon.
    private static func moonAge(for date: Date) -> Double {
        let referenceNewMoon = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2000, month: 1, day: 6, hour: 0, minute: 18
        ).date!
        let daysSinceRef = date.timeIntervalSince(referenceNewMoon) / 86400.0
        let synodicMonth = 29.53059
        let age = daysSinceRef.truncatingRemainder(dividingBy: synodicMonth)
        return age < 0 ? age + synodicMonth : age
    }

    // MARK: - Forecast

    private func fetchForecast(city: String?, days: Int) async throws -> ToolIO {
        let (location, name) = try await resolveLocation(city: city)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        let params = "current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max&wind_speed_unit=ms&timezone=auto&forecast_days=\(days)"
        let data = try await fetchAPI(lat: lat, lon: lon, params: params)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let maxTemps = daily["temperature_2m_max"] as? [Double],
              let minTemps = daily["temperature_2m_min"] as? [Double],
              let codes = daily["weather_code"] as? [Int] else {
            throw WeatherError.parseError
        }

        let precipProbs = daily["precipitation_probability_max"] as? [Int]

        let temp = (current["temperature_2m"] as? Double) ?? 0
        let code = (current["weather_code"] as? Int) ?? 0
        let condition = Self.mapWeatherCode(code)
        let iconName = Self.mapWeatherIcon(code)
        let tempString = formatTemp(temp)

        // Build forecast entries
        var forecastEntries: [WeatherForecastEntry] = []

        for i in 0..<min(days, dates.count) {
            let dayLabel: String
            if i == 0 {
                dayLabel = "Today"
            } else if let date = Self.apiDateFormatter.date(from: dates[i]) {
                dayLabel = Self.shortWeekdayFormatter.string(from: date)
            } else {
                dayLabel = dates[i]
            }

            let entry = WeatherForecastEntry(
                dayLabel: dayLabel,
                high: formatTemp(maxTemps[i]),
                low: formatTemp(minTemps[i]),
                condition: Self.mapWeatherCode(codes[i]),
                iconName: Self.mapWeatherIcon(codes[i]),
                precipChance: precipProbs?[safe: i]
            )
            forecastEntries.append(entry)
        }

        // Text summary for LLM ingredients
        var textLines = ["Current weather for \(name): \(tempString), \(condition)."]
        textLines.append("\(days)-day forecast:")
        for entry in forecastEntries {
            var line = "  \(entry.dayLabel): \(entry.high)/\(entry.low), \(entry.condition)"
            if let precip = entry.precipChance { line += " (\(precip)% rain)" }
            textLines.append(line)
        }

        let widgetData = WeatherForecastWidgetData(
            city: name,
            currentTemp: tempString,
            currentCondition: condition,
            currentIcon: iconName,
            forecast: forecastEntries
        )

        return ToolIO(
            text: textLines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "WeatherForecastWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Comparison

    private func fetchComparison(city1: String?, city2: String) async throws -> ToolIO {
        let (loc1, name1) = try await resolveLocation(city: city1)
        let (loc2, name2) = try await resolveLocation(city: city2)

        let params = "current=temperature_2m,weather_code,relative_humidity_2m,wind_speed_10m&wind_speed_unit=ms&timezone=auto"

        async let data1 = fetchAPI(lat: loc1.coordinate.latitude, lon: loc1.coordinate.longitude, params: params)
        async let data2 = fetchAPI(lat: loc2.coordinate.latitude, lon: loc2.coordinate.longitude, params: params)

        let (raw1, raw2) = try await (data1, data2)

        guard let json1 = try JSONSerialization.jsonObject(with: raw1) as? [String: Any],
              let cur1 = json1["current"] as? [String: Any],
              let json2 = try JSONSerialization.jsonObject(with: raw2) as? [String: Any],
              let cur2 = json2["current"] as? [String: Any] else {
            throw WeatherError.parseError
        }

        let temp1 = (cur1["temperature_2m"] as? Double) ?? 0
        let code1 = (cur1["weather_code"] as? Int) ?? 0
        let hum1 = (cur1["relative_humidity_2m"] as? Int) ?? 0
        let wind1 = (cur1["wind_speed_10m"] as? Double) ?? 0

        let temp2 = (cur2["temperature_2m"] as? Double) ?? 0
        let code2 = (cur2["weather_code"] as? Int) ?? 0
        let hum2 = (cur2["relative_humidity_2m"] as? Int) ?? 0
        let wind2 = (cur2["wind_speed_10m"] as? Double) ?? 0

        let tempDiff = temp1 - temp2
        let warmer = tempDiff > 0 ? name1 : (tempDiff < 0 ? name2 : "neither")
        let absDiff = formatTemp(abs(tempDiff))

        let text = """
        \(name1): \(formatTemp(temp1)), \(Self.mapWeatherCode(code1)). Humidity: \(hum1)%. Wind: \(formatWind(wind1)).
        \(name2): \(formatTemp(temp2)), \(Self.mapWeatherCode(code2)). Humidity: \(hum2)%. Wind: \(formatWind(wind2)).
        \(warmer == "neither" ? "Same temperature" : "\(warmer) is \(absDiff) warmer").
        """

        let widgetData = WeatherComparisonWidgetData(
            city1: name1, temp1: formatTemp(temp1), condition1: Self.mapWeatherCode(code1),
            icon1: Self.mapWeatherIcon(code1), humidity1: hum1,
            city2: name2, temp2: formatTemp(temp2), condition2: Self.mapWeatherCode(code2),
            icon2: Self.mapWeatherIcon(code2), humidity2: hum2
        )

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "WeatherComparisonWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Location Resolution

    private func resolveLocation(city: String?) async throws -> (CLLocation, String) {
        // Treat placeholder names as nil — fall through to device location
        if let city, !LocationManager.isPlaceholderName(city) {
            return try await geocode(city: city)
        }
        let resolved = try await LocationManager.shared.resolveCurrentLocation()
        return (resolved.coordinate, resolved.cityName)
    }

    private func geocode(city: String) async throws -> (CLLocation, String) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = city
        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        guard let item = response.mapItems.first else {
            throw WeatherError.locationNotFound(city)
        }
        let resolvedName = extractCityName(from: item) ?? item.name ?? city
        return (item.location, resolvedName)
    }

    private func extractCityName(from item: MKMapItem?) -> String? {
        guard let address = item?.address else { return nil }
        if let short = address.shortAddress {
            let city = short.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            if let city, !city.isEmpty { return city }
        }
        let parts = address.fullAddress.components(separatedBy: ",")
        if parts.count >= 2 {
            let candidate = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty && !candidate.first!.isNumber { return candidate }
        }
        return nil
    }

    // MARK: - API

    private func fetchAPI(lat: Double, lon: Double, params: String) async throws -> Data {
        let unitParam: String? = useFahrenheit ? "fahrenheit" : nil

        guard let url = APIEndpoints.OpenMeteo.forecast(lat: lat, lon: lon, params: params, temperatureUnit: unitParam) else {
            throw WeatherError.invalidURL
        }

        let (data, _) = try await session.data(from: url)
        return data
    }

    // MARK: - Formatting

    /// Per-request unit override, stored in a task-local-like static so the struct
    /// stays immutable. Reset after each `execute(args:...)` call via `defer`.
    /// CONCURRENCY NOTE: Concurrent calls to `execute` can race on this static.
    /// This is acceptable because WeatherTool is only invoked sequentially by
    /// ExecutionEngine (max 1 weather request per turn). If parallel execution
    /// is ever needed, refactor `useFahrenheit` into a parameter threaded through
    /// the formatting methods.
    private static let _unitOverride = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    private var useFahrenheit: Bool {
        if let override = Self._unitOverride.withLock({ $0 }) { return override }
        return TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: AppConfig.temperatureUnitKey) ?? "system")?.usesFahrenheit
            ?? TemperatureUnit.system.usesFahrenheit
    }

    private func formatTemp(_ temp: Double) -> String {
        let unit = useFahrenheit ? "\u{00B0}F" : "\u{00B0}C"
        return "\(Int(round(temp)))\(unit)"
    }

    private func formatWind(_ speedMs: Double) -> String {
        if useFahrenheit {
            return String(format: "%.0f mph", speedMs * 2.237)
        }
        return String(format: "%.1f m/s", speedMs)
    }

    private func compassDirection(from degrees: Double) -> String {
        let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                          "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int(round(degrees / 22.5)) % 16
        return directions[index]
    }

    private func uvLevel(_ index: Double) -> String {
        switch index {
        case ..<3: return "Low"
        case ..<6: return "Moderate"
        case ..<8: return "High"
        case ..<11: return "Very High"
        default: return "Extreme"
        }
    }

    // MARK: - Weather Code Mapping

    static func mapWeatherCode(_ code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow fall"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }

    static func mapWeatherIcon(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1: return "cloud.sun"
        case 2: return "cloud"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55: return "cloud.drizzle"
        case 56, 57: return "cloud.sleet"
        case 61, 63, 65: return "cloud.rain"
        case 66, 67: return "cloud.sleet"
        case 71, 73, 75: return "snowflake"
        case 77: return "snowflake"
        case 80, 81, 82: return "cloud.heavyrain"
        case 85, 86: return "cloud.snow"
        case 95: return "cloud.bolt"
        case 96, 99: return "cloud.bolt.rain"
        default: return "questionmark.circle"
        }
    }

    // MARK: - Date Helpers

    /// Formats a date as "Today" if it's today, or a localized medium date otherwise.
    static func formatDateLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        return mediumDateFormatter.string(from: date)
    }

    // MARK: - Search Condition

    /// Searches for the next occurrence of a weather condition (full moon, sunny day, etc.).
    private func searchCondition(_ condition: String, city: String?) async throws -> ToolIO {
        let lower = condition.lowercased()

        // "next full moon" / "next new moon" etc.
        let moonPhases: [(keyword: String, phaseName: String)] = [
            ("full moon", "Full Moon"),
            ("new moon", "New Moon"),
            ("first quarter", "First Quarter"),
            ("last quarter", "Last Quarter"),
        ]

        for (keyword, phaseName) in moonPhases {
            if lower.contains(keyword) {
                return try await searchNextMoonPhase(phaseName: phaseName, city: city)
            }
        }

        // "next sunny day" / "next clear day"
        let clearKeywords = ["sunny", "clear", "nice"]
        if clearKeywords.contains(where: { lower.contains($0) }) {
            return try await searchNextClearDay(city: city)
        }

        return ToolIO(
            text: "I can search for the next full moon, new moon, or sunny day. Try: \"next full moon\" or \"next sunny day\".",
            status: .ok
        )
    }

    /// Iterates daily from today up to 45 days to find the next occurrence of a moon phase.
    private func searchNextMoonPhase(phaseName: String, city: String?) async throws -> ToolIO {
        let (_, name) = try await resolveLocation(city: city)
        let calendar = Calendar.current
        let today = Date()

        for dayOffset in 1...45 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let phase = Self.computeMoonPhase(for: date)
            if phase.name == phaseName {
                let illumination = Self.moonIllumination(for: date)
                let illuminationPct = Int(round(illumination * 100))
                let dateLabel = Self.formatDateLabel(for: date)

                let widgetData = MoonWidgetData(
                    phaseName: phase.name,
                    phaseIcon: phase.icon,
                    illumination: illuminationPct,
                    location: name,
                    emoji: phase.emoji,
                    dateLabel: dateLabel,
                    isSearch: true
                )

                return ToolIO(
                    text: "Next \(phaseName) near \(name): \(dateLabel) (\(illuminationPct)% illuminated).",
                    status: .ok,
                    outputWidget: "MoonWidget",
                    widgetData: widgetData,
                    isVerifiedData: true
                )
            }
        }

        return ToolIO(
            text: "Could not find the next \(phaseName) within 45 days.",
            status: .ok
        )
    }

    /// Fetches a 7-day forecast and finds the first day with clear weather (codes 0, 1).
    private func searchNextClearDay(city: String?) async throws -> ToolIO {
        let (location, name) = try await resolveLocation(city: city)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        let params = "daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=7"
        let data = try await fetchAPI(lat: lat, lon: lon, params: params)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [Int],
              let maxTemps = daily["temperature_2m_max"] as? [Double],
              let minTemps = daily["temperature_2m_min"] as? [Double] else {
            throw WeatherError.parseError
        }

        // Find first clear day (weather codes 0 = clear sky, 1 = mainly clear)
        let clearCodes: Set<Int> = [0, 1]

        for i in 0..<dates.count {
            if clearCodes.contains(codes[i]) {
                guard let date = Self.apiDateFormatter.date(from: dates[i]) else { continue }
                // Skip today
                if Calendar.current.isDateInToday(date) { continue }
                let dateLabel = Self.formatDateLabel(for: date)
                let condition = Self.mapWeatherCode(codes[i])
                let high = formatTemp(maxTemps[i])
                let low = formatTemp(minTemps[i])

                return ToolIO(
                    text: "Next clear day in \(name): \(dateLabel) — \(condition), \(high)/\(low).",
                    status: .ok,
                    isVerifiedData: true
                )
            }
        }

        return ToolIO(
            text: "No clear days found in the 7-day forecast for \(name). The forecast doesn't extend far enough to predict beyond that.",
            status: .ok
        )
    }

    // MARK: - Errors

    enum WeatherError: Error, LocalizedError {
        case locationNotFound(String)
        case invalidURL
        case parseError

        var errorDescription: String? {
            switch self {
            case .locationNotFound(let city): return "Could not find location: \(city)"
            case .invalidURL: return "Invalid API URL"
            case .parseError: return "Could not parse weather data"
            }
        }
    }
}

// MARK: - PreFetchable

extension WeatherTool: PreFetchable {
    /// Pre-fetch current weather for the device location.
    /// Cache key matches queries like "weather", "what's the weather", etc.
    /// (after stop-word stripping, these all reduce to "weather").
    public func preFetchEntries() async -> [PreFetchEntry] {
        [
            PreFetchEntry(
                cacheKey: ScratchpadCache.makeKey(toolName: "Weather", input: "weather"),
                label: "Device location weather",
                ttl: 1800, // 30 minutes
                toolName: "Weather",
                fetch: {
                    try await WeatherTool().execute(input: "current weather", entities: nil)
                }
            )
        ]
    }
}

// MARK: - DateResolver

/// Resolves natural language date expressions to Date objects.
enum DateResolver {
    /// Attempts to resolve a date string using NSDataDetector, then common format fallbacks.
    static func resolve(_ input: String) -> Date? {
        // Try NSDataDetector for natural language dates
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(input.startIndex..., in: input)
            if let match = detector.firstMatch(in: input, range: range), let date = match.date {
                return date
            }
        }

        // Format fallbacks
        let formatters: [(String, String)] = [
            ("yyyy-MM-dd", input),
            ("MMMM d", input),
            ("MMMM d, yyyy", input),
            ("MMM d", input),
            ("MMM d, yyyy", input),
        ]

        let df = DateFormatter()
        df.locale = Locale.current
        for (format, str) in formatters {
            df.dateFormat = format
            if let date = df.date(from: str) {
                // If no year was specified, assume current or next occurrence
                if !format.contains("yyyy") {
                    let calendar = Calendar.current
                    var components = calendar.dateComponents([.month, .day], from: date)
                    components.year = calendar.component(.year, from: Date())
                    if let adjusted = calendar.date(from: components), adjusted < Date() {
                        components.year! += 1
                    }
                    return calendar.date(from: components)
                }
                return date
            }
        }

        return nil
    }
}

// MARK: - API Response Models

private struct CurrentResponse: Codable {
    let current: CurrentData
    struct CurrentData: Codable {
        let temperature_2m: Double
        let weather_code: Int
    }
}

// Keep the public models for backward compat with existing tests
struct OpenMeteoResponse: Codable {
    let current: CurrentWeather
}

struct CurrentWeather: Codable {
    let temperature_2m: Double
    let weather_code: Int
}

// MARK: - Widget Data Models

/// Data for the forecast widget.
public struct WeatherForecastEntry: Sendable {
    public let dayLabel: String
    public let high: String
    public let low: String
    public let condition: String
    public let iconName: String
    public let precipChance: Int?
}

public struct WeatherForecastWidgetData: Sendable {
    public let city: String
    public let currentTemp: String
    public let currentCondition: String
    public let currentIcon: String
    public let forecast: [WeatherForecastEntry]
}

/// Data for the comparison widget.
public struct WeatherComparisonWidgetData: Sendable {
    public let city1: String
    public let temp1: String
    public let condition1: String
    public let icon1: String
    public let humidity1: Int
    public let city2: String
    public let temp2: String
    public let condition2: String
    public let icon2: String
    public let humidity2: Int
}

/// Data for the sunrise/sunset widget.
public struct SunWidgetData: Sendable {
    public let city: String
    public let sunrise: String
    public let sunset: String
    public let daylight: String      // e.g. "12h 15m of daylight"
    public let goldenMorningEnd: String?   // e.g. "7:30 AM" (golden hour ends)
    public let goldenEveningStart: String? // e.g. "6:45 PM" (golden hour begins)
    public let dateLabel: String?    // "Today" or localized date
}

/// Data for the moon phase widget.
public struct MoonWidgetData: Sendable {
    public let phaseName: String
    public let phaseIcon: String    // SF Symbol name
    public let illumination: Int    // 0-100%
    public let location: String
    public let emoji: String
    public let dateLabel: String?   // "Today" or localized date
    public let isSearch: Bool       // true for "next full moon" queries — date-prominent layout
}

// MARK: - Collection Safety

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
