import SwiftUI

/// Widget showing current weather + multi-day forecast.
/// Used by WeatherTool for `.forecast(days:)` intent.
struct WeatherForecastWidgetView: View {
    let data: WeatherForecastWidgetData

    var body: some View {
        VStack(spacing: 12) {
            // Current weather header
            HStack(spacing: 10) {
                Image(systemName: data.currentIcon)
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(data.city)
                        .font(.subheadline.weight(.semibold))
                    Text(data.currentCondition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(data.currentTemp)
                    .font(.title.weight(.thin))
                    .fontDesign(.rounded)
            }

            Divider()
                .opacity(0.3)

            // Forecast rows
            HStack(spacing: 0) {
                ForEach(data.forecast, id: \.dayLabel) { entry in
                    VStack(spacing: 6) {
                        Text(entry.dayLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

                        Image(systemName: entry.iconName)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.primary)
                            .font(.body)
                            .accessibilityHidden(true)

                        VStack(spacing: 1) {
                            Text(entry.high)
                                .font(.caption.weight(.semibold))
                            Text(entry.low)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if let precip = entry.precipChance {
                            HStack(spacing: 2) {
                                Image(systemName: "drop.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.blue.opacity(0.7))
                                    .accessibilityHidden(true)
                                Text("\(precip)%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(forecastAccessibilityLabel(for: entry))
                }
            }
        }
        .padding(16)
        .glassContainer(cornerRadius: 20, hasShadow: false)
        .frame(minWidth: 220)
    }

    private func forecastAccessibilityLabel(for entry: WeatherForecastEntry) -> Text {
        var parts: [String] = [entry.dayLabel, "high \(entry.high)", "low \(entry.low)"]
        if let precip = entry.precipChance {
            parts.append("\(precip) percent precipitation")
        }
        return Text(parts.joined(separator: ", "))
    }
}

#Preview("3-day forecast") {
    WeatherForecastWidgetView(data: WeatherForecastWidgetData(
        city: "London",
        currentTemp: "14°C",
        currentCondition: "Partly cloudy",
        currentIcon: "cloud.sun",
        forecast: [
            WeatherForecastEntry(dayLabel: "Today", high: "15°C", low: "9°C", condition: "Partly cloudy", iconName: "cloud.sun", precipChance: 20),
            WeatherForecastEntry(dayLabel: "Thu", high: "17°C", low: "10°C", condition: "Clear sky", iconName: "sun.max", precipChance: 5),
            WeatherForecastEntry(dayLabel: "Fri", high: "13°C", low: "8°C", condition: "Rain", iconName: "cloud.rain", precipChance: 70),
        ]
    ))
    .padding()
}
