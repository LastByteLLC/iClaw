import Foundation

/// Sends user feedback to the backend API.
///
/// Endpoint: `POST {AppConfig.apiBaseURL}{AppConfig.feedbackEndpoint}`
/// Fire-and-forget — failures are logged but not surfaced to the user.
public actor FeedbackSender {
    public static let shared = FeedbackSender()

    private let session: URLSession

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    /// Sends feedback. Returns true on success (HTTP 201).
    public func send(summary: String, feedbackID: String) async -> Bool {
        guard !summary.isEmpty else { return false }

        guard let url = URL(string: AppConfig.apiBaseURL + AppConfig.feedbackEndpoint) else {
            Log.tools.error("Invalid feedback endpoint URL")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = AppConfig.networkRequestTimeout

        let body: [String: String] = [
            "message": String(summary.prefix(5000)),
            "category": "general",
            "app_version": Self.appVersion
        ]

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 201 {
                    Log.tools.info("Feedback submitted [\(feedbackID)]")
                    return true
                } else {
                    Log.tools.error("Feedback submission failed: HTTP \(http.statusCode)")
                    return false
                }
            }
            return false
        } catch {
            Log.tools.error("Feedback submission error: \(error.localizedDescription)")
            return false
        }
    }

    private static var appVersion: String { AppConfig.appVersion }
}
