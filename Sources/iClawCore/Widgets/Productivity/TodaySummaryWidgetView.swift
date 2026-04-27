import SwiftUI

struct TodaySummaryWidgetView: View {
    let data: TodaySummaryWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            eventsSection
            remindersSection
            hintsSection
        }
        .padding()
        .frame(minWidth: 240)
        .glassContainer(cornerRadius: 20)
    }

    // MARK: - Header (weather integrated)

    private var headerSection: some View {
        HStack {
            if let weather = data.weather {
                Image(systemName: weather.iconName)
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)
            } else {
                Image(systemName: "calendar.badge.clock")
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let weather = data.weather {
                    Text("\(weather.temperature) \(weather.condition)")
                        .font(.headline)
                    Text("\(weather.city) — H: \(weather.high)  L: \(weather.low)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Today")
                        .font(.headline)
                    Text(data.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Events", systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if data.events.isEmpty {
                Text("No events today")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(data.events.prefix(5).enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                        Text(event.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if event.isAllDay {
                            Text("All day")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(event.startTime, format: .dateTime.hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if data.events.count > 5 {
                    Text(String(format: String(localized: "more_items", bundle: .iClawCore), data.events.count - 5))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Reminders", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if data.reminders.isEmpty {
                Text("All clear")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(data.reminders.prefix(5).enumerated()), id: \.offset) { _, reminder in
                    HStack(spacing: 6) {
                        Image(systemName: "circle")
                            .font(.system(size: 8)) // SF Symbol sizing — small bullet indicator
                            .foregroundStyle(.orange)
                        Text(reminder.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                if data.reminders.count > 5 {
                    Text(String(format: String(localized: "more_items", bundle: .iClawCore), data.reminders.count - 5))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Hints (upsell unavailable data sources)

    @ViewBuilder
    private var hintsSection: some View {
        if !data.hints.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(data.hints, id: \.self) { hint in
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
        }
    }
}
