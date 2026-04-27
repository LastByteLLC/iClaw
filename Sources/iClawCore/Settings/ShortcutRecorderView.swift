import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A SwiftUI view that lets the user record a global keyboard shortcut.
/// Stores the key code and modifier flags in UserDefaults via `@AppStorage`.
public struct ShortcutRecorderView: View {
    @AppStorage(AppConfig.hotkeyKeyCodeKey) private var keyCode: Int = 0
    @AppStorage(AppConfig.hotkeyModifierFlagsKey) private var modifierFlags: Int = 0
    @State private var isRecording = false

    public init() {}

    public var body: some View {
        HStack {
            Text(displayString)
                .font(.body.monospaced())
                .foregroundStyle(keyCode > 0 ? .primary : .secondary)

            Spacer()

            if isRecording {
                Text("Press shortcut...", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    #if canImport(AppKit)
                    .background(KeyCaptureView(
                        onCapture: { code, mods in
                            keyCode = Int(code)
                            modifierFlags = Int(mods.intersection(.deviceIndependentFlagsMask).rawValue)
                            isRecording = false
                            NotificationCenter.default.post(name: .iClawHotkeyChanged, object: nil)
                        },
                        onCancel: { isRecording = false }
                    ).frame(width: 0, height: 0))
                    #endif
            } else {
                Button(keyCode > 0 ? String(localized: "Change", bundle: .iClawCore) : String(localized: "Record Shortcut", bundle: .iClawCore)) {
                    isRecording = true
                }
                .controlSize(.small)

                if keyCode > 0 {
                    Button(String(localized: "Clear", bundle: .iClawCore)) {
                        keyCode = 0
                        modifierFlags = 0
                        NotificationCenter.default.post(name: .iClawHotkeyChanged, object: nil)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var displayString: String {
        guard keyCode > 0 else { return String(localized: "Not Set", bundle: .iClawCore) }
        let mods = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        var parts: [String] = []
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(keyName(for: UInt16(keyCode)))
        return parts.joined()
    }

    private func keyName(for code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            // Map key code to character via a temporary CGEvent
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true),
               let ns = NSEvent(cgEvent: event),
               let chars = ns.charactersIgnoringModifiers, !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key\(code)"
        }
    }
}

// MARK: - Notification

public extension Notification.Name {
    static let iClawHotkeyChanged = Notification.Name("iClawHotkeyChanged")
}

// MARK: - Key Capture NSView

#if canImport(AppKit)
/// An invisible NSView that becomes first responder to capture a single key event.
struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {}

    final class KeyCaptureNSView: NSView {
        var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Escape cancels recording
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            // Require at least one modifier
            guard !mods.intersection([.command, .option, .shift, .control]).isEmpty else { return }
            onCapture?(event.keyCode, mods)
        }
    }
}
#endif
