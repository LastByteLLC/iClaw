/// iClawCLI — Headless daemon for driving iClaw's execution pipeline from the terminal.
///
/// Runs as a long-lived process that accepts commands via stdin and returns
/// responses via stdout. Designed for integration with Claude Code, scripts,
/// and automated testing without the GUI.
///
/// Usage:
///   swift build --product iClawCLI && .build/debug/iClawCLI
///   make cli && .build/debug/iClawCLI
///
/// Commands (JSON-based protocol over stdin/stdout):
///   {"type": "prompt", "text": "What's the weather in London?"}
///   {"type": "setting", "key": "personalityLevel", "value": "neutral"}
///   {"type": "setting_get", "key": "personalityLevel"}
///   {"type": "status"}
///   {"type": "reset"}
///   {"type": "quit"}
///
/// Responses (JSON, one per line):
///   {"type": "response", "text": "...", "widgetType": null, "isError": false, "durationMs": 1234}
///   {"type": "setting_ack", "key": "...", "value": "..."}
///   {"type": "status", "turnCount": 5, "facts": [...], "settings": {...}}
///   {"type": "error", "message": "..."}

import Foundation
import iClawCore

// MARK: - JSON Protocol Types

struct CLIRequest: Decodable {
    let type: String
    let text: String?
    let key: String?
    let value: String?
    /// For prompt_sequence: array of prompts to execute in one session
    let prompts: [String]?
    /// For reply: index of the prior response to reply to (0 = most recent)
    let replyIndex: Int?
    /// For judge: the user input (being evaluated) and the assistant response
    let user: String?
    let assistant: String?
}

struct CLIResponse: Encodable {
    let type: String
    var text: String?
    var widgetType: String?
    var isError: Bool?
    var durationMs: Int?
    var message: String?
    var key: String?
    var value: String?
    var turnCount: Int?
    var facts: [FactInfo]?
    var settings: [String: String]?

    // Per-turn telemetry (populated on `prompt`/`reply` responses only).
    var routedTools: [String]?           // real tools that ran (synthetic labels excluded)
    var routingOutcome: String?          // tools / fmTools / mixed / disambiguation / conversational / clarification / error
    var pivotDetected: Bool?
    var followUpDetected: Bool?
    var classifierLabel: String?
    var classifierConfidence: Double?

    struct FactInfo: Encodable {
        let tool: String
        let key: String
        let value: String
    }
}

// MARK: - Bootstrap

/// Minimal bootstrap for headless execution.
/// ExecutionEngine and all its dependencies are GUI-independent.
// MARK: - Trace Writer
//
// Writes one JSON file per prompt turn to a directory. Enabled by
// `--trace-dir <path>`. The meta-harness evaluator reads these to grade
// candidates. Intentionally capture-everything: the proposer agent greps these
// to form causal hypotheses (Meta-Harness paper ablation: raw traces over
// scalar scores is +15pp).

struct TurnTrace: Encodable {
    let turn: Int
    let timestamp: String
    let prompt: String
    let harnessDir: String?
    let durationMs: Int?
    let response: CLIResponse
    /// Structured per-turn trace: LLM calls (site, chars, ms) and router
    /// stages (winning stage per route() call). `nil` when the daemon is
    /// running without tracing or no turn has completed.
    let traceSnapshot: TurnTraceCollector.Snapshot?

    enum CodingKeys: String, CodingKey {
        case turn, timestamp, prompt, harnessDir = "harness_dir", durationMs = "duration_ms", response
        case traceSnapshot = "trace"
    }
}

