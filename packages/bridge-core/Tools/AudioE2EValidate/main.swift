import AudioToolbox
import BridgeCore
import CoreAudio
import Foundation

private struct ValidationConfig {
    let injectOutputUID: String
    let captureInputUID: String
    let sampleRate: Double
    let frequencyHz: Double
    let amplitude: Float
    let preRollSeconds: Double
    let toneSeconds: Double
    let postRollSeconds: Double
    let extraCaptureSeconds: Double
    let probeFrames: Int
    let coarseStepFrames: Int
    let minCaptureRMS: Double
    let minCorrelation: Double
    let maxErrorRatio: Double

    static let defaults = ValidationConfig(
        injectOutputUID: "",
        captureInputUID: "",
        sampleRate: 48_000,
        frequencyHz: 997,
        amplitude: 0.20,
        preRollSeconds: 0.25,
        toneSeconds: 0.25,
        postRollSeconds: 0.75,
        extraCaptureSeconds: 3.00,
        probeFrames: 4096,
        coarseStepFrames: 32,
        minCaptureRMS: 0.002,
        minCorrelation: 0.70,
        maxErrorRatio: 0.45
    )
}

private enum ValidationError: Error, CustomStringConvertible {
    case usage(String)
    case invalidArgument(String)
    case invalidState(String)
    case osStatus(OSStatus, String)

    var description: String {
        switch self {
        case let .usage(message):
            return message
        case let .invalidArgument(message):
            return "Invalid argument: \(message)"
        case let .invalidState(message):
            return "Invalid state: \(message)"
        case let .osStatus(status, context):
            let fourCC = fourCharacterCode(status)
            return "\(context) failed with OSStatus=\(status) (\(fourCC))"
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
        for index in chars.indices where chars[index].asciiValue == nil {
            chars[index] = "?"
        }
        return String(chars)
    }
}

@discardableResult
private func check(_ status: OSStatus, _ context: String) throws -> OSStatus {
    guard status == noErr else {
        throw ValidationError.osStatus(status, context)
    }
    return status
}

private func parseArguments() throws -> ValidationConfig {
    var cfg = ValidationConfig.defaults
    var index = 1
    let args = CommandLine.arguments

    func requireValue(_ flag: String) throws -> String {
        guard index + 1 < args.count else {
            throw ValidationError.usage("Missing value for \(flag)")
        }
        index += 1
        return args[index]
    }

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--inject-output-uid":
            cfg = ValidationConfig(
                injectOutputUID: try requireValue(arg),
                captureInputUID: cfg.captureInputUID,
                sampleRate: cfg.sampleRate,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--capture-input-uid":
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: try requireValue(arg),
                sampleRate: cfg.sampleRate,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--sample-rate":
            guard let value = Double(try requireValue(arg)), value >= 8_000 else {
                throw ValidationError.invalidArgument("sample-rate must be >= 8000")
            }
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: cfg.captureInputUID,
                sampleRate: value,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--frequency-hz":
            guard let value = Double(try requireValue(arg)), value > 0 else {
                throw ValidationError.invalidArgument("frequency-hz must be > 0")
            }
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: cfg.captureInputUID,
                sampleRate: cfg.sampleRate,
                frequencyHz: value,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--tone-seconds":
            guard let value = Double(try requireValue(arg)), value > 0.05 else {
                throw ValidationError.invalidArgument("tone-seconds must be > 0.05")
            }
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: cfg.captureInputUID,
                sampleRate: cfg.sampleRate,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: value,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--min-capture-rms":
            guard let value = Double(try requireValue(arg)), value >= 0 else {
                throw ValidationError.invalidArgument("min-capture-rms must be >= 0")
            }
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: cfg.captureInputUID,
                sampleRate: cfg.sampleRate,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: value,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--min-correlation":
            guard let value = Double(try requireValue(arg)), value >= 0, value <= 1 else {
                throw ValidationError.invalidArgument("min-correlation must be in [0,1]")
            }
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: cfg.captureInputUID,
                sampleRate: cfg.sampleRate,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: value,
                maxErrorRatio: cfg.maxErrorRatio
            )
        case "--max-error-ratio":
            guard let value = Double(try requireValue(arg)), value >= 0 else {
                throw ValidationError.invalidArgument("max-error-ratio must be >= 0")
            }
            cfg = ValidationConfig(
                injectOutputUID: cfg.injectOutputUID,
                captureInputUID: cfg.captureInputUID,
                sampleRate: cfg.sampleRate,
                frequencyHz: cfg.frequencyHz,
                amplitude: cfg.amplitude,
                preRollSeconds: cfg.preRollSeconds,
                toneSeconds: cfg.toneSeconds,
                postRollSeconds: cfg.postRollSeconds,
                extraCaptureSeconds: cfg.extraCaptureSeconds,
                probeFrames: cfg.probeFrames,
                coarseStepFrames: cfg.coarseStepFrames,
                minCaptureRMS: cfg.minCaptureRMS,
                minCorrelation: cfg.minCorrelation,
                maxErrorRatio: value
            )
        case "--help", "-h":
            throw ValidationError.usage(usageText())
        default:
            throw ValidationError.usage("Unknown flag: \(arg)\n\n\(usageText())")
        }
        index += 1
    }

    guard !cfg.injectOutputUID.isEmpty else {
        throw ValidationError.usage("Missing required --inject-output-uid\n\n\(usageText())")
    }
    guard !cfg.captureInputUID.isEmpty else {
        throw ValidationError.usage("Missing required --capture-input-uid\n\n\(usageText())")
    }

    return cfg
}

