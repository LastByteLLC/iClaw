import Foundation
#if os(macOS)
import AppKit
#endif

/// Widget data for the AutomateWidget.
public struct AutomateWidgetData: Sendable {
    /// The generated AppleScript source code.
    public let script: String
    /// Plain-language description of what the script does.
    public let description: String
    /// Which apps the script interacts with.
    public let apps: [String]
    /// Number of ReAct iterations used to produce the script.
    public let iterations: Int
}

/// Closure type for injecting a test LLM responder.
public typealias AutomateLLMResponder = DualInputLLMResponder

/// Closure type for injecting a test AppleScript runner.
/// Parameters: (script source) -> (success: Bool, output: String, error: String?)
public typealias AutomateScriptRunner = @Sendable (String) async -> (success: Bool, output: String, error: String?)

/// CoreTool that creates AppleScript automations through a conversational ReAct loop.
/// Chip-only: triggered exclusively via `#automate`, not through ML classification.
/// macOS only — AppleScript is not available on iOS.
///
/// ReAct loop:
/// 1. **Reason** — identify which apps/objects are needed from user description
/// 2. **Act** — generate AppleScript via LLM using curated app capabilities
/// 3. **Observe** — validate syntax via `osacompile`
/// 4. **Iterate** — if syntax errors, feed them back to LLM for correction (max 3 iterations)
///
/// Returns an AutomateWidget with the script and actions: Run, Save, Open in Script Editor.
public struct AutomateTool: CoreTool, Sendable {
    public let name = "Automate"
    public let schema = "Create AppleScript automations: '#automate send an email', '#automate rename files on desktop'."
    public let isInternal = false
    public let category = CategoryEnum.offline
    public var consentPolicy: ActionConsentPolicy { .destructive(description: "Generate and run AppleScript") }

    /// Maximum ReAct iterations for syntax correction.
    static let maxIterations = 3

    private let llmResponder: AutomateLLMResponder?
    private let scriptRunner: AutomateScriptRunner?

    // MARK: - Init

    /// Production init.
    public init() {
        self.llmResponder = nil
        self.scriptRunner = nil
    }

    /// Test init with injected dependencies.
    public init(
        llmResponder: AutomateLLMResponder? = nil,
        scriptRunner: AutomateScriptRunner? = nil
    ) {
        self.llmResponder = llmResponder
        self.scriptRunner = scriptRunner
    }

    // MARK: - App Catalog

    struct AppInfo: Decodable, Sendable {
        let name: String
        let bundleId: String
        let description: String
        let objects: [String]
        let example: String
    }

    struct AppCatalog: Decodable, Sendable {
        let apps: [AppInfo]
    }

    private static let catalog: AppCatalog? = ConfigLoader.load("AutomateApps", as: AppCatalog.self)

    /// Returns a plain-language listing of available scriptable apps.
    static func listCapabilities() -> String {
        guard let apps = catalog?.apps else { return "No app catalog available." }
        return apps.map { app in
            "- **\(app.name)**: \(app.description) (objects: \(app.objects.joined(separator: ", ")))"
        }.joined(separator: "\n")
    }

    /// Finds apps relevant to the user's request by keyword matching.
    static func findRelevantApps(for input: String) -> [AppInfo] {
        guard let apps = catalog?.apps else { return [] }
        let lower = input.lowercased()
        return apps.filter { app in
            lower.contains(app.name.lowercased())
            || app.objects.contains(where: { lower.contains($0.lowercased()) })
            || app.description.lowercased().split(separator: " ").contains(where: { lower.contains(String($0)) && $0.count > 3 })
        }
    }

