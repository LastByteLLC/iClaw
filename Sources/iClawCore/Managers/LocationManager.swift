import Foundation
import CoreLocation
import MapKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Location Types

public struct ResolvedLocation: Sendable {
    public let coordinate: CLLocation
    public let cityName: String
    public let source: LocationSource
}

public enum LocationSource: Sendable {
    case coreLocation, userFallback, geoIP
}

public enum LocationError: Error, LocalizedError, Sendable {
    case unresolvable

    public var errorDescription: String? {
        "I couldn't determine your location. Try asking for weather in a specific city (e.g. \"weather in London\"), grant location permission in System Settings, or set a default location in iClaw Settings."
    }
}

// MARK: - LocationManager

@MainActor
class LocationManager: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationManager()
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Error>?
    private var cachedResolved: ResolvedLocation?

    /// Test-only override. When set, `resolveCurrentLocation()` returns this immediately
    /// without hitting CoreLocation, GeoIP, or any async delegates.
    /// `nonisolated(unsafe)` so it can be set synchronously from any context before tests run.
    nonisolated(unsafe) static var testLocationOverride: ResolvedLocation?

    // MARK: - Fallback Location

    public struct FallbackLocation: Codable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let displayName: String
    }

    private static let fallbackLocationKey = "iClaw_fallbackLocation"

    public static var fallbackLocation: FallbackLocation? {
        guard let data = UserDefaults.standard.data(forKey: fallbackLocationKey) else { return nil }
        return try? JSONDecoder().decode(FallbackLocation.self, from: data)
    }

    public static func setFallbackLocation(_ location: FallbackLocation?) {
        if let location {
            UserDefaults.standard.set(try? JSONEncoder().encode(location), forKey: fallbackLocationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: fallbackLocationKey)
        }
        shared.invalidateCache()
    }

    private override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: - Unified Resolution

    /// Resolves the user's current location with coordinates and a validated city name.
    /// Chain: CoreLocation → User fallback → GeoIP (MapKit-validated) → throws .unresolvable
    func resolveCurrentLocation() async throws -> ResolvedLocation {
        if let override = Self.testLocationOverride { return override }

        if let cached = cachedResolved, !Self.isPlaceholderName(cached.cityName) {
            return cached
        }

        // 1. CoreLocation
        if let resolved = await resolveCoreLocation() {
            Log.tools.debug("Location resolved via CoreLocation: \(resolved.cityName)")
            cachedResolved = resolved
            return resolved
        }

        // 2. User-configured fallback (already MapKit-validated at save time)
        if let fallback = Self.fallbackLocation {
            Log.tools.debug("Using user-configured fallback location: \(fallback.displayName)")
            let resolved = ResolvedLocation(
                coordinate: CLLocation(latitude: fallback.latitude, longitude: fallback.longitude),
                cityName: fallback.displayName,
                source: .userFallback
            )
            cachedResolved = resolved
            return resolved
        }

        // 3. GeoIP with MapKit validation
        if let resolved = await resolveGeoIP() {
            Log.tools.debug("GeoIP resolved: \(resolved.cityName)")
            cachedResolved = resolved
            return resolved
        }

        // 4. All failed — never return a placeholder
        throw LocationError.unresolvable
    }

    /// Clears the cached resolved location (e.g., when user changes fallback settings).
    func invalidateCache() {
        cachedResolved = nil
    }

    // MARK: - CoreLocation Resolution

    private func resolveCoreLocation() async -> ResolvedLocation? {
        guard let location = try? await getCoreLocation() else { return nil }
        guard let cityName = await reverseGeocode(location),
              !Self.isPlaceholderName(cityName) else { return nil }
        return ResolvedLocation(coordinate: location, cityName: cityName, source: .coreLocation)
    }

    private func getCoreLocation() async throws -> CLLocation {
        var status = manager.authorizationStatus
        Log.tools.debug("Current authorization status: \(status.rawValue)")

        if status == .notDetermined {
            Log.tools.debug("Requesting location authorization...")

            // Wait for the delegate callback via CheckedContinuation, with a 5s timeout.
            // The delegate's locationManagerDidChangeAuthorization resumes authContinuation
            // as soon as the user responds to the system prompt.
            status = try await withThrowingTaskGroup(of: CLAuthorizationStatus.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Error>) in
                        Task { @MainActor in
                            self.authContinuation = continuation
                            #if canImport(AppKit)
                            NSApp?.activate(ignoringOtherApps: true)
                            self.manager.requestAlwaysAuthorization()
                            #else
                            self.manager.requestWhenInUseAuthorization()
                            #endif
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw NSError(domain: "LocationManager", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Location authorization timed out."])
                }
                let result = try await group.next()!
                group.cancelAll()
                await MainActor.run { self.authContinuation = nil }
                return result
            }
            Log.tools.debug("Authorization result: \(status.rawValue)")
        }

        if status == .notDetermined || status == .denied || status == .restricted {
            throw NSError(domain: "LocationManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Location authorization denied or not determined."])
        }

        guard isAuthorized(status) else {
            throw NSError(domain: "LocationManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Location not authorized."])
        }

        Log.tools.debug("Requesting location...")
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { @MainActor in
                        self.locationContinuation = continuation
                        self.manager.requestLocation()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw NSError(domain: "LocationManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Location request timed out."])
            }
            let result = try await group.next()!
            group.cancelAll()
            await MainActor.run { self.locationContinuation = nil }
            return result
        }
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        return status == .authorized || status == .authorizedAlways || status == .authorizedWhenInUse
        #else
        return status == .authorized || status == .authorizedAlways
        #endif
    }

    // MARK: - GeoIP Resolution

    private func resolveGeoIP() async -> ResolvedLocation? {
        // Run the network request in a detached task so it is immune to
        // parent-task cancellation. When CoreLocation auth polling exits
        // with status .notDetermined, the parent task may carry a cancelled
        // state that causes URLSession.data(from:) to throw immediately.
        let coords: (lat: Double, lon: Double)? = await Task.detached {
            do {
                let url = URL(string: "https://ipwho.is/?fields=success,latitude,longitude")!
                // Explicit 5s timeout — matches the CoreLocation-auth timeout
                // above. URLSession.shared's default is 60s which previously
                // allowed a slow GeoIP backend to stall a "weather" request
                // past any reasonable user-visible deadline.
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    return nil
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success,
                      let lat = json["latitude"] as? Double,
                      let lon = json["longitude"] as? Double else {
                    return nil
                }

                return (lat: lat, lon: lon)
            } catch {
                Log.tools.debug("GeoIP lookup failed: \(error.localizedDescription)")
                return nil
            }
        }.value

        guard let coords else { return nil }

        let location = CLLocation(latitude: coords.lat, longitude: coords.lon)

        // Always validate via MapKit reverse geocoding — never trust raw ipwho.is city names
        // reverseGeocode is nonisolated, so also run detached to avoid cancellation.
        let cityName: String? = await Task.detached {
            await self.reverseGeocode(location)
        }.value

        guard let cityName else {
            Log.tools.debug("GeoIP reverse geocode failed for (\(coords.lat), \(coords.lon))")
            return nil
        }

        return ResolvedLocation(coordinate: location, cityName: cityName, source: .geoIP)
    }

    // MARK: - Reverse Geocoding

    /// Known MapKit placeholder names that should never be displayed as a city.
    /// Matched case-insensitively after trimming; see `isPlaceholderName(_:)`.
    static nonisolated let placeholderNames: Set<String> = [
        "Current Location", "Current View", "My Location",
        "Your Location", "Unknown Location"
    ]

    /// Case-insensitive, whitespace-tolerant placeholder check. MapKit occasionally
    /// returns names like " current view ", "Current View (Default)" etc., and exact
    /// `Set.contains` has let them leak through for months.
    public static nonisolated func isPlaceholderName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
        for placeholder in placeholderNames {
            let placeholderLower = placeholder.lowercased()
            if lowered == placeholderLower { return true }
            // Reject "Current View (Default)" / "Current View - Area" style variants.
            if lowered.hasPrefix(placeholderLower + " ") ||
               lowered.hasPrefix(placeholderLower + ",") ||
               lowered.hasPrefix(placeholderLower + "-") ||
               lowered.hasPrefix(placeholderLower + "(") {
                return true
            }
        }
        return false
    }

    /// Reverse-geocodes a location to a city name via MapKit.
    private nonisolated func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let mapItems = try? await request.mapItems, let first = mapItems.first else { return nil }
        // Prefer cityName from address representations
        if let city = first.addressRepresentations?.cityName, !Self.isPlaceholderName(city) {
            return city.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Parse from short address (first component before comma)
        if let short = first.address?.shortAddress {
            let component = short.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let component, !Self.isPlaceholderName(component) {
                return component
            }
        }
        // Reject known placeholder names from MKMapItem.name
        if let name = first.name, !Self.isPlaceholderName(name) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status != .notDetermined, let continuation = authContinuation {
            authContinuation = nil
            continuation.resume(returning: status)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            guard let continuation = locationContinuation else { return }
            locationContinuation = nil
            continuation.resume(returning: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(throwing: error)
    }
}
