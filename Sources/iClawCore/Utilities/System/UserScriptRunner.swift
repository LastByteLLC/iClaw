#if os(macOS)
import Foundation
import os

/// Executes AppleScript via `NSUserAppleScriptTask`, which runs scripts from the
/// Application Scripts directory without requiring `com.apple.security.automation.apple-events`.
///
/// This enables sandboxed apps to send Apple Events to apps that lack `scripting-targets`
/// access groups in their sdef (e.g., Messages, Notes, System Events Appearance Suite).
/// Per-app TCC prompts appear on first use of each target app instead of a blanket prompt at launch.
public enum UserScriptRunner {

    // MARK: - Public

    /// Writes `source` to a temporary `.applescript` file in the Application Scripts directory,
    /// executes it via `NSUserAppleScriptTask`, and returns the result string.
    public static func run(_ source: String) async throws -> String {
        let scriptsDir = try scriptsDirectory()
        let scriptURL = scriptsDir.appendingPathComponent(UUID().uuidString + ".applescript")

        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let task = try NSUserAppleScriptTask(url: scriptURL)
        // Extract stringValue inside the callback to avoid sending non-Sendable
        // NSAppleEventDescriptor across isolation boundaries.
        let output: String = try await withCheckedThrowingContinuation { continuation in
            task.execute(withAppleEvent: nil) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result?.stringValue ?? "Success.")
                }
            }
        }
        return output
    }

    /// Removes stale `.applescript` files left behind by interrupted executions.
    /// Call once at launch (best-effort, non-fatal).
    public static func cleanupStaleScripts() {
        guard let dir = try? scriptsDirectory() else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour
        for url in contents where url.pathExtension == "applescript" {
            if let creation = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               creation < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Private

    private static func scriptsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
#endif
