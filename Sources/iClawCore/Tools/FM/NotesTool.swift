#if os(macOS)
import Foundation
import AppKit

// MARK: - Extraction Args

public struct NotesArgs: ToolArguments {
    public let action: String   // "create", "search", "append"
    public let title: String?
    public let body: String?
}

// MARK: - NotesTool (CoreTool)

/// Creates, searches, or appends to notes. Shows confirmation widget for "create",
/// falls back to clipboard + Notes.app on AppleScript failure or MAS build.
public struct NotesTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Notes"
    #if MAS_BUILD
    public let schema = "Create search list notes memo journal personal entries jot write down create add append find recall"
    #else
    public let schema = "Create search list notes memo journal personal entries jot write down create add append find recall"
    #endif
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Modify notes")

    public init() {}

    public typealias Args = NotesArgs
    #if MAS_BUILD
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Notes-MAS", fallback: #"{"action":"create","title":"string?","body":"string?"}"#
    )
    #else
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Notes", fallback: #"{"action":"create|search|append","title":"string?","body":"string?"}"#
    )
    #endif

    public func execute(args: NotesArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await executeAction(action: args.action, title: args.title ?? "iClaw Note", body: args.body ?? "")
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await executeAction(action: "create", title: "iClaw Note", body: input)
    }

    private func executeAction(action: String, title: String, body: String) async -> ToolIO {
        switch action {
        case "create", "add", "new":
            return await createNote(title: title, body: body)
        #if !MAS_BUILD
        case "search":
            return await searchNotes(title: title)
        case "append":
            return await appendNote(title: title, body: body)
        #endif
        default:
            #if MAS_BUILD
            return await createNote(title: title, body: body)
            #else
            return ToolIO(text: "Unknown action '\(action)'. Use 'create', 'search', or 'append'.", status: .error)
            #endif
        }
    }

    // MARK: - Create

    private func createNote(title: String, body: String) async -> ToolIO {
        #if MAS_BUILD
        return clipboardFallback(title: title, body: body)
        #else
        let escaped = escapeForAppleScript(title: title, body: body)
        let script = """
        tell application "Notes"
            tell account "iCloud"
                make new note at folder "Notes" with properties {name:"\(escaped.title)", body:"\(escaped.body)"}
            end tell
        end tell
        """
        do {
            _ = try await UserScriptRunner.run(script)
            let widgetData = NoteConfirmationData(title: title, body: body, isConfirmed: true)
            return ToolIO(
                text: "Note '\(title)' created.",
                status: .ok,
                outputWidget: "NoteConfirmationWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        } catch {
            Log.engine.debug("Notes AppleScript failed: \(error)")
            return clipboardFallback(title: title, body: body)
        }
        #endif
    }

    private func clipboardFallback(title: String, body: String) -> ToolIO {
        let widgetData = NoteConfirmationData(title: title, body: body, isConfirmed: false)
        return ToolIO(
            text: "Couldn't create the note directly. Use the button to copy and open Notes.",
            status: .ok,
            outputWidget: "NoteConfirmationWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    #if !MAS_BUILD

    // MARK: - Search

    private func searchNotes(title: String) async -> ToolIO {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        do {
            let result = try await UserScriptRunner.run("tell application \"Notes\" to get name of every note whose name contains \"\(escaped)\"")
            return ToolIO(text: result, status: .ok, isVerifiedData: true)
        } catch {
            return ToolIO(text: "Notes search failed: \(error.localizedDescription)", status: .error)
        }
    }

    // MARK: - Append

    private func appendNote(title: String, body: String) async -> ToolIO {
        guard !body.isEmpty else { return ToolIO(text: "Body required for append.", status: .error) }
        let escaped = escapeForAppleScript(title: title, body: body)
        let script = """
        tell application "Notes"
            set theNotes to notes whose name is "\(escaped.title)"
            if (count of theNotes) is 0 then
                return "Note '\(escaped.title)' not found."
            else
                set theNote to item 1 of theNotes
                set oldBody to body of theNote
                set body of theNote to oldBody & "<br><br>" & "\(escaped.body)"
                return "Appended to '\(escaped.title)'."
            end if
        end tell
        """
        do {
            let result = try await UserScriptRunner.run(script)
            return ToolIO(text: result, status: .ok, isVerifiedData: true)
        } catch {
            return ToolIO(text: "Notes append failed: \(error.localizedDescription)", status: .error)
        }
    }

    #endif

    // MARK: - Helpers

    private func escapeForAppleScript(title: String, body: String) -> (title: String, body: String) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "\\r")
        }
        return (escape(title), escape(body))
    }
}
#endif