private func usageText() -> String {
    """
    Usage: micbridge-audio-e2e-validate --inject-output-uid <uid> --capture-input-uid <uid> [options]

    Required:
      --inject-output-uid <uid>   Output device UID used for tone injection (for example BlackHole2ch_UID).
      --capture-input-uid <uid>   Input device UID used for capture (for example ch.hefti.micbridge.virtualmic.device).

    Optional:
      --sample-rate <hz>          Default: 48000
      --frequency-hz <hz>         Default: 997
      --tone-seconds <seconds>    Default: 0.25
      --min-capture-rms <value>   Default: 0.002
      --min-correlation <value>   Default: 0.70
      --max-error-ratio <value>   Default: 0.45
    """
}

private func makePCMFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func setUnitProperty<T>(
    _ unit: AudioUnit,
    _ property: AudioUnitPropertyID,
    _ scope: AudioUnitScope,
    _ element: AudioUnitElement,
    _ value: inout T
) throws {
    let status = withUnsafePointer(to: &value) { pointer -> OSStatus in
        AudioUnitSetProperty(
            unit,
            property,
            scope,
            element,
            pointer,
            UInt32(MemoryLayout<T>.size)
        )
    }
    try check(status, "AudioUnitSetProperty(\(property))")
}

private final class ToneOutputUnit {
    private let sampleRate: Double
    private let preRollFrames: Int
    private let postRollFrames: Int
    private let channelCount: Int
    private let maxFramesPerSlice: UInt32
    private let signalFrames: [Float]

    private var unit: AudioUnit?
    private var frameCursor = 0
    private var frameScratch: UnsafeMutablePointer<Float>

    init(
        sampleRate: Double,
        signalFrames: [Float],
        preRollFrames: Int,
        postRollFrames: Int,
        channelCount: Int,
        maxFramesPerSlice: UInt32 = 2048
    ) {
        self.sampleRate = sampleRate
        self.signalFrames = signalFrames
        self.preRollFrames = preRollFrames
        self.postRollFrames = postRollFrames
        self.channelCount = channelCount
        self.maxFramesPerSlice = maxFramesPerSlice
        self.frameScratch = .allocate(capacity: Int(maxFramesPerSlice))
        self.frameScratch.initialize(repeating: 0, count: Int(maxFramesPerSlice))
    }

    deinit {
        stop()
        frameScratch.deinitialize(count: Int(maxFramesPerSlice))
        frameScratch.deallocate()
    }

    func configure(outputDeviceID: AudioDeviceID) throws {
        stop()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw ValidationError.invalidState("HAL output component not found for tone injector")
        }

