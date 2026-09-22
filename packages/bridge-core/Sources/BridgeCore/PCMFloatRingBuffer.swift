import BridgeRT
import Foundation

/// Preallocated single-producer/single-consumer transport. Clear only when stopped;
/// trimming belongs to the consumer, never the capture producer.
public final class PCMFloatRingBuffer {
    public let channels: Int
    public let capacityFrames: Int
    private let handle: OpaquePointer
    public init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        guard let pointer = mb_create(Int32(channels), Int32(capacityFrames)) else {
            preconditionFailure("Unable to allocate lock-free audio transport")
        }
        handle = pointer
    }
    deinit { mb_destroy(handle) }
    public func clear() { mb_clear(handle) }
    public func fillLevelFrames() -> Int { Int(mb_fill(handle)) }
    public func signalPeaks() -> (input: Float, output: Float) {
        let m = mb_metrics(handle); return (m.inputPeak, m.outputPeak)
    }
    public func metrics() -> MBMetrics { mb_metrics(handle) }
    public func observe(_ input: UnsafePointer<Float>, frames: Int) { mb_observe(handle, input, Int32(frames)) }
    public func recordError(_ code: Int32) { mb_error(handle, code) }
    @discardableResult public func write(from input: UnsafePointer<Float>, frameCount: Int) -> Int {
        Int(mb_write(handle, input, Int32(frameCount)))
    }
    @discardableResult public func read(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        Int(mb_read(handle, output, Int32(frameCount)))
    }
    @discardableResult public func discardExcessLatency(sampleRate: Double, callbackFrames: Int) -> Int {
        Int(mb_trim(handle, Int32(max(Int(sampleRate * 0.040), callbackFrames * 2)),
                    Int32(max(Int(sampleRate * 0.010), callbackFrames))))
    }
    public func readAdaptive(into output: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Double) -> Int {
        Int(mb_read_adaptive(handle, output, Int32(frameCount), sampleRate))
    }
    public func dropOldest(frames: Int) {
        guard frames > 0 else { return }
        let fill = fillLevelFrames()
        _ = mb_trim(handle, Int32(max(0, fill - frames)), Int32(max(0, fill - frames)))
    }
}
