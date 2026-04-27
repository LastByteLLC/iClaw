import os

/// Structured logging categories for the iClaw app.
/// Replaces 107+ `print()` calls with proper os.Logger instances.
public enum Log {
    public static let engine     = Logger(subsystem: "com.geticlaw.iClaw", category: "engine")
    public static let router     = Logger(subsystem: "com.geticlaw.iClaw", category: "router")
    public static let tools      = Logger(subsystem: "com.geticlaw.iClaw", category: "tools")
    public static let model      = Logger(subsystem: "com.geticlaw.iClaw", category: "model")
    public static let bridge     = Logger(subsystem: "com.geticlaw.iClaw", category: "bridge")
    public static let ui         = Logger(subsystem: "com.geticlaw.iClaw", category: "ui")
    public static let classifier = Logger(subsystem: "com.geticlaw.iClaw", category: "classifier")
}
