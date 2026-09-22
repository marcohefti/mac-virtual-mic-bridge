import AppKit
import AVFoundation
import BridgeCore
import Foundation
import Darwin

final class BridgeDaemonController {
    private let configStore = BridgeConfigStore()
    private let statusStore = BridgeStatusStore()
    private let engine = AudioBridgeEngine()
    private let worker = DispatchQueue(label: "ch.hefti.micbridge.recovery")
    private let watchdog = WorkerWatchdog()
    private var watchdogTimer: DispatchSourceTimer?
    private var permissionRequested = false
    private var suspended = false
    private var generation: UInt64 = 0
    private var healthRestarts: [Date] = []
    private var previousCounters: (underflow: UInt64, dropped: UInt64) = (0, 0)
    private var instanceLock: Int32 = -1

    private var currentConfig: BridgeConfig?
    private var currentSession: BridgeSessionInfo?
    private var lastConfigModificationDate: Date?

    private var lastTelemetryLogAt = Date.distantPast
    private var tickTimer: DispatchSourceTimer?
    private var retryAfterErrorSeconds: Int = 3
    private var nextRetryAt: Date?
    private let missingSourceRetrySeconds: TimeInterval = 2
    private var waitingForConfiguredSourceUID: String?

    private var hupSignalSource: DispatchSourceSignal?
    private var termSignalSource: DispatchSourceSignal?
    private var intSignalSource: DispatchSourceSignal?

