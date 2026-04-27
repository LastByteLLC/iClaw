import SwiftUI

struct WeatherWidgetData: Sendable {
    let city: String
    let temperature: String
    let condition: String
    let iconName: String
}

struct WeatherWidgetView: View {
    let data: WeatherWidgetData

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: data.iconName)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                
                VStack(alignment: .leading) {
                    Text(data.city)
                        .font(.headline)
                    Text(data.condition)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Text(data.temperature)
                .font(.largeTitle.weight(.thin))
                .fontDesign(.rounded)
        }
        .padding()
        .frame(minWidth: 160)
        .glassContainer()
        .copyable("\(data.city): \(data.temperature), \(data.condition)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.city), \(data.condition), \(data.temperature)")
    }
}
