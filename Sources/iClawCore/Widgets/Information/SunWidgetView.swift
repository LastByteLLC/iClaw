import SwiftUI

struct SunWidgetView: View {
    let data: SunWidgetData

    var body: some View {
        VStack(spacing: 12) {
            // City
            VStack(spacing: 2) {
                Text(data.city)
                    .font(.headline)
                if let dateLabel = data.dateLabel {
                    Text(dateLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Sunrise / Sunset row
            HStack(spacing: 24) {
                // Sunrise
                VStack(spacing: 4) {
                    Image(systemName: "sunrise.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.title2)
                        .foregroundStyle(.primary)
                    Text(data.sunrise)
                        .font(.system(.title3, design: .rounded, weight: .medium))
                    Text("Sunrise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Sunset
                VStack(spacing: 4) {
                    Image(systemName: "sunset.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.title2)
                        .foregroundStyle(.primary)
                    Text(data.sunset)
                        .font(.system(.title3, design: .rounded, weight: .medium))
                    Text("Sunset")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Daylight duration
            if !data.daylight.isEmpty {
                Text(data.daylight)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Golden hour info
            if data.goldenMorningEnd != nil || data.goldenEveningStart != nil {
                Divider()

                HStack(spacing: 16) {
                    if let morning = data.goldenMorningEnd {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("Golden hour until \(morning)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let evening = data.goldenEveningStart {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("Golden hour from \(evening)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 200)
        .glassContainer()
    }
}
