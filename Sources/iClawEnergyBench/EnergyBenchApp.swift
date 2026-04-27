import SwiftUI

@main
struct EnergyBenchApp: App {
    @State private var runner = BenchmarkRunner()

    /// Launch with BENCH_ITERATIONS=20 to override iteration count.
    private var iterationCount: Int {
        if let env = ProcessInfo.processInfo.environment["BENCH_ITERATIONS"],
           let count = Int(env) {
            return count
        }
        return 10
    }

    /// Launch with BENCH_AUTORUN=1 to auto-start.
    private var autoRun: Bool {
        ProcessInfo.processInfo.environment["BENCH_AUTORUN"] == "1"
    }

    var body: some Scene {
        WindowGroup("iClaw Energy Benchmark") {
            EnergyBenchView(runner: runner)
                .frame(minWidth: 600, minHeight: 500)
                .task {
                    if autoRun && !runner.isRunning {
                        runner.start(iterations: iterationCount)
                    }
                }
        }
        .windowResizability(.contentMinSize)
    }
}
