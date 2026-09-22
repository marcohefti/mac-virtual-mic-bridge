import AudioToolbox
import CoreAudio
import Foundation

public struct BridgeSessionInfo {
    public let sourceDeviceUID: String
    public let targetDeviceUID: String
    public let sampleRate: Double
    public let bridgeChannels: Int
    public let sourceDeviceName: String
    public let targetDeviceName: String
}

public final class AudioBridgeEngine {
    private let preferredSampleRate: Double = 48_000
    private let maxFramesPerSlice: UInt32 = 2048

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?

    private var sourceDevice: AudioDevice?
    private var targetDevice: AudioDevice?

    private var inputChannelSelection: InputChannelSelection?
    private var sourceCaptureChannels: Int = 0
    private var bridgeChannels: Int = 0
    private var sampleRate: Double = 0

    private var ringBuffer: PCMFloatRingBuffer?

    private var inputScratch: UnsafeMutablePointer<Float>?
    private var convertedInputScratch: UnsafeMutablePointer<Float>?
    private var outputScratch: UnsafeMutablePointer<Float>?

    private var deliveryMonitor: DeliveryMonitor?
    private var health = RecoveryHealth()
    private var previousDeliveryCalls: UInt64 = 0
    private var isRunning = false

    public init() {}

    deinit {
        stop()
    }

    public func start(config: BridgeConfig) throws -> BridgeSessionInfo {
        stop()

        let devices = try CoreAudioDeviceRegistry.allDevices()
        let defaultInput = try? CoreAudioDeviceRegistry.findDefaultInputDevice()

        guard let chosenSource = DeviceSelectionPolicy.selectSourceDevice(
            configuredUID: config.sourceDeviceUID,
            defaultInputUID: defaultInput?.uid,
            devices: devices
        ) else {
            if let configuredSourceUID = config.sourceDeviceUID {
                throw CoreAudioError.notFound(
                    "Configured source device unavailable: \(configuredSourceUID). Waiting for selected input to reconnect."
                )
            }
            throw CoreAudioError.notFound("No input device available for bridge source")
        }

        guard let chosenTarget = DeviceSelectionPolicy.selectTargetDevice(
            configuredUID: config.targetDeviceUID,
            preferredVirtualMicName: config.virtualMicrophoneName,
            devices: devices
        ) else {
            throw CoreAudioError.notFound("No output device found for virtual microphone target")
        }

        guard chosenSource.uid != chosenTarget.uid else {
            throw CoreAudioError.invalidState("Source and target must be different devices")
        }
        if let configuredTargetUID = config.targetDeviceUID, configuredTargetUID != chosenTarget.uid {
            BridgeLogger.log(
                .warning,
                "Configured target device UID not found (\(configuredTargetUID)). Falling back to \(chosenTarget.name)."
            )
        }

        guard chosenSource.isInputCandidate else {
            throw CoreAudioError.invalidState("Selected source device has no usable input channels")
        }

        guard chosenTarget.isOutputCandidate else {
            throw CoreAudioError.invalidState("Selected target device has no usable output channels")
        }

        try CoreAudioDeviceRegistry.setNominalSampleRate(deviceID: chosenTarget.id, rate: preferredSampleRate)

        let refreshedSource = try CoreAudioDeviceRegistry.findDevice(uid: chosenSource.uid)
        let refreshedTarget = try CoreAudioDeviceRegistry.findDevice(uid: chosenTarget.uid)

        sourceCaptureChannels = refreshedSource.inputChannels
        inputChannelSelection = try InputChannelSelection(channel: config.sourceInputChannel, sourceChannels: sourceCaptureChannels)
        bridgeChannels = min(max(1, refreshedTarget.outputChannels), 2)

        if bridgeChannels < 1 || sourceCaptureChannels < 1 {
            throw CoreAudioError.invalidState("Invalid channel configuration for source/target")
        }

        sampleRate = refreshedTarget.nominalSampleRate > 0 ? refreshedTarget.nominalSampleRate : preferredSampleRate
        let sourceRate = refreshedSource.nominalSampleRate > 0 ? refreshedSource.nominalSampleRate : sampleRate
        guard abs(sourceRate - sampleRate) < 1 else {
            throw CoreAudioError.invalidState("Set \(refreshedSource.name) to 48 kHz in Audio MIDI Setup. Current rate: \(Int(sourceRate)) Hz; the bridge will not change a shared hardware clock automatically.")
        }

        let ringCapacityFrames = Int(sampleRate)
        ringBuffer = PCMFloatRingBuffer(channels: bridgeChannels, capacityFrames: max(ringCapacityFrames, 4096))

        allocateScratchBuffers()
        try configureUnits(source: refreshedSource, target: refreshedTarget)

        sourceDevice = refreshedSource
        targetDevice = refreshedTarget

        guard let outputUnit else {
            throw CoreAudioError.invalidState("Output unit was not created")
        }
        guard let inputUnit else {
            throw CoreAudioError.invalidState("Input unit was not created")
        }

        try checkOSStatus(AudioOutputUnitStart(outputUnit), "AudioOutputUnitStart(output)")
        try checkOSStatus(AudioOutputUnitStart(inputUnit), "AudioOutputUnitStart(input)")

        deliveryMonitor = DeliveryMonitor()
        try deliveryMonitor?.start(deviceID: refreshedTarget.id, sampleRate: sampleRate)
        health = RecoveryHealth()
        previousDeliveryCalls = 0
        isRunning = true

        BridgeLogger.log(
            .info,
            "Bridge running: \(refreshedSource.name) [input \(config.sourceInputChannel)] -> \(refreshedTarget.name) @ \(Int(sampleRate)) Hz, \(bridgeChannels)ch"
        )

        return BridgeSessionInfo(
            sourceDeviceUID: refreshedSource.uid,
            targetDeviceUID: refreshedTarget.uid,
            sampleRate: sampleRate,
            bridgeChannels: bridgeChannels,
            sourceDeviceName: refreshedSource.name,
            targetDeviceName: refreshedTarget.name
        )
    }

