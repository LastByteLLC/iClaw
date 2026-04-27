import SwiftUI

struct CalendarWidgetView: View {
    let data: CalendarWidgetData

    var body: some View {
        VStack(spacing: 8) {
            Text(data.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(data.result)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            
            if let date = data.date {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(minWidth: 140, minHeight: 100)
        .glassContainer(cornerRadius: 20)
    }
}
