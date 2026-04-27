import SwiftUI

struct MoonWidgetView: View {
    let data: MoonWidgetData

    var body: some View {
        if data.isSearch {
            searchLayout
        } else {
            currentPhaseLayout
        }
    }

    /// Layout for "next full moon" — date is the hero element.
    private var searchLayout: some View {
        VStack(spacing: 10) {
            // Date in large print — this is what the user asked for
            if let dateLabel = data.dateLabel {
                Text(dateLabel)
                    .font(.title.bold())
                    .fontDesign(.rounded)
            }

            // Phase name + icon inline
            HStack(spacing: 6) {
                Image(systemName: data.phaseIcon)
                    .symbolRenderingMode(.monochrome)
                    .font(.title3) // SF Symbol sizing
                    .foregroundStyle(.secondary)
                Text(data.phaseName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Location
            Text(data.location)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(minWidth: 160)
        .glassContainer()
    }

    /// Layout for current moon phase — phase icon is the hero element.
    private var currentPhaseLayout: some View {
        VStack(spacing: 12) {
            // Moon phase SF Symbol — large and centered
            Image(systemName: data.phaseIcon)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 48)) // SF Symbol sizing — hero moon phase display
                .foregroundStyle(.primary)

            // Phase name
            Text(data.phaseName)
                .font(.headline)

            // Illumination bar
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.8))
                            .frame(width: geo.size.width * CGFloat(data.illumination) / 100.0, height: 8)
                    }
                }
                .frame(height: 8)

                Text("\(data.illumination)% illuminated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(format: String(localized: "moon.a11y.illumination", bundle: .iClawCore), data.illumination))

            // Location and optional date
            VStack(spacing: 2) {
                Text(data.location)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let dateLabel = data.dateLabel {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .frame(minWidth: 160)
        .glassContainer()
    }
}