    public func stop() {
        deliveryMonitor?.stop()
        deliveryMonitor = nil
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
            self.inputUnit = nil
        }

        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }

        inputChannelSelection = nil
        sourceDevice = nil
        targetDevice = nil
        ringBuffer?.clear()
        ringBuffer = nil
        releaseScratchBuffers()

        isRunning = false
    }

    public func isBridgeRunning() -> Bool {
        isRunning
    }

    public func currentTelemetryMessage() -> String {
        let fill = ringBuffer?.fillLevelFrames() ?? 0
        let queuedMilliseconds = sampleRate > 0 ? Double(fill) * 1000 / sampleRate : 0
        let metrics = ringBuffer?.metrics()
        let peaks = ringBuffer?.signalPeaks() ?? (input: Float(0), output: Float(0))
        let delivery = deliveryMonitor?.snapshot
        let signal = String(format: "input_peak=%.8f output_peak=%.8f", peaks.input, peaks.output)
        return "input_channel=\(inputChannelSelection.map { $0.channelIndex + 1 } ?? 0) buffer=\(fill)f queued_ms=\(Int(queuedMilliseconds.rounded())) underflow=\(metrics?.underflow ?? 0) dropped=\(metrics?.dropped ?? 0) input_callbacks=\(metrics?.inputCalls ?? 0) output_callbacks=\(metrics?.outputCalls ?? 0) correction_ppm=\(Int(metrics?.correctionPPM ?? 0)) errors=\(metrics?.errors ?? 0) last_error=\(metrics?.lastError ?? 0) \(signal) delivered_peak=\(delivery?.peak ?? 0) delivery_callbacks=\(delivery?.calls ?? 0)"
    }

    public func discontinuityCounters() -> (underflow: UInt64, dropped: UInt64) {
        let m = ringBuffer?.metrics(); return (m?.underflow ?? 0, m?.dropped ?? 0)
    }

    public func healthFailure() -> String? {
        guard let metrics = ringBuffer?.metrics() else { return "Missing audio transport" }
        let delivery = deliveryMonitor?.snapshot
        defer { previousDeliveryCalls = delivery?.calls ?? 0 }
        return health.evaluate(input: metrics.inputCalls, output: metrics.outputCalls,
            errors: metrics.errors + (delivery?.errors ?? 0), sourcePeak: metrics.outputPeak,
            deliveredPeak: delivery?.peak, deliveredProgress: delivery.map { $0.calls > previousDeliveryCalls } ?? false)
    }

    public func hasLiveDevices() -> Bool {
        guard let sourceDevice, let targetDevice else {
            return false
        }

        do {
            let source = try CoreAudioDeviceRegistry.findDevice(uid: sourceDevice.uid)
            let target = try CoreAudioDeviceRegistry.findDevice(uid: targetDevice.uid)
            return source.isAlive && target.isAlive && source.id == sourceDevice.id && target.id == targetDevice.id
                && source.inputChannels == sourceCaptureChannels && abs(target.nominalSampleRate - sampleRate) < 1
                && abs(source.nominalSampleRate - sampleRate) < 1
        } catch {
            return false
        }
    }

    private func allocateScratchBuffers() {
        releaseScratchBuffers()

        inputScratch = .allocate(capacity: Int(maxFramesPerSlice) * max(sourceCaptureChannels, 1))
        convertedInputScratch = .allocate(capacity: Int(maxFramesPerSlice) * max(bridgeChannels, 1))
        outputScratch = .allocate(capacity: Int(maxFramesPerSlice) * max(bridgeChannels, 1))

        inputScratch?.initialize(repeating: 0, count: Int(maxFramesPerSlice) * max(sourceCaptureChannels, 1))
        convertedInputScratch?.initialize(repeating: 0, count: Int(maxFramesPerSlice) * max(bridgeChannels, 1))
        outputScratch?.initialize(repeating: 0, count: Int(maxFramesPerSlice) * max(bridgeChannels, 1))
    }

    private func releaseScratchBuffers() {
        if let inputScratch {
            inputScratch.deallocate()
            self.inputScratch = nil
        }
        if let convertedInputScratch {
            convertedInputScratch.deallocate()
            self.convertedInputScratch = nil
        }
        if let outputScratch {
            outputScratch.deallocate()
            self.outputScratch = nil
        }
    }

    private func configureUnits(source: AudioDevice, target: AudioDevice) throws {
        var inputDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let inputComponent = AudioComponentFindNext(nil, &inputDescription) else {
            throw CoreAudioError.invalidState("Could not find HAL output component for input")
        }

        var localInputUnit: AudioUnit?
        try checkOSStatus(AudioComponentInstanceNew(inputComponent, &localInputUnit), "AudioComponentInstanceNew(input)")
        guard let inputUnit = localInputUnit else {
            throw CoreAudioError.invalidState("AudioComponentInstanceNew(input) returned nil")
        }

        var committed = false
        var createdOutput: AudioUnit?
        defer {
            if !committed {
                if let unit = createdOutput { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
                AudioUnitUninitialize(inputUnit)
                AudioComponentInstanceDispose(inputUnit)
            }
        }
        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        var sourceID = source.id

        try setUnitProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput)
        try setUnitProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput)
        try setUnitProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &sourceID)

        var inputFormat = makePCMFormat(sampleRate: sampleRate, channels: sourceCaptureChannels)
        try setUnitProperty(
            inputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &inputFormat
        )

        var maxFrames = maxFramesPerSlice
        try setUnitProperty(inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)

        var inputCallback = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try setUnitProperty(
            inputUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &inputCallback
        )

        try checkOSStatus(AudioUnitInitialize(inputUnit), "AudioUnitInitialize(input)")

        var outputDescription = inputDescription
        guard let outputComponent = AudioComponentFindNext(nil, &outputDescription) else {
            throw CoreAudioError.invalidState("Could not find HAL output component for output")
        }

        var localOutputUnit: AudioUnit?
        try checkOSStatus(AudioComponentInstanceNew(outputComponent, &localOutputUnit), "AudioComponentInstanceNew(output)")
        guard let outputUnit = localOutputUnit else {
            throw CoreAudioError.invalidState("AudioComponentInstanceNew(output) returned nil")
        }

        createdOutput = outputUnit
        var enableOutput: UInt32 = 1
        var disableInput: UInt32 = 0
        var targetID = target.id

        try setUnitProperty(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutput)
        try setUnitProperty(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput)
        try setUnitProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &targetID)

        var outputFormat = makePCMFormat(sampleRate: sampleRate, channels: bridgeChannels)
        try setUnitProperty(
            outputUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &outputFormat
        )

        try setUnitProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)

        var renderCallback = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try setUnitProperty(
            outputUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &renderCallback
        )

        try checkOSStatus(AudioUnitInitialize(outputUnit), "AudioUnitInitialize(output)")

        self.inputUnit = inputUnit
        self.outputUnit = outputUnit
        committed = true
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

        try checkOSStatus(status, "AudioUnitSetProperty(\(property))")
    }

    fileprivate func handleInputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let inputUnit, let ringBuffer, let inputScratch, let convertedInputScratch, let inputChannelSelection else {
            return noErr
        }

        if inNumberFrames > maxFramesPerSlice {
            ringBuffer.recordError(kAudioUnitErr_TooManyFramesToProcess)
            return kAudioUnitErr_TooManyFramesToProcess
        }

        let frameCount = Int(inNumberFrames)
        let inputSampleCount = frameCount * sourceCaptureChannels

        let buffer = AudioBuffer(
            mNumberChannels: UInt32(sourceCaptureChannels),
            mDataByteSize: UInt32(inputSampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(inputScratch)
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)

        let status = AudioUnitRender(
            inputUnit,
            ioActionFlags,
            inTimeStamp,
            1,
            inNumberFrames,
            &bufferList
        )
        if status != noErr {
            ringBuffer.recordError(status)
            return status
        }

        inputChannelSelection.copy(from: inputScratch, to: convertedInputScratch,
                                   frameCount: frameCount, targetChannels: bridgeChannels)
        _ = ringBuffer.write(from: convertedInputScratch, frameCount: frameCount)

        return noErr
    }

    fileprivate func handleOutputCallback(
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ringBuffer, let ioData, let outputScratch else {
            return noErr
        }

        if inNumberFrames > maxFramesPerSlice {
            for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            ringBuffer.recordError(kAudioUnitErr_TooManyFramesToProcess)
            return kAudioUnitErr_TooManyFramesToProcess
        }

        let frameCount = Int(inNumberFrames)
        let sampleCount = frameCount * bridgeChannels

        let readFrames = ringBuffer.readAdaptive(into: outputScratch, frameCount: frameCount, sampleRate: sampleRate)

        if readFrames < frameCount {
            let missingSamples = (frameCount - readFrames) * bridgeChannels
            let fillStart = outputScratch + (readFrames * bridgeChannels)
            for index in 0..<missingSamples {
                fillStart[index] = 0
            }
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
        if bufferList.count == 1 {
            guard let data = bufferList[0].mData else { return noErr }
            _ = memcpy(data, outputScratch, sampleCount * MemoryLayout<Float>.size)
            bufferList[0].mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
            return noErr
        }

        // De-interleave for devices exposing multiple buffers.
        for channel in 0..<bufferList.count {
            guard let channelData = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                channelData[frame] = outputScratch[(frame * bridgeChannels) + min(channel, bridgeChannels - 1)]
            }
            bufferList[channel].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        }

        return noErr
    }
}

private let inputRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let engine = Unmanaged<AudioBridgeEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleInputCallback(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inNumberFrames: inNumberFrames
    )
}

private let outputRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
    let engine = Unmanaged<AudioBridgeEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleOutputCallback(inNumberFrames: inNumberFrames, ioData: ioData)
}