        var localUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &localUnit), "AudioComponentInstanceNew(tone output)")
        guard let localUnit else {
            throw ValidationError.invalidState("AudioComponentInstanceNew returned nil for tone injector")
        }

        var enableOutput: UInt32 = 1
        var disableInput: UInt32 = 0
        var deviceID = outputDeviceID
        var format = makePCMFormat(sampleRate: sampleRate, channels: channelCount)
        var maxFrames = maxFramesPerSlice
        var callback = AURenderCallbackStruct(
            inputProc: toneRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try setUnitProperty(localUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutput)
        try setUnitProperty(localUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput)
        try setUnitProperty(localUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID)
        try setUnitProperty(localUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
        try setUnitProperty(localUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)
        try setUnitProperty(localUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback)

        try check(AudioUnitInitialize(localUnit), "AudioUnitInitialize(tone output)")
        unit = localUnit
        frameCursor = 0
    }

    func start() throws {
        guard let unit else {
            throw ValidationError.invalidState("Tone output unit not configured")
        }
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart(tone output)")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    fileprivate func render(inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let frameCount = Int(inNumberFrames)
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

        let safeFrameCount = min(frameCount, Int(maxFramesPerSlice))
        if safeFrameCount > 0 {
            let toneStart = preRollFrames
            let toneEnd = preRollFrames + signalFrames.count
            let totalFrames = preRollFrames + signalFrames.count + postRollFrames

            for frame in 0..<safeFrameCount {
                let absoluteFrame = frameCursor + frame
                if absoluteFrame >= toneStart && absoluteFrame < toneEnd && absoluteFrame < totalFrames {
                    frameScratch[frame] = signalFrames[absoluteFrame - toneStart]
                } else {
                    frameScratch[frame] = 0
                }
            }
        }

        if bufferList.count == 1 {
            guard let data = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let channels = max(1, Int(bufferList[0].mNumberChannels))
            for frame in 0..<safeFrameCount {
                let sample = frameScratch[frame]
                let base = frame * channels
                for channel in 0..<channels {
                    data[base + channel] = sample
                }
            }
            if frameCount > safeFrameCount {
                let start = safeFrameCount * channels
                let remaining = (frameCount - safeFrameCount) * channels
                for index in 0..<remaining {
                    data[start + index] = 0
                }
            }
            bufferList[0].mDataByteSize = UInt32(frameCount * channels * MemoryLayout<Float>.size)
        } else {
            for bufferIndex in 0..<bufferList.count {
                guard let data = bufferList[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<safeFrameCount {
                    data[frame] = frameScratch[frame]
                }
                if frameCount > safeFrameCount {
                    for frame in safeFrameCount..<frameCount {
                        data[frame] = 0
                    }
                }
                bufferList[bufferIndex].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
            }
        }

        frameCursor += frameCount
        return noErr
    }
}

private final class InputCaptureUnit {
    private let sampleRate: Double
    private let channelCount: Int
    private let maxCaptureFrames: Int
    private let maxFramesPerSlice: UInt32

    private var unit: AudioUnit?
    private var scratch: UnsafeMutablePointer<Float>
    private var captureStorage: UnsafeMutablePointer<Float>
    private let captureCapacitySamples: Int
    private var writtenSamples = 0
    private(set) var droppedSamples = 0

    init(
        sampleRate: Double,
        channelCount: Int,
        maxCaptureFrames: Int,
        maxFramesPerSlice: UInt32 = 2048
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maxCaptureFrames = maxCaptureFrames
        self.maxFramesPerSlice = maxFramesPerSlice
        self.captureCapacitySamples = maxCaptureFrames * channelCount

        self.scratch = .allocate(capacity: Int(maxFramesPerSlice) * channelCount)
        self.captureStorage = .allocate(capacity: captureCapacitySamples)

        self.scratch.initialize(repeating: 0, count: Int(maxFramesPerSlice) * channelCount)
        self.captureStorage.initialize(repeating: 0, count: captureCapacitySamples)
    }

    deinit {
        stop()
        scratch.deinitialize(count: Int(maxFramesPerSlice) * channelCount)
        captureStorage.deinitialize(count: captureCapacitySamples)
        scratch.deallocate()
        captureStorage.deallocate()
    }

    func configure(inputDeviceID: AudioDeviceID) throws {
        stop()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw ValidationError.invalidState("HAL output component not found for capture unit")
        }

        var localUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &localUnit), "AudioComponentInstanceNew(capture input)")
        guard let localUnit else {
            throw ValidationError.invalidState("AudioComponentInstanceNew returned nil for capture unit")
        }

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        var deviceID = inputDeviceID
        var format = makePCMFormat(sampleRate: sampleRate, channels: channelCount)
        var maxFrames = maxFramesPerSlice
        var callback = AURenderCallbackStruct(
            inputProc: captureInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try setUnitProperty(localUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput)
        try setUnitProperty(localUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput)
        try setUnitProperty(localUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID)
        try setUnitProperty(localUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
        try setUnitProperty(localUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)
        try setUnitProperty(localUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)

        try check(AudioUnitInitialize(localUnit), "AudioUnitInitialize(capture input)")
        unit = localUnit
        writtenSamples = 0
        droppedSamples = 0
    }

    func start() throws {
        guard let unit else {
            throw ValidationError.invalidState("Capture input unit not configured")
        }
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart(capture input)")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    func capturedMono() -> [Float] {
        guard writtenSamples > 0 else { return [] }
        let frameCount = writtenSamples / channelCount
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: captureStorage, count: frameCount))
        }

        var mono = Array(repeating: Float(0), count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            let base = frame * channelCount
            for channel in 0..<channelCount {
                sum += captureStorage[base + channel]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }

    fileprivate func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let unit else { return noErr }
        let frameCount = Int(inNumberFrames)

        if frameCount > Int(maxFramesPerSlice) {
            droppedSamples += frameCount * channelCount
            return noErr
        }

        let sampleCount = frameCount * channelCount
        let audioBuffer = AudioBuffer(
            mNumberChannels: UInt32(channelCount),
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(scratch)
        )
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)

        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &list)
        guard status == noErr else { return status }

        let remaining = max(0, captureCapacitySamples - writtenSamples)
        let copyCount = min(sampleCount, remaining)
        if copyCount > 0 {
            let dst = captureStorage + writtenSamples
            _ = memcpy(dst, scratch, copyCount * MemoryLayout<Float>.size)
            writtenSamples += copyCount
        }

        if copyCount < sampleCount {
            droppedSamples += sampleCount - copyCount
        }

        return noErr
    }
}

