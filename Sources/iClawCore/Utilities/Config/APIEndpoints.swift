import Foundation

/// Centralized URL construction for external API endpoints.
public enum APIEndpoints {

    public enum Wikipedia {
        private static let base = "https://en.wikipedia.org/w/api.php"

        /// OpenSearch API — finds the best-matching title for a query.
        public static func search(query: String, limit: Int = 1) -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "\(base)?action=opensearch&search=\(encoded)&limit=\(limit)&format=json")
        }

        /// Extract API — fetches the introductory text and thumbnail for a given title.
        public static func extract(title: String) -> URL? {
            guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "\(base)?action=query&prop=extracts|pageimages|pageterms&explaintext=1&exintro=1&piprop=thumbnail&pithumbsize=400&titles=\(encoded)&format=json")
        }
    }

    public enum DuckDuckGo {
        /// HTML search results page.
        public static func htmlSearch(query: String) -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)")
        }

        /// Instant Answer JSON API.
        public static func instantAnswer(query: String) -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")
        }
    }

    public enum Brave {
        /// Brave Search results page.
        public static func search(query: String) -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://search.brave.com/search?q=\(encoded)")
        }
    }

    public enum Nager {
        /// Public holidays for a given year and ISO country code.
        public static func holidays(year: Int, countryCode: String) -> URL? {
            URL(string: "https://date.nager.at/api/v3/publicholidays/\(year)/\(countryCode)")
        }
    }

    public enum Yahoo {
        /// Initial cookie-setting page.
        public static let cookieURL = URL(string: "https://www.yahoo.com/")!

        /// Crumb token endpoint (requires cookies from `cookieURL`).
        public static let crumbURL = URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!

        /// Quote summary endpoint via URLComponents.
        public static func quoteSummary(symbol: String, modules: String, crumb: String) -> URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "query2.finance.yahoo.com"
            components.path = "/v11/finance/quoteSummary/"
            components.queryItems = [
                URLQueryItem(name: "symbols", value: symbol),
                URLQueryItem(name: "modules", value: modules),
                URLQueryItem(name: "crumb", value: crumb),
            ]
            return components.url
        }
    }

    public enum iTunes {
        private static let base = "https://itunes.apple.com"

        /// Search the iTunes catalog (podcasts, music, etc.).
        public static func search(term: String, media: String? = nil, entity: String? = nil, limit: Int = 5) -> URL? {
            guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            var urlString = "\(base)/search?term=\(encoded)&limit=\(limit)"
            if let media { urlString += "&media=\(media)" }
            if let entity { urlString += "&entity=\(entity)" }
            return URL(string: urlString)
        }

        /// Lookup an item by collection ID, optionally including episodes.
        public static func lookup(collectionId: Int, entity: String? = nil, limit: Int = 5) -> URL? {
            var urlString = "\(base)/lookup?id=\(collectionId)&limit=\(limit)"
            if let entity { urlString += "&entity=\(entity)" }
            return URL(string: urlString)
        }
    }

    public enum OpenMeteo {
        private static let forecastBase = "https://api.open-meteo.com/v1/forecast"
        private static let airQualityBase = "https://air-quality-api.open-meteo.com/v1/air-quality"

        /// General forecast endpoint with arbitrary query parameters.
        public static func forecast(lat: Double, lon: Double, params: String, temperatureUnit: String? = nil) -> URL? {
            var urlString = "\(forecastBase)?latitude=\(lat)&longitude=\(lon)&\(params)"
            if let unit = temperatureUnit { urlString += "&temperature_unit=\(unit)" }
            return URL(string: urlString)
        }

        /// Sunrise/sunset endpoint with optional date range or forecast days.
        public static func sunriseSunset(lat: Double, lon: Double, startDate: String? = nil, endDate: String? = nil, forecastDays: Int? = nil, temperatureUnit: String? = nil) -> URL? {
            var urlString = "\(forecastBase)?latitude=\(lat)&longitude=\(lon)&daily=sunrise,sunset&timezone=auto"
            if let start = startDate, let end = endDate {
                urlString += "&start_date=\(start)&end_date=\(end)"
            } else if let days = forecastDays {
                urlString += "&forecast_days=\(days)"
            }
            if let unit = temperatureUnit { urlString += "&temperature_unit=\(unit)" }
            return URL(string: urlString)
        }

        /// Current weather + daily min/max for today summary.
        public static func todaySummary(lat: Double, lon: Double, temperatureUnit: String? = nil) -> URL? {
            var urlString = "\(forecastBase)?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"
            if let unit = temperatureUnit { urlString += "&temperature_unit=\(unit)" }
            return URL(string: urlString)
        }

        /// Air quality endpoint.
        public static func airQuality(lat: Double, lon: Double) -> URL? {
            URL(string: "\(airQualityBase)?latitude=\(lat)&longitude=\(lon)&current=european_aqi,pm10,pm2_5,nitrogen_dioxide,ozone,carbon_monoxide&timezone=auto")
        }
    }

    public enum GoogleNews {
        /// RSS search feed for a query.
        public static func rssSearch(query: String, language: String = "en", country: String = "US") -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=\(language)&gl=\(country)&ceid=\(country):\(language)")
        }
    }

    public enum Currency {
        /// Exchange rates for a base currency code (lowercase).
        public static func rates(base: String) -> URL? {
            URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/\(base).json")
        }
    }

    public enum Wikidata {
        private static let base = "https://www.wikidata.org/w/api.php"

        /// Search for a Wikidata entity by name.
        public static func searchEntities(query: String, language: String = "en", limit: Int = 1) -> URL? {
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "\(base)?action=wbsearchentities&search=\(encoded)&language=\(language)&limit=\(limit)&format=json")
        }

        /// Fetch claims (properties) for a Wikidata entity.
        public static func entityClaims(entityId: String) -> URL? {
            URL(string: "\(base)?action=wbgetentities&ids=\(entityId)&props=claims&format=json")
        }
    }
}
