import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Maps error messages to actionable fixes the user can take.
/// Patterns loaded from `Resources/Config/ErrorActions.json`.
enum ErrorActionResolver {
    private struct ErrorPattern: Decodable {
        let keywords: [String]
        let label: String
        let url: String
    }

    private struct ErrorActionsConfig: Decodable {
        let macOS: [ErrorPattern]
        let iOS: [ErrorPattern]
    }

    private static let patterns: [(keywords: [String], label: String, url: String)] = {
        guard let config = ConfigLoader.load("ErrorActions", as: ErrorActionsConfig.self) else { return [] }
        #if os(macOS)
        return config.macOS.map { (keywords: $0.keywords, label: $0.label, url: $0.url) }
        #else
        return config.iOS.map { entry in
            let url = entry.url == "app-settings:" ? UIApplication.openSettingsURLString : entry.url
            return (keywords: entry.keywords, label: entry.label, url: url)
        }
        #endif
    }()

    static func resolve(from message: String) -> ErrorAction? {
        let lower = message.lowercased()
        for pattern in patterns {
            if pattern.keywords.contains(where: { lower.contains($0) }) {
                return ErrorAction(label: pattern.label, urlString: pattern.url)
            }
        }
        return nil
    }
}