private let toneRenderCallback: AURenderCallback = { refCon, _, _, _, inNumberFrames, ioData in
    let injector = Unmanaged<ToneOutputUnit>.fromOpaque(refCon).takeUnretainedValue()
    return injector.render(inNumberFrames: inNumberFrames, ioData: ioData)
}

private let captureInputCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let capture = Unmanaged<InputCaptureUnit>.fromOpaque(refCon).takeUnretainedValue()
    return capture.handleInput(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inNumberFrames: inNumberFrames)
}

private func generateReferenceSignal(
    sampleRate: Double,
    frequencyHz: Double,
    amplitude: Float,
    frameCount: Int
) -> [Float] {
    let startHz = max(80.0, frequencyHz)
    let nyquist = sampleRate * 0.5
    let endHz = min(nyquist * 0.45, max(startHz + 300.0, startHz * 3.0))
    let duration = Double(frameCount) / sampleRate
    let k = (endHz - startHz) / max(duration, 0.001)

    var values = Array(repeating: Float(0), count: frameCount)
    for frame in 0..<frameCount {
        let t = Double(frame) / sampleRate
        let phase = 2.0 * Double.pi * (startHz * t + 0.5 * k * t * t)
        var sample = sin(phase)

        let fadeFrames = max(1, min(frameCount / 20, Int(sampleRate * 0.02)))
        let fadeGain: Double
        if frame < fadeFrames {
            fadeGain = Double(frame) / Double(fadeFrames)
        } else if frame >= frameCount - fadeFrames {
            fadeGain = Double(frameCount - frame - 1) / Double(fadeFrames)
        } else {
            fadeGain = 1.0
        }
        sample *= max(0, min(1, fadeGain))

        values[frame] = Float(sample) * amplitude
    }
    return values
}

private func rms(_ values: [Float]) -> Double {
    guard !values.isEmpty else { return 0 }
    var energy = 0.0
    for value in values {
        let d = Double(value)
        energy += d * d
    }
    return sqrt(energy / Double(values.count))
}

