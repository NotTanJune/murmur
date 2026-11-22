import OSLog

/// Loggers shared across the app, one category per subsystem area.
public enum Log {
    public static let audio = Logger(subsystem: "ai.pivotstudio.murmur", category: "audio")
    public static let speech = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")
    public static let performance = Logger(subsystem: "ai.pivotstudio.murmur", category: "performance")
    public static let performanceSignposter = OSSignposter(logger: performance)
    public static let hotkey = Logger(subsystem: "ai.pivotstudio.murmur", category: "hotkey")
    public static let inject = Logger(subsystem: "ai.pivotstudio.murmur", category: "inject")
    public static let app = Logger(subsystem: "ai.pivotstudio.murmur", category: "app")
}
