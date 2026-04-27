import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Widget Data

/// Data for the calendar event confirmation widget. Used for both the live-created
/// confirmation and the .ics fallback (when calendar permission is denied).
public struct CalendarEventConfirmationData: Sendable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    /// If non-nil, the event was saved as an .ics file (permission denied path).
    public let icsFileURL: URL?
    /// True if the event was successfully added to the calendar.
    public let isConfirmed: Bool

    public init(title: String, startDate: Date, endDate: Date, location: String? = nil, icsFileURL: URL? = nil, isConfirmed: Bool = false) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.icsFileURL = icsFileURL
        self.isConfirmed = isConfirmed
    }
}

// MARK: - Widget View

struct CalendarEventConfirmationWidgetView: View {
    let data: CalendarEventConfirmationData

    private var isICSFallback: Bool { data.icsFileURL != nil }

    private var dayNumber: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f.string(from: data.startDate)
    }

    private var dayOfWeek: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: data.startDate).uppercased()
    }

    private var monthYear: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMyyyy")
        return f.string(from: data.startDate)
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return "\(f.string(from: data.startDate)) – \(f.string(from: data.endDate))"
    }

    var body: some View {
        HStack(spacing: 14) {
            // Calendar date block
            VStack(spacing: 2) {
                Text(dayOfWeek)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                Text(dayNumber)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                Text(monthYear)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 60, height: 70)
            .background(.ultraThinMaterial)
            .clipShape(.rect(cornerRadius: 12))

            // Event details
            VStack(alignment: .leading, spacing: 4) {
                Text(data.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Label(timeRange, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let location = data.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Status or action
                if isICSFallback {
                    Button {
                        openICSFile()
                    } label: {
                        Label(String(localized: "Add to Calendar", bundle: .iClawCore), systemImage: "calendar.badge.plus")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                    .padding(.top, 2)
                } else if data.isConfirmed {
                    Label(String(localized: "Added to Calendar", bundle: .iClawCore), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .glassContainer(hasShadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.title), \(timeRange)")
    }

    private func openICSFile() {
        #if canImport(AppKit)
        guard let url = data.icsFileURL else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
