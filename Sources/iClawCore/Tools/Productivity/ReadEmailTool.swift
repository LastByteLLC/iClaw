import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Structured arguments for LLM-extracted email read requests.
public struct ReadEmailArgs: ToolArguments {
    public let intent: String       // "latest", "unread", "search", "sender"
    public let count: Int?
    public let query: String?
    public let senderName: String?
}

/// Reads and searches emails from Mail.app via AppleScript.
/// Supports intents: latest (most recent N), unread, search (full-text), fromSender.
/// macOS only — requires Automation permission for Mail.app.
public struct ReadEmailTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "ReadEmail"
    public let schema = "Read search list recent emails inbox unread mail mailbox recent emails from sender subject check my email show recent emails"
    public let isInternal = false
    public let consentPolicy: ActionConsentPolicy = .safe
    public let category = CategoryEnum.offline

    public init() {}

    // MARK: - ExtractableCoreTool

    public typealias Args = ReadEmailArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "ReadEmail", fallback: "{\"intent\":\"latest|unread|search|sender\"}"
    )

    public func execute(args: ReadEmailArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        #if os(macOS)
        guard await isMailRunning() else {
            return ToolIO(text: "Mail.app isn't running. Open it first, then try again.", status: .error)
        }
        return await timed {
            let intent: ReadEmailIntent
            switch args.intent {
            case "unread":
                intent = .unread
            case "search":
                let q = args.query ?? rawInput
                guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return ToolIO(text: "I need a search term. Try: 'search email for invoice'.", status: .error)
                }
                intent = .search(query: q)
            case "sender":
                let name = args.senderName ?? ""
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return ToolIO(text: "I need a sender name. Try: 'emails from Sarah'.", status: .error)
                }
                intent = .fromSender(name: name)
            default:
                intent = .latest(count: args.count ?? AppConfig.maxReadEmailResults)
            }

            return await executeIntent(intent)
        }
        #else
        return ToolIO(text: "Email reading is only available on macOS.", status: .error)
        #endif
    }

    // MARK: - Intent Detection

    enum ReadEmailIntent: Sendable {
        case latest(count: Int)
        case unread
        case search(query: String)
        case fromSender(name: String)
    }

    // MARK: - Keyword Config

    private struct KeywordsConfig: Decodable, Sendable {
        let unreadKeywords: [String]
        let searchKeywords: [String]
        let senderKeywords: [String]
        let latestKeywords: [String]
    }

    private static let config: KeywordsConfig? = ConfigLoader.load("ReadEmailKeywords", as: KeywordsConfig.self)
    private static let unreadKeywords: [String] = config?.unreadKeywords ?? []
    private static let searchKeywords: [String] = config?.searchKeywords ?? []
    private static let senderKeywords: [String] = config?.senderKeywords ?? []
    private static let latestKeywords: [String] = config?.latestKeywords ?? []

    // MARK: - Email Summary

    public struct EmailSummary: Sendable {
        public let subject: String
        public let sender: String
        public let date: String
        public let bodySnippet: String
        public let isRead: Bool

        public init(subject: String, sender: String, date: String, bodySnippet: String, isRead: Bool) {
            self.subject = subject
            self.sender = sender
            self.date = date
            self.bodySnippet = bodySnippet
            self.isRead = isRead
        }
    }

    // MARK: - Widget Data

    public struct EmailListWidgetData: Sendable {
        public let emails: [EmailSummary]
        public let intentLabel: String
        public let query: String?

        public init(emails: [EmailSummary], intentLabel: String, query: String? = nil) {
            self.emails = emails
            self.intentLabel = intentLabel
            self.query = query
        }
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        #if os(macOS)
        guard await isMailRunning() else {
            return ToolIO(text: "Mail.app isn't running. Open it first, then try again.", status: .error)
        }
        return await timed {
            let intent = detectIntent(input: input, entities: entities)
            return await executeIntent(intent)
        }
        #else
        return ToolIO(text: "Email reading is only available on macOS.", status: .error)
        #endif
    }

    // MARK: - Shared Execution

    #if os(macOS)
    private func executeIntent(_ intent: ReadEmailIntent) async -> ToolIO {
        let script = buildAppleScript(for: intent)
        let result = await runAppleScript(script)

        switch result {
        case .success(let output):
            let emails = parseEmailOutput(output)
            if emails.isEmpty {
                return ToolIO(
                    text: emptyResultMessage(for: intent),
                    status: .ok,
                    isVerifiedData: true
                )
            }
            let (text, label, query) = formatResult(emails: emails, intent: intent)
            let widgetData = EmailListWidgetData(emails: emails, intentLabel: label, query: query)
            return ToolIO(
                text: text,
                status: .ok,
                outputWidget: "EmailListWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == "NSAppleScriptErrorDomain", nsError.code == -1743 {
                return ToolIO(
                    text: "iClaw needs Automation permission for Mail.app. Grant it in System Settings > Privacy & Security > Automation, then try again.",
                    status: .error
                )
            }
            return ToolIO(
                text: "Failed to read emails from Mail.app: \(error.localizedDescription). Make sure Mail.app is running and Automation permission is granted in System Settings > Privacy & Security > Automation.",
                status: .error
            )
        }
    }

    @MainActor
    private func isMailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
    }
    #endif

    // MARK: - Intent Detection

    func detectIntent(input: String, entities: ExtractedEntities? = nil) -> ReadEmailIntent {
        let lower = input.lowercased()

        // Check unread first — most specific
        if Self.unreadKeywords.contains(where: { lower.contains($0) }) {
            return .unread
        }

        // Check sender — "from" keyword + name extraction
        if Self.senderKeywords.contains(where: { lower.contains($0) }) {
            let senderName = extractSenderName(from: lower, entities: entities)
            if !senderName.isEmpty {
                return .fromSender(name: senderName)
            }
        }

        // Check search
        if Self.searchKeywords.contains(where: { lower.contains($0) }) {
            let query = extractSearchQuery(from: lower)
            if !query.isEmpty {
                return .search(query: query)
            }
        }

        // Default: latest
        return .latest(count: AppConfig.maxReadEmailResults)
    }

    // MARK: - Name/Query Extraction

    private func extractSenderName(from input: String, entities: ExtractedEntities?) -> String {
        // Use NER-extracted names first
        if let names = entities?.names, let first = names.first {
            return first
        }

        // Strip known prefixes to get the sender name
        let prefixes = ["emails from", "mail from", "email from", "sent by", "from"]
        var remaining = input
        for prefix in prefixes {
            if let range = remaining.range(of: prefix) {
                remaining = String(remaining[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Take first word or two as the name
        let words = remaining.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.prefix(2).joined(separator: " ")
    }

    private func extractSearchQuery(from input: String) -> String {
        let prefixes = ["search my email for", "search my mail for", "search email for",
                        "search mail for", "find email about", "find mail about",
                        "find email", "find mail", "search email", "search mail",
                        "look for", "about", "containing", "mentions"]
        var remaining = input
        for prefix in prefixes {
            if let range = remaining.range(of: prefix) {
                remaining = String(remaining[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Strip reademail routing artifact
        remaining = remaining.replacingOccurrences(of: "reademail", with: "").trimmingCharacters(in: .whitespaces)
        return remaining
    }

    // MARK: - AppleScript Builder

    func buildAppleScript(for intent: ReadEmailIntent) -> String {
        let limit = AppConfig.maxReadEmailResults
        let snippetLimit = AppConfig.emailBodySnippetLimit

        switch intent {
        case .latest(let count):
            let fetchCount = min(count, limit)
            return """
            tell application "Mail"
                set msgList to messages 1 thru \(fetchCount) of inbox
                set output to ""
                repeat with msg in msgList
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date received of msg as string
                    set msgRead to read status of msg
                    set msgBody to content of msg
                    if (length of msgBody) > \(snippetLimit) then
                        set msgBody to text 1 thru \(snippetLimit) of msgBody
                    end if
                    set output to output & msgSubject & "||" & msgSender & "||" & msgDate & "||" & msgRead & "||" & msgBody & "<<END>>"
                end repeat
                return output
            end tell
            """
        case .unread:
            return """
            tell application "Mail"
                set msgList to (messages of inbox whose read status is false)
                set output to ""
                set msgCount to 0
                repeat with msg in msgList
                    if msgCount ≥ \(limit) then exit repeat
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date received of msg as string
                    set msgBody to content of msg
                    if (length of msgBody) > \(snippetLimit) then
                        set msgBody to text 1 thru \(snippetLimit) of msgBody
                    end if
                    set output to output & msgSubject & "||" & msgSender & "||" & msgDate & "||false||" & msgBody & "<<END>>"
                    set msgCount to msgCount + 1
                end repeat
                return output
            end tell
            """
        case .search(let query):
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return """
            tell application "Mail"
                set msgList to (messages of inbox whose subject contains "\(escaped)" or content contains "\(escaped)")
                set output to ""
                set msgCount to 0
                repeat with msg in msgList
                    if msgCount ≥ \(limit) then exit repeat
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date received of msg as string
                    set msgRead to read status of msg
                    set msgBody to content of msg
                    if (length of msgBody) > \(snippetLimit) then
                        set msgBody to text 1 thru \(snippetLimit) of msgBody
                    end if
                    set output to output & msgSubject & "||" & msgSender & "||" & msgDate & "||" & msgRead & "||" & msgBody & "<<END>>"
                    set msgCount to msgCount + 1
                end repeat
                return output
            end tell
            """
        case .fromSender(let name):
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return """
            tell application "Mail"
                set msgList to (messages of inbox whose sender contains "\(escaped)")
                set output to ""
                set msgCount to 0
                repeat with msg in msgList
                    if msgCount ≥ \(limit) then exit repeat
                    set msgSubject to subject of msg
                    set msgSender to sender of msg
                    set msgDate to date received of msg as string
                    set msgRead to read status of msg
                    set msgBody to content of msg
                    if (length of msgBody) > \(snippetLimit) then
                        set msgBody to text 1 thru \(snippetLimit) of msgBody
                    end if
                    set output to output & msgSubject & "||" & msgSender & "||" & msgDate & "||" & msgRead & "||" & msgBody & "<<END>>"
                    set msgCount to msgCount + 1
                end repeat
                return output
            end tell
            """
        }
    }

    // MARK: - AppleScript Execution

    #if os(macOS)
    private func runAppleScript(_ source: String) async -> Result<String, Error> {
        do {
            let output = try await UserScriptRunner.run(source)
            return .success(output)
        } catch {
            return .failure(error)
        }
    }
    #endif

    // MARK: - Output Parsing

    func parseEmailOutput(_ output: String) -> [EmailSummary] {
        let entries = output.components(separatedBy: "<<END>>").filter { !$0.isEmpty }
        return entries.compactMap { entry in
            let fields = entry.components(separatedBy: "||")
            guard fields.count >= 5 else { return nil }
            let body = ContentCompactor.compact(fields[4].trimmingCharacters(in: .whitespacesAndNewlines),
                                                limit: AppConfig.emailBodySnippetLimit)
            return EmailSummary(
                subject: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                sender: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                date: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
                bodySnippet: body,
                isRead: fields[3].trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            )
        }
    }

    // MARK: - Result Formatting

    private func formatResult(emails: [EmailSummary], intent: ReadEmailIntent) -> (text: String, label: String, query: String?) {
        var lines: [String] = []
        for (i, email) in emails.enumerated() {
            let readMarker = email.isRead ? "" : "[NEW] "
            lines.append("\(i + 1). \(readMarker)\(email.subject) — from \(email.sender) (\(email.date))")
            if !email.bodySnippet.isEmpty {
                let snippet = email.bodySnippet.prefix(120)
                lines.append("   \(snippet)...")
            }
        }

        let text: String
        let label: String
        let query: String?

        switch intent {
        case .latest:
            text = "Latest \(emails.count) emails:\n" + lines.joined(separator: "\n")
            label = "Inbox"
            query = nil
        case .unread:
            text = "\(emails.count) unread email\(emails.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
            label = "Unread"
            query = nil
        case .search(let q):
            text = "\(emails.count) email\(emails.count == 1 ? "" : "s") matching \"\(q)\":\n" + lines.joined(separator: "\n")
            label = "Search"
            query = q
        case .fromSender(let name):
            text = "\(emails.count) email\(emails.count == 1 ? "" : "s") from \(name):\n" + lines.joined(separator: "\n")
            label = "From"
            query = name
        }

        return (text, label, query)
    }

    func emptyResultMessage(for intent: ReadEmailIntent) -> String {
        switch intent {
        case .latest: return "No emails found in your inbox."
        case .unread: return "No unread emails — you're all caught up."
        case .search(let q): return "No emails found matching \"\(q)\"."
        case .fromSender(let name): return "No emails found from \(name)."
        }
    }
}
