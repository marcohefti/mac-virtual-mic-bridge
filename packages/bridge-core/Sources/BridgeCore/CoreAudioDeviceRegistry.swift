import CoreAudio
import Foundation

public struct AudioDevice: Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    public let isAlive: Bool

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        inputChannels: Int,
        outputChannels: Int,
        nominalSampleRate: Double,
        isAlive: Bool
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isAlive = isAlive
    }

    public var isInputCandidate: Bool { inputChannels > 0 && isAlive }
    public var isOutputCandidate: Bool { outputChannels > 0 && isAlive }
}

public enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case notFound(String)
    case invalidState(String)

    public var description: String {
        switch self {
        case let .osStatus(status, context):
            let fourCC = fourCharacterCode(status)
            return "\(context) failed with OSStatus=\(status) (\(fourCC))"
        case let .notFound(message):
            return message
        case let .invalidState(message):
            return message
        }
    }

    private func fourCharacterCode(_ status: OSStatus) -> String {
        let bigEndian = CFSwapInt32HostToBig(UInt32(bitPattern: status))
        var chars = [
            Character(UnicodeScalar((bigEndian >> 24) & 0xff)!),
            Character(UnicodeScalar((bigEndian >> 16) & 0xff)!),
            Character(UnicodeScalar((bigEndian >> 8) & 0xff)!),
            Character(UnicodeScalar(bigEndian & 0xff)!)
        ]
        for index in chars.indices {
            if chars[index].asciiValue == nil {
                chars[index] = "?"
            }
        }
        return String(chars)
    }
}

@discardableResult
func checkOSStatus(_ status: OSStatus, _ context: String) throws -> OSStatus {
    guard status == noErr else {
        throw CoreAudioError.osStatus(status, context)
    }
    return status
}

public enum DeviceSelectionPolicy {
    public static func selectSourceDevice(
        configuredUID: String?,
        defaultInputUID: String?,
        devices: [AudioDevice]
    ) -> AudioDevice? {
        let inputs = devices
            .filter { $0.isInputCandidate }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !inputs.isEmpty else {
            return nil
        }

        if let configuredUID,
           let configured = inputs.first(where: { $0.uid == configuredUID })
        {
            return configured
        }

        if let defaultInputUID,
           let defaultInput = inputs.first(where: { $0.uid == defaultInputUID })
        {
            return defaultInput
        }

        return inputs.first
    }

    public static func selectTargetDevice(
        configuredUID: String?,
        preferredVirtualMicName: String?,
        devices: [AudioDevice]
    ) -> AudioDevice? {
        let outputs = devices
            .filter { $0.isOutputCandidate }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !outputs.isEmpty else {
            return nil
        }

        if let configuredUID,
           let configured = outputs.first(where: { $0.uid == configuredUID })
        {
            return configured
        }

        if let preferredVirtualMicName {
            let trimmed = preferredVirtualMicName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let exact = outputs.first(where: {
                    $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    return exact
                }
                if let contains = outputs.first(where: { $0.name.localizedCaseInsensitiveContains(trimmed) }) {
                    return contains
                }
            }
        }

        if let micBridgeUIDMatch = outputs.first(where: { $0.uid.hasPrefix("ch.hefti.micbridge.") }) {
            return micBridgeUIDMatch
        }

        if let micBridgeNameMatch = outputs.first(where: { $0.name.localizedCaseInsensitiveContains("MicBridge") }) {
            return micBridgeNameMatch
        }

        return outputs.first
    }
}

public enum CoreAudioDeviceRegistry {
    public static func allDevices() throws -> [AudioDevice] {
        let ids = try getSystemAudioObjectIDArray(selector: kAudioHardwarePropertyDevices)
        return try ids.compactMap { id in
            guard let uid = try getDeviceStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }

            let name = try getDeviceStringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Unknown Device"
            let inputChannels = try getChannelCount(deviceID: id, scope: kAudioDevicePropertyScopeInput)
            let outputChannels = try getChannelCount(deviceID: id, scope: kAudioDevicePropertyScopeOutput)
            let nominalSampleRate = try getDeviceFloat64Property(
                id: id,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            ) ?? 0
            let isAliveValue = try getDeviceUInt32Property(
                id: id,
                selector: kAudioDevicePropertyDeviceIsAlive,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            ) ?? 0

            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                inputChannels: inputChannels,
                outputChannels: outputChannels,
                nominalSampleRate: nominalSampleRate,
                isAlive: isAliveValue != 0
            )
        }
    }

    public static func findDevice(uid: String) throws -> AudioDevice {
        guard let device = try allDevices().first(where: { $0.uid == uid }) else {
            throw CoreAudioError.notFound("Audio device not found for UID: \(uid)")
        }
        return device
    }

    public static func findDefaultInputDevice() throws -> AudioDevice {
        guard let deviceID = try getSystemAudioObjectID(selector: kAudioHardwarePropertyDefaultInputDevice) else {
            throw CoreAudioError.notFound("Unable to resolve default input device")
        }

        guard let device = try allDevices().first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.notFound("Default input device id \(deviceID) missing from device list")
        }

        return device
    }

    public static func findLikelyVirtualTargetDevice(preferredName: String? = nil) throws -> AudioDevice? {
        try DeviceSelectionPolicy.selectTargetDevice(
            configuredUID: nil,
            preferredVirtualMicName: preferredName,
            devices: allDevices()
        )
    }

    public static func setNominalSampleRate(deviceID: AudioObjectID, rate: Double) throws {
        var newRate = rate
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &newRate
        )

        if status != noErr {
            BridgeLogger.log(.warning, "Could not set sample rate \(rate) on device \(deviceID), status=\(status)")
        }
    }
}

private func getSystemAudioObjectID(selector: AudioObjectPropertySelector) throws -> AudioObjectID? {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectHasProperty(systemObject, &address) else {
        return nil
    }

    var value: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)

    try checkOSStatus(
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &value),
        "AudioObjectGetPropertyData(system id: \(selector))"
    )

    return value
}

private func getSystemAudioObjectIDArray(selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    try checkOSStatus(
        AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(system ids: \(selector))"
    )

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = Array<AudioObjectID>(repeating: 0, count: count)

    try checkOSStatus(
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids),
        "AudioObjectGetPropertyData(system ids: \(selector))"
    )

    return ids
}

private func getDeviceStringProperty(id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectHasProperty(id, &address) else {
        return nil
    }

    var size = UInt32(MemoryLayout<CFString?>.size)
    var cfString: CFString?

    let status = withUnsafeMutablePointer(to: &cfString) { pointer -> OSStatus in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    if status != noErr {
        throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyData(string: \(selector))")
    }

    guard let cfString else { return nil }
    return cfString as String
}

private func getDeviceUInt32Property(
    id: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )

    guard AudioObjectHasProperty(id, &address) else {
        return nil
    }

    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)

    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    if status != noErr {
        throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyData(UInt32: \(selector))")
    }

    return value
}

private func getDeviceFloat64Property(
    id: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> Float64? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )

    guard AudioObjectHasProperty(id, &address) else {
        return nil
    }

    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)

    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    if status != noErr {
        throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyData(Float64: \(selector))")
    }

    return value
}

private func getChannelCount(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    try checkOSStatus(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(stream config)"
    )

    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }

    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw),
        "AudioObjectGetPropertyData(stream config)"
    )

    let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
    return audioBufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
}
