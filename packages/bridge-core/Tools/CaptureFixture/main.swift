import BridgeCore
import Foundation

private struct FixtureDevice: Codable {
    let id: UInt32
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double
    let isAlive: Bool
}

private enum CaptureError: Error, CustomStringConvertible {
    case usage
    case emptyOutputPath

    var description: String {
        switch self {
        case .usage:
            return "Usage: micbridge-capture-fixture <output-json-path>"
        case .emptyOutputPath:
            return "Output path cannot be empty."
        }
    }
}

private func normalizeSampleRate(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

private func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 1 else {
        throw CaptureError.usage
    }

    let outputPath = args[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !outputPath.isEmpty else {
        throw CaptureError.emptyOutputPath
    }

    let devices = try CoreAudioDeviceRegistry.allDevices()
        .sorted { lhs, rhs in
            lhs.uid.localizedCaseInsensitiveCompare(rhs.uid) == .orderedAscending
        }

    let fixture = devices.enumerated().map { index, device in
        FixtureDevice(
            id: UInt32(index + 1),
            uid: device.uid,
            name: device.name,
            inputChannels: device.inputChannels,
            outputChannels: device.outputChannels,
            nominalSampleRate: normalizeSampleRate(device.nominalSampleRate),
            isAlive: device.isAlive
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(fixture)

    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: outputURL, options: .atomic)

    print("Captured \(fixture.count) devices -> \(outputURL.path)")
}

do {
    try run()
} catch {
    fputs("Fixture capture failed: \(error)\n", stderr)
    exit(1)
}