private func findBestOffset(
    captured: [Float],
    probe: [Float],
    coarseStep: Int,
    maxSearchOffset: Int? = nil
) -> (offset: Int, correlation: Double) {
    guard !probe.isEmpty, captured.count >= probe.count else {
        return (-1, 0)
    }

    var probeEnergy = 0.0
    for sample in probe {
        let p = Double(sample)
        probeEnergy += p * p
    }
    guard probeEnergy > 1e-12 else { return (-1, 0) }

    let naturalMaxOffset = captured.count - probe.count
    let maxOffset = min(naturalMaxOffset, maxSearchOffset ?? naturalMaxOffset)
    guard maxOffset >= 0 else { return (-1, 0) }
    let step = max(1, coarseStep)

    func corrAt(_ offset: Int) -> Double {
        var dot = 0.0
        var capEnergy = 0.0
        for i in 0..<probe.count {
            let c = Double(captured[offset + i])
            let p = Double(probe[i])
            dot += c * p
            capEnergy += c * c
        }
        guard capEnergy > 1e-12 else { return 0 }
        return dot / sqrt(capEnergy * probeEnergy)
    }

    var bestOffset = 0
    var bestCorrelation = 0.0
    var bestScore = -Double.infinity

    var offset = 0
    while offset <= maxOffset {
        let corr = corrAt(offset)
        let score = abs(corr)
        if score > bestScore {
            bestScore = score
            bestCorrelation = corr
            bestOffset = offset
        }
        offset += step
    }

    let refineStart = max(0, bestOffset - step)
    let refineEnd = min(maxOffset, bestOffset + step)
    if refineStart <= refineEnd {
        for candidate in refineStart...refineEnd {
            let corr = corrAt(candidate)
            let score = abs(corr)
            if score > bestScore {
                bestScore = score
                bestCorrelation = corr
                bestOffset = candidate
            }
        }
    }

    if !bestCorrelation.isFinite {
        return (-1, 0)
    }

    return (bestOffset, bestCorrelation)
}

private struct SimilarityMetrics {
    let gain: Double
    let segmentRMS: Double
    let correlation: Double
    let errorRatio: Double
}

private func computeSimilarity(captured: [Float], reference: [Float], offset: Int) -> SimilarityMetrics? {
    guard offset >= 0, offset + reference.count <= captured.count else {
        return nil
    }

    var dot = 0.0
    var refEnergy = 0.0
    var capEnergy = 0.0
    for i in 0..<reference.count {
        let ref = Double(reference[i])
        let cap = Double(captured[offset + i])
        dot += cap * ref
        refEnergy += ref * ref
        capEnergy += cap * cap
    }

    guard refEnergy > 1e-12 else { return nil }
    let gain = dot / refEnergy

    var errorEnergy = 0.0
    for i in 0..<reference.count {
        let ref = Double(reference[i]) * gain
        let cap = Double(captured[offset + i])
        let err = cap - ref
        errorEnergy += err * err
    }

    let scaledRefEnergy = max(1e-12, gain * gain * refEnergy)
    let errorRatio = sqrt(errorEnergy / scaledRefEnergy)
    let correlation = dot / sqrt(max(1e-12, refEnergy * capEnergy))
    let segmentRMS = sqrt(capEnergy / Double(reference.count))

    return SimilarityMetrics(
        gain: gain,
        segmentRMS: segmentRMS,
        correlation: correlation,
        errorRatio: errorRatio
    )
}

private func trySetNominalSampleRate(_ device: AudioDevice, rate: Double) {
    do {
        try CoreAudioDeviceRegistry.setNominalSampleRate(deviceID: device.id, rate: rate)
    } catch {
        fputs("[audio-e2e] warning: could not set sample rate \(Int(rate)) on \(device.name): \(error)\n", stderr)
    }
}

