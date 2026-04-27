import SwiftUI

struct TimerWidgetView: View {
    let data: TimerWidgetData

    @Environment(\.dismissWidget) private var dismissWidget
    @State private var remainingTime: TimeInterval = 0
    @State private var isActive = false
    @State private var isDeleted = false
    
    var body: some View {
        if isDeleted {
            EmptyView()
        } else {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "timer")
                        .foregroundStyle(.blue)
                    
                    Text(data.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button {
                        isActive = false
                        dismissWidget?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss timer", bundle: .iClawCore))
                }
                
                Text(formatTime(remainingTime))
                    .font(.title.bold())
                    .fontDesign(.monospaced)
                    .foregroundStyle(remainingTime > 0 ? Color.primary : Color.red)
                    .contentTransition(.numericText())
                    .accessibilityLabel(String(format: String(localized: "timer.a11y.remaining", bundle: .iClawCore), formatTime(remainingTime)))
                
                ProgressView(value: max(0, min(1, remainingTime / (data.duration > 0 ? data.duration : 1))))
                    .tint(remainingTime > 0 ? Color.blue : Color.red)
                    .padding(.horizontal)
                
                HStack(spacing: 16) {
                    Button {
                        isActive.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isActive ? "pause.fill" : "play.fill")
                            Text(isActive ? String(localized: "Pause", bundle: .iClawCore) : String(localized: "Resume", bundle: .iClawCore))
                        }
                        .font(.caption.bold())
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        isActive = false
                        dismissWidget?()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.8))
                            .padding(8)
                            .background(.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Cancel timer", bundle: .iClawCore))
                }
            }
            .padding()
            .frame(minWidth: 180)
            .glassContainer(cornerRadius: 20, hasShadow: false)
            .onAppear {
                remainingTime = data.duration
                isActive = true
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if isActive && remainingTime > 0 {
                    remainingTime -= 1
                    if remainingTime <= 0 {
                        isActive = false
                        NSSound(named: NSSound.Name("Glass"))?.play()
                    }
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
