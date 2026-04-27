#if os(macOS) && !MAS_BUILD
import Foundation
import FoundationModels

@Generable
struct SpotlightInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Search query for finding files on the Mac")
    var query: String
}

struct SpotlightTool: Tool {
    typealias Arguments = SpotlightInput
    typealias Output = String

    let name = "spotlight"
    let description = "Search for files on the user's Mac using Spotlight. Use when the user asks about local files or documents."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: SpotlightInput) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["--", input.query]

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(10)

        if files.isEmpty {
            return "No files found matching '\(input.query)'."
        }
        return "Files found:\n" + files.joined(separator: "\n")
    }
}
#endif
