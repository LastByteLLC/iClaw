import Foundation

/// Per-turn timing breakdown emitted at the end of each pipeline run.
public struct TurnPerformance: Sendable {
    public let totalMs: Double
    public let preprocessingMs: Double
    public let routingMs: Double
    public let extractionMs: Double
    public let executionMs: Double
    public let validationMs: Double
    public let finalizationMs: Double
    public let widgetMs: Double
    public let toolName: String?
    public let wasFollowUp: Bool
    public let wasReRouted: Bool
}

/// Real-time progress updates emitted by the ExecutionEngine during processing.
public enum ProgressUpdate: Sendable {
    case routing
    case executing(toolName: String, step: Int, totalSteps: Int)
    case retrying(toolName: String, reason: String)
    case processing(description: String)
    case finalizing
    case reactIteration(current: Int, total: Int)
    case planning
    case planStep(current: Int, total: Int, toolName: String)
    case chaining(fromTool: String, toTool: String)
    case performance(TurnPerformance)
}
