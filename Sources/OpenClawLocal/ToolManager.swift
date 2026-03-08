import Foundation
import PermissionsKit
import SwiftSoup
import EventKit
import Contacts

@MainActor
class ToolManager {
    static let shared = ToolManager()
    
    private init() {}
    
    func executeTool(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "WebSearch":
            return try await webSearch(query: arguments["query"] as? String ?? "")
        case "Fetch":
            return try await fetch(url: arguments["url"] as? String ?? "")
        case "ReadFile":
            return try await readFile(path: arguments["path"] as? String ?? "")
        case "SpotlightSearch":
            return try await spotlightSearch(query: arguments["query"] as? String ?? "")
        case "Calendar":
            return try await manageCalendar(arguments: arguments)
        case "Contacts":
            return try await searchContacts(query: arguments["query"] as? String ?? "")
        case "SendMessage":
            return try await sendMessage(to: arguments["to"] as? String ?? "", content: arguments["content"] as? String ?? "")
        case "WikipediaSearch":
            return try await wikipediaSearch(query: arguments["query"] as? String ?? "")
        case "WikipediaFetch":
            return try await wikipediaFetch(title: arguments["title"] as? String ?? "")
        default:
            throw ToolError.unknownTool(name)
        }
    }
    
    private func wikipediaSearch(query: String) async throws -> String {
        let url = "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&limit=5&format=json"
        let jsonString = try await fetch(url: url)
        
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1,
              let titles = json[1] as? [String] else {
            return "No Wikipedia results found for '\(query)'."
        }
        
        return "Wikipedia search results for '\(query)':\n" + titles.joined(separator: "\n")
    }
    
    private func wikipediaFetch(title: String) async throws -> String {
        let url = "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&titles=\(title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&format=json"
        let jsonString = try await fetch(url: url)
        
        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let firstPageId = pages.keys.first,
              let page = pages[firstPageId] as? [String: Any],
              let extract = page["extract"] as? String else {
            return "Could not fetch Wikipedia content for '\(title)'."
        }
        
        if extract.count > 3000 {
            let summary = await SummarizationManager.shared.summarize(text: extract)
            return "Content for \(title) (Summarized due to length):\n\(summary)"
        }
        
        return "Content for \(title):\n\(extract)"
    }
    
    private func manageCalendar(arguments: [String: Any]) async throws -> String {
        // EventKit implementation
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .authorized {
            // Request permission (in real app, this would be an async prompt)
            return "Calendar access not authorized. Please grant permission in System Settings."
        }
        
        if let action = arguments["action"] as? String, action == "add" {
            let event = EKEvent(eventStore: store)
            event.title = arguments["title"] as? String ?? "New Event"
            event.startDate = Date().addingTimeInterval(3600)
            event.endDate = event.startDate.addingTimeInterval(3600)
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return "Event '\(event.title!)' added."
        }
        return "Unsupported calendar action."
    }
    
    private func searchContacts(query: String) async throws -> String {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        
        let results = contacts.map { "\($0.givenName) \($0.familyName): \($0.emailAddresses.first?.value ?? "")" }.joined(separator: "\n")
        return "Contact search results:\n\(results)"
    }
    
    private func sendMessage(to: String, content: String) async throws -> String {
        let scriptSource = """
        tell application "Messages"
            send "\(content)" to participant "\(to)"
        end tell
        """
        
        if let script = NSAppleScript(source: scriptSource) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                return "Failed to send message: \(error)"
            }
            return "Message sent to \(to)."
        }
        return "Failed to initialize script."
    }
    
    private func webSearch(query: String) async throws -> String {
        // Fallback logic: Google -> DDG
        let searchURL = "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let html = try await fetch(url: searchURL)
        
        let doc = try SwiftSoup.parse(html)
        let results = try doc.select("h3").map { try $0.text() }.prefix(5).joined(separator: "\n")
        
        return "Search results for \(query):\n\(results)"
    }
    
    private func fetch(url: String) async throws -> String {
        guard let url = URL(string: url) else { throw ToolError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(data: data, encoding: .utf8) ?? "Could not decode data"
    }
    
    private func readFile(path: String) async throws -> String {
        // Check permissions via PermissionsKit if needed (Files and Folders is special)
        // For now, simple read if allowed by sandbox
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let content = try String(contentsOf: url)
        return "Content of \(path):\n\(content.prefix(1000))..."
    }
    
    private func spotlightSearch(query: String) async throws -> String {
        let task = Process()
        task.launchPath = "/usr/bin/mdfind"
        task.arguments = [query]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        try task.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "No results"
    }
    
    private func manageClipboard(action: String, content: String?) async throws -> String {
        let pasteboard = NSPasteboard.general
        if action == "write", let content = content {
            pasteboard.clearContents()
            pasteboard.setString(content, forType: .string)
            return "Copied to clipboard"
        } else {
            return pasteboard.string(forType: .string) ?? "Clipboard empty"
        }
    }
}

enum ToolError: Error {
    case unknownTool(String)
    case invalidURL
}
