import SwiftUI
import iClawCore

/// Environment variables for scripted runs:
/// - `STRESS_AUTORUN=50`   — auto-start with 50 prompts on launch
/// - `STRESS_AUTO_EXIT=1`  — terminate the app when the run completes
///
/// Example:
/// ```
/// STRESS_AUTORUN=100 STRESS_AUTO_EXIT=1 \
///   .build/arm64-apple-macosx/debug/iClawStressTest.app/Contents/MacOS/iClawStressTest
/// ```
@main
struct StressTestApp: App {
    @State private var runner = StressTestRunner()

    private static let env = ProcessInfo.processInfo.environment

    /// Number of prompts to auto-run (nil = manual).
    private var autoRunCount: Int? {
        Self.env["STRESS_AUTORUN"].flatMap(Int.init)
    }

    /// When true, the app exits after the stress run completes.
    private var autoExit: Bool {
        Self.env["STRESS_AUTO_EXIT"] == "1"
    }

    var body: some Scene {
        WindowGroup("iClaw Stress Test") {
            StressTestView(runner: runner)
                .frame(minWidth: 700, minHeight: 500)
                .task {
                    if let count = autoRunCount, !runner.isRunning {
                        let defaultModel = ProviderKind.appleFoundation.models[0]
                        runner.start(promptCount: count, provider: AppleFoundationProvider(), modelOption: defaultModel)
                    }
                }
                .onChange(of: runner.phase) {
                    if autoExit && (runner.phase == .done || runner.phase == .failed) {
                        // Allow a brief delay for final file writes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
