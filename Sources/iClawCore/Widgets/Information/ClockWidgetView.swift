import SwiftUI

/// A macOS 26+ widget that renders a live analog and digital clock.
/// Uses Liquid Glass aesthetic (ultraThinMaterial, thin border).
struct ClockWidgetView: View {
    let data: ClockWidgetData

    @Environment(\.isHUDVisible) private var isHUDVisible
    @State private var currentTime = Date()
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var timeZone: TimeZone {
        TimeZone(identifier: data.timeZoneIdentifier) ?? TimeZone.current
    }
    
    /// Creates a local formatter per call to avoid data races from mutating a shared static.
    private var digitalTimeString: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.timeZone = timeZone
        return f.string(from: currentTime)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text(data.location)
                .font(.headline)
                .foregroundStyle(.primary)
            
            // Analog Clock Face
            ZStack {
                // Outer ring
                Circle()
                    .stroke(.primary.opacity(0.1), lineWidth: 4)
                    .background(Circle().fill(.ultraThinMaterial))
                    .frame(width: 140, height: 140)
                
                // Tick marks for 12 hours
                ForEach(0..<12) { i in
                    Rectangle()
                        .fill(.primary.opacity(0.4))
                        .frame(width: 2, height: i % 3 == 0 ? 10 : 5)
                        .offset(y: -60)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
                
                // Hour Hand
                ClockHand(angle: hourAngle, length: 40, width: 4, color: .primary)
                
                // Minute Hand
                ClockHand(angle: minuteAngle, length: 55, width: 3, color: .primary)
                
                // Second Hand (Live update)
                ClockHand(angle: secondAngle, length: 60, width: 1.5, color: .red)
                
                // Center pin
                Circle()
                    .fill(.primary)
                    .frame(width: 8, height: 8)
            }
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: String(localized: "clock.a11y.showing", bundle: .iClawCore), digitalTimeString))


            // Digital Clock readout (Live update)
            Text(digitalTimeString)
                .font(.title2.bold())
                .fontDesign(.monospaced)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(24)
        .glassContainer(cornerRadius: 32, hasShadow: false)
        .copyable("\(data.location): \(digitalTimeString)")
        .frame(minWidth: 180)
        .onReceive(timer) { input in
            guard isHUDVisible else { return }
            currentTime = input
        }
    }
    
    // Rotation Angle calculations
    private var hourAngle: Angle {
        let components = Calendar.current.dateComponents(in: timeZone, from: currentTime)
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        return .degrees((hour * 30) + (minute * 0.5))
    }
    
    private var minuteAngle: Angle {
        let components = Calendar.current.dateComponents(in: timeZone, from: currentTime)
        let minute = Double(components.minute ?? 0)
        return .degrees(minute * 6)
    }
    
    private var secondAngle: Angle {
        let components = Calendar.current.dateComponents(in: timeZone, from: currentTime)
        let second = Double(components.second ?? 0)
        return .degrees(second * 6)
    }
}

/// Helper view for rendering clock hands.
struct ClockHand: View {
    let angle: Angle
    let length: CGFloat
    let width: CGFloat
    let color: Color
    
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(angle)
    }
}

#Preview {
    ClockWidgetView(data: ClockWidgetData(location: "Tokyo", timeZoneIdentifier: "Asia/Tokyo"))
}
