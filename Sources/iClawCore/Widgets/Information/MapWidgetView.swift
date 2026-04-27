import SwiftUI
import MapKit
import _MapKit_SwiftUI

/// Data passed from MapsCoreTool to MapWidgetView.
struct MapWidgetData: Sendable {
    let originName: String
    let destinationName: String
    let originCoordinate: CLLocationCoordinate2D
    let destinationCoordinate: CLLocationCoordinate2D
    /// Route coordinates stored as flat array [lat, lon, lat, lon, ...] for Sendable compliance.
    let routeCoordinates: [Double]
    let distanceText: String
    let etaText: String
    let mapsURL: URL

    /// For nearby/search results (no route).
    let searchResults: [MapSearchResult]?

    init(
        originName: String,
        destinationName: String,
        originCoordinate: CLLocationCoordinate2D,
        destinationCoordinate: CLLocationCoordinate2D,
        routeCoordinates: [Double] = [],
        distanceText: String,
        etaText: String,
        mapsURL: URL,
        searchResults: [MapSearchResult]? = nil
    ) {
        self.originName = originName
        self.destinationName = destinationName
        self.originCoordinate = originCoordinate
        self.destinationCoordinate = destinationCoordinate
        self.routeCoordinates = routeCoordinates
        self.distanceText = distanceText
        self.etaText = etaText
        self.mapsURL = mapsURL
        self.searchResults = searchResults
    }

    /// Reconstructs an MKPolyline from the stored flat coordinate array.
    var polyline: MKPolyline? {
        guard routeCoordinates.count >= 4 else { return nil }
        var coords: [CLLocationCoordinate2D] = []
        for i in stride(from: 0, to: routeCoordinates.count - 1, by: 2) {
            coords.append(CLLocationCoordinate2D(latitude: routeCoordinates[i], longitude: routeCoordinates[i + 1]))
        }
        return MKPolyline(coordinates: coords, count: coords.count)
    }
}

struct MapSearchResult: Sendable, Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

extension CLLocationCoordinate2D: @retroactive @unchecked Sendable {}

struct MapWidgetView: View {
    let data: MapWidgetData

    var body: some View {
        VStack(spacing: 0) {
            // Map preview
            mapPreview(for: data)
                .frame(height: 160)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))

            // Info bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let results = data.searchResults, !results.isEmpty {
                        Text(String(format: String(localized: "results_near_you", bundle: .iClawCore), results.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(data.destinationName)
                            .font(.headline)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Label(data.distanceText, systemImage: "arrow.triangle.swap")
                            Label(data.etaText, systemImage: "car.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    URLOpener.open(data.mapsURL)
                } label: {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open in Apple Maps", bundle: .iClawCore))
                .accessibilityLabel(String(localized: "Open in Apple Maps", bundle: .iClawCore))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        }
        .frame(minWidth: 240)
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(String(localized: "Open in Maps", bundle: .iClawCore))
        .onTapGesture {
            URLOpener.open(data.mapsURL)
        }
    }

    @ViewBuilder
    private func mapPreview(for data: MapWidgetData) -> some View {
        if let results = data.searchResults, !results.isEmpty {
            // Search results mode — show pins
            Map {
                ForEach(results) { result in
                    Marker(result.name, coordinate: result.coordinate)
                        .tint(.red)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .including([.restaurant, .cafe, .store])))
            .allowsHitTesting(false)
        } else {
            // Directions mode — show origin, destination, and route
            Map {
                Marker(data.originName, coordinate: data.originCoordinate)
                    .tint(.green)
                Marker(data.destinationName, coordinate: data.destinationCoordinate)
                    .tint(.red)
                if let polyline = data.polyline {
                    MapPolyline(polyline)
                        .stroke(.blue, lineWidth: 4)
                }
            }
            .mapStyle(.standard)
            .allowsHitTesting(false)
        }
    }
}
