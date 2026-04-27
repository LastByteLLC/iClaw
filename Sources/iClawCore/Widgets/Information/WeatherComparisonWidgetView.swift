import SwiftUI

/// Widget showing side-by-side weather comparison between two locations.
/// Used by WeatherTool for `.comparison(otherCity:)` intent.
struct WeatherComparisonWidgetView: View {
    let data: WeatherComparisonWidgetData

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // City 1
                WeatherComparisonColumn(
                    city: data.city1,
                    temp: data.temp1,
                    condition: data.condition1,
                    iconName: data.icon1,
                    humidity: data.humidity1
                )

                // Divider
                Rectangle()
                    .fill(.primary.opacity(0.15))
                    .frame(width: 1, height: 80)

                // City 2
                WeatherComparisonColumn(
                    city: data.city2,
                    temp: data.temp2,
                    condition: data.condition2,
                    iconName: data.icon2,
                    humidity: data.humidity2
                )
            }
        }
        .padding(20)
        .glassContainer(cornerRadius: 24, hasShadow: false)
        .frame(minWidth: 240)
    }
}

/// A single column in the weather comparison widget.
private struct WeatherComparisonColumn: View {
    let city: String
    let temp: String
    let condition: String
    let iconName: String
    let humidity: Int

    var body: some View {
        VStack(spacing: 6) {
            Text(city)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 100)

            Image(systemName: iconName)
                .symbolRenderingMode(.multicolor)
                .font(.title2)

            Text(temp)
                .font(.title2.bold())
                .fontDesign(.rounded)

            Text(condition)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            HStack(spacing: 2) {
                Image(systemName: "humidity.fill")
                    .font(.system(size: 9)) // SF Symbol sizing — small decorative icon
                    .foregroundStyle(.blue.opacity(0.6))
                Text("\(humidity)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("London vs Paris") {
    WeatherComparisonWidgetView(data: WeatherComparisonWidgetData(
        city1: "London", temp1: "14°C", condition1: "Partly cloudy",
        icon1: "cloud.sun", humidity1: 72,
        city2: "Paris", temp2: "18°C", condition2: "Clear sky",
        icon2: "sun.max", humidity2: 58
    ))
    .padding()
}
