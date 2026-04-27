import Foundation
import FoundationModels
#if os(macOS)
import AppKit
#endif
#if MAS_BUILD
import Intents
#endif

@Generable
struct ShortcutsInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Action: 'list' to show shortcuts, 'run' to execute one")
    var action: String
    @Guide(description: "Name of the shortcut to run (required for 'run' action)")
    var name: String?
    @Guide(description: "Optional input text to pass to the shortcut")
    var input: String?
}

struct ShortcutsTool: Tool {
    typealias Arguments = ShortcutsInput
    typealias Output = String

    let name = "shortcuts"
    let description = "List or run Apple Shortcuts. Also handles Home automation — create Shortcuts that control HomeKit devices, then run them here."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: ShortcutsInput) async throws -> String {
        let action = input.action.lowercased().trimmingCharacters(in: .whitespaces)

        switch action {
        case "list":
            return await listShortcuts()
        case "run":
            guard let name = input.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return "No shortcut name provided. Use the 'list' action to see available shortcuts."
            }
            return await runShortcut(name: name, input: input.input)
        default:
            return "Unknown action '\(input.action)'. Use 'list' or 'run'."
        }
    }

    #if os(macOS) && MAS_BUILD
    private func listShortcuts() async -> String {
        let center = INVoiceShortcutCenter.shared
        do {
            let names: [String] = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
                center.getAllVoiceShortcuts { shortcuts, error in
                    if let error { cont.resume(throwing: error) }
                    else {
                        let result = (shortcuts ?? []).compactMap {
                            $0.shortcut.intent?.suggestedInvocationPhrase ?? $0.shortcut.userActivity?.title
                        }
                        cont.resume(returning: result)
                    }
                }
            }
            if names.isEmpty {
                return "No Siri shortcuts found. Open the Shortcuts app to see all your shortcuts."
            }
            return "Siri shortcuts: \(names.joined(separator: ", "))"
        } catch {
            return "Could not retrieve Siri shortcuts: \(error.localizedDescription). Open the Shortcuts app to see all your shortcuts."
        }
    }

    private func runShortcut(name: String, input: String?) async -> String {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        var urlString = "shortcuts://run-shortcut?name=\(encodedName)"
        if let input = input?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
            let encodedInput = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
            urlString += "&input=text&text=\(encodedInput)"
        }
        guard let url = URL(string: urlString) else {
            return "Invalid shortcut name."
        }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        return "Running shortcut '\(name)'"
    }
    #elseif os(macOS)
    private func listShortcuts() async -> String {
        let script = """
        tell application "Shortcuts Events"
            get name of every shortcut
        end tell
        """

        do {
            let output = try await UserScriptRunner.run(script)
            // Parse comma-separated list from AppleScript result
            let names = output.components(separatedBy: ", ").filter { !$0.isEmpty }
            if names.isEmpty {
                return "No shortcuts found."
            }
            return "Available shortcuts (\(names.count)):\n" + names.map { "• \($0)" }.joined(separator: "\n")
        } catch {
            return "Failed to list shortcuts: \(error.localizedDescription)"
        }
    }

    private func runShortcut(name: String, input: String?) async -> String {
        let safeName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let script: String
        if let input = input?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
            let safeInput = input
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            script = """
            tell application "Shortcuts Events"
                run shortcut "\(safeName)" with input "\(safeInput)"
            end tell
            """
        } else {
            script = """
            tell application "Shortcuts Events"
                run shortcut "\(safeName)"
            end tell
            """
        }

        do {
            _ = try await UserScriptRunner.run(script)
            return "Shortcut '\(name)' executed successfully."
        } catch {
            return "Failed to run shortcut '\(name)': \(error.localizedDescription)"
        }
    }
    #else
    private func listShortcuts() -> String {
        "To see your shortcuts, open the Shortcuts app. Listing is not available on iOS from third-party apps."
    }

    private func runShortcut(name: String, input: String?) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        var urlString = "shortcuts://run-shortcut?name=\(encoded)"
        if let input = input?.trimmingCharacters(in: .whitespaces), !input.isEmpty,
           let encodedInput = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&input=text&text=\(encodedInput)"
        }
        if let url = URL(string: urlString) {
            URLOpener.open(url)
            return "Opening shortcut '\(name)' in the Shortcuts app."
        }
        return "Failed to create URL for shortcut '\(name)'."
    }
    #endif
}
