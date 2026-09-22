import BridgeCore
import CoreAudio
import Foundation

private struct FixtureDevice: Decodable {
    let id: UInt32
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double
    let isAlive: Bool

    func asAudioDevice() -> AudioDevice {
        AudioDevice(
            id: AudioObjectID(id),
            uid: uid,
            name: name,
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            nominalSampleRate: nominalSampleRate,
            isAlive: isAlive
        )
    }
}

private enum ValidationCaseKind: String, Decodable {
    case source
    case target
}

private struct ValidationCase: Decodable {
    let name: String
    let fixture: String
    let kind: ValidationCaseKind
    let configuredUID: String?
    let defaultInputUID: String?
    let preferredVirtualMicName: String?
    let expectedUID: String?
}

private enum ValidationFailure: Error, CustomStringConvertible {
    case rootNotFound
    case fixtureMissing(String)
    case validationCasesMissing(String)
    case expectationFailed(String)

    var description: String {
        switch self {
        case .rootNotFound:
            return "Could not resolve repo root (Package.swift not found)."
        case let .fixtureMissing(path):
            return "Fixture file missing: \(path)"
        case let .validationCasesMissing(path):
            return "Validation case file missing: \(path)"
        case let .expectationFailed(message):
            return message
        }
    }
}

private func resolveRepoRoot() throws -> URL {
    if let envRoot = ProcessInfo.processInfo.environment["MICBRIDGE_REPO_ROOT"], !envRoot.isEmpty {
        return URL(fileURLWithPath: envRoot, isDirectory: true)
    }

    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
            return current
        }
        current.deleteLastPathComponent()
    }

    throw ValidationFailure.rootNotFound
}

private func loadFixture(_ filename: String, repoRoot: URL) throws -> [AudioDevice] {
    let url = repoRoot.appendingPathComponent("packages/bridge-core/fixtures/\(filename).json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ValidationFailure.fixtureMissing(url.path)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([FixtureDevice].self, from: data).map { $0.asAudioDevice() }
}

private func loadValidationCases(repoRoot: URL) throws -> [ValidationCase] {
    let url = repoRoot.appendingPathComponent("packages/bridge-core/fixtures/validation_cases.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ValidationFailure.validationCasesMissing(url.path)
    }

    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([ValidationCase].self, from: data)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ValidationFailure.expectationFailed(message)
    }
}

