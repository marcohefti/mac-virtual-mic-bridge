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

    print("Fixture validation passed (\(cases.count) assertions).")
}

do {
    try run()
} catch {
    fputs("Fixture validation failed: \(error)\n", stderr)
    exit(1)
}
