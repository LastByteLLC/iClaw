import Foundation
import Observation
import SwiftUI

/// Observable state tracking the active Skill Mode for UI display.
///
/// When a Mode is active, routing is overridden — only allowed tools are
/// available, and the mode's system prompt replaces the normal skill context.
/// Messages are tagged with `modeGroupId` for thread collapse on exit.
@MainActor
@Observable
public class SkillModeState {
    public var isActive = false
    public var displayName = ""
    public var icon = ""
    public var modeGroupId: UUID?
    /// Background tint color for the mode, parsed from hex.
    public var tintColor: Color?

    public static let shared = SkillModeState()
    private init() {}

    public func activate(name: String, icon: String, groupId: UUID, tintHex: String? = nil) {
        self.displayName = name
        self.icon = icon
        self.modeGroupId = groupId
        self.tintColor = tintHex.flatMap { Self.colorFromHex($0) }
        self.isActive = true
    }

    public func deactivate() {
        self.isActive = false
        self.displayName = ""
        self.icon = ""
        self.modeGroupId = nil
        self.tintColor = nil
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8) & 0xFF) / 255
        let b = Double(val & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}
