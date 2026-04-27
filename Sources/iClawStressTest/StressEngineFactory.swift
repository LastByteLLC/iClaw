import Foundation
import iClawCore

/// Shared factory for building ExecutionEngine instances in stress tests.
/// Eliminates the 4× duplicated instantiation pattern across runners.
enum StressEngineFactory {

    /// Tools that trigger side effects (send email, open apps) or hang without
    /// system configuration (Mail.app not set up, microphone not granted).
    static let blockedCoreToolNames: Set<String> = ["Email", "ReadEmail", "Transcribe"]
    static let blockedFMToolNames: Set<String> = ["system_control", "shortcuts", "clipboard"]

    /// Builds an engine with side-effect tools replaced by spy stubs.
    static func makeEngine(
        includeFMTools: Bool = true,
        extraBlockedTools: Set<String> = []
    ) -> ExecutionEngine {
        let allBlocked = blockedCoreToolNames.union(extraBlockedTools)
        var core: [any CoreTool] = ToolRegistry.coreTools.filter {
            !allBlocked.contains($0.name)
        }
        // Replace blocked tools with inert stubs so routing still works
        for name in allBlocked {
            if let orig = ToolRegistry.coreTools.first(where: { $0.name == name }) {
                core.append(StressFactorySpyTool(
                    name: name,
                    schema: orig.schema,
                    category: orig.category
                ))
            }
        }

        let fm: [any FMToolDescriptor] = includeFMTools
            ? ToolRegistry.fmTools.filter { !blockedFMToolNames.contains($0.name) }
            : []

        return ExecutionEngine(
            preprocessor: InputPreprocessor(),
            router: ToolRouter(availableTools: core, fmTools: fm),
            conversationManager: ConversationManager(),
            finalizer: OutputFinalizer(),
            planner: ExecutionPlanner()
        )
    }
}

/// Inert stub tool for stress tests — records invocations but performs no side effects.
/// Separate from StressTestRunner.StressSpyTool (which is private) to avoid coupling.
final class StressFactorySpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal = false
    let category: CategoryEnum

    init(name: String, schema: String, category: CategoryEnum) {
        self.name = name
        self.schema = schema
        self.category = category
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        ToolIO(text: "[Stress test stub for \(name)]", status: .ok)
    }
}
