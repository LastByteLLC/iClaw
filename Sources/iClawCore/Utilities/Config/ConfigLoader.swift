import Foundation
import os

private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "ConfigLoader")

/// Loads JSON configuration files from `Resources/Config/` via `Bundle.iClawCore`.
///
/// Meta-harness support: when the `ICLAW_CONFIG_DIR` environment variable points
/// to a directory, any `{filename}.json` present there wins over the bundled
/// version. Missing files in the override dir fall back to the bundle. Reads
/// are uncached, so a candidate swap is just an env-var + process restart — no
/// rebuild. Writes to the override dir during a live process are not picked up
/// by already-loaded `static let shared` singletons.
enum ConfigLoader {
    /// Resolve the first readable URL for `filename.json`: override dir first,
    /// then bundle. Returns nil if neither source has it.
    private static func resolveURL(for filename: String) -> URL? {
        if let overrideDir = ProcessInfo.processInfo.environment["ICLAW_CONFIG_DIR"],
           !overrideDir.isEmpty {
            let candidate = URL(fileURLWithPath: overrideDir)
                .appendingPathComponent("\(filename).json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return Bundle.iClawCore.url(forResource: filename, withExtension: "json", subdirectory: "Config")
    }

    /// Load and decode a JSON file from the Config subdirectory.
    static func load<T: Decodable>(_ filename: String, as type: T.Type) -> T? {
        guard let url = resolveURL(for: filename) else {
            logger.error("Config file not found: \(filename).json")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read config file: \(filename).json at \(url.path)")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode \(filename).json: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load a JSON file as a string array.
    static func loadStringArray(_ filename: String) -> [String] {
        load(filename, as: [String].self) ?? []
    }

    /// Load a JSON file as a string-to-string dictionary.
    static func loadStringDict(_ filename: String) -> [String: String] {
        load(filename, as: [String: String].self) ?? [:]
    }
}
