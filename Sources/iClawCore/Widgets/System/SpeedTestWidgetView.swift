#if os(macOS)
import SwiftUI

/// Data model for the speed test widget.
public struct SpeedTestWidgetData: Sendable {
    public let downloadMbps: Double?
    public let latencyMs: Int?
    public let signalStrength: Int   // dBm
    public let signalQuality: String
    public let ssid: String?
    public let channel: String?
    public let isConnected: Bool
}

struct SpeedTestWidgetView: View {
    let data: SpeedTestWidgetData

    var body: some View {
        VStack(spacing: 12) {
            // Hero: download speed
            HStack(spacing: 4) {
                Image(systemName: "wifi.circle")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .font(.title2)

                if let mbps = data.downloadMbps {
                    Text(String(format: "%.1f", mbps))
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if data.isConnected {
                    Text("Speed test failed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Secondary stats
            HStack(spacing: 16) {
                if let latency = data.latencyMs {
                    VStack(spacing: 2) {
                        Text("\(latency)")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                        Text("ms")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 2) {
                    Text(data.signalQuality)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                    Text("Signal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 2) {
                    Text("\(data.signalStrength)")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                    Text("dBm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // WiFi info
            if let ssid = data.ssid {
                HStack(spacing: 8) {
                    Text(ssid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let ch = data.channel {
                        Text("Ch \(ch)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 180)
        .glassContainer(cornerRadius: 20)
    }
}
#endif
