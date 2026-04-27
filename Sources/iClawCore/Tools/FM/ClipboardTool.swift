import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import FoundationModels

@Generable
struct ClipboardInput: ConvertibleFromGeneratedContent {
    @Guide(description: "'read' to get clipboard contents, 'write' to set clipboard contents")
    var action: String
    @Guide(description: "Text to copy to clipboard (for 'write' action)")
    var text: String?
}

struct ClipboardTool: Tool {
    typealias Arguments = ClipboardInput
    typealias Output = String

    let name = "clipboard"
    let description = "Read or write the system clipboard."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: ClipboardInput) async throws -> String {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        if input.action == "write", let text = input.text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return "Copied to clipboard."
        }
        return pasteboard.string(forType: .string) ?? "Clipboard is empty."
        #else
        let pasteboard = UIPasteboard.general
        if input.action == "write", let text = input.text {
            pasteboard.string = text
            return "Copied to clipboard."
        }
        return pasteboard.string ?? "Clipboard is empty."
        #endif
    }
}
