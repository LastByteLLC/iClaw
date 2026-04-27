#if CONTINUITY_ENABLED
import Foundation

/// A CoreTool that proxies execution to a remote device via CloudKit.
/// Created on-demand by the router when a remote device has the needed tool.
public struct RemoteToolProxy: CoreTool, Sendable {
    public let name: String
    public let schema: String
    public let isInternal = false
    public let category = CategoryEnum.async

    private let targetDeviceID: String?
    private let targetDeviceName: String
    private let query: String?

    public init(name: String, targetDeviceID: String? = nil, targetDeviceName: String = "remote device", query: String? = nil) {
        self.name = name
        self.schema = "Execute \(name) on \(targetDeviceName)"
        self.targetDeviceID = targetDeviceID
        self.targetDeviceName = targetDeviceName
        self.query = query
    }

    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await timed {
            let effectiveInput = (query?.isEmpty == false) ? query! : input

            Log.tools.info("RemoteToolProxy: Routing '\(self.name)' to \(self.targetDeviceName)")

            let response = try await ContinuityManager.shared.sendRequest(
                toolName: name,
                input: effectiveInput,
                targetDeviceID: targetDeviceID
            )

            return ToolIO(
                text: response.text,
                status: response.status,
                outputWidget: response.widgetType
            )
        }
    }
}
#endif
