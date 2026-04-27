#if CONTINUITY_ENABLED
import Foundation
import CloudKit

/// Executes tool requests received from remote devices and writes back responses.
public actor RemoteToolExecutor {
    public static let shared = RemoteToolExecutor()

    /// Executes a tool locally and writes the response to CloudKit.
    public func execute(requestID: String, toolName: String, input: String, database: CKDatabase) async {
        let tools = ToolRegistry.coreTools
        guard let tool = tools.first(where: { $0.name.lowercased() == toolName.lowercased() }) else {
            await writeResponse(
                requestID: requestID,
                text: "Tool '\(toolName)' not found on this device.",
                status: .error,
                database: database
            )
            return
        }

        do {
            let result = try await tool.execute(input: input, entities: nil)
            await writeResponse(
                requestID: requestID,
                text: result.text,
                status: result.status,
                widgetType: result.outputWidget,
                database: database
            )
        } catch {
            await writeResponse(
                requestID: requestID,
                text: "Remote execution failed: \(error.localizedDescription)",
                status: .error,
                database: database
            )
        }
    }

    private func writeResponse(
        requestID: String,
        text: String,
        status: StatusEnum,
        widgetType: String? = nil,
        widgetDataJSON: String? = nil,
        fileURL: URL? = nil,
        database: CKDatabase
    ) async {
        let record = CKRecord(recordType: "ToolResponse")
        record["requestID"] = requestID
        record["text"] = text
        record["status"] = status.rawValue
        record["widgetType"] = widgetType
        record["widgetDataJSON"] = widgetDataJSON
        record["hasFile"] = fileURL != nil

        if let url = fileURL {
            record["fileAsset"] = CKAsset(fileURL: url)
        }

        do {
            try await database.save(record)
            Log.engine.info("Continuity: Response written for [\(requestID)]")
        } catch {
            Log.engine.error("Continuity: Failed to write response: \(error)")
        }
    }
}
#endif
