import Foundation
import FoundationModels

// MARK: - Skill Fetch FM Tool

/// FM tool that lets the LLM fetch a URL during finalization.
/// Injected when a skill references `webfetch` — the skill instruction
/// guides the LLM to call this with the right API URL.
///
/// Not registered in ToolRegistry (invisible to normal routing).
/// Only injected by ExecutionEngine when a skill-driven WebFetch is detected.

@Generable
struct SkillFetchInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The complete URL to fetch, including scheme (https://)")
    var url: String
}

struct SkillFetchTool: Tool {
    typealias Arguments = SkillFetchInput
    typealias Output = String

    let name = "webfetch"
    let description = "Fetch content from a URL and return the response. Use for API calls and web pages."
    var parameters: GenerationSchema { Arguments.generationSchema }

    private let backend: any FetchBackend

    init(backend: any FetchBackend = HTTPFetchBackend()) {
        self.backend = backend
    }

    func call(arguments input: SkillFetchInput) async throws -> String {
        guard let url = URL(string: input.url),
              url.scheme == "http" || url.scheme == "https" else {
            Log.tools.debug("SkillFetch: invalid URL '\(input.url)'")
            return "Invalid URL: \(input.url)"
        }

        Log.tools.debug("SkillFetch: fetching \(url.absoluteString)")

        do {
            let result = try await backend.fetch(url: url)
            if result.statusCode >= 400 {
                return "Error \(result.statusCode) fetching \(url.absoluteString)"
            }
            return ContentCompactor.compact(result.text)
        } catch {
            Log.tools.debug("SkillFetch: fetch failed — \(error.localizedDescription)")
            return "Failed to fetch \(url.absoluteString): \(error.localizedDescription)"
        }
    }
}

// MARK: - Descriptor

/// Descriptor for skill-driven webfetch. Not registered in ToolRegistry —
/// only injected by ExecutionEngine when a skill references `webfetch`.
struct SkillFetchFMDescriptor: FMToolDescriptor {
    let name = "webfetch"
    let chipName = "fetch"
    let routingKeywords: [String] = []
    let category: CategoryEnum = .online

    func makeTool() -> any Tool { SkillFetchTool() }
}
