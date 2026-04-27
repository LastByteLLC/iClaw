import SwiftUI

/// View mode for the calendar date widget.
public enum DateViewMode: String, Sendable {
    case day, week, month
}

/// Data model for the date view widget.
public struct DateViewWidgetData: Sendable {
    public let referenceDate: Date
    public let viewMode: DateViewMode
    public let highlightedDates: [Date]
    public let title: String?

    public init(referenceDate: Date, viewMode: DateViewMode, highlightedDates: [Date] = [], title: String? = nil) {
        self.referenceDate = referenceDate
        self.viewMode = viewMode
        self.highlightedDates = highlightedDates
        self.title = title
    }
}

struct DateViewWidget: View {
    let data: DateViewWidgetData

    private var calendar: Calendar { .current }

    var body: some View {
        switch data.viewMode {
        case .day:
            dayView(data)
        case .week:
            weekView(data)
        case .month:
            monthView(data)
        }
    }

    // MARK: - Day View

    @ViewBuilder
    private func dayView(_ d: DateViewWidgetData) -> some View {
        VStack(spacing: 8) {
            Text(dayName(d.referenceDate))
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)

            Text(formattedDate(d.referenceDate))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Week \(calendar.component(.weekOfYear, from: d.referenceDate))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(minWidth: 160)
        .glassContainer(cornerRadius: 20)
    }

    // MARK: - Week View

    @ViewBuilder
    private func weekView(_ d: DateViewWidgetData) -> some View {
        let weekDates = datesForWeek(containing: d.referenceDate)

        VStack(spacing: 10) {
            // Header
            Text("\(monthYearString(d.referenceDate)) — Week \(calendar.component(.weekOfYear, from: d.referenceDate))")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)

            // Day headers
            HStack(spacing: 0) {
                ForEach(weekDates, id: \.self) { date in
                    Text(shortDayName(date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day numbers
            HStack(spacing: 0) {
                ForEach(weekDates, id: \.self) { date in
                    let isToday = calendar.isDateInToday(date)
                    Text("\(calendar.component(.day, from: date))")
                        .font(.system(.headline, design: .rounded, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isToday {
                                Circle()
                                    .fill(.primary.opacity(0.15))
                                    .frame(width: 30, height: 30)
                            }
                        }
                }
            }
        }
        .padding()
        .frame(minWidth: 240)
        .glassContainer(cornerRadius: 20)
    }

    // MARK: - Month View

    @ViewBuilder
    private func monthView(_ d: DateViewWidgetData) -> some View {
        let monthDays = daysInMonth(for: d.referenceDate)
        let firstWeekday = firstWeekdayOffset(for: d.referenceDate)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let highlightedDaySet = Set(d.highlightedDates.map { calendar.startOfDay(for: $0) })

        VStack(spacing: 8) {
            // Header
            Text(monthYearString(d.referenceDate))
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)

            // Day-of-week headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols(), id: \.self) { sym in
                    Text(sym)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Calendar grid
            LazyVGrid(columns: columns, spacing: 4) {
                // Leading empty cells for offset
                ForEach(0..<firstWeekday, id: \.self) { _ in
                    Text("")
                        .frame(height: 24)
                }

                // Day cells
                ForEach(Array(1...monthDays), id: \.self) { (day: Int) in
                    let date = dateFor(day: day, in: d.referenceDate)
                    let isToday = date.map { calendar.isDateInToday($0) } ?? false
                    let isHighlighted = date.map { highlightedDaySet.contains(calendar.startOfDay(for: $0)) } ?? false

                    VStack(spacing: 1) {
                        Text("\(day)")
                            .font(.system(.caption, design: .rounded, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? .primary : .secondary)
                            .frame(width: 24, height: 24)
                            .background {
                                if isToday {
                                    Circle()
                                        .fill(.primary.opacity(0.15))
                                }
                            }

                        if isHighlighted {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 240)
        .glassContainer(cornerRadius: 20)
    }

    // MARK: - Helpers

    private static let dayNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EE"
        return f
    }()

    private static let weekdaySymbolsFormatter = DateFormatter()

    private func dayName(_ date: Date) -> String {
        Self.dayNameFormatter.string(from: date)
    }

    private func formattedDate(_ date: Date) -> String {
        Self.longDateFormatter.string(from: date)
    }

    private func monthYearString(_ date: Date) -> String {
        Self.monthYearFormatter.string(from: date)
    }

    private func shortDayName(_ date: Date) -> String {
        Self.shortDayFormatter.string(from: date)
    }

    private func weekdaySymbols() -> [String] {
        let symbols = Self.weekdaySymbolsFormatter.veryShortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let firstWeekday = calendar.firstWeekday - 1
        return Array(symbols[firstWeekday...]) + Array(symbols[..<firstWeekday])
    }

    private func datesForWeek(containing date: Date) -> [Date] {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekInterval.start) }
    }

    private func daysInMonth(for date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    private func firstWeekdayOffset(for date: Date) -> Int {
        guard let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return 0 }
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let firstWeekday = calendar.firstWeekday
        return (weekday - firstWeekday + 7) % 7
    }

    private func dateFor(day: Int, in referenceDate: Date) -> Date? {
        var comps = calendar.dateComponents([.year, .month], from: referenceDate)
        comps.day = day
        return calendar.date(from: comps)
    }
}
