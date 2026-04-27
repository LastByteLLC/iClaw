import Foundation

/// Semantic grouping of tools into domains.
///
/// Rather than exposing 30+ tools to the LLM (which overwhelms on-device models),
/// the complexity gate identifies relevant domains and the agent runner receives
/// only the 3-8 tools in those domains. The ML classifier can then be retrained
/// against ~8 domain labels instead of 37+ tool labels, improving per-label accuracy.
public enum ToolDomain: String, CaseIterable, Sendable, Codable {
    case weather
    case productivity
    case finance
    case media
    case communication
    case research
    case system
    case utility

    /// Returns the tool names that belong to this domain.
    /// Includes both CoreTool and FMTool names.
    public var toolNames: Set<String> {
        switch self {
        case .weather:
            return [ToolNames.weather, ToolNames.time, ToolNames.today]
        case .productivity:
            return [ToolNames.calendar, ToolNames.time, ToolNames.calendarEvent,
                    ToolNames.reminders, ToolNames.notes, ToolNames.shortcuts]
        case .finance:
            return [ToolNames.stocks, ToolNames.convert, ToolNames.calculator, ToolNames.compute]
        case .media:
            return [ToolNames.podcast, ToolNames.transcribe, ToolNames.spotlight, "Music"]
        case .communication:
            return [ToolNames.email, ToolNames.messages, ToolNames.contacts, ToolNames.readEmail]
        case .research:
            return [ToolNames.webFetch, ToolNames.webSearch, ToolNames.news,
                    ToolNames.wikipediaSearch, ToolNames.research]
        case .system:
            return [ToolNames.systemInfo, ToolNames.systemControl, ToolNames.screenshot,
                    ToolNames.techSupport, ToolNames.automate, ToolNames.clipboard, ToolNames.readFile]
        case .utility:
            return [ToolNames.random, ToolNames.dictionary, ToolNames.translate,
                    ToolNames.maps, ToolNames.help, ToolNames.feedback, ToolNames.importTool, "Alarm"]
        }
    }
}

/// Provides scoped tool sets for agent execution.
///
/// Instead of giving the LLM the full 30+ tool registry (which causes
/// selection failures on the 3B on-device model), this provider returns
/// only the tools belonging to requested domains.
public enum ToolProvider {

    /// Returns all CoreTools belonging to the given domains.
    public static func coreTools(for domains: Set<ToolDomain>) -> [any CoreTool] {
        let names = domains.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
        return ToolRegistry.coreTools.filter { names.contains($0.name) }
    }

    /// Returns all FMToolDescriptors belonging to the given domains.
    public static func fmTools(for domains: Set<ToolDomain>) -> [any FMToolDescriptor] {
        let names = domains.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
        return ToolRegistry.fmTools.filter { names.contains($0.name) }
    }

    /// Infers domains from a set of tool names.
    public static func domains(for toolNames: Set<String>) -> Set<ToolDomain> {
        var result = Set<ToolDomain>()
        for domain in ToolDomain.allCases {
            if !domain.toolNames.isDisjoint(with: toolNames) {
                result.insert(domain)
            }
        }
        return result
    }
}
