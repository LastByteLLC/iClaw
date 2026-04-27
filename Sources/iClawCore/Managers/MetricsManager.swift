import MetricKit
import os

/// Manages MetricKit subscription for anonymous crash and performance data collection.
///
/// When enabled, receives `MXDiagnosticPayload` from the system and posts crash
/// diagnostics to `{AppConfig.apiBaseURL}{AppConfig.crashLogEndpoint}`.
/// Gated by the `sendAnonymousCrashData` user setting.
@MainActor
public final class MetricsManager: NSObject {
    public static let shared = MetricsManager()

    private override init() {
        super.init()
    }

    public func enable() {
        MXMetricManager.shared.add(self)
        Log.engine.debug("MetricKit subscriber enabled")
    }

    public func disable() {
        MXMetricManager.shared.remove(self)
        Log.engine.debug("MetricKit subscriber disabled")
    }
}

extension MetricsManager: MXMetricManagerSubscriber {
    nonisolated public func didReceive(_ payloads: [MXMetricPayload]) {
        Log.engine.debug("Received \(payloads.count) metric payload(s)")
    }

    nonisolated public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Log.engine.debug("Received \(payloads.count) diagnostic payload(s)")

        for payload in payloads {
            // Extract crash diagnostics
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                for crash in crashes {
                    var parts: [String] = ["App version: \(crash.applicationVersion)"]
                    if let memInfo = crash.virtualMemoryRegionInfo {
                        parts.append(memInfo)
                    }
                    let report = parts.joined(separator: "\n")
                    Task.detached {
                        await CrashLogSender.shared.send(report: report)
                    }
                }
            }

            // Also send the full JSON representation if available
            let jsonData = payload.jsonRepresentation()
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                Task.detached {
                    await CrashLogSender.shared.send(report: jsonString)
                }
            }
        }
    }
}

/// Fire-and-forget crash log sender.
///
/// Endpoint: `POST {AppConfig.apiBaseURL}{AppConfig.crashLogEndpoint}`
/// Failures are logged but never surfaced to the user.
actor CrashLogSender {
    static let shared = CrashLogSender()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(report: String) async {
        guard !report.isEmpty else { return }

        guard let url = URL(string: AppConfig.apiBaseURL + AppConfig.crashLogEndpoint) else {
            Log.engine.error("Invalid crash log endpoint URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = AppConfig.networkRequestTimeout

        let body: [String: String] = [
            "report": String(report.prefix(50000)),
            "app_version": Self.appVersion,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": Self.hardwareModel
        ]

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 201 {
                Log.engine.info("Crash log submitted (\(report.count) chars)")
            } else if let http = response as? HTTPURLResponse {
                Log.engine.error("Crash log submission failed: HTTP \(http.statusCode)")
            }
        } catch {
            Log.engine.error("Crash log submission error: \(error.localizedDescription)")
        }
    }

    private static var appVersion: String { AppConfig.appVersion }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
