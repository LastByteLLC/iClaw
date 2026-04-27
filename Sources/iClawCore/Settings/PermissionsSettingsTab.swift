import SwiftUI
import MapKit

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {
    @State private var rejectedPermissions: Set<PermissionManager.PermissionKind> = []
    @State private var fallbackLocationText: String = LocationManager.fallbackLocation?.displayName ?? ""
    @State private var currentFallbackName: String? = LocationManager.fallbackLocation?.displayName
    @State private var isGeocoding = false

    var body: some View {
        Form {
            Section {
                Text("iClaw requests permissions only when a tool needs them. Tap a permission to open System Settings.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Privacy Permissions", bundle: .iClawCore)) {
                permissionRow(name: String(localized: "Location", bundle: .iClawCore), icon: "location", kind: .location, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
                permissionRow(name: String(localized: "Contacts", bundle: .iClawCore), icon: "person.crop.circle", kind: .contacts, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
                permissionRow(name: String(localized: "Calendars", bundle: .iClawCore), icon: "calendar", kind: .calendar, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                permissionRow(name: String(localized: "Reminders", bundle: .iClawCore), icon: "checklist", kind: .reminders, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
                permissionRow(name: String(localized: "Microphone", bundle: .iClawCore), icon: "mic", kind: .microphone, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                PermissionRow(name: String(localized: "Speech Recognition", bundle: .iClawCore), icon: "waveform", urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
                PermissionRow(name: String(localized: "Screen Recording", bundle: .iClawCore), icon: "rectangle.inset.filled.and.person.filled", urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }

            Section(String(localized: "System Permissions", bundle: .iClawCore)) {
                permissionRow(name: String(localized: "Notifications", bundle: .iClawCore), icon: "bell", kind: .notifications, urlString: "x-apple.systempreferences:com.apple.preference.notifications")
                PermissionRow(name: String(localized: "Automation (AppleScript)", bundle: .iClawCore), icon: "applescript", urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }

            Section(String(localized: "Default Location", bundle: .iClawCore)) {
                HStack {
                    TextField(String(localized: "City or address", bundle: .iClawCore), text: $fallbackLocationText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { geocodeLocation() }

                    if isGeocoding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let name = currentFallbackName {
                    HStack {
                        Text("Set to: \(name)", bundle: .iClawCore)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Clear", bundle: .iClawCore)) {
                            LocationManager.setFallbackLocation(nil)
                            currentFallbackName = nil
                            fallbackLocationText = ""
                        }
                        .font(.caption)
                    }
                }

                Text("Used when Location Services is unavailable.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            rejectedPermissions = PermissionManager.allRejected()
        }
    }

    @ViewBuilder
    private func permissionRow(name: String, icon: String, kind: PermissionManager.PermissionKind, urlString: String) -> some View {
        if rejectedPermissions.contains(kind) {
            HStack {
                Label(name, systemImage: icon)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Rejected", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button(String(localized: "Clear", bundle: .iClawCore)) {
                    PermissionManager.clearRejection(kind)
                    rejectedPermissions.remove(kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            PermissionRow(name: name, icon: icon, urlString: urlString)
        }
    }

    private func geocodeLocation() {
        let text = fallbackLocationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isGeocoding = true

        Task {
            defer { isGeocoding = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            let search = MKLocalSearch(request: request)
            guard let response = try? await search.start(),
                  let item = response.mapItems.first else { return }

            let coordinate = item.location.coordinate
            let displayName: String
            if let address = item.address, let short = address.shortAddress, !short.isEmpty {
                displayName = short
            } else {
                displayName = item.name ?? text
            }
            let fallback = LocationManager.FallbackLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                displayName: displayName
            )
            LocationManager.setFallbackLocation(fallback)
            currentFallbackName = fallback.displayName
            fallbackLocationText = ""
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let name: String
    let icon: String
    let urlString: String

    var body: some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            Button {
                if let url = URL(string: urlString) {
                    URLOpener.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Open \(name) in System Settings", bundle: .iClawCore))
        }
        .accessibilityElement(children: .combine)
    }
}
