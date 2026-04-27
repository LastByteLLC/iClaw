import SwiftUI

/// Widget that shows local time, remote time, and the computed difference side by side.
/// Used by TimeTool when a remote location is resolved.
struct TimeComparisonWidgetView: View {
    let data: TimeComparisonWidgetData

    @Environment(\.isHUDVisible) private var isHUDVisible
    @State private var currentTime = Date()
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var localTZ: TimeZone {
        TimeZone(identifier: data.localTimeZoneIdentifier) ?? .current
    }

    private var remoteTZ: TimeZone {
        TimeZone(identifier: data.remoteTimeZoneIdentifier) ?? .current
    }

    private var differenceLabel: String {
        let diff = data.differenceSeconds
        if diff == 0 { return String(localized: "Same timezone", bundle: .iClawCore) }
        let hours = Double(abs(diff)) / 3600.0
        let key: String.LocalizationValue = diff > 0 ? "time.comparison.ahead" : "time.comparison.behind"
        let hoursStr = hours == hours.rounded() ? "\(Int(hours))" : String(format: "%.1f", hours)
        return String(format: String(localized: key, bundle: .iClawCore), hoursStr)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Difference badge
            Text(differenceLabel)
                .font(.footnote.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(data.differenceSeconds == 0 ? .secondary : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())

            HStack(spacing: 20) {
                // Local time column
                TimeColumn(
                    label: String(localized: "You", bundle: .iClawCore),
                    timeZone: localTZ,
                    currentTime: currentTime,
                    isLocal: true
                )
                .accessibilityElement(children: .combine)

                // Divider
                Rectangle()
                    .fill(.primary.opacity(0.15))
                    .frame(width: 1, height: 60)
                    .accessibilityHidden(true)

                // Remote time column
                TimeColumn(
                    label: data.remoteLocationName,
                    timeZone: remoteTZ,
                    currentTime: currentTime,
                    isLocal: false
                )
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .glassContainer(cornerRadius: 24, hasShadow: false)
        .copyable("\(data.remoteLocationName): \(differenceLabel)")
        .frame(minWidth: 220)
        .onReceive(timer) { guard isHUDVisible else { return }; currentTime = $0 }
    }
}

/// A single column showing a location label, time, and date.
private struct TimeColumn: View {
    let label: String
    let timeZone: TimeZone
    let currentTime: Date
    let isLocal: Bool

    /// Creates local formatters per call to avoid data races from mutating shared statics.
    private var timeString: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.timeZone = timeZone
        return f.string(from: currentTime)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        f.timeZone = timeZone
        return f.string(from: currentTime)
    }

    private var abbreviation: String {
        timeZone.abbreviation(for: currentTime) ?? ""
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 90)

            Text(timeString)
                .font(.title2.bold())
                .fontDesign(.monospaced)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text("\(dateString) \(abbreviation)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview("Same day") {
    TimeComparisonWidgetView(data: TimeComparisonWidgetData(
        localTimeZoneIdentifier: "America/New_York",
        remoteTimeZoneIdentifier: "America/Los_Angeles",
        remoteLocationName: "Seattle",
        differenceSeconds: -3 * 3600
    ))
    .padding()
}

#Preview("Cross-day") {
    TimeComparisonWidgetView(data: TimeComparisonWidgetData(
        localTimeZoneIdentifier: "America/New_York",
        remoteTimeZoneIdentifier: "Asia/Tokyo",
        remoteLocationName: "Tokyo",
        differenceSeconds: 14 * 3600
    ))
    .padding()
}
