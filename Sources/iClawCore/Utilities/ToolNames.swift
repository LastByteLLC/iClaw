import Foundation

/// Type-safe tool name constants. Use these instead of string literals when
/// referencing tool names in routing, heuristics, and agent code.
///
/// Eliminates silent breakage from tool name typos — a rename becomes a
/// compile error instead of a runtime mis-route.
public enum ToolNames {
    // MARK: - Core Tools (PascalCase)

    public static let calculator = "Calculator"
    public static let calendar = "Calendar"
    public static let calendarEvent = "CalendarEvent"
    public static let compute = "Compute"
    public static let contacts = "Contacts"
    public static let convert = "Convert"
    public static let dictionary = "Dictionary"
    public static let email = "Email"
    public static let feedback = "Feedback"
    public static let help = "Help"
    public static let importTool = "Import"
    public static let maps = "Maps"
    public static let messages = "Messages"
    public static let news = "News"
    public static let notes = "Notes"
    public static let podcast = "Podcast"
    public static let random = "Random"
    public static let readEmail = "ReadEmail"
    public static let reminders = "Reminders"
    public static let research = "Research"
    public static let screenshot = "Screenshot"
    public static let stocks = "Stocks"
    public static let systemInfo = "SystemInfo"
    public static let techSupport = "TechSupport"
    public static let time = "Time"
    public static let today = "Today"
    public static let transcribe = "Transcribe"
    public static let translate = "Translate"
    public static let weather = "Weather"
    public static let webFetch = "WebFetch"
    public static let wikipediaSearch = "WikipediaSearch"

    // MARK: - Core Tools (macOS only)

    public static let automate = "Automate"
    public static let automation = "Automation"

    // MARK: - FM Tools (snake_case)

    public static let webSearch = "web_search"
    public static let readFile = "read_file"
    public static let writeFile = "write_file"
    public static let clipboard = "clipboard"
    public static let systemControl = "system_control"
    public static let spotlight = "spotlight"
    public static let shortcuts = "shortcuts"
    public static let browser = "browser"

    // MARK: - Disabled / Planned (referenced in configs)

    public static let create = "Create"
}
