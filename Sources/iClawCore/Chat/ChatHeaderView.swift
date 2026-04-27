import SwiftUI

/// The top bar of the chat view, showing the default header, search header, or mode header.
struct ChatHeaderView: View {
    @Binding var isSearchActive: Bool
    @FocusState.Binding var isSearchFieldFocused: Bool
    @Bindable var searchManager: ConversationSearchManager
    var skillModeState: SkillModeState

    var onExitSkillMode: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if isSearchActive {
                searchHeader
            } else if skillModeState.isActive {
                modeHeader
            } else {
                defaultHeader
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .animation(.snappy, value: isSearchActive)
        .animation(.snappy, value: skillModeState.isActive)
    }

    // MARK: - Mode Header

    private var modeHeader: some View {
        HStack {
            Image(systemName: skillModeState.icon)
                .foregroundStyle(.yellow)

            Text(skillModeState.displayName)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                onExitSkillMode()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Exit mode", bundle: .iClawCore))
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    // MARK: - Default Header

    private var defaultHeader: some View {
        HStack {
            ClawIcon.image
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text("iClaw", bundle: .iClawCore)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                isSearchActive = true
                isSearchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Search conversations", bundle: .iClawCore))
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

            // Use @Environment(\.openSettings) — the official SwiftUI API.
            // SettingsLink and raw selectors don't work reliably from a non-activating FloatingPanel.
            Button {
                #if canImport(AppKit)
                // Ensure the app is active so the Settings window can appear.
                let wasAccessory = NSApp.activationPolicy() == .accessory
                if wasAccessory { NSApp.setActivationPolicy(.regular) }
                NSApp.activate()
                #endif
                SettingsNavigation.shared.requestedTab = .general
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Settings", bundle: .iClawCore))
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(localized: "Search conversations...", bundle: .iClawCore), text: $searchManager.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)

            if searchManager.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close search", bundle: .iClawCore))
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    // MARK: - Helpers

    func closeSearch() {
        isSearchActive = false
        searchManager.searchQuery = ""
        isSearchFieldFocused = false
    }
}
