#if CONTINUITY_ENABLED
import Foundation
import CloudKit

/// Manages cross-device communication via CloudKit private database.
/// Handles device registration, heartbeat, and remote tool request/response flow.
public actor ContinuityManager {
    public static let shared = ContinuityManager()

    private var _container: CKContainer?
    private var container: CKContainer {
        if let existing = _container { return existing }
        let c = CKContainer(identifier: "iCloud.com.geticlaw.iClaw")
        _container = c
        return c
    }
    private var database: CKDatabase { container.privateCloudDatabase }

    private var deviceID: String
    private var heartbeatTask: Task<Void, Never>?
    private var subscriptionCreated = false

    /// Whether continuity is enabled by the user.
    /// Continuity disabled — coming soon. Always returns false until feature is ready.
    @MainActor public static var isEnabled: Bool {
        get { false }
        set { UserDefaults.standard.set(newValue, forKey: AppConfig.continuityEnabledKey) }
    }

    /// Currently discovered remote devices.
    public private(set) var availableDevices: [RemoteDevice] = []

    /// Pending response continuations keyed by requestID.
    /// When a ToolResponse notification arrives, the matching continuation is resumed.
    private var responseContinuations: [String: CheckedContinuation<RemoteToolResponse, Error>] = [:]

    private init() {
        // Persist device ID across launches
        if let stored = UserDefaults.standard.string(forKey: AppConfig.continuityDeviceIDKey) {
            self.deviceID = stored
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: AppConfig.continuityDeviceIDKey)
            self.deviceID = newID
        }
    }

    // MARK: - Lifecycle

    /// Start continuity services: register device, start heartbeat, subscribe to requests.
    public func start() async {
        guard await Self.isEnabled else { return }

        await registerDevice()
        startHeartbeat()
        await createSubscription()
        await refreshDevices()
    }

    /// Stop all continuity services.
    public func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Device Registration

    private func registerDevice() async {
        let record = CKRecord(recordType: "Device", recordID: CKRecord.ID(recordName: deviceID))
        record["deviceID"] = deviceID
        #if os(macOS)
        record["deviceType"] = "mac"
        #else
        record["deviceType"] = "phone"
        #endif
        record["availableTools"] = ToolRegistry.allToolNames as NSArray
        record["lastHeartbeat"] = Date() as NSDate
        record["appVersion"] = AppConfig.appVersion as NSString

        do {
            try await database.save(record)
            Log.engine.info("Continuity: Device registered [\(self.deviceID)]")
        } catch {
            Log.engine.error("Continuity: Failed to register device: \(error)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [deviceID] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard !Task.isCancelled else { break }

                let recordID = CKRecord.ID(recordName: deviceID)
                do {
                    let record = try await self.database.record(for: recordID)
                    record["lastHeartbeat"] = Date() as NSDate
                    try await self.database.save(record)
                } catch {
                    Log.engine.error("Continuity: Heartbeat failed: \(error)")
                }
            }
        }
    }

    // MARK: - Device Discovery

    /// Refreshes the list of available remote devices.
    public func refreshDevices() async {
        let query = CKQuery(recordType: "Device", predicate: NSPredicate(format: "deviceID != %@", deviceID))
        query.sortDescriptors = [NSSortDescriptor(key: "lastHeartbeat", ascending: false)]

        do {
            let (results, _) = try await database.records(matching: query)
            availableDevices = results.compactMap { _, result in
                guard let record = try? result.get() else { return nil }
                return RemoteDevice(
                    id: record["deviceID"] as? String ?? "",
                    deviceType: RemoteDevice.DeviceType(rawValue: record["deviceType"] as? String ?? "mac") ?? .mac,
                    availableTools: record["availableTools"] as? [String] ?? [],
                    lastHeartbeat: record["lastHeartbeat"] as? Date ?? .distantPast,
                    appVersion: record["appVersion"] as? String ?? "?"
                )
            }.filter { $0.isAvailable }
        } catch {
            Log.engine.error("Continuity: Device discovery failed: \(error)")
        }
    }

    // MARK: - Send Request

    /// Sends a tool execution request to a remote device and waits for the response.
    /// - Parameters:
    ///   - toolName: The tool to execute remotely.
    ///   - input: The input for the tool.
    ///   - targetDeviceID: Specific device ID, or nil for any available.
    /// - Returns: The remote tool response.
    public func sendRequest(toolName: String, input: String, targetDeviceID: String? = nil) async throws -> RemoteToolResponse {
        let request = RemoteToolRequest(
            senderDeviceID: deviceID,
            targetDeviceID: targetDeviceID,
            toolName: toolName,
            input: input
        )

        let record = CKRecord(recordType: "ToolRequest")
        record["requestID"] = request.requestID
        record["senderDeviceID"] = request.senderDeviceID
        record["targetDeviceID"] = request.targetDeviceID ?? "any"
        record["toolName"] = request.toolName
        record["input"] = request.input
        record["status"] = "pending"
        record["createdAt"] = request.createdAt as NSDate

        try await database.save(record)
        Log.engine.info("Continuity: Sent request [\(request.requestID)] for \(toolName)")

        // Wait for response via push notification (CKQuerySubscription on ToolResponse).
        // The subscription fires handleIncomingResponse which resumes the continuation.
        // Falls back to timeout after 30s.
        return try await withThrowingTaskGroup(of: RemoteToolResponse.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.registerResponseContinuation(requestID: request.requestID, continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw ContinuityError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            await removeResponseContinuation(requestID: request.requestID)
            return result
        }
    }

    // MARK: - Handle Incoming Requests

    /// Processes a tool request targeted at this device.
    public func handleIncomingRequest(record: CKRecord) async {
        guard let toolName = record["toolName"] as? String,
              let input = record["input"] as? String,
              let requestID = record["requestID"] as? String else { return }

        Log.engine.info("Continuity: Handling request [\(requestID)] for \(toolName)")

        // Update status to processing
        record["status"] = "processing"
        _ = try? await database.save(record)

        // Execute locally
        await RemoteToolExecutor.shared.execute(
            requestID: requestID,
            toolName: toolName,
            input: input,
            database: database
        )
    }

    // MARK: - Response Continuation Management

    private func registerResponseContinuation(requestID: String, continuation: CheckedContinuation<RemoteToolResponse, Error>) {
        responseContinuations[requestID] = continuation
    }

    private func removeResponseContinuation(requestID: String) {
        responseContinuations.removeValue(forKey: requestID)
    }

    /// Called when a ToolResponse notification arrives (via CKQuerySubscription push).
    public func handleIncomingResponse(record: CKRecord) {
        guard let requestID = record["requestID"] as? String else { return }

        var fileURL: URL? = nil
        if let asset = record["fileAsset"] as? CKAsset {
            fileURL = asset.fileURL
        }

        let response = RemoteToolResponse(
            requestID: requestID,
            text: record["text"] as? String ?? "",
            status: StatusEnum(rawValue: record["status"] as? String ?? "ok") ?? .ok,
            widgetType: record["widgetType"] as? String,
            widgetDataJSON: record["widgetDataJSON"] as? String,
            hasFile: record["hasFile"] as? Bool ?? false,
            fileURL: fileURL
        )

        if let continuation = responseContinuations.removeValue(forKey: requestID) {
            continuation.resume(returning: response)
            Log.engine.info("Continuity: Response received for [\(requestID)] via push")
        }
    }

    // MARK: - Subscriptions

    private func createSubscription() async {
        guard !subscriptionCreated else { return }

        // Subscribe to incoming tool requests targeted at this device
        let requestPredicate = NSPredicate(format: "targetDeviceID == %@ OR targetDeviceID == %@", deviceID, "any")
        let requestSubscriptionID = "continuity-request-\(deviceID)"
        let requestSubscription = CKQuerySubscription(
            recordType: "ToolRequest",
            predicate: requestPredicate,
            subscriptionID: requestSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        let requestInfo = CKSubscription.NotificationInfo()
        requestInfo.shouldSendContentAvailable = true
        requestSubscription.notificationInfo = requestInfo

        // Subscribe to tool responses for requests sent by this device
        let responsePredicate = NSPredicate(format: "senderDeviceID == %@", deviceID)
        let responseSubscriptionID = "continuity-response-\(deviceID)"
        let responseSubscription = CKQuerySubscription(
            recordType: "ToolResponse",
            predicate: responsePredicate,
            subscriptionID: responseSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        let responseInfo = CKSubscription.NotificationInfo()
        responseInfo.shouldSendContentAvailable = true
        responseSubscription.notificationInfo = responseInfo

        do {
            try await database.save(requestSubscription)
            try await database.save(responseSubscription)
            subscriptionCreated = true
            Log.engine.info("Continuity: Subscriptions created (request + response)")
        } catch {
            Log.engine.error("Continuity: Subscription failed: \(error)")
        }
    }

    // MARK: - Errors

    public enum ContinuityError: Error, LocalizedError {
        case timeout
        case cancelled
        case deviceUnavailable

        public var errorDescription: String? {
            switch self {
            case .timeout: return "Remote device did not respond within 30 seconds."
            case .cancelled: return "Remote request was cancelled."
            case .deviceUnavailable: return "No remote device is available."
            }
        }
    }
}
#endif