    // MARK: - Execute

    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        #if os(macOS)
        await timed {
            let stripped = InputParsingUtilities.stripToolChips(from: input)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // If no description provided, list available capabilities
            if stripped.isEmpty {
                let capabilities = Self.listCapabilities()
                let text = """
                I can create AppleScript automations for these apps:

                \(capabilities)

                Tell me what you'd like to automate. For example:
                - `#automate send an email to John with subject "Meeting tomorrow"`
                - `#automate rename all .txt files on my desktop to .md`
                - `#automate create a reminder to call dentist tomorrow at 3pm`
                - `#automate play my favorites playlist in Music`
                """
                return ToolIO(
                    text: text,
                    status: .ok
                )
            }

            // Check script cache for a previously validated script
            if let cached = await ScriptCache.shared.lookup(stripped) {
                Log.tools.debug("AutomateTool: cache hit for request")
                let widgetData = AutomateWidgetData(
                    script: cached.script,
                    description: cached.description,
                    apps: cached.apps,
                    iterations: 0
                )
                return ToolIO(
                    text: "Generated AppleScript automation:\n\(cached.description)\n\nApps used: \(cached.apps.joined(separator: ", "))",
                    status: .ok,
                    outputWidget: "AutomateWidget",
                    widgetData: widgetData
                )
            }

            // Find relevant apps for context
            let relevantApps = Self.findRelevantApps(for: stripped)
            let appContext = Self.buildAppContext(apps: relevantApps)
            let appNames = relevantApps.map(\.name)

            // ReAct loop: generate → validate syntax → judge semantics → fix
            var script = ""
            var description = ""
            var lastError: String?
            var iteration = 0

            while iteration < Self.maxIterations {
                iteration += 1

                // Reason + Act: generate script via LLM
                let prompt = Self.buildGenerationPrompt(
                    request: stripped,
                    appContext: appContext,
                    previousScript: iteration > 1 ? script : nil,
                    syntaxError: lastError
                )

                do {
                    let response = try await generateWithLLM(prompt: prompt)
                    let parsed = Self.parseScriptResponse(response)
                    script = parsed.script
                    description = parsed.description
                } catch {
                    Log.tools.error("AutomateTool LLM generation failed: \(error)")
                    return ToolIO(
                        text: "Failed to generate automation script. Please try rephrasing your request.",
                        status: .error
                    )
                }

                guard !script.isEmpty else {
                    return ToolIO(
                        text: "I couldn't generate a script for that request. Try being more specific about which app and action you want.",
                        status: .error
                    )
                }

                // Observe: validate syntax
                let validation = await validateSyntax(script)
                if !validation.valid {
                    lastError = validation.error
                    Log.tools.debug("AutomateTool: syntax error on iteration \(iteration): \(validation.error ?? "unknown")")
                    if iteration >= Self.maxIterations {
                        description += "\n\nNote: This script may contain syntax issues. Review before running."
                    }
                    continue
                }

                // Judge: semantic validation — does the script accomplish the request?
                let judgment = await judgeScript(request: stripped, script: script)
                if judgment.pass {
                    Log.tools.debug("AutomateTool: script valid after \(iteration) iteration(s)")
                    break
                }

                // Script compiles but doesn't accomplish the task — retry with feedback
                lastError = "The script compiles but does not accomplish the task: \(judgment.reason)"
                Log.tools.debug("AutomateTool: judge rejected on iteration \(iteration): \(judgment.reason)")

                if iteration >= Self.maxIterations {
                    // All iterations exhausted — tell the user honestly
                    return ToolIO(
                        text: "I wasn't able to create a working automation for that request. \(judgment.reason) Try breaking it into smaller steps or using a different approach.",
                        status: .error
                    )
                }
            }

            // Cache the validated script for future reuse
            await ScriptCache.shared.store(
                request: stripped,
                script: script,
                description: description,
                apps: appNames
            )

            let widgetData = AutomateWidgetData(
                script: script,
                description: description,
                apps: appNames,
                iterations: iteration
            )

            return ToolIO(
                text: "Generated AppleScript automation:\n\(description)\n\nApps used: \(appNames.joined(separator: ", "))",
                status: .ok,
                outputWidget: "AutomateWidget",
                widgetData: widgetData
            )
        }
        #else
        return ToolIO(text: "AppleScript automation is only available on macOS.", status: .error)
        #endif
    }

    // MARK: - LLM Generation

    private func generateWithLLM(prompt: String) async throws -> String {
        if let responder = llmResponder {
            return try await responder(prompt, "")
        }
        return try await LLMAdapter.shared.generateWithInstructions(
            prompt: prompt,
            instructions: makeInstructions {
                Directive("You are an AppleScript expert. Generate correct, safe AppleScript code. Always wrap output in ```applescript code blocks.")
            }
        )
    }

    // MARK: - Script Judge

    /// Semantic validation: does the script actually accomplish the user's request?
    /// Catches scripts that compile but are just error dialogs, capability disclaimers,
    /// or otherwise don't address the task.
    private func judgeScript(request: String, script: String) async -> (pass: Bool, reason: String) {
        // Fast-path heuristic: scripts that are just display dialog with no real logic
        let lines = script.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }

        let actionLines = lines.filter {
            !$0.hasPrefix("try") && !$0.hasPrefix("on error") && !$0.hasPrefix("end try")
            && !$0.hasPrefix("end tell")
        }

        // If the only substantive action is "display dialog", it's not accomplishing anything
        let dialogOnly = actionLines.allSatisfy {
            $0.hasPrefix("display dialog") || $0.hasPrefix("tell application") || $0.hasPrefix("return")
        }
        if dialogOnly && actionLines.contains(where: { $0.hasPrefix("display dialog") }) {
            let hasErrorText = script.lowercased().contains("error") || script.lowercased().contains("cannot")
                || script.lowercased().contains("not possible") || script.lowercased().contains("unable")
                || script.lowercased().contains("no application")
            if hasErrorText {
                return (false, "The script just displays an error message instead of performing the requested action.")
            }
        }

        // LLM judge: short evaluation call
        let judgePrompt = """
        Does this AppleScript accomplish the user's request?

        REQUEST: \(request)

        SCRIPT:
        \(script.prefix(800))

        Answer PASS if the script performs the requested action.
        Answer FAIL with a brief reason if the script does NOT perform the action \
        (e.g., it only shows an error dialog, does nothing useful, or addresses a \
        completely different task).

        One word: PASS or FAIL followed by reason.
        """

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(judgePrompt, "")
            } else {
                response = try await LLMAdapter.shared.generateWithInstructions(
                    prompt: judgePrompt,
                    instructions: makeInstructions {
                        Directive("You are a code reviewer. Evaluate whether the script accomplishes the stated goal. Be strict — a script that just shows an error message is a FAIL.")
                    }
                )
            }
            let upper = response.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if upper.hasPrefix("PASS") {
                return (true, "")
            }
            // Extract reason after "FAIL"
            let reason = response
                .replacingOccurrences(of: "FAIL", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return (false, reason.isEmpty ? "Script does not accomplish the requested task." : String(reason.prefix(200)))
        } catch {
            Log.tools.warning("AutomateTool: judge LLM call failed, allowing script: \(error)")
            // If the judge can't run, fall back to heuristic result (already checked above)
            return (true, "")
        }
    }

    // MARK: - Prompt Building

    static func buildGenerationPrompt(
        request: String,
        appContext: String,
        previousScript: String?,
        syntaxError: String?
    ) -> String {
        var parts: [String] = []

        parts.append("Generate an AppleScript that does the following: \(request)")
        parts.append("\nAvailable apps and their capabilities:\n\(appContext)")

        if let prev = previousScript, let error = syntaxError {
            parts.append("\nThe previous attempt had a syntax error:")
            parts.append("Script:\n```applescript\n\(prev)\n```")
            parts.append("Error: \(error)")
            parts.append("\nFix the syntax error and return the corrected script.")
        }

        parts.append("""

        Rules:
        - Use only the apps listed above
        - Escape special characters in strings properly
        - Add error handling with try/on error blocks for operations that might fail
        - Keep it concise and focused on the requested task

        Return format:
        DESCRIPTION: One sentence describing what the script does
        ```applescript
        -- your script here
        ```
        """)

        return parts.joined(separator: "\n")
    }

    static func buildAppContext(apps: [AppInfo]) -> String {
        if apps.isEmpty {
            // Fall back to full catalog if no apps matched
            guard let allApps = catalog?.apps else { return "No app info available." }
            return allApps.prefix(5).map { app in
                "\(app.name): \(app.description)\nObjects: \(app.objects.joined(separator: ", "))\nExample: \(app.example)"
            }.joined(separator: "\n\n")
        }
        return apps.map { app in
            "\(app.name): \(app.description)\nObjects: \(app.objects.joined(separator: ", "))\nExample: \(app.example)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Response Parsing

    struct ParsedScript {
        let script: String
        let description: String
    }

    static func parseScriptResponse(_ response: String) -> ParsedScript {
        // Extract description
        var description = ""
        if let descRange = response.range(of: "DESCRIPTION:", options: .caseInsensitive) {
            let afterDesc = response[descRange.upperBound...]
            if let newline = afterDesc.firstIndex(of: "\n") {
                description = String(afterDesc[..<newline]).trimmingCharacters(in: .whitespaces)
            } else {
                description = String(afterDesc).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract script from code block
        var script = ""
        let codeBlockPattern = "```(?:applescript)?\\s*\\n([\\s\\S]*?)```"
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           match.numberOfRanges >= 2,
           let scriptRange = Range(match.range(at: 1), in: response) {
            script = String(response[scriptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: if no code block, try to find tell application blocks
        if script.isEmpty {
            let lines = response.components(separatedBy: .newlines)
            var inScript = false
            var scriptLines: [String] = []
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("tell application") {
                    inScript = true
                }
                if inScript {
                    scriptLines.append(line)
                    if line.trimmingCharacters(in: .whitespaces).lowercased() == "end tell" {
                        // Check if this closes the outermost tell
                        let tellCount = scriptLines.filter { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("tell ") }.count
                        let endCount = scriptLines.filter { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("end tell") }.count
                        if endCount >= tellCount {
                            inScript = false
                        }
                    }
                }
            }
            if !scriptLines.isEmpty {
                script = scriptLines.joined(separator: "\n")
            }
        }

        if description.isEmpty && !script.isEmpty {
            description = "AppleScript automation"
        }

        return ParsedScript(script: script, description: description)
    }

    // MARK: - Syntax Validation

    struct ValidationResult {
        let valid: Bool
        let error: String?
    }

    #if os(macOS)
    func validateSyntax(_ script: String) async -> ValidationResult {
        if let runner = scriptRunner {
            let result = await runner(script)
            return ValidationResult(valid: result.success, error: result.error)
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let result = Self.compileCheck(script)
                continuation.resume(returning: result)
            }
        }
    }

    /// Validates AppleScript syntax by attempting to compile without executing.
    @MainActor
    static func compileCheck(_ source: String) -> ValidationResult {
        var errorDict: NSDictionary?
        let script: NSAppleScript? = NSAppleScript(source: source)
        _ = script?.compileAndReturnError(&errorDict)
        if let errorDict, let message = errorDict[NSAppleScript.errorMessage] as? String {
            return ValidationResult(valid: false, error: message)
        }
        return ValidationResult(valid: true, error: nil)
    }
    #endif

    // MARK: - Script Execution (for widget)

    #if os(macOS)
    /// Runs an AppleScript and returns the result. Used by the widget's Run button.
    /// Patterns that are always blocked regardless of context.
    /// Checked against the normalized (lowercased) script source.
    private static let blockedPatterns: [String] = [
        "do shell script",
        "run script",          // dynamic AppleScript eval (bypasses source-text checks)
        "load script",         // loads compiled .scpt from disk
        "store script",        // creates compiled script objects
        "do javascript",       // Safari JS execution via AppleScript
        "key code",
        "keystroke",
        "delete every",
        "empty trash",
        "rm -",
        "format disk",
        "do script",           // Terminal
        "sh -c",
        "osascript",
        "curl ",
        "open for access",     // raw file I/O
        "write to file",
    ]

    /// Validates that a script is safe to execute by checking for dangerous operations.
    /// Uses pattern matching on the normalized source after compilation succeeds.
    private static func validateScriptSafety(_ source: String) -> (safe: Bool, reason: String?) {
        let normalized = source.lowercased()

        // Block dangerous patterns (checked after concatenation is resolved by the parser)
        for pattern in blockedPatterns {
            if normalized.contains(pattern) {
                return (false, "Script contains blocked operation: \(pattern)")
            }
        }

        // Allowlist: only permit `tell application` targeting apps from the catalog
        let tellPattern = try? NSRegularExpression(pattern: #"tell\s+application\s+"([^"]+)""#, options: .caseInsensitive)
        let matches = tellPattern?.matches(in: source, range: NSRange(source.startIndex..., in: source)) ?? []
        let allowedApps = Set((catalog?.apps.map { $0.name.lowercased() } ?? []) + [
            "system events", "shortcuts events", "finder",
        ])

        for match in matches {
            if let range = Range(match.range(at: 1), in: source) {
                let appName = String(source[range]).lowercased()
                if !allowedApps.contains(appName) {
                    return (false, "Script targets unauthorized application: \(source[range])")
                }
            }
        }

        return (true, nil)
    }

    @MainActor
    public static func runScript(_ source: String) async -> (success: Bool, output: String) {
        // Step 1: Compile to catch syntax errors (no entitlement needed for compile-only)
        var compileError: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.compileAndReturnError(&compileError)
        if let compileError, let message = compileError[NSAppleScript.errorMessage] as? String {
            return (false, "Compile error: \(message)")
        }

        // Step 2: Validate safety on the original source
        let safety = validateScriptSafety(source)
        guard safety.safe else {
            return (false, safety.reason ?? "Script blocked for safety.")
        }

        // Step 3: Execute via NSUserAppleScriptTask (sandbox-safe, no blanket entitlement)
        do {
            let output = try await UserScriptRunner.run(source)
            return (true, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Saves an AppleScript to a user-chosen location via NSSavePanel (sandbox-safe).
    @MainActor
    public static func saveScript(_ source: String, name: String) async -> URL? {
        let sanitized = name.prefix(50)
            .replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let fileName = sanitized.isEmpty ? "iClaw Automation" : sanitized

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileName).applescript"
        panel.allowedContentTypes = [.appleScript]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.tools.error("Failed to save AppleScript: \(error)")
            return nil
        }
    }

    /// Opens a script in Script Editor by saving it first, then opening.
    @MainActor
    public static func openInScriptEditor(_ source: String, name: String) async {
        guard let url = await saveScript(source, name: name) else { return }
        NSWorkspace.shared.open(url)
    }
    #endif
}
