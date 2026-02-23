import Foundation

public struct BridgePaths {
    public static let appSupportDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MacVirtualMicBridge", isDirectory: true)
    }()

    public static let logsDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return base.appendingPathComponent("MacVirtualMicBridge", isDirectory: true)
    }()

    public static let configPath = appSupportDir.appendingPathComponent("config.json")
    public static let statusPath = appSupportDir.appendingPathComponent("status.json")
    public static let pidPath = appSupportDir.appendingPathComponent("daemon.pid")
    public static let daemonLogPath = logsDir.appendingPathComponent("daemon.log")
    public static let menubarLogPath = logsDir.appendingPathComponent("menubar.log")

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
}

public struct BridgeConfig: Codable, Equatable {
    public var sourceDeviceUID: String?
    public var targetDeviceUID: String?
    public var virtualMicrophoneName: String
    public var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case sourceDeviceUID
        case targetDeviceUID
        case virtualMicrophoneName
        case enabled
    }

    public init(
        sourceDeviceUID: String? = nil,
        targetDeviceUID: String? = nil,
        virtualMicrophoneName: String = "MicBridge Virtual Mic",
        enabled: Bool = true
    ) {
        self.sourceDeviceUID = sourceDeviceUID
        self.targetDeviceUID = targetDeviceUID
        self.virtualMicrophoneName = virtualMicrophoneName
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceDeviceUID = try container.decodeIfPresent(String.self, forKey: .sourceDeviceUID)
        targetDeviceUID = try container.decodeIfPresent(String.self, forKey: .targetDeviceUID)
        virtualMicrophoneName = try container.decodeIfPresent(String.self, forKey: .virtualMicrophoneName) ?? "MicBridge Virtual Mic"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sourceDeviceUID, forKey: .sourceDeviceUID)
        try container.encodeIfPresent(targetDeviceUID, forKey: .targetDeviceUID)
        try container.encode(virtualMicrophoneName, forKey: .virtualMicrophoneName)
        try container.encode(enabled, forKey: .enabled)
    }
}

public enum BridgeRuntimeState: String, Codable {
    case stopped
    case starting
    case running
    case restarting
    case error
}

public struct BridgeStatus: Codable {
    public var state: BridgeRuntimeState
    public var message: String
    public var sourceDeviceUID: String?
    public var targetDeviceUID: String?
    public var sampleRate: Double?
    public var channelCount: Int?
    public var updatedAtISO8601: String

    public init(
        state: BridgeRuntimeState,
        message: String,
        sourceDeviceUID: String? = nil,
        targetDeviceUID: String? = nil,
        sampleRate: Double? = nil,
        channelCount: Int? = nil
    ) {
        self.state = state
        self.message = message
        self.sourceDeviceUID = sourceDeviceUID
        self.targetDeviceUID = targetDeviceUID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.updatedAtISO8601 = ISO8601DateFormatter().string(from: Date())
    }
}

public final class BridgeConfigStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func load() throws -> BridgeConfig {
        try BridgePaths.ensureDirectories()

        if !FileManager.default.fileExists(atPath: BridgePaths.configPath.path) {
            let firstRunConfig = BridgeConfig()
            try save(firstRunConfig)
            return firstRunConfig
        }

        let data = try Data(contentsOf: BridgePaths.configPath)
        return try decoder.decode(BridgeConfig.self, from: data)
    }

    public func save(_ config: BridgeConfig) throws {
        try BridgePaths.ensureDirectories()
        let data = try encoder.encode(config)
        try data.write(to: BridgePaths.configPath, options: .atomic)
    }

    public func loadLastModificationDate() -> Date? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: BridgePaths.configPath.path),
            let date = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return date
    }
}

public final class BridgeStatusStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func save(_ status: BridgeStatus) {
        do {
            try BridgePaths.ensureDirectories()
            let data = try encoder.encode(status)
            try data.write(to: BridgePaths.statusPath, options: .atomic)
        } catch {
            fputs("[BridgeStatusStore] Failed to save status: \(error)\n", stderr)
        }
    }

    public func load() -> BridgeStatus? {
        guard
            let data = try? Data(contentsOf: BridgePaths.statusPath),
            let status = try? decoder.decode(BridgeStatus.self, from: data)
        else {
            return nil
        }
        return status
    }
}