    func start() throws {
        try BridgePaths.ensureDirectories()
        instanceLock = open(BridgePaths.appSupportDir.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            fputs("Another bridge daemon already owns the runtime\n", stderr)
            exit(0)
        }
        try writePIDFile()

        BridgeLogger.log(.info, "Runtime executable: \(Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "unknown")")
        BridgeLogger.log(.info, "Daemon started. Config path: \(BridgePaths.configPath.path)")
        statusStore.save(BridgeStatus(state: .starting, message: "Starting daemon"))

        setupSignals()
        setupSleepWakeObservers()
        setupTickTimer()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.watchdog.isExpired(after: 45) else { return }
            // Bypass a possibly stuck control worker; launchd recreates the process.
            fputs("MicBridge recovery worker stalled for 45s; exiting for launchd recovery\n", stderr)
            _exit(70)
        }
        timer.resume(); watchdogTimer = timer
        worker.async { self.safeApplyConfig(forceRestart: true, reason: "startup") }
    }

    private func setupSignals() {
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        hupSignalSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: worker)
        hupSignalSource?.setEventHandler { [weak self] in
            guard let self else { return }
            BridgeLogger.log(.info, "Received SIGHUP, reloading config")
            self.safeApplyConfig(forceRestart: true, reason: "sighup")
        }
        hupSignalSource?.resume()

        termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: worker)
        termSignalSource?.setEventHandler { [weak self] in
            self?.shutdown(reason: "SIGTERM")
        }
        termSignalSource?.resume()

        intSignalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: worker)
        intSignalSource?.setEventHandler { [weak self] in
            self?.shutdown(reason: "SIGINT")
        }
        intSignalSource?.resume()
    }

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.watchdog.beat(suspended: true)
            self.worker.async {
                self.suspended = true; self.generation &+= 1
                self.engine.stop(); self.currentSession = nil
                self.statusStore.save(BridgeStatus(state: .restarting, message: "System sleeping, bridge paused"))
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.watchdog.beat()
            self.worker.async {
                self.suspended = false; self.generation &+= 1
                let expected = self.generation
                self.nextRetryAt = Date().addingTimeInterval(1)
                self.worker.asyncAfter(deadline: .now() + 1) {
                    guard !self.suspended, self.generation == expected else { return }
                    self.safeApplyConfig(forceRestart: true, reason: "wake")
                }
            }
        }
    }

    private func setupTickTimer() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.onTick()
        }
        timer.resume()
        tickTimer = timer
    }

    private func onTick() {
        watchdog.beat(suspended: suspended)
        guard !suspended else { return }
        let currentMod = configStore.loadLastModificationDate()
        if currentMod != lastConfigModificationDate {
            safeApplyConfig(forceRestart: true, reason: "config_changed")
            return
        }

        if engine.isBridgeRunning() {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                reportError("Microphone authorization revoked; capture stopped")
                return
            }
            let counters = engine.discontinuityCounters()
            if counters.underflow > previousCounters.underflow || counters.dropped > previousCounters.dropped {
                BridgeLogger.log(.warning, "Audio discontinuity: \(engine.currentTelemetryMessage())")
            }
            previousCounters = counters
            if let failure = engine.healthFailure() {
                BridgeLogger.log(.error, "Health failure: \(failure). \(engine.currentTelemetryMessage())")
                healthRestarts = healthRestarts.filter { Date().timeIntervalSince($0) < 60 }
                healthRestarts.append(Date())
                if healthRestarts.count >= 3 {
                    statusStore.save(BridgeStatus(state: .error, message: "Repeated audio failures; restarting daemon"))
                    exit(70)
                }
                safeApplyConfig(forceRestart: true, reason: "health_failure")
                return
            }
            if !engine.hasLiveDevices() {
                BridgeLogger.log(.warning, "Device liveness check failed, restarting bridge")
                safeApplyConfig(forceRestart: true, reason: "device_lost")
                return
            }

            if let session = currentSession {
                if Date().timeIntervalSince(lastTelemetryLogAt) >= 30 {
                    BridgeLogger.log(.info, "Audio health: \(engine.currentTelemetryMessage())")
                    lastTelemetryLogAt = Date()
                }
                statusStore.save(
                    BridgeStatus(
                        state: .running,
                        message: "Running. \(engine.currentTelemetryMessage())",
                        sourceDeviceUID: session.sourceDeviceUID,
                        targetDeviceUID: session.targetDeviceUID,
                        sampleRate: session.sampleRate,
                        channelCount: session.bridgeChannels
                    )
                )
            }
            return
        }

        guard let config = currentConfig, config.enabled else {
            return
        }

        if let nextRetryAt, Date() < nextRetryAt {
            return
        }

        safeApplyConfig(forceRestart: true, reason: "retry")
    }

    private func safeApplyConfig(forceRestart: Bool, reason: String) {
        guard !suspended else { return }
        generation &+= 1
        watchdog.beat()
        statusStore.save(BridgeStatus(state: .starting, message: "Starting audio (\(reason))"))
        defer { watchdog.beat(suspended: suspended) }
        do {
            try applyConfig(forceRestart: forceRestart, reason: reason)
            retryAfterErrorSeconds = 3
            nextRetryAt = nil
            waitingForConfiguredSourceUID = nil
        } catch {
            handleApplyConfigError(error, reason: reason)
        }
    }

    private func applyConfig(forceRestart: Bool, reason: String) throws {
        let config = try configStore.load()
        lastConfigModificationDate = configStore.loadLastModificationDate()

        let changed = config != currentConfig
        if !forceRestart && !changed {
            return
        }

        BridgeLogger.log(.info, "Applying config reason=\(reason)")
        currentConfig = config

        if !config.enabled {
            engine.stop()
            currentSession = nil
            waitingForConfiguredSourceUID = nil
            statusStore.save(BridgeStatus(state: .stopped, message: "Bridge disabled in config"))
            return
        }

        engine.stop()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            if !permissionRequested {
                permissionRequested = true
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    BridgeLogger.log(.info, "Microphone permission result: \(granted)")
                }
            }
            throw CoreAudioError.invalidState("Microphone permission pending. Allow MicBridge Audio in the macOS prompt.")
        default:
            throw CoreAudioError.invalidState("Microphone access denied. Enable MicBridge Audio in System Settings > Privacy & Security > Microphone.")
        }

        do {
            let session = try engine.start(config: config)
            currentSession = session
            previousCounters = engine.discontinuityCounters()
            statusStore.save(
                BridgeStatus(
                    state: .running,
                    message: "Running. \(engine.currentTelemetryMessage())",
                    sourceDeviceUID: session.sourceDeviceUID,
                    targetDeviceUID: session.targetDeviceUID,
                    sampleRate: session.sampleRate,
                    channelCount: session.bridgeChannels
                )
            )
        } catch {
            currentSession = nil
            throw error
        }
    }

    private func handleApplyConfigError(_ error: Error, reason: String) {
        if let sourceUID = unavailableConfiguredSourceUID() {
            reportWaitingForSelectedSource(sourceUID: sourceUID, reason: reason)
            return
        }
        waitingForConfiguredSourceUID = nil
        reportError("Apply config failed (reason=\(reason)): \(error)")
    }

    private func unavailableConfiguredSourceUID() -> String? {
        guard
            let config = currentConfig,
            config.enabled,
            let sourceUID = config.sourceDeviceUID
        else {
            return nil
        }

        guard let devices = try? CoreAudioDeviceRegistry.allDevices() else {
            return nil
        }

        let sourceIsAvailable = devices.contains { $0.uid == sourceUID && $0.isInputCandidate }
        return sourceIsAvailable ? nil : sourceUID
    }

    private func reportWaitingForSelectedSource(sourceUID: String, reason: String) {
        if waitingForConfiguredSourceUID != sourceUID {
            BridgeLogger.log(
                .warning,
                "Selected source input is offline (\(sourceUID)); waiting for reconnection. reason=\(reason)"
            )
        }

        waitingForConfiguredSourceUID = sourceUID
        engine.stop()
        currentSession = nil
        statusStore.save(
            BridgeStatus(
                state: .restarting,
                message: "Waiting for selected input device to reconnect",
                sourceDeviceUID: sourceUID,
                targetDeviceUID: currentConfig?.targetDeviceUID
            )
        )
        retryAfterErrorSeconds = 3
        nextRetryAt = Date().addingTimeInterval(missingSourceRetrySeconds)
    }

    private func reportError(_ message: String) {
        engine.stop()
        currentSession = nil
        waitingForConfiguredSourceUID = nil
        BridgeLogger.log(.error, message)
        statusStore.save(BridgeStatus(state: .error, message: message))

        // Keep backoff small for fast recovery; cap to avoid rapid thrash.
        retryAfterErrorSeconds = min(retryAfterErrorSeconds * 2, 20)
        nextRetryAt = Date().addingTimeInterval(TimeInterval(retryAfterErrorSeconds))
    }

    private func writePIDFile() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)\n".write(to: BridgePaths.pidPath, atomically: true, encoding: .utf8)
    }

    private func shutdown(reason: String) {
        BridgeLogger.log(.info, "Shutting down daemon (\(reason))")
        engine.stop()
        statusStore.save(BridgeStatus(state: .stopped, message: "Daemon stopped (\(reason))"))
        try? FileManager.default.removeItem(at: BridgePaths.pidPath)
        exit(0)
    }
}

let args = CommandLine.arguments
if args.contains("--debug") {
    BridgeLogger.isDebugEnabled = true
}

do {
    let controller = BridgeDaemonController()
    try controller.start()
    RunLoop.main.run()
} catch {
    BridgeLogger.log(.error, "Fatal startup error: \(error)")
    BridgeStatusStore().save(BridgeStatus(state: .error, message: "Fatal startup error: \(error)"))
    exit(1)
}
