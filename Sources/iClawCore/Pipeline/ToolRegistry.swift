import Foundation
import os

public enum ToolRegistry {

    /// When true, tools avoid WKWebView and other GUI-dependent subsystems.
    /// Set by the CLI daemon before accessing `coreTools`.
    /// Safe to mutate from @MainActor only (set once at startup, read once during
    /// lazy `baseCoreTools` init, both on the main actor).
    public nonisolated(unsafe) static var headlessMode = false

    // MARK: - Core Tools

    /// Tools that are always available regardless of hardware/software.
    private static let baseCoreTools: [any CoreTool] = {
        var tools: [any CoreTool] = [
            TodayTool(),
            CalendarTool(),
            CalendarEventTool(),
            MessagesTool(),
            RemindersTool(),
            ContactsTool(),
            TimeTool(),
            RandomTool(),
            EmailTool(),
            ConvertTool(),
            CalculatorTool(),
            headlessMode ? WebFetchTool(session: .shared) : WebFetchTool(),
            TranslateTool(),
            TranscribeTool(),
            PodcastTool(),
            WeatherTool(),
            StockTool(),
            MapsCoreTool(),
            NewsTool(),
            FeedbackTool(),
            ResearchTool(),
            WikipediaCoreTool(),
            HelpTool(),
            ComputeTool()
        ]
        #if os(macOS)
        tools += [DictionaryTool(), SystemInfoTool(), ScreenshotTool(), TechSupportTool(), ImportTool(), NotesTool()]
        #if !MAS_BUILD
        // These tools require Apple Events entitlement (not available in MAS).
        // AutomateTool (AppleScript), AutomationTool (scheduled recurring), ReadEmailTool (Mail.app)
        // are all excluded from MAS builds.
        tools.append(AutomateTool())
        tools.append(AutomationTool())
        tools.append(ReadEmailTool())
        #endif
        #else
        tools += [DictionaryToolIOS(), SystemInfoToolIOS(), AlarmTool()]
        #endif
        return tools
    }()

    /// Tools registered conditionally at runtime based on hardware/software availability.
    /// Populated by `registerConditionalTools()` during app startup.
    private static let _conditionalTools = OSAllocatedUnfairLock(initialState: [any CoreTool]())

    /// Name-keyed stub replacements. When populated, `coreTools` substitutes
    /// each matching base tool with the stub version (preserving name/schema
    /// but swapping execute()). Used by `HeadlessStubs` in CLI/test mode so
    /// EventKit / AppleScript / Mail.app code paths are never invoked.
    private static let _stubTools = OSAllocatedUnfairLock(initialState: [String: any CoreTool]())

    /// Register stub tools by name. Each entry replaces the production tool
    /// with the matching `name` in the `coreTools` getter. Empty dict clears
    /// all stubs. Safe to call at any time; callers on the CLI should invoke
    /// from `@MainActor` during bootstrap.
    public static func setStubTools(_ stubs: [String: any CoreTool]) {
        _stubTools.withLock { $0 = stubs }
    }

    /// All registered CoreTools (base + conditional), with stubs substituted
    /// by name, excluding user-disabled tools.
    public static var coreTools: [any CoreTool] {
        let base = baseCoreTools + _conditionalTools.withLock { $0 }
        let stubs = _stubTools.withLock { $0 }
        let swapped: [any CoreTool] = base.map { tool in stubs[tool.name] ?? tool }
        let disabled = Self.loadDisabledToolNames()
        if disabled.isEmpty { return swapped }
        return swapped.filter { !disabled.contains($0.name) }
    }

    /// Read disabled tool names directly from UserDefaults (no actor isolation needed).
    /// Public for use by ChatInputView and HelpTool filters.
    public static func loadDisabledToolNamesPublic() -> Set<String> {
        loadDisabledToolNames()
    }

    private static func loadDisabledToolNames() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "iClaw_disabledTools"),
              let names = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return names
    }

    /// Register tools that depend on runtime availability checks.
    /// Call once from AppDelegate.applicationDidFinishLaunching (main thread).
    ///
    /// Tools gated here are **categorically absent** without the right hardware/software —
    /// unlike tools that are always registered but return errors when permissions are missing
    /// (Weather without location, Email without Mail.app).
    @MainActor
    public static func registerConditionalTools() {
        // No conditional tools to register at this time.
    }

    // MARK: - FM Tools

    /// FM tools that are always available on this platform.
    private static let baseFMTools: [any FMToolDescriptor] = {
        var tools: [any FMToolDescriptor] = [
            // CalendarEventTool is now a CoreTool (returns confirmation widget)
            ClipboardFMDescriptor(),
            // ContactsTool, RemindersTool moved to baseCoreTools (returns preview widgets)
            ReadFileFMDescriptor(),
            WebSearchFMDescriptor()
        ]

        // All FM tools below have MAS-compatible fallbacks (URL schemes, Core Audio, Intents)
        tools.append(ShortcutsFMDescriptor())
        // MessagesTool, NotesTool moved to baseCoreTools (returns preview widgets)

        #if os(macOS)
        #if !MAS_BUILD
        tools.append(SpotlightFMDescriptor())    // Process() — not available in MAS sandbox
        #endif
        tools.append(SystemControlFMDescriptor()) // MAS: Core Audio + NSWorkspace
        tools.append(BrowserFMDescriptor())         // Browser extraction + interactive actions
        #endif
        tools.append(WriteFileFMDescriptor())        // Save files to Downloads
        return tools
    }()

    /// FM tools registered conditionally based on hardware availability.
    private static let _conditionalFMTools = OSAllocatedUnfairLock(initialState: [any FMToolDescriptor]())

    /// All registered FMToolDescriptors (base + conditional).
    public static var fmTools: [any FMToolDescriptor] {
        baseFMTools + _conditionalFMTools.withLock { $0 }
    }

    // MARK: - Helpers

    /// Combined names for autocomplete, routing
    public static var allToolNames: [String] {
        coreTools.map { $0.name } + fmTools.map { $0.name }
    }
}
