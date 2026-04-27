import Foundation
import FoundationModels

// MARK: - ModelManager

/// Actor wrapping Foundation Model interactions.
/// Converted from @MainActor singleton to actor for proper Swift 6 concurrency
/// and to enable dependency injection in tests.
public actor ModelManager {
    public static let shared = ModelManager()

    public init() {}

    func generateSystemPrompt() async -> String {
        var parts = [BrainProvider.current, SoulProvider.current]
        let userCtx = await UserProfileProvider.current()
        if !userCtx.isEmpty { parts.append(userCtx) }
        return parts.joined(separator: "\n\n")
    }

    /// All FM tools from ToolRegistry.
    private var fmTools: [any Tool] {
        ToolRegistry.fmTools.map { $0.makeTool() }
    }

    func generateResponse(prompt: String, history: [Memory]) async throws -> String {
        let systemPrompt = await generateSystemPrompt()
        Log.model.debug("Prompt: \(prompt)")

        let routedTools = fmTools
        Log.model.debug("Active tools (\(routedTools.count)): \(routedTools.map { $0.name }.joined(separator: ", "))")

        let entities = InputParsingUtilities.extractNamedEntities(from: prompt)
        var nerHints = ""
        if !entities.places.isEmpty {
            nerHints += "\nDetected locations: \(entities.places.joined(separator: ", ")). Pass these as tool arguments (e.g. locationName for weather)."
        }
        if !entities.people.isEmpty {
            nerHints += "\nDetected people: \(entities.people.joined(separator: ", ")). Pass these as tool arguments (e.g. name for contacts, query for podcast)."
        }
        if !entities.orgs.isEmpty {
            nerHints += "\nDetected organizations: \(entities.orgs.joined(separator: ", "))."
        }
        if !nerHints.isEmpty {
            Log.model.debug("NER:\(nerHints)")
        }

        var instructions = systemPrompt

        if routedTools.count <= 3 {
            let toolList = routedTools.map { $0.name }.joined(separator: " or ")
            instructions += "\n\nYou MUST call the \(toolList) tool to answer this question. Do not answer from memory. NEVER output JSON or function call syntax as text — use the tool calling mechanism instead."
        }

        if !nerHints.isEmpty {
            instructions += "\n" + nerHints
        }

        let relevantHistory = history.suffix(5).filter { memory in
            let content = memory.content
            return content.count < 300
                && !content.contains("Error")
                && !content.contains("denied")
                && !content.contains("PHOTO_CAPTURED")
                && !content.contains("CURRENT LOCATION")
        }
        if !relevantHistory.isEmpty {
            let context = relevantHistory.map { "[\($0.role)] \($0.content)" }.joined(separator: "\n")
            instructions += "\n\nRecent context (for reference only — answer the user's NEW message, not these):\n\(context)"
        }

        do {
            let response = try await LLMAdapter.shared.guardedGenerate(
                prompt: prompt,
                tools: routedTools,
                instructions: instructions
            )
            var content = response.content
            Log.model.debug("Response: \(content.prefix(300))")

            if content.contains("\"name\"") && content.contains("\"arguments\"") {
                Log.model.debug("Detected raw JSON tool call in response — retrying")
                let retryResponse = try await LLMAdapter.shared.guardedGenerate(
                    prompt: prompt,
                    tools: routedTools,
                    instructions: instructions + "\n\nIMPORTANT: You just failed by outputting JSON text. USE the tool calling mechanism. Do NOT write JSON."
                )
                content = retryResponse.content
                Log.model.debug("Retry response: \(content.prefix(300))")

                if content.contains("\"name\"") && content.contains("\"arguments\"") {
                    Log.model.debug("Retry still produced JSON — falling back")
                    return "I tried to use a tool but the on-device model is having trouble. Try rephrasing your question."
                }
            }

            return content
        } catch {
            Log.model.debug("Error: \(error)")
            return "An error occurred: \(error.localizedDescription)"
        }
    }
}
