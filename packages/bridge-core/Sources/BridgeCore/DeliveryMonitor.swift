import AudioToolbox
import CoreAudio
import Foundation

/// Read-only virtual-input observer. No audio is retained or written to disk.
/// Runs for the life of a bridge session; exposes atomic peak/progress telemetry.
final class DeliveryMonitor {
    private var unit: AudioUnit?
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    private let telemetry = PCMFloatRingBuffer(channels: 1, capacityFrames: 2048)
    init() { scratch.initialize(repeating: 0, count: 2048) }
    deinit { stop(); scratch.deallocate() }
    func stop() {
        if let unit {
            AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
    }
    var snapshot: (calls: UInt64, peak: Float, errors: UInt64) {
        let m = telemetry.metrics(); return (m.inputCalls, m.inputPeak, m.errors)
    }
    func start(deviceID: AudioDeviceID, sampleRate: Double) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw CoreAudioError.invalidState("No monitor HAL component") }
        try checkOSStatus(AudioComponentInstanceNew(component, &unit), "Create delivery monitor")
        guard let unit else { throw CoreAudioError.invalidState("No monitor unit") }
        func set<T>(_ key: AudioUnitPropertyID, _ scope: AudioUnitScope, _ bus: UInt32, _ value: inout T) throws {
            let status = withUnsafePointer(to: &value) { pointer in
                AudioUnitSetProperty(unit, key, scope, bus, pointer, UInt32(MemoryLayout<T>.size))
            }
            try checkOSStatus(status, "Configure delivery monitor")
        }
        var on: UInt32 = 1, off: UInt32 = 0, device = deviceID, maxFrames: UInt32 = 2048
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on)
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off)
        try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device)
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)
        var callback = AURenderCallbackStruct(inputProc: deliveryCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
        try checkOSStatus(AudioUnitInitialize(unit), "Initialize delivery monitor")
        try checkOSStatus(AudioOutputUnitStart(unit), "Start delivery monitor")
    }
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit, frames <= 2048 else { telemetry.recordError(kAudioUnitErr_TooManyFramesToProcess); return noErr }
        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
            mDataByteSize: frames * 4, mData: scratch))
        let result = AudioUnitRender(unit, flags, timestamp, 1, frames, &buffers)
        if result == noErr { telemetry.observe(scratch, frames: Int(frames)) }
        else { telemetry.recordError(result) }
        return result
    }
}
private let deliveryCallback: AURenderCallback = { context, flags, timestamp, _, frames, _ in
    Unmanaged<DeliveryMonitor>.fromOpaque(context).takeUnretainedValue().render(flags, timestamp, frames)
}
