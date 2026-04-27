import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Provides the Ollama logo as a SwiftUI Image, rendered from inline SVG data.
/// Used in the chat badge when Ollama is the active LLM backend.
public enum OllamaIcon {

    /// SwiftUI Image of the Ollama logo, suitable for use as a template image.
    public static var image: Image {
        #if os(macOS)
        Image(nsImage: nsImage)
        #else
        Image(systemName: "server.rack")
        #endif
    }

    #if os(macOS)
    /// NSImage of the Ollama logo (template mode), sized to match caption2 text.
    public static var nsImage: NSImage {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="14" viewBox="0 0 17 25" fill="none">
          <path fill="#000" fill-rule="evenodd" d="m4.4.1.6.5q.4.5.7 1.4l.4 2q1-.7 2-.8a4 4 0 0 1 2.9.7q0-1 .3-1.9l.8-1.4.5-.5h.8q.7.2 1 .8.5.7.6 1.5.4 1.6.1 4.1l.1.1q1.2 1 1.6 2.7c.4 1.7.2 3.6-.6 4.6q.6 1.4.8 2.8a7 7 0 0 1-.9 3.6q.8 2 .5 4 0 .4-.3.6h-.7l-.2-.2-.1-.6q.3-1.7-.5-3.5v-.7q1-1.5.9-3.1-.1-1.4-.8-2.6-.2-.2-.1-.5 0-.3.2-.5.4-.3.6-1.3V9.7q-.4-1.2-1.2-2-.9-.7-2.4-.6l-.3-.1-.3-.3Q11 5.6 10.1 5a3 3 0 0 0-1.8-.3 3 3 0 0 0-2.7 1.9l-.2.3L5 7q-1.5 0-2.5.8-.8.7-1 1.9-.3 1-.1 2.1.2 1 .6 1.4t0 1q-.4 1-.6 2.7 0 1.8.7 2.9l.2.4v.4a6 6 0 0 0-.6 3.5l-.1.5q-.1.3-.4.3H.7l-.3-.5q-.3-1.8.5-4l-.6-1.5-.2-2q0-1.7.6-3L.1 12q-.2-1.6.1-2.8a5 5 0 0 1 1.7-2.8q-.2-2.4.1-4 .2-.9.6-1.5a2 2 0 0 1 1-.8q.4-.2.8 0m4.1 10.3q1.5 0 2.5 1t1 2.2q0 1.5-1.2 2.3-.9.6-2.4.6T6 15.7t-1-2a3 3 0 0 1 1-2.4q1.1-1 2.5-1m0 1q-1 0-1.9.8a2 2 0 0 0-.7 1.4q0 .8.6 1.3a3 3 0 0 0 2 .6q1.1 0 1.9-.5t.7-1.4q0-.8-.7-1.4-.8-.8-1.9-.8m.7 1.4v.6l-.4.2v.9h-.6l-.1-.3v-.6l-.3-.2v-.6l.2-.1h.3l.2.3.2-.2a.3.3 0 0 1 .5 0m-5-2.2q.7.1.8 1 0 .4-.2.7t-.7.3l-.6-.3-.2-.7.2-.7zm8.6 0q.9.1 1 1 0 .4-.3.7t-.7.3l-.6-.3-.2-.7.2-.7zM4 1.5l-.2.2-.4 1Q3 3.9 3.2 5.9q.6-.3 1.4-.3l.2-.3q0-1.5-.3-2.8zm9.2 0v.1q-.4.3-.5 1-.5 1.4-.3 2.9v.1h.1q.8 0 1.5.2l-.1-3-.4-1z" clip-rule="evenodd"/>
        </svg>
        """
        guard let data = svg.data(using: .utf8),
              let img = NSImage(data: data) else {
            return NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Ollama")!
        }
        img.isTemplate = true
        return img
    }
    #endif
}
