import Darwin
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
    private static let ioQueue = DispatchQueue(label: "ch.hefti.macvirtualmicbridge.logger")
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private static let maxArchivedFiles: Int = 4

    private static let logFileURL: URL = {
        switch ProcessInfo.processInfo.processName {
        case "micbridge-daemon":
            return BridgePaths.daemonLogPath
        case "micbridge-menubar":
            return BridgePaths.menubarLogPath
        default:
            let sanitized = ProcessInfo.processInfo.processName.replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
            let fallbackName = sanitized.isEmpty ? "micbridge" : sanitized
            return BridgePaths.logsDir.appendingPathComponent("\(fallbackName).log")
        }
    }()

    private static let shouldMirrorToStdout: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["MICBRIDGE_LOG_STDOUT"] == "1" {
            return true
        }
        if env["MICBRIDGE_LOG_STDOUT"] == "0" {
            return false
        }
        return isatty(STDOUT_FILENO) != 0
    }()

    public static var isDebugEnabled = false

    public static func log(_ level: BridgeLogLevel, _ message: String) {
        if level == .debug && !isDebugEnabled {
            return
        }
        let line = "[\(formatter.string(from: Date()))] [\(level.rawValue)] \(message)"
        if shouldMirrorToStdout {
            print(line)
        }
        writeToFile("\(line)\n")
    }

    private static func writeToFile(_ line: String) {
        ioQueue.sync {
            do {
                try BridgePaths.ensureDirectories()
                guard let data = line.data(using: .utf8) else {
                    return
                }
                try rotateIfNeeded(nextWriteBytes: UInt64(data.count))
                try append(data: data)
            } catch {
                if shouldMirrorToStdout {
                    fputs("[BridgeLogger] Failed to write log file: \(error)\n", stderr)
                }
            }
        }
    }

    private static func append(data: Data) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: logFileURL)
        defer {
            handle.closeFile()
        }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private static func rotateIfNeeded(nextWriteBytes: UInt64) throws {
        let currentSize = (try? fileSize(of: logFileURL)) ?? 0
        guard currentSize + nextWriteBytes > maxFileBytes else {
            return
        }
        try rotateFiles()
    }

    private static func rotateFiles() throws {
        let fileManager = FileManager.default

        let oldestArchive = archivedLogURL(index: maxArchivedFiles)
        if fileManager.fileExists(atPath: oldestArchive.path) {
            try fileManager.removeItem(at: oldestArchive)
        }

        if maxArchivedFiles > 1 {
            for index in stride(from: maxArchivedFiles - 1, through: 1, by: -1) {
                let source = archivedLogURL(index: index)
                let destination = archivedLogURL(index: index + 1)
                if fileManager.fileExists(atPath: source.path) {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        }

        if fileManager.fileExists(atPath: logFileURL.path) {
            let firstArchive = archivedLogURL(index: 1)
            if fileManager.fileExists(atPath: firstArchive.path) {
                try fileManager.removeItem(at: firstArchive)
            }
            try fileManager.moveItem(at: logFileURL, to: firstArchive)
        }

        fileManager.createFile(atPath: logFileURL.path, contents: nil)
    }

    private static func archivedLogURL(index: Int) -> URL {
        URL(fileURLWithPath: "\(logFileURL.path).\(index)")
    }

    private static func fileSize(of fileURL: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs[.size] as? UInt64 ?? 0
    }
}