actor TraceWriter {
    let directory: URL
    private var counter: Int = 0
    private let encoder: JSONEncoder
    private let formatter: ISO8601DateFormatter
    private let harnessDir: String?

    init?(path: String, harnessDir: String?) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        self.directory = url
        self.harnessDir = harnessDir
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func write(prompt: String, response: CLIResponse, snapshot: TurnTraceCollector.Snapshot?) {
        counter += 1
        let trace = TurnTrace(
            turn: counter,
            timestamp: formatter.string(from: Date()),
            prompt: prompt,
            harnessDir: harnessDir,
            durationMs: response.durationMs,
            response: response,
            traceSnapshot: snapshot
        )
        let filename = String(format: "trace-%06d.json", counter)
        let dest = directory.appendingPathComponent(filename)
        do {
            let data = try encoder.encode(trace)
            try data.write(to: dest)
        } catch {
            fputs("{\"type\":\"error\",\"message\":\"Trace write failed: \(error.localizedDescription)\"}\n", stderr)
        }
    }
}

/// Parses `--harness-dir <path>` from CommandLine. If the directory exists,
/// installs it as the overlay root for all Config JSON + prompt Markdown:
///   • `ICLAW_CONFIG_DIR` env var → `ConfigLoader` reads overrides first.
///   • `UserDefaults["prompt.brain.variant.path"]` → `BRAIN.md` override.
///   • `UserDefaults["prompt.brain-conversational.variant.path"]` → conversational brain override.
///   • `UserDefaults["prompt.soul.path"]` → `SOUL.md` override.
/// Must be called before any code that reads a static `shared` config
/// (`MLThresholdsConfig.shared`, etc.) — Swift lazy-init caches the first read.
func installHarnessOverridesIfRequested() {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--harness-dir"),
          idx + 1 < args.count else { return }
    let dir = args[idx + 1]
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
        fputs("{\"type\":\"error\",\"message\":\"--harness-dir path does not exist or is not a directory: \(dir)\"}\n", stderr)
        return
    }
    setenv("ICLAW_CONFIG_DIR", dir, 1)

    let fm = FileManager.default
    let brain = (dir as NSString).appendingPathComponent("BRAIN.md")
    if fm.fileExists(atPath: brain) {
        UserDefaults.standard.set(brain, forKey: "prompt.brain.variant.path")
    }
    let brainConv = (dir as NSString).appendingPathComponent("BRAIN-conversational.md")
    if fm.fileExists(atPath: brainConv) {
        UserDefaults.standard.set(brainConv, forKey: "prompt.brain-conversational.variant.path")
    }
    let soul = (dir as NSString).appendingPathComponent("SOUL.md")
    if fm.fileExists(atPath: soul) {
        UserDefaults.standard.set(soul, forKey: "prompt.soul.path")
    }
}

@MainActor
func bootstrap() {
    // Headless mode: use HTTP-only fetch (no WKWebView / keychain access)
    ToolRegistry.headlessMode = true
    // Register conditional tools (currently a no-op but required by contract)
    ToolRegistry.registerConditionalTools()

    // Replace tools that depend on EventKit / AppleScript / NSWorkspace /
    // NSAlert.runModal with deterministic stubs so the daemon never blocks
    // on a missing GUI. Can be bypassed with `--real-tools`.
    if !CommandLine.arguments.contains("--real-tools") {
        HeadlessStubs.install()
    }

    // Default the consent manager to .alwaysApprove so autonomous runs
    // don't stall on requiresConsent/destructive prompts. Override at
    // runtime with `{"type":"consent","value":"..."}` on stdin.
    ConsentManager.shared.testModePolicy = .alwaysApprove

    // LoRA adapter loading is not wired up pending
    // https://developer.apple.com/forums/thread/823001.
}

// MARK: - Command Handlers

