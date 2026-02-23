import AppKit
import BridgeCore
import Foundation

final class BridgeDaemonController {
    private let configStore = BridgeConfigStore()
    private let statusStore = BridgeStatusStore()
    private let engine = AudioBridgeEngine()

    private var currentConfig: BridgeConfig?
    private var currentSession: BridgeSessionInfo?
    private var lastConfigModificationDate: Date?

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
        try writePIDFile()

        BridgeLogger.log(.info, "Daemon started. Config path: \(BridgePaths.configPath.path)")
        statusStore.save(BridgeStatus(state: .starting, message: "Starting daemon"))

        setupSignals()
        setupSleepWakeObservers()
        setupTickTimer()

        safeApplyConfig(forceRestart: true, reason: "startup")
    }

    private func setupSignals() {
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        hupSignalSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hupSignalSource?.setEventHandler { [weak self] in
            guard let self else { return }
            BridgeLogger.log(.info, "Received SIGHUP, reloading config")
            self.safeApplyConfig(forceRestart: true, reason: "sighup")
        }
        hupSignalSource?.resume()

        termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSignalSource?.setEventHandler { [weak self] in
            self?.shutdown(reason: "SIGTERM")
        }
        termSignalSource?.resume()

        intSignalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSignalSource?.setEventHandler { [weak self] in
            self?.shutdown(reason: "SIGINT")
        }
        intSignalSource?.resume()
    }

    private func setupSleepWakeObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            BridgeLogger.log(.info, "System will sleep, stopping bridge")
            self.engine.stop()
            self.statusStore.save(BridgeStatus(state: .restarting, message: "System sleeping, bridge paused"))
        }

        workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            BridgeLogger.log(.info, "System woke up, restarting bridge")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                self.safeApplyConfig(forceRestart: true, reason: "wake")
            }
        }
    }

    private func setupTickTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.onTick()
        }
        timer.resume()
        tickTimer = timer
    }

    private func onTick() {
        let currentMod = configStore.loadLastModificationDate()
        if currentMod != lastConfigModificationDate {
            safeApplyConfig(forceRestart: true, reason: "config_changed")
            return
        }

        if engine.isBridgeRunning() {
            if !engine.hasLiveDevices() {
                BridgeLogger.log(.warning, "Device liveness check failed, restarting bridge")
                safeApplyConfig(forceRestart: true, reason: "device_lost")
                return
            }

            if let session = currentSession {
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

        do {
            let session = try engine.start(config: config)
            currentSession = session
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
