import Foundation
import MapKit
import CoreLocation

/// Structured arguments for LLM-extracted maps requests.
public struct MapsArgs: ToolArguments {
    public let intent: String       // "directions", "nearby", "search"
    public let origin: String?
    public let destination: String?
    public let transport: String?   // "automobile", "walking", "transit"
    public let query: String?
}

/// Core Maps tool that executes MapKit queries directly and returns real data.
/// Handles: directions, distance, ETA, nearby search, and place lookup.
public struct MapsCoreTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Maps"
    public let schema = "Get directions, distance, ETA, drive time between places. Search nearby restaurants, places, businesses. E.g. 'how far is Texas', 'directions to airport', 'restaurants near me', 'how long to drive from Boston to NYC'."
    public let isInternal = false
    public let category = CategoryEnum.online

    public init() {}

    // MARK: - ExtractableCoreTool

    public typealias Args = MapsArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Maps", fallback: "{\"intent\":\"directions|nearby|search\",\"destination\":\"string?\"}"
    )

    public func execute(args: MapsArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            switch args.intent {
            case "nearby", "search":
                let searchQuery = args.query ?? args.destination ?? rawInput
                return await searchNearby(input: searchQuery)
            default:
                // Directions — build a synthetic input for the existing parser,
                // or use origin/destination directly via entities
                if let dest = args.destination {
                    var syntheticEntities = entities
                    // Create entities with extracted places if available
                    if let origin = args.origin {
                        syntheticEntities = ExtractedEntities(
                            names: entities?.names ?? [],
                            places: [origin, dest],
                            organizations: entities?.organizations ?? [],
                            urls: entities?.urls ?? [],
                            phoneNumbers: entities?.phoneNumbers ?? [],
                            emails: entities?.emails ?? [],
                            ocrText: nil
                        )
                    } else {
                        syntheticEntities = ExtractedEntities(
                            names: entities?.names ?? [],
                            places: [dest],
                            organizations: entities?.organizations ?? [],
                            urls: entities?.urls ?? [],
                            phoneNumbers: entities?.phoneNumbers ?? [],
                            emails: entities?.emails ?? [],
                            ocrText: nil
                        )
                    }
                    return await getDirections(input: rawInput, entities: syntheticEntities)
                }
                return await getDirections(input: rawInput, entities: entities)
            }
        }
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let lower = input.lowercased()

            // Multilingual intent detection via `Resources/Config/MapsIntentKeywords.json`.
            // Falls back to English when the detected language isn't in the
            // config, which matches the pre-Phase-6c behavior for English inputs
            // while covering EN/ES/FR/DE/PT/IT/JA/ZH/KO/AR out of the box.
            let isDirections = Self.intentKeywords?.matches(intent: "directions", in: input) ?? false
            let isNearby = Self.intentKeywords?.matches(intent: "nearby", in: input) ?? false

            if isNearby || (!isDirections && looksLikeSearch(lower)) {
                return await searchNearby(input: input)
            } else {
                return await getDirections(input: input, entities: entities)
            }
        }
    }

    /// Lazy-loaded multilingual keyword table — loaded once, reused across turns.
    private static let intentKeywords: MultilingualKeywords? = MultilingualKeywords.load("MapsIntentKeywords")

    // MARK: - Directions / Distance / ETA

    private func getDirections(input: String, entities: ExtractedEntities?) async -> ToolIO {
        let lower = input.lowercased()

        // Parse origin and destination from natural language
        let (originQuery, destQuery) = parseOriginDestination(lower, entities: entities)

        do {
            let request = MKDirections.Request()
            request.transportType = parseTransport(lower)

            // Resolve origin
            let originItem: MKMapItem
            let originName: String
            if let oq = originQuery, !oq.isEmpty {
                originItem = try await geocode(query: oq)
                originName = originItem.name ?? oq
            } else {
                let resolved = try await LocationManager.shared.resolveCurrentLocation()
                originItem = MKMapItem(location: resolved.coordinate, address: nil)
                originName = resolved.cityName
            }
            request.source = originItem

            // Resolve destination
            guard let dq = destQuery, !dq.isEmpty else {
                return ToolIO(
                    text: "Couldn't determine a destination from your request. Try: 'directions to [place]'.",
                    status: .error
                )
            }
            let destItem = try await geocode(query: dq)
            let destName = destItem.name ?? dq
            request.destination = destItem

            // Calculate route
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()

            guard let route = response.routes.first else {
                return ToolIO(
                    text: "No route found from \(originName) to \(destName).",
                    status: .error
                )
            }

            let distanceMiles = route.distance / 1609.344
            let distanceKm = route.distance / 1000.0
            let minutes = Int(route.expectedTravelTime / 60)
            let hours = minutes / 60
            let remainingMinutes = minutes % 60

            let distanceText = String(format: "%.1f mi (%.0f km)", distanceMiles, distanceKm)
            let etaText = hours > 0 ? "\(hours)h \(remainingMinutes)m" : "\(remainingMinutes)m"

            // Build step-by-step directions for the LLM
            var textLines = [
                "Route from \(originName) to \(destName):",
                "Distance: \(distanceText)",
                "Estimated travel time: \(etaText)",
                ""
            ]
            for (i, step) in route.steps.enumerated() where !step.instructions.isEmpty {
                textLines.append("\(i + 1). \(step.instructions)")
            }

            // Build Apple Maps URL
            let destCoord = destItem.location.coordinate
            let originCoord = originItem.location.coordinate
            let encodedDest = dq.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dq
            let mapsURL = URL(string: "maps://?saddr=\(originCoord.latitude),\(originCoord.longitude)&daddr=\(encodedDest)")
                ?? URL(string: "maps://?daddr=\(encodedDest)")!

            // Encode polyline coordinates as flat [lat, lon, ...] for Sendable
            let polyline = route.polyline
            let pointCount = polyline.pointCount
            var routeCoords: [Double] = []
            if pointCount > 0 {
                var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
                polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
                // Sample at most 200 points to keep data reasonable
                let step = max(1, pointCount / 200)
                for i in stride(from: 0, to: pointCount, by: step) {
                    routeCoords.append(coords[i].latitude)
                    routeCoords.append(coords[i].longitude)
                }
            }

            let widgetData = MapWidgetData(
                originName: originName,
                destinationName: destName,
                originCoordinate: originCoord,
                destinationCoordinate: destCoord,
                routeCoordinates: routeCoords,
                distanceText: distanceText,
                etaText: etaText,
                mapsURL: mapsURL
            )

            return ToolIO(
                text: textLines.joined(separator: "\n"),
                status: .ok,
                outputWidget: "MapWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        } catch {
            return ToolIO(
                text: "Maps error: \(error.localizedDescription)",
                status: .error
            )
        }
    }

    // MARK: - Nearby Search

    private func searchNearby(input: String) async -> ToolIO {
        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = input

            // Center search on current location
            if let resolved = try? await LocationManager.shared.resolveCurrentLocation() {
                let region = MKCoordinateRegion(
                    center: resolved.coordinate.coordinate,
                    latitudinalMeters: 5000,
                    longitudinalMeters: 5000
                )
                request.region = region
            }

            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            if response.mapItems.isEmpty {
                return ToolIO(
                    text: "No results found for '\(input)'.",
                    status: .error
                )
            }

            let items = response.mapItems.prefix(8)
            var textLines: [String] = []
            var searchResults: [MapSearchResult] = []

            for item in items {
                let name = item.name ?? "Unknown"
                let address = item.address?.fullAddress ?? ""
                let coord = item.location.coordinate

                var parts = [name]
                if !address.isEmpty { parts.append(address) }
                if let phone = item.phoneNumber { parts.append(phone) }
                textLines.append(parts.joined(separator: " — "))

                searchResults.append(MapSearchResult(
                    name: name,
                    address: address,
                    coordinate: coord
                ))
            }

            // Build maps URL for the search query
            let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
            let mapsURL = URL(string: "maps://?q=\(encoded)") ?? URL(string: "maps://")!

            // Use the first result's coordinates as center for the widget
            let center = searchResults.first?.coordinate ?? CLLocationCoordinate2D()

            let widgetData = MapWidgetData(
                originName: "You",
                destinationName: input,
                originCoordinate: center,
                destinationCoordinate: center,
                distanceText: "",
                etaText: "",
                mapsURL: mapsURL,
                searchResults: searchResults
            )

            return ToolIO(
                text: textLines.joined(separator: "\n"),
                status: .ok,
                outputWidget: "MapWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        } catch {
            return ToolIO(
                text: "Search error: \(error.localizedDescription)",
                status: .error
            )
        }
    }

    // MARK: - Parsing Helpers

    /// Extracts origin and destination from natural language input.
    private func parseOriginDestination(_ input: String, entities: ExtractedEntities?) -> (origin: String?, destination: String?) {
        // Patterns like "from X to Y" or "between X and Y"
        let fromToPattern = try? NSRegularExpression(pattern: "from\\s+(.+?)\\s+to\\s+(.+?)(?:\\s*\\?|$)", options: .caseInsensitive)
        let betweenPattern = try? NSRegularExpression(pattern: "between\\s+(.+?)\\s+and\\s+(.+?)(?:\\s*\\?|$)", options: .caseInsensitive)
        let toPattern = try? NSRegularExpression(pattern: "(?:directions?|drive|distance|eta|route|navigate|how far|how long).*?(?:to|for)\\s+(.+?)(?:\\s*\\?|$)", options: .caseInsensitive)
        let range = NSRange(input.startIndex..<input.endIndex, in: input)

        // "from Boston to New York"
        if let match = fromToPattern?.firstMatch(in: input, range: range),
           let originRange = Range(match.range(at: 1), in: input),
           let destRange = Range(match.range(at: 2), in: input) {
            return (String(input[originRange]).trimmingCharacters(in: .whitespaces),
                    String(input[destRange]).trimmingCharacters(in: .whitespaces))
        }

        // "between Boston and New York"
        if let match = betweenPattern?.firstMatch(in: input, range: range),
           let firstRange = Range(match.range(at: 1), in: input),
           let secondRange = Range(match.range(at: 2), in: input) {
            return (String(input[firstRange]).trimmingCharacters(in: .whitespaces),
                    String(input[secondRange]).trimmingCharacters(in: .whitespaces))
        }

        // "directions to Texas" / "how far is Texas"
        if let match = toPattern?.firstMatch(in: input, range: range),
           let destRange = Range(match.range(at: 1), in: input) {
            return (nil, String(input[destRange]).trimmingCharacters(in: .whitespaces))
        }

        // "how far is Texas?" — simpler pattern
        let isPattern = try? NSRegularExpression(pattern: "how\\s+(?:far|long)\\s+(?:is|to)\\s+(.+?)(?:\\s*\\?|$)", options: .caseInsensitive)
        if let match = isPattern?.firstMatch(in: input, range: range),
           let destRange = Range(match.range(at: 1), in: input) {
            return (nil, String(input[destRange]).trimmingCharacters(in: .whitespaces))
        }

        // Use NER entities as fallback
        if let places = entities?.places, !places.isEmpty {
            if places.count >= 2 {
                return (places[0], places[1])
            } else {
                return (nil, places[0])
            }
        }

        return (nil, nil)
    }

    private func parseTransport(_ input: String) -> MKDirectionsTransportType {
        if input.contains("walk") { return .walking }
        if input.contains("transit") || input.contains("bus") || input.contains("train") || input.contains("public") { return .transit }
        return .automobile
    }

    private func looksLikeSearch(_ input: String) -> Bool {
        let searchTerms = ["find", "search", "look for", "where is", "where can i",
                           "best", "top", "good", "recommend"]
        return searchTerms.contains { input.contains($0) }
    }

    private func geocode(query: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw NSError(domain: "MapsCoreTool", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Location not found: \(query)"])
        }
        return item
    }
}