private func run() throws {
    let repoRoot = try resolveRepoRoot()
    let cases = try loadValidationCases(repoRoot: repoRoot)
    var fixtureCache: [String: [AudioDevice]] = [:]

    for testCase in cases {
        let devices: [AudioDevice]
        if let cached = fixtureCache[testCase.fixture] {
            devices = cached
        } else {
            let loaded = try loadFixture(testCase.fixture, repoRoot: repoRoot)
            fixtureCache[testCase.fixture] = loaded
            devices = loaded
        }

        let selected: AudioDevice?
        switch testCase.kind {
        case .source:
            selected = DeviceSelectionPolicy.selectSourceDevice(
                configuredUID: testCase.configuredUID,
                defaultInputUID: testCase.defaultInputUID,
                devices: devices
            )
        case .target:
            selected = DeviceSelectionPolicy.selectTargetDevice(
                configuredUID: testCase.configuredUID,
                preferredVirtualMicName: testCase.preferredVirtualMicName,
                devices: devices
            )
        }

        if let expectedUID = testCase.expectedUID {
            try expect(
                selected?.uid == expectedUID,
                "[\(testCase.name)] expected UID \(expectedUID), got \(selected?.uid ?? "nil")"
            )
        } else {
            try expect(
                selected == nil,
                "[\(testCase.name)] expected nil result, got \(selected?.uid ?? "nil")"
            )
        }
    }

    var healthy = RecoveryHealth()
    for tick in 1...20 {
        try expect(healthy.evaluate(input: UInt64(tick), output: UInt64(tick), errors: 0,
            sourcePeak: 0, deliveredPeak: 0) == nil, "Quiet microphone must remain healthy")
    }
    for _ in 0..<2 { _ = healthy.evaluate(input: 20, output: 20, errors: 0, sourcePeak: 0, deliveredPeak: 0) }
    try expect(healthy.evaluate(input: 20, output: 20, errors: 0, sourcePeak: 0, deliveredPeak: 0) != nil,
        "Stalled callbacks must request recovery")
    var silence = RecoveryHealth()
    for tick in 1...2 { _ = silence.evaluate(input: UInt64(tick), output: UInt64(tick), errors: 0,
        sourcePeak: 0.2, deliveredPeak: 0) }
    try expect(silence.evaluate(input: 3, output: 3, errors: 0, sourcePeak: 0.2, deliveredPeak: 0) != nil,
        "Silent virtual delivery must request recovery even with advancing callbacks")
    var errorHealth = RecoveryHealth()
    try expect(errorHealth.evaluate(input: 1, output: 1, errors: 1, sourcePeak: 0, deliveredPeak: 0) != nil,
        "Render errors must request recovery")
    let legacyConfig = try JSONDecoder().decode(BridgeConfig.self, from: Data("{}".utf8))
    try expect(legacyConfig.sourceInputChannel == 1, "Legacy configuration must default to input 1")
    let channelConfig = BridgeConfig(sourceInputChannel: 2)
    let decodedConfig = try JSONDecoder().decode(BridgeConfig.self, from: JSONEncoder().encode(channelConfig))
    try expect(decodedConfig == channelConfig, "Input channel must survive a config round trip")
    for selectedChannel in [1, 2, 12] {
        let route = try InputChannelSelection(channel: selectedChannel, sourceChannels: 12)
        let input = (0..<36).map { Float($0 + 1) / 100 }
        for targetChannels in [1, 2] {
            var output = [Float](repeating: -1, count: 3 * targetChannels)
            input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    route.copy(from: src.baseAddress!, to: dst.baseAddress!, frameCount: 3, targetChannels: targetChannels)
                }
            }
            for frame in 0..<3 {
                for target in 0..<targetChannels {
                    try expect(output[frame * targetChannels + target] == input[frame * 12 + selectedChannel - 1],
                               "Input \(selectedChannel) must pass through at unity gain without mixing other inputs")
                }
            }
        }
    }
    for channel in [0, 13] {
        var rejected = false
        do { _ = try InputChannelSelection(channel: channel, sourceChannels: 12) }
        catch { rejected = true }
        try expect(rejected, "Unavailable input channel must fail instead of silently selecting another input")
    }

    // Reproduce a live producer getting ahead of its consumer, then a stalled reader.
    // These sample ramps also check that recovery keeps recent audio in order.
    for queuedFrames in [5632, 8192, 48000] {
        let ring = PCMFloatRingBuffer(channels: 1, capacityFrames: 48000)
        let samples = (0..<queuedFrames).map { Float($0) }
        samples.withUnsafeBufferPointer { _ = ring.write(from: $0.baseAddress!, frameCount: queuedFrames) }
        let dropped = ring.discardExcessLatency(sampleRate: 48000, callbackFrames: 512)
        try expect(ring.fillLevelFrames() <= 1920, "Latency backlog \(queuedFrames) was not bounded to 40 ms")
        var output = [Float](repeating: 0, count: 512)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frameCount: 512) }
        try expect(read == 512 && output[0] == Float(dropped) && output[511] == Float(dropped + 511),
                   "Latency recovery corrupted or reordered audio")
    }
    for callbackFrames in [64, 256, 512, 2048] {
        let ring = PCMFloatRingBuffer(channels: 2, capacityFrames: 48000)
        let samples = [Float](repeating: 0.25, count: callbackFrames * 2)
        samples.withUnsafeBufferPointer { _ = ring.write(from: $0.baseAddress!, frameCount: callbackFrames) }
        try expect(ring.discardExcessLatency(sampleRate: 48000, callbackFrames: callbackFrames) == 0,
                   "Normal callback audio must not be dropped")
        try expect(ring.fillLevelFrames() == callbackFrames, "Normal callback was truncated")
    }

    // Signal diagnostics must distinguish captured audio from an empty consumer
    // and must not retain a previous session's nonzero level after restart.
    let signalRing = PCMFloatRingBuffer(channels: 1, capacityFrames: 8)
    let signal: [Float] = [-0.75, 0.25]
    signal.withUnsafeBufferPointer { _ = signalRing.write(from: $0.baseAddress!, frameCount: 2) }
    try expect(signalRing.signalPeaks().input == 0.75 && signalRing.signalPeaks().output == 0,
               "Signal diagnostics must distinguish producer from consumer")
    var signalOutput = [Float](repeating: 0, count: 2)
    signalOutput.withUnsafeMutableBufferPointer { _ = signalRing.read(into: $0.baseAddress!, frameCount: 2) }
    try expect(signalRing.signalPeaks().output == 0.75 && signalOutput == signal,
               "Signal metering must preserve samples and include negative peaks")
    signalRing.clear()
    try expect(signalRing.signalPeaks().input == 0 && signalRing.signalPeaks().output == 0,
               "Restart must clear stale signal levels")

    // Exercise wraparound and a long consumer pause: the next read must contain
    // recent speech, not the oldest audio retained when the allocation filled.
    let liveRing = PCMFloatRingBuffer(channels: 1, capacityFrames: 48000)
    var totalFrames = 0
    for _ in 0..<400 {
        let samples = (totalFrames..<(totalFrames + 512)).map { Float($0) }
        samples.withUnsafeBufferPointer { _ = liveRing.write(from: $0.baseAddress!, frameCount: 512) }
        liveRing.discardExcessLatency(sampleRate: 48000, callbackFrames: 512)
        totalFrames += 512
    }
    var recent = [Float](repeating: 0, count: 512)
    let recovered = recent.withUnsafeMutableBufferPointer { liveRing.read(into: $0.baseAddress!, frameCount: 512) }
    try expect(recovered == 512 && recent[0] >= Float(totalFrames - 1920),
               "Consumer resumed with stale speech after wraparound")
    try expect(recent[511] == recent[0] + 511, "Wrapped audio is not contiguous")

    print("Fixture validation passed (\(cases.count) device scenarios, channel routing checks, and 16 latency assertions).")
}

do {
    try run()
} catch {
    fputs("Fixture validation failed: \(error)\n", stderr)
    exit(1)
}
