import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Centralized clipboard operations.
public enum ClipboardHelper {
    /// Copies the given string to the system pasteboard.
    @MainActor
    public static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Copyable View Modifier

extension View {
    /// Adds a "Copy" context menu to any view. Use on widgets with discrete copyable values.
    public func copyable(_ text: @autoclosure @escaping () -> String) -> some View {
        self.contextMenu {
            Button {
                ClipboardHelper.copy(text())
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
