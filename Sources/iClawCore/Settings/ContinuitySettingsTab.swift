import SwiftUI

// MARK: - Continuity Settings

#if CONTINUITY_ENABLED
struct ContinuitySettingsView: View {
    @AppStorage(AppConfig.continuityEnabledKey) private var continuityEnabled = false
    @State private var devices: [RemoteDevice] = []
    @State private var isRefreshing = false

    var body: some View {
        ZStack {
            Form {
                Section {
                    Toggle(String(localized: "Enable iPhone/Mac Continuity", bundle: .iClawCore), isOn: $continuityEnabled)
                        .onChange(of: continuityEnabled) { _, enabled in
                            if enabled {
                                Task { await ContinuityManager.shared.start() }
                            } else {
                                Task { await ContinuityManager.shared.stop() }
                            }
                        }
                    Text("Route tool requests between your devices via CloudKit. Both devices must be signed into the same Apple ID.", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if continuityEnabled {
                    Section(String(localized: "Registered Devices", bundle: .iClawCore)) {
                        if devices.isEmpty && !isRefreshing {
                            Text("No other devices found.", bundle: .iClawCore)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(devices) { device in
                            HStack {
                                Image(systemName: device.deviceType == .mac ? "desktopcomputer" : "iphone")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                        .font(.body)
                                    Text(device.isAvailable ? String(localized: "Available", bundle: .iClawCore) : String(localized: "Offline", bundle: .iClawCore))
                                        .font(.caption)
                                        .foregroundStyle(device.isAvailable ? .green : .red)
                                }
                                Spacer()
                                Text("v\(device.appVersion)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            isRefreshing = true
                            Task {
                                await ContinuityManager.shared.refreshDevices()
                                devices = await ContinuityManager.shared.availableDevices
                                isRefreshing = false
                            }
                        } label: {
                            HStack {
                                if isRefreshing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                                Text("Refresh", bundle: .iClawCore)
                            }
                        }
                        .disabled(isRefreshing)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .disabled(true)
            .opacity(0.4)

            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.title) // SF Symbol sizing
                    .foregroundStyle(.secondary)
                Text("Coming Soon")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            if continuityEnabled {
                await ContinuityManager.shared.refreshDevices()
                devices = await ContinuityManager.shared.availableDevices
            }
        }
    }
}
#else
struct ContinuitySettingsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Coming Soon", bundle: .iClawCore)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
