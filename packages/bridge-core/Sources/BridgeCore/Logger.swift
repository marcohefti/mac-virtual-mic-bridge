import Foundation

public enum BridgeLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public enum BridgeLogger {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static var isDebugEnabled = false

    public static func log(_ level: BridgeLogLevel, _ message: String) {
        if level == .debug && !isDebugEnabled {
            return
        }
        let line = "[\(formatter.string(from: Date()))] [\(level.rawValue)] \(message)"
        print(line)
    }
}
