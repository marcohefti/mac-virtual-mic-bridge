import Foundation

public final class PCMFloatRingBuffer {
    public let channels: Int
    public let capacityFrames: Int

    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0

    public init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.storage = Array(repeating: 0, count: channels * capacityFrames)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        storage.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
    }

    public func fillLevelFrames() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return availableFrames
    }

    @discardableResult
    public func write(from input: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        let writable = min(frameCount, capacityFrames - availableFrames)
        guard writable > 0 else { return 0 }

        var framesWritten = 0
        while framesWritten < writable {
            let contiguous = min(writable - framesWritten, capacityFrames - writeIndex)
            let dstOffset = writeIndex * channels
            let srcOffset = framesWritten * channels
            let sampleCount = contiguous * channels

            storage.withUnsafeMutableBufferPointer { dst in
                _ = memcpy(dst.baseAddress! + dstOffset, input + srcOffset, sampleCount * MemoryLayout<Float>.size)
            }

            writeIndex = (writeIndex + contiguous) % capacityFrames
            framesWritten += contiguous
        }

        availableFrames += writable
        return writable
    }

    @discardableResult
    public func read(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }

        lock.lock()
        defer { lock.unlock() }

        let readable = min(frameCount, availableFrames)
        guard readable > 0 else { return 0 }

        var framesRead = 0
        while framesRead < readable {
            let contiguous = min(readable - framesRead, capacityFrames - readIndex)
            let srcOffset = readIndex * channels
            let dstOffset = framesRead * channels
            let sampleCount = contiguous * channels

            storage.withUnsafeBufferPointer { src in
                _ = memcpy(output + dstOffset, src.baseAddress! + srcOffset, sampleCount * MemoryLayout<Float>.size)
            }

            readIndex = (readIndex + contiguous) % capacityFrames
            framesRead += contiguous
        }

        availableFrames -= readable
        return readable
    }

    public func dropOldest(frames: Int) {
        guard frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        let dropCount = min(frames, availableFrames)
        readIndex = (readIndex + dropCount) % capacityFrames
        availableFrames -= dropCount
    }
}