do {
    let cfg = try parseArguments()

    let injectDevice = try CoreAudioDeviceRegistry.findDevice(uid: cfg.injectOutputUID)
    let captureDevice = try CoreAudioDeviceRegistry.findDevice(uid: cfg.captureInputUID)

    guard injectDevice.outputChannels > 0 else {
        throw ValidationError.invalidState("Inject output device has no output channels: \(injectDevice.name)")
    }
    guard captureDevice.inputChannels > 0 else {
        throw ValidationError.invalidState("Capture input device has no input channels: \(captureDevice.name)")
    }

    trySetNominalSampleRate(injectDevice, rate: cfg.sampleRate)
    trySetNominalSampleRate(captureDevice, rate: cfg.sampleRate)

    let outputChannels = min(max(1, injectDevice.outputChannels), 2)
    let captureChannels = min(max(1, captureDevice.inputChannels), 2)

    let preRollFrames = Int((cfg.preRollSeconds * cfg.sampleRate).rounded())
    let toneFrames = Int((cfg.toneSeconds * cfg.sampleRate).rounded())
    let postRollFrames = Int((cfg.postRollSeconds * cfg.sampleRate).rounded())
    let captureFrames = preRollFrames + toneFrames + postRollFrames + Int((cfg.extraCaptureSeconds * cfg.sampleRate).rounded())

    guard toneFrames > 0 else {
        throw ValidationError.invalidArgument("tone-seconds produced zero frames")
    }

    let capture = InputCaptureUnit(
        sampleRate: cfg.sampleRate,
        channelCount: captureChannels,
        maxCaptureFrames: captureFrames
    )
    try capture.configure(inputDeviceID: captureDevice.id)

    let reference = generateReferenceSignal(
        sampleRate: cfg.sampleRate,
        frequencyHz: cfg.frequencyHz,
        amplitude: cfg.amplitude,
        frameCount: toneFrames
    )

    let output = ToneOutputUnit(
        sampleRate: cfg.sampleRate,
        signalFrames: reference,
        preRollFrames: preRollFrames,
        postRollFrames: postRollFrames,
        channelCount: outputChannels
    )
    try output.configure(outputDeviceID: injectDevice.id)

    print("[audio-e2e] inject=\(injectDevice.name) (\(injectDevice.uid))")
    print("[audio-e2e] capture=\(captureDevice.name) (\(captureDevice.uid))")
    print("[audio-e2e] sampleRate=\(Int(cfg.sampleRate))Hz signature-start=\(cfg.frequencyHz)Hz duration=\(cfg.toneSeconds)s")

    try capture.start()
    try output.start()
    Thread.sleep(forTimeInterval: Double(captureFrames) / cfg.sampleRate)
    output.stop()
    capture.stop()

    let capturedMono = capture.capturedMono()
    let overallCaptureRMS = rms(capturedMono)
    if capturedMono.count < toneFrames {
        throw ValidationError.invalidState(
            "Capture too short: got \(capturedMono.count) frames, need at least \(toneFrames)"
        )
    }

    let probeFrameCount = max(512, min(cfg.probeFrames, reference.count))
    let probe = Array(reference.prefix(probeFrameCount))
    let maxSearchOffset = capturedMono.count - reference.count
    let offsetResult = findBestOffset(
        captured: capturedMono,
        probe: probe,
        coarseStep: cfg.coarseStepFrames,
        maxSearchOffset: maxSearchOffset
    )

    guard offsetResult.offset >= 0 else {
        throw ValidationError.invalidState("Unable to align captured signal to reference")
    }

    guard let similarity = computeSimilarity(captured: capturedMono, reference: reference, offset: offsetResult.offset) else {
        throw ValidationError.invalidState("Unable to compare captured/reference signal windows")
    }

    let expectedToneStart = preRollFrames
    let latencyFrames = offsetResult.offset - expectedToneStart
    let latencyMs = (Double(latencyFrames) * 1000.0) / cfg.sampleRate

    print("[audio-e2e] capture_frames=\(capturedMono.count)")
    print("[audio-e2e] dropped_samples=\(capture.droppedSamples)")
    print(String(format: "[audio-e2e] capture_rms=%.6f", overallCaptureRMS))
    print(String(format: "[audio-e2e] offset_frames=%d latency_ms=%.2f", offsetResult.offset, latencyMs))
    print(String(format: "[audio-e2e] probe_correlation=%.4f", offsetResult.correlation))
    print(String(format: "[audio-e2e] segment_rms=%.6f gain=%.6f", similarity.segmentRMS, similarity.gain))
    print(String(format: "[audio-e2e] full_correlation=%.4f error_ratio=%.4f", similarity.correlation, similarity.errorRatio))

    if overallCaptureRMS < cfg.minCaptureRMS {
        throw ValidationError.invalidState(
            String(
                format: "Captured signal too quiet (rms=%.6f < min=%.6f)",
                overallCaptureRMS,
                cfg.minCaptureRMS
            )
        )
    }
    if abs(offsetResult.correlation) < cfg.minCorrelation {
        throw ValidationError.invalidState(
            String(
                format: "Low probe correlation (%.4f < min=%.4f)",
                abs(offsetResult.correlation),
                cfg.minCorrelation
            )
        )
    }
    if similarity.errorRatio > cfg.maxErrorRatio {
        throw ValidationError.invalidState(
            String(
                format: "Error ratio too high (%.4f > max=%.4f)",
                similarity.errorRatio,
                cfg.maxErrorRatio
            )
        )
    }

    print("[audio-e2e] PASS: deterministic tone reached capture device with acceptable similarity")
} catch let error as ValidationError {
    if case .usage = error {
        print(error.description)
    } else {
        fputs("[audio-e2e] FAIL: \(error.description)\n", stderr)
    }
    exit(1)
} catch {
    fputs("[audio-e2e] FAIL: \(error)\n", stderr)
    exit(1)
}