actor CLIDaemon {
    private let engine: ExecutionEngine
    private let conversationManager: ConversationManager
    private let encoder = JSONEncoder()

    /// History of prompt/response pairs for the reply command.
    private var history: [(prompt: String, response: String)] = []

    /// Snapshot of the engine's per-turn trace (populated by `handlePrompt`).
    /// Read by the CLI main loop to attach to the TraceWriter artifact.
    func lastTurnTrace() async -> TurnTraceCollector.Snapshot? {
        await engine.lastTurnTrace
    }

    init() {
        let cm = ConversationManager()
        self.conversationManager = cm
        self.engine = ExecutionEngine(
            preprocessor: InputPreprocessor(),
            router: ToolRouter(availableTools: ToolRegistry.coreTools, fmTools: ToolRegistry.fmTools),
            conversationManager: cm,
            finalizer: OutputFinalizer(),
            planner: ExecutionPlanner()
        )
    }

    func handlePrompt(_ text: String) async -> CLIResponse {
        let start = ContinuousClock.now
        // 20s timeout on the entire engine pipeline. On cold start (fresh CLI
        // process), the ML model, NLEmbedding, location manager, and LLM adapter
        // all initialize simultaneously, which can exceed 30s. The timeout
        // ensures the CLI always responds, even if the engine hangs.
        let result: (text: String, widgetType: String?, widgetData: (any Sendable)?, isError: Bool, suggestedQueries: [String]?)
        result = await withTaskGroup(of: (text: String, widgetType: String?, widgetData: (any Sendable)?, isError: Bool, suggestedQueries: [String]?).self) { group in
            group.addTask {
                await self.engine.run(input: text)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return (text: "Request timed out. The on-device model is still initializing — try again.", widgetType: nil as String?, widgetData: nil as (any Sendable)?, isError: true, suggestedQueries: nil as [String]?)
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        let elapsed = start.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

        // Record facts and history
        let telemetry = await engine.lastTurnTelemetry
        let rawRouted = await engine.lastRoutedToolNames
        history.append((prompt: text, response: result.text))
        if history.count > 10 { history.removeFirst() } // keep last 10

        // lastRoutedToolNames is the canonical source — multiple execution
        // paths populate it (fast path, planning path, agent path). The
        // routing-outcome telemetry is only set by the main routing switch
        // so we derive real tool names directly here and synthesize outcome.
        let synthetic: Set<String> = ["conversational", "disambiguation", "clarification"]
        let realRouted = rawRouted.filter { !synthetic.contains($0) }
        let outcome: String = {
            if !realRouted.isEmpty { return telemetry.routingOutcome.rawValue == "conversational" ? "tools" : telemetry.routingOutcome.rawValue }
            if rawRouted.contains("disambiguation") { return "disambiguation" }
            if rawRouted.contains("clarification") { return "clarification" }
            if rawRouted.contains("conversational") { return "conversational" }
            return telemetry.routingOutcome.rawValue
        }()

        var response = CLIResponse(
            type: "response",
            text: result.text,
            widgetType: result.widgetType,
            isError: result.isError,
            durationMs: ms,
            key: realRouted.first  // legacy: first real tool
        )
        response.routedTools = realRouted
        response.routingOutcome = outcome
        response.pivotDetected = telemetry.pivotDetected
        response.followUpDetected = telemetry.followUpDetected
        response.classifierLabel = telemetry.classifierLabel
        response.classifierConfidence = telemetry.classifierConfidence
        return response
    }

    func handleSetting(key: String, value: String) -> CLIResponse {
        // Map known settings to UserDefaults
        switch key {
        case "personalityLevel":
            UserDefaults.standard.set(value, forKey: "personalityLevel")
        case "customPersonality":
            UserDefaults.standard.set(value, forKey: "customPersonality")
        case "autoApproveActions":
            UserDefaults.standard.set(value == "true", forKey: "autoApproveActions")
        case "screenContextEnabled":
            UserDefaults.standard.set(value == "true", forKey: AppConfig.screenContextEnabledKey)
        case AppConfig.useClassifierResponseCleaningKey,
             AppConfig.useClassifierUserFactsKey,
             AppConfig.useClassifierIntentRoutingKey,
             AppConfig.useLLMJudgeKey,
             AppConfig.knowledgeMemoryEnabledKey,
             AppConfig.dynamicWidgetsEnabledKey:
            // Boolean feature flags — explicit list so "true"/"false" strings
            // become actual Bool values rather than String storage (which
            // `UserDefaults.bool(forKey:)` would read as false).
            UserDefaults.standard.set(value == "true", forKey: key)
        default:
            // Generic string setting
            UserDefaults.standard.set(value, forKey: key)
        }
        return CLIResponse(type: "setting_ack", key: key, value: value)
    }

    func handleSettingGet(key: String) -> CLIResponse {
        let value: String
        if let str = UserDefaults.standard.string(forKey: key) {
            value = str
        } else if UserDefaults.standard.object(forKey: key) is Bool {
            value = UserDefaults.standard.bool(forKey: key) ? "true" : "false"
        } else {
            value = UserDefaults.standard.object(forKey: key).map { "\($0)" } ?? "(not set)"
        }
        return CLIResponse(type: "setting_ack", key: key, value: value)
    }

    func handleStatus() async -> CLIResponse {
        let state = await conversationManager.state
        // Combine tool-returned facts and user-stated facts so status reflects
        // both sources of memory. UserFacts appear under `tool: "user"`.
        var facts = state.recentFacts.map {
            CLIResponse.FactInfo(tool: $0.tool, key: $0.key, value: $0.value)
        }
        facts += state.userFacts.map {
            CLIResponse.FactInfo(tool: "user", key: $0.category, value: $0.value)
        }
        let settings: [String: String] = [
            "personalityLevel": UserDefaults.standard.string(forKey: "personalityLevel") ?? "full",
            "autoApproveActions": UserDefaults.standard.bool(forKey: "autoApproveActions") ? "true" : "false",
        ]
        return CLIResponse(
            type: "status",
            turnCount: state.turnCount,
            facts: facts,
            settings: settings
        )
    }

    func handleReset() async -> CLIResponse {
        await engine.resetConversation()
        history.removeAll()
        return CLIResponse(type: "status", message: "Conversation reset")
    }

    /// Runs a dedicated judge prompt through LLMAdapter, bypassing the
    /// routing pipeline. Returns parsed JSON scores on four axes. Used by
    /// prompt_eval.py and other external quality harnesses.
    func handleJudge(user: String, assistant: String) async -> CLIResponse {
        let rubric = """
        Rate the assistant response on four axes (1-5, integer). Output JSON only.

        - correctness: does it factually match the user ask?
        - completeness: does it include the salient information?
        - brevity: is it as concise as the content permits (5 = excellent, 1 = bloated)?
        - tone: does it sound helpful and direct, not refusal-like or disclaimer-heavy?

        User: \(user)
        Assistant: \(assistant)

        Output format: {"correctness": N, "completeness": N, "brevity": N, "tone": N}
        """
        let response = (try? await LLMAdapter.shared.generateText(rubric)) ?? ""
        // Extract the first {...} block with all four axes.
        let pattern = #"\{[^{}]*"correctness"[^{}]*"completeness"[^{}]*"brevity"[^{}]*"tone"[^{}]*\}"#
        let jsonPayload: String = {
            if let range = response.range(of: pattern, options: .regularExpression) {
                return String(response[range])
            }
            return ""
        }()
        return CLIResponse(
            type: "judge_result",
            text: response,
            value: jsonPayload.isEmpty ? nil : jsonPayload
        )
    }

    func handleConsentPolicy(_ policy: String) async -> CLIResponse {
        let normalized = policy.lowercased()
        await MainActor.run {
            switch normalized {
            case "alwaysapprove", "approve", "true":
                ConsentManager.shared.testModePolicy = .alwaysApprove
            case "alwaysdeny", "deny", "false":
                ConsentManager.shared.testModePolicy = .alwaysDeny
            case "clear", "off", "none":
                ConsentManager.shared.testModePolicy = nil
            default:
                ConsentManager.shared.testModePolicy = .alwaysApprove
            }
        }
        return CLIResponse(type: "setting_ack", key: "consent", value: normalized)
    }

    /// Handles a reply to a previous response. Constructs the same
    /// `[Replying to: "prompt" → "response"]` prefix that the GUI uses,
    /// so CalculatorTool's explain pattern match works identically.
    func handleReply(text: String, replyIndex: Int) async -> CLIResponse {
        guard !history.isEmpty else {
            return CLIResponse(type: "error", message: "No previous response to reply to")
        }
        let idx = min(replyIndex, history.count - 1)
        let target = history[history.count - 1 - idx]
        let replyInput = "[Replying to: \"\(target.prompt)\" → \"\(target.response)\"]\n\(text)"
        return await handlePrompt(replyInput)
    }
}

// MARK: - I/O Loop

func writeLine(_ response: CLIResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(response),
          let json = String(data: data, encoding: .utf8) else {
        fputs("{\"type\":\"error\",\"message\":\"Encoding failed\"}\n", stdout)
        return
    }
    print(json)
    fflush(stdout)
}

func writeError(_ message: String) {
    writeLine(CLIResponse(type: "error", message: message))
}

// MARK: - Main

/// Parses `--trace-dir <path>`. Returns the absolute path if provided and the
/// directory can be created, else nil. Must run AFTER
/// `installHarnessOverridesIfRequested` so `harnessDir` is resolvable.
func resolveTraceDirArg() -> String? {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--trace-dir"),
          idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func resolveHarnessDirArg() -> String? {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--harness-dir"),
          idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

@MainActor
func main() async {
    // Must run before bootstrap() so ICLAW_CONFIG_DIR is visible to any static
    // `shared` config initializer that fires during registry setup.
    installHarnessOverridesIfRequested()
    bootstrap()

    // Optional per-turn trace writer for the meta-harness evaluator.
    let traceWriter: TraceWriter? = {
        guard let path = resolveTraceDirArg() else { return nil }
        return TraceWriter(path: path, harnessDir: resolveHarnessDirArg())
    }()

    // Start BrowserBridge if --bridge flag is passed (enables push/pull testing)
    let bridgeEnabled = CommandLine.arguments.contains("--bridge")
    var bridgePort: UInt16?
    if bridgeEnabled {
        UserDefaults.standard.set(true, forKey: "browserBridgeEnabled")
        try? await BrowserBridge.shared.start()
        // Wait briefly for listener to bind
        try? await Task.sleep(for: .milliseconds(200))
        bridgePort = await BrowserBridge.shared.port
    }

    let daemon = CLIDaemon()
    let decoder = JSONDecoder()

    // Synchronous warmup: load the ML classifier and prewarm the Neural Engine
    // BEFORE emitting "ready". This prevents cold-start deadlocks where
    // the first query stacks ML model load + NLEmbedding init + LLM init
    // across multiple actor boundaries, totaling >45s.
    // The batch runner waits for "ready" before sending prompts, so this
    // naturally gates query submission.
    //
    // prewarmForFinalization() loads model resources and caches the brain+soul
    // prompt prefix, which is cheaper than the old generateText(".") call
    // (no full inference round-trip) while still warming the Neural Engine.
    await MLToolClassifier.shared.loadModel()
    await LLMAdapter.shared.prewarmForFinalization()

    // Print ready signal (include bridge port if enabled)
    var readyResponse = CLIResponse(type: "ready", message: "iClawCLI daemon ready")
    if let port = bridgePort {
        readyResponse.value = "\(port)"
        readyResponse.key = "bridgePort"
    }
    writeLine(readyResponse)

    // Read commands from stdin, one JSON object per line
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        // Parse command — distinguish malformed JSON from missing/wrong fields
        guard let data = trimmed.data(using: .utf8) else {
            writeError("Input is not valid UTF-8")
            continue
        }
        let request: CLIRequest
        do {
            request = try decoder.decode(CLIRequest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            writeError("Missing required field '\(key.stringValue)' in JSON command")
            continue
        } catch let DecodingError.typeMismatch(_, context) {
            writeError("Type mismatch at '\(context.codingPath.map(\.stringValue).joined(separator: "."))': \(context.debugDescription)")
            continue
        } catch {
            writeError("Invalid JSON: \(error.localizedDescription)")
            continue
        }

        switch request.type {
        case "prompt":
            guard let text = request.text, !text.isEmpty else {
                writeError("Missing 'text' field for prompt command")
                continue
            }
            let response = await daemon.handlePrompt(text)
            // Write trace BEFORE sending the response line. This guarantees
            // durability: a client that reads the response and immediately
            // SIGKILLs the daemon can't lose the trace.
            if let traceWriter {
                let snap = await daemon.lastTurnTrace()
                await traceWriter.write(prompt: text, response: response, snapshot: snap)
            }
            writeLine(response)

        case "prompt_sequence":
            // Execute multiple prompts sequentially within one session,
            // preserving conversation state, facts, and prior context.
            // Essential for testing multi-turn flows (calc → explain).
            guard let prompts = request.prompts, !prompts.isEmpty else {
                writeError("Missing 'prompts' array for prompt_sequence command")
                continue
            }
            for prompt in prompts {
                let response = await daemon.handlePrompt(prompt)
                if let traceWriter {
                    let snap = await daemon.lastTurnTrace()
                    await traceWriter.write(prompt: prompt, response: response, snapshot: snap)
                }
                writeLine(response)
            }

        case "reply":
            // Reply to the most recent response, injecting its context.
            // Mirrors the GUI's Reply mechanism for explanation follow-ups.
            guard let text = request.text, !text.isEmpty else {
                writeError("Missing 'text' field for reply command")
                continue
            }
            let replyText = await daemon.handleReply(text: text, replyIndex: request.replyIndex ?? 0)
            if let traceWriter {
                let snap = await daemon.lastTurnTrace()
                await traceWriter.write(prompt: text, response: replyText, snapshot: snap)
            }
            writeLine(replyText)

        case "setting":
            guard let key = request.key, let value = request.value else {
                writeError("Missing 'key' or 'value' for setting command")
                continue
            }
            let response = await daemon.handleSetting(key: key, value: value)
            writeLine(response)

        case "setting_get":
            guard let key = request.key else {
                writeError("Missing 'key' for setting_get command")
                continue
            }
            let response = await daemon.handleSettingGet(key: key)
            writeLine(response)

        case "status":
            let response = await daemon.handleStatus()
            writeLine(response)

        case "reset":
            let response = await daemon.handleReset()
            writeLine(response)

        case "judge":
            guard let user = request.user, let assistant = request.assistant,
                  !user.isEmpty, !assistant.isEmpty else {
                writeError("Missing 'user' or 'assistant' for judge command")
                continue
            }
            let response = await daemon.handleJudge(user: user, assistant: assistant)
            writeLine(response)

        case "consent":
            // Set the ConsentManager test-mode policy so destructive/consent-
            // required actions resolve deterministically in autonomous runs.
            //   {"type":"consent","value":"alwaysApprove"}
            //   {"type":"consent","value":"alwaysDeny"}
            //   {"type":"consent","value":"clear"}
            let policy = request.value ?? "alwaysApprove"
            let ack = await daemon.handleConsentPolicy(policy)
            writeLine(ack)

        case "quit", "exit":
            writeLine(CLIResponse(type: "status", message: "Shutting down"))
            exit(0)

        default:
            writeError("Unknown command type: '\(request.type)'. Valid: prompt, setting, setting_get, status, reset, consent, quit")
        }
    }
}

// Entry point — run the async main on the MainActor
await main()

