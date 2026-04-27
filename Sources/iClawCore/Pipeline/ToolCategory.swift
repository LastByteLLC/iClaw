import Foundation

/// A high-level grouping of tools that share a common user intent.
///
/// Categories are the only chip-level concept visible to users (e.g., `#math`, `#live`).
/// Individual tools within a category are selected via within-category disambiguation,
/// not by user action. This reduces the cognitive surface area from 34 chips to 8.
///
/// When a category chip is used, the router restricts tool selection to the category's
/// members and uses the category's disambiguation logic. If no tool matches within the
/// category, the escape hatch falls through to full routing.
public struct ToolCategory: Sendable {
    /// Display name for the category (e.g., "Math").
    public let name: String

    /// The chip name users type (e.g., "math" for `#math`).
    public let chipName: String

    /// SF Symbol icon for the chip picker.
    public let icon: String

    /// Core tool names in this category.
    public let coreToolNames: [String]

    /// FM tool names in this category.
    public let fmToolNames: [String]

    /// Chip aliases that also route to this category (e.g., `#calculator` → Math).
    public let chipAliases: [String]

    public init(
        name: String,
        chipName: String,
        icon: String,
        coreToolNames: [String],
        fmToolNames: [String] = [],
        chipAliases: [String] = []
    ) {
        self.name = name
        self.chipName = chipName
        self.icon = icon
        self.coreToolNames = coreToolNames
        self.fmToolNames = fmToolNames
        self.chipAliases = chipAliases
    }

    /// Returns whether a given chip string matches this category (primary or alias).
    public func matchesChip(_ chip: String) -> Bool {
        let lower = chip.lowercased()
        return chipName.lowercased() == lower || chipAliases.contains(where: { $0.lowercased() == lower })
    }
}

// MARK: - Category Registry

public enum ToolCategoryRegistry {

    /// All defined tool categories.
    public static let categories: [ToolCategory] = {
        var cats = [
            math,
            live,
            search,
            utilities,
            schedule,
            system,
            email,
            help,
        ]
        #if !MAS_BUILD
        cats.append(automate)
        #endif
        return cats
    }()

    /// Looks up a category by chip name or alias.
    public static func category(forChip chip: String) -> ToolCategory? {
        categories.first(where: { $0.matchesChip(chip) })
    }

    // MARK: - Category Definitions

    /// Math: arithmetic, conversion, statistics, date calculations.
    public static let math = ToolCategory(
        name: "Math",
        chipName: "math",
        icon: "function",
        coreToolNames: ["Calculator", "Convert", "Compute"],
        chipAliases: ["calculator", "convert", "compute", "calc"]
    )

    /// Live: real-time data fetching from online sources.
    public static let live = ToolCategory(
        name: "Live",
        chipName: "live",
        icon: "antenna.radiowaves.left.and.right",
        coreToolNames: ["Weather", "Stocks", "News", "Podcast"],
        chipAliases: ["weather", "stocks", "news", "podcast"]
    )

    /// Search: information retrieval from web, Wikipedia, and deep research.
    public static let search = ToolCategory(
        name: "Search",
        chipName: "search",
        icon: "magnifyingglass",
        coreToolNames: ["Research", "WikipediaSearch"],
        fmToolNames: ["web_search"],
        chipAliases: ["wiki", "research"]
    )

    /// Utilities: text and audio processing tools.
    public static let utilities = ToolCategory(
        name: "Utilities",
        chipName: "util",
        icon: "wrench",
        coreToolNames: ["Translate", "Transcribe", "Dictionary"],
        chipAliases: ["translate", "transcribe", "define", "dictionary"]
    )

    /// Schedule: time, timers, calendar, and daily briefing.
    public static let schedule = ToolCategory(
        name: "Schedule",
        chipName: "schedule",
        icon: "calendar.badge.clock",
        coreToolNames: ["Calendar", "CalendarEvent", "Time", "Today"],
        fmToolNames: [],
        chipAliases: ["calendar", "clock", "timer", "today", "time"]
    )

    /// System: device info, diagnostics, and troubleshooting.
    public static let system = ToolCategory(
        name: "System",
        chipName: "system",
        icon: "desktopcomputer",
        coreToolNames: ["SystemInfo", "TechSupport"],
        fmToolNames: ["system_control"],
        chipAliases: ["systeminfo", "techsupport"]
    )

    /// Email: compose and read email.
    public static let email = ToolCategory(
        name: "Email",
        chipName: "email",
        icon: "envelope",
        coreToolNames: ["Email", "ReadEmail"],
        chipAliases: ["reademail"]
    )

    /// Help: information about iClaw itself.
    public static let help = ToolCategory(
        name: "Help",
        chipName: "help",
        icon: "questionmark.circle",
        coreToolNames: ["Help"],
        fmToolNames: [],
        chipAliases: ["feedback"]
    )

    /// Automate: scripting, scheduled tasks, and shortcuts (DMG only).
    public static let automate = ToolCategory(
        name: "Automate",
        chipName: "automate",
        icon: "gearshape.2",
        coreToolNames: ["Automate", "Automation"],
        fmToolNames: ["shortcuts"],
        chipAliases: ["automation", "shortcuts"]
    )

    // MARK: - NL-Only Tools

    /// Tools that are never chip-accessible — routed only via natural language or other tools.
    public static let nlOnlyToolNames: Set<String> = [
        // Communication (clear intent from NL)
        "Contacts", "Messages", "Reminders",
        // System (triggered by specific NL intents)
        "system_control", "shortcuts", "spotlight", "clipboard", "Notes",
        // Media
        "Screenshot",
        // Misc
        "Random", "Maps", "WebFetch", "Feedback", "Import",
        "read_file", "write_file", "browser",
    ]

    /// Returns whether a tool name is NL-only (no chip access).
    public static func isNLOnly(_ toolName: String) -> Bool {
        nlOnlyToolNames.contains(toolName)
    }
}
