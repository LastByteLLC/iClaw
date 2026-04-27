import Foundation

#if CONTINUITY_ENABLED

/// Represents a remote device discovered via CloudKit.
public struct RemoteDevice: Sendable, Identifiable {
    public let id: String  // deviceID (UUID string)
    public let deviceType: DeviceType
    public let availableTools: [String]
    public let lastHeartbeat: Date
    public let appVersion: String

    public enum DeviceType: String, Sendable, Codable {
        case mac
        case phone
    }

    /// Device is considered available if heartbeat was within the last 2 minutes.
    public var isAvailable: Bool {
        Date().timeIntervalSince(lastHeartbeat) < 120
    }

    public var displayName: String {
        switch deviceType {
        case .mac: return "Mac"
        case .phone: return "iPhone"
        }
    }
}

/// A request to execute a tool on a remote device.
public struct RemoteToolRequest: Sendable {
    public let requestID: String
    public let senderDeviceID: String
    public let targetDeviceID: String?  // nil = "any available"
    public let toolName: String
    public let input: String
    public let createdAt: Date

    public init(
        requestID: String = UUID().uuidString,
        senderDeviceID: String,
        targetDeviceID: String? = nil,
        toolName: String,
        input: String,
        createdAt: Date = Date()
    ) {
        self.requestID = requestID
        self.senderDeviceID = senderDeviceID
        self.targetDeviceID = targetDeviceID
        self.toolName = toolName
        self.input = input
        self.createdAt = createdAt
    }
}

/// The response from a remote tool execution.
public struct RemoteToolResponse: Sendable {
    public let requestID: String
    public let text: String
    public let status: StatusEnum
    public let widgetType: String?
    public let widgetDataJSON: String?
    public let hasFile: Bool
    public let fileURL: URL?

    public init(
        requestID: String,
        text: String,
        status: StatusEnum = .ok,
        widgetType: String? = nil,
        widgetDataJSON: String? = nil,
        hasFile: Bool = false,
        fileURL: URL? = nil
    ) {
        self.requestID = requestID
        self.text = text
        self.status = status
        self.widgetType = widgetType
        self.widgetDataJSON = widgetDataJSON
        self.hasFile = hasFile
        self.fileURL = fileURL
    }
}

/// Data for the RemoteFileListWidget.
public struct RemoteFileListWidgetData: Sendable {
    public let files: [RemoteFileEntry]
    public let sourceDevice: String

    public struct RemoteFileEntry: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let path: String
        public let size: Int64
        public let isTransferring: Bool

        public init(id: String = UUID().uuidString, name: String, path: String, size: Int64 = 0, isTransferring: Bool = false) {
            self.id = id
            self.name = name
            self.path = path
            self.size = size
            self.isTransferring = isTransferring
        }
    }

    public init(files: [RemoteFileEntry], sourceDevice: String) {
        self.files = files
        self.sourceDevice = sourceDevice
    }
}

#else

// MARK: - Stub types when Continuity is disabled at compile time

/// Stub RemoteDevice for compile-time compatibility.
public struct RemoteDevice: Sendable, Identifiable {
    public let id: String
    public enum DeviceType: String, Sendable, Codable { case mac, phone }
    public let deviceType: DeviceType
    public var displayName: String { "" }
    public var isAvailable: Bool { false }
    public var availableTools: [String] { [] }
}

/// Stub RemoteFileListWidgetData for WidgetOutput enum compatibility.
public struct RemoteFileListWidgetData: Sendable {
    public let files: [RemoteFileEntry]
    public let sourceDevice: String

    public struct RemoteFileEntry: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let path: String
        public let size: Int64
        public let isTransferring: Bool
    }

    public init(files: [RemoteFileEntry], sourceDevice: String) {
        self.files = files
        self.sourceDevice = sourceDevice
    }
}

#endif
