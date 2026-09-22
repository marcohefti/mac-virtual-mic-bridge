import Foundation

/// Control-plane only. Quiet microphones are healthy if callbacks keep moving.
public struct RecoveryHealth {
    private var previousInput: UInt64 = 0
    private var previousOutput: UInt64 = 0
    private var previousErrors: UInt64 = 0
    private var stalledTicks = 0
    private var silentDeliveryTicks = 0
    public init() {}
    public mutating func evaluate(input: UInt64, output: UInt64, errors: UInt64,
                                  sourcePeak: Float, deliveredPeak: Float?, deliveredProgress: Bool = true) -> String? {
        let stalled = input == previousInput || output == previousOutput || !deliveredProgress
        stalledTicks = stalled ? stalledTicks + 1 : 0
        silentDeliveryTicks = sourcePeak > 0.00001 && deliveredPeak == 0 ? silentDeliveryTicks + 1 : 0
        let newErrors = errors > previousErrors
        previousInput = input; previousOutput = output; previousErrors = errors
        if newErrors { return "Audio render error" }
        if stalledTicks >= 3 { return "Audio callback progress stalled" }
        if silentDeliveryTicks >= 3 { return "Output signal present but virtual capture is silent" }
        return nil
    }
}

public final class WorkerWatchdog {
    private let lock = NSLock()
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var suspended = false
    public init() {}
    public func beat(suspended: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.suspended = suspended
        lastProgress = ProcessInfo.processInfo.systemUptime
    }
    public func isExpired(after seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !suspended && ProcessInfo.processInfo.systemUptime - lastProgress > seconds
    }
}
