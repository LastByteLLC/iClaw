import Foundation
import FoundationModels

// AppManagerFMDescriptor removed — merged into SystemControlFMDescriptor

// CalendarEventTool moved to CoreTool (returns widget data)

/// Routing keywords for FM descriptors, loaded from
/// `Resources/Config/FMToolKeywords.json`. Per the project convention in
/// CLAUDE.md, keywords live in JSON and are accessed via ConfigLoader — not
/// hardcoded in Swift. The table is loaded once at first access.
private enum FMKeywords {
    private static let table: [String: [String]] = ConfigLoader.load(
        "FMToolKeywords", as: [String: [String]].self
    ) ?? [:]

    static func keywords(for key: String) -> [String] { table[key] ?? [] }
}

// MARK: - Clipboard
public struct ClipboardFMDescriptor: FMToolDescriptor {
    public let name = "clipboard"
    public let chipName = "clipboard"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .offline
    public func makeTool() -> any Tool { ClipboardTool() }
    public init() {}
}

// ContactsTool, NotesTool moved to CoreTool (returns preview widgets)

// MARK: - ReadFile
public struct ReadFileFMDescriptor: FMToolDescriptor {
    public let name = "read_file"
    public let chipName = "read"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .offline
    public func makeTool() -> any Tool { ReadFileTool() }
    public init() {}
}

// MARK: - Browser
#if os(macOS)
public struct BrowserFMDescriptor: FMToolDescriptor {
    public let name = "browser"
    public let chipName = "browser"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .online
    public let consentPolicy = ActionConsentPolicy.destructive(description: "Interact with browser page")
    public func makeTool() -> any Tool { BrowserTool() }
    public init() {}
}

#endif

// MARK: - WriteFile
public struct WriteFileFMDescriptor: FMToolDescriptor {
    public let name = "write_file"
    public let chipName = "save"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Save file to Downloads")
    public func makeTool() -> any Tool { WriteFileTool() }
    public init() {}
}

// RemindersTool moved to CoreTool (returns confirmation widget)

#if os(macOS)
#if !MAS_BUILD
// MARK: - Spotlight
public struct SpotlightFMDescriptor: FMToolDescriptor {
    public let name = "spotlight"
    public let chipName = "spotlight"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .offline
    public func makeTool() -> any Tool { SpotlightTool() }
    public init() {}
}
#endif

// MARK: - SystemControl (includes app management)
public struct SystemControlFMDescriptor: FMToolDescriptor {
    public let name = "system_control"
    public let chipName = "system"
    #if MAS_BUILD
    public var routingKeywords: [String] { FMKeywords.keywords(for: "system_control_mas") }
    #else
    public var routingKeywords: [String] { FMKeywords.keywords(for: "system_control") }
    #endif
    public let category: CategoryEnum = .offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Control system settings or manage apps")
    public func makeTool() -> any Tool { SystemControlTool() }
    public init() {}
}
#endif

// MARK: - WebSearch
public struct WebSearchFMDescriptor: FMToolDescriptor {
    public let name = "web_search"
    public let chipName = "search"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .online
    private let session: URLSession
    public func makeTool() -> any Tool { WebSearchTool(session: session) }
    public init(session: URLSession = .iClawDefault) { self.session = session }
}

// MessagesTool moved to CoreTool (returns compose preview widget)

// MARK: - Shortcuts
public struct ShortcutsFMDescriptor: FMToolDescriptor {
    public let name = "shortcuts"
    public let chipName = "shortcuts"
    public var routingKeywords: [String] { FMKeywords.keywords(for: name) }
    public let category: CategoryEnum = .offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Run a Shortcut")
    public func makeTool() -> any Tool { ShortcutsTool() }
    public init() {}
}
