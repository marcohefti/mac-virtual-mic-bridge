import AppKit
import BridgeCore
import Darwin
import Foundation

// Keep the badge decorative so clicks still reach the status item's menu.
private final class StatusBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MenuBarController: NSObject, NSApplicationDelegate {
    private enum SelectedInputAvailability {
        case automatic
        case online(name: String)
        case offline(uid: String)
    }

    private let configStore = BridgeConfigStore()
    private let statusStore = BridgeStatusStore()

    private let defaultVirtualTargetUID = "ch.hefti.micbridge.virtualmic.device"

    private var config = BridgeConfig()
    private var inputDevices: [AudioDevice] = []

    private var statusItem: NSStatusItem!
    private let statusBadge = StatusBadgeView()
    private var refreshTimer: Timer?
    private var repoRoot: URL?
    private var currentVersion: String = "0.0.0-dev"
    private var updateService: GitHubReleaseUpdateService?
    private var updateState: UpdateMenuState = .unavailable(reason: "Not configured")
    private var updateProgressStatus: String?
    private var updateProgressTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        repoRoot = resolveRepoRoot()
        currentVersion = resolveCurrentVersion()

        do {
            config = try configStore.load()
        } catch {
            BridgeLogger.log(.error, "Failed to load config on startup: \(error)")
        }

        if config.targetDeviceUID != defaultVirtualTargetUID {
            config.targetDeviceUID = defaultVirtualTargetUID
            persistConfigAndSignalDaemon()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        configureUpdateService()
        refreshModel()
        rebuildMenu()
        refreshUpdateStatus(interactive: false)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshModel()
            self?.rebuildMenu()
        }
    }

    private func refreshModel() {
        do {
            let devices = try CoreAudioDeviceRegistry.allDevices()
            inputDevices = devices.filter { $0.isInputCandidate }.sorted { $0.name < $1.name }
        } catch {
            BridgeLogger.log(.error, "Failed to refresh devices: \(error)")
            inputDevices = []
        }

        do {
            config = try configStore.load()
        } catch {
            BridgeLogger.log(.warning, "Failed to reload config: \(error)")
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = statusStore.load()
        let inputAvailability = selectedInputAvailability()
        updateStatusItemAppearance(
            daemonState: status?.isFresh == true ? status?.state : .error,
            bridgeEnabled: config.enabled,
            inputAvailability: inputAvailability
        )

        let summary = NSMenuItem()
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 68))
        let lines = [
            "\(bridgeSummary(status)) · \(currentInputName())",
            interfaceSummary(inputAvailability),
            deliverySummary(status)
        ]
        for (index, text) in lines.enumerated() {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 14, y: 46 - index * 20, width: 292, height: 18)
            label.font = index == 0 ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = text
            header.addSubview(label)
        }
        summary.view = header
        menu.addItem(summary)

        menu.addItem(.separator())

        let inputMenu = NSMenu(title: "Input Source")
        for (index, device) in inputDevices.enumerated() {
            let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (device.uid == config.sourceDeviceUID) ? .on : .off
            inputMenu.addItem(item)
        }
        if inputDevices.isEmpty {
            let none = NSMenuItem(title: "No input devices", action: nil, keyEquivalent: "")
            none.isEnabled = false
            inputMenu.addItem(none)
        }
        let inputParent = NSMenuItem(title: "Input Source", action: nil, keyEquivalent: "")
        menu.setSubmenu(inputMenu, for: inputParent)
        menu.addItem(inputParent)

        let channelMenu = NSMenu(title: "Microphone Channel")
        let selectedUID = config.sourceDeviceUID ?? status?.sourceDeviceUID
        if let device = inputDevices.first(where: { $0.uid == selectedUID }) {
            for channel in 1...device.inputChannels {
                let item = NSMenuItem(title: "\(channel): \(CoreAudioDeviceRegistry.inputChannelName(deviceID: device.id, channel: channel))", action: #selector(selectInputChannel(_:)), keyEquivalent: "")
                item.target = self
                item.tag = channel
                item.state = channel == config.sourceInputChannel ? .on : .off
                channelMenu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: "Input \(config.sourceInputChannel) (device unavailable)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            channelMenu.addItem(item)
        }
        let channelParent = NSMenuItem(title: "Microphone Channel", action: nil, keyEquivalent: "")
        menu.setSubmenu(channelMenu, for: channelParent)
        menu.addItem(channelParent)
        let identify = NSMenuItem(title: "Identify Microphone Channel…", action: #selector(identifyChannel), keyEquivalent: "")
        identify.target = self; menu.addItem(identify)
        let toggle = NSMenuItem(title: config.enabled ? "Stop Bridge" : "Start Bridge", action: #selector(toggleBridge), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        let restart = NSMenuItem(title: "Restart Audio", action: #selector(restartAudio), keyEquivalent: "")
        restart.target = self; menu.addItem(restart)
        let diagnosticsMenu = NSMenu(title: "Diagnostics")
        for (title, action) in [
            ("View Diagnostics…", #selector(showDiagnostics)),
            ("Copy Diagnostics", #selector(copyDiagnostics)),
            ("Open Logs", #selector(openLogs))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            diagnosticsMenu.addItem(item)
        }
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnostics.submenu = diagnosticsMenu
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let updatesItem = NSMenuItem(title: updateState.checkActionTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        updatesItem.isEnabled = !updateState.isChecking
        menu.addItem(updatesItem)

        let updateStateItem = NSMenuItem(title: updateProgressStatus ?? updateState.statusText, action: nil, keyEquivalent: "")
        updateStateItem.isEnabled = false
        menu.addItem(updateStateItem)

        let aboutItem = NSMenuItem(title: "About MicBridge", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Menu (Bridge Keeps Running)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func bridgeSummary(_ status: BridgeStatus?) -> String {
        guard config.enabled else { return "Disabled" }
        guard let status, status.isFresh else { return "Status unavailable" }
        switch status.state {
        case .running: return "Running"
        case .starting: return "Starting"
        case .restarting: return "Reconnecting"
        case .stopped: return "Stopped"
        case .error: return "Needs attention"
        }
    }

    private func interfaceSummary(_ availability: SelectedInputAvailability) -> String {
        switch availability {
        case .automatic: return "Interface: automatic selection"
        case .online: return "Interface: connected"
        case .offline: return "Interface: disconnected · waiting for reconnect"
        }
    }

    private func deliverySummary(_ status: BridgeStatus?) -> String {
        guard config.enabled, let status, status.isFresh, status.state == .running else {
            return "Virtual mic: delivery not confirmed"
        }
        // This is the daemon's virtual-input monitor, not the receiving app's state.
        let peak = status.message.split(separator: " ").first { $0.hasPrefix("delivered_peak=") }
            .flatMap { Double($0.dropFirst("delivered_peak=".count)) }
        guard let peak else { return "Virtual mic: delivery not confirmed" }
        return peak > 0 ? "Virtual mic: signal detected" : "Virtual mic: quiet · no signal detected"
    }

    private func diagnosticsText() -> String {
        let status = statusStore.load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let statusJSON = status.flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "Unavailable"
        let configJSON = (try? encoder.encode(config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "Unavailable"
        return """
        MicBridge \(currentVersion)
        Captured: \(ISO8601DateFormatter().string(from: Date()))
        Status: \(bridgeSummary(status))
        Route: \(currentInputName()) → \(config.virtualMicrophoneName)
        \(interfaceSummary(selectedInputAvailability()))
        \(deliverySummary(status))

        Underflow and dropped-frame counters are cumulative for the current transport;
        a nonzero total alone does not indicate a current fault.
        Signal detection confirms the virtual-input monitor, not Discord or another app.

        Status snapshot:
        \(statusJSON)

        Configuration:
        \(configJSON)

        Logs: \(BridgePaths.logsDir.path)
        """
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(BridgePaths.logsDir)
    }

    @objc private func showDiagnostics() {
        let snapshot = diagnosticsText()
        let alert = NSAlert()
        alert.messageText = "MicBridge Diagnostics"
        alert.informativeText = "A snapshot of the bridge and its cumulative counters."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = snapshot
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Copy Diagnostics")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot, forType: .string)
        }
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard inputDevices.indices.contains(sender.tag) else { return }
        let uid = inputDevices[sender.tag].uid
        if uid != config.sourceDeviceUID {
            if let oldUID = config.sourceDeviceUID { config.sourceChannelSelections[oldUID] = config.sourceInputChannel }
            let remembered = config.sourceChannelSelections[uid] ?? 1
            config.sourceInputChannel = min(max(1, remembered), inputDevices[sender.tag].inputChannels)
        }
        config.sourceDeviceUID = uid
        persistConfigAndSignalDaemon()
        rebuildMenu()
    }

    @objc private func selectInputChannel(_ sender: NSMenuItem) {
        config.sourceInputChannel = sender.tag
        if let uid = config.sourceDeviceUID { config.sourceChannelSelections[uid] = sender.tag }
        persistConfigAndSignalDaemon()
        rebuildMenu()
    }

    @objc private func toggleBridge() {
        config.enabled.toggle(); persistConfigAndSignalDaemon(); rebuildMenu()
    }
    @objc private func restartAudio() { persistConfigAndSignalDaemon() }
    @objc private func identifyChannel() {
        let alert = NSAlert()
        alert.messageText = "Identify microphone channel"
        alert.informativeText = "After clicking Start, speak for five seconds. Signal levels are measured locally; no recording is saved. Channel selection will not change automatically."
        alert.addButton(withTitle: "Start"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let executable = BridgePaths.appSupportDir.appendingPathComponent("bin/current/micbridge-audio-e2e-validate")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); let pipe = Pipe()
            process.executableURL = executable; process.arguments = ["--identify-channels"]
            process.standardOutput = pipe; process.standardError = pipe
            let result: String
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = String(data: data, encoding: .utf8) ?? "No result"
            } catch { result = "Channel check failed: \(error)" }
            DispatchQueue.main.async {
                let resultAlert = NSAlert(); resultAlert.messageText = "Input channel activity"
                resultAlert.informativeText = result; resultAlert.runModal()
            }
        }
    }

    @objc private func checkForUpdates() {
        if case let .updateAvailable(_, latestVersion, releaseURL, archiveURL, checksumURL) = updateState {
            showUpdateResultAlert(
                .updateAvailable(
                    latestVersion: latestVersion,
                    releaseURL: releaseURL,
                    archiveURL: archiveURL,
                    checksumURL: checksumURL
                )
            )
            return
        }

        refreshUpdateStatus(interactive: true)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "MicBridge"
        alert.informativeText = """
        Version: \(currentVersion)
        Route: \(currentInputName()) -> \(config.virtualMicrophoneName)
        Updates: \(updateState.statusText)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func currentInputName() -> String {
        switch selectedInputAvailability() {
        case .automatic:
            return "Auto Input"
        case let .online(name):
            return "\(name) · Input \(config.sourceInputChannel)"
        case .offline:
            return "Unavailable Input"
        }
    }

    private func selectedInputAvailability() -> SelectedInputAvailability {
        guard let sourceUID = config.sourceDeviceUID else {
            return .automatic
        }
        if let device = inputDevices.first(where: { $0.uid == sourceUID }) {
            return .online(name: device.name)
        }
        return .offline(uid: sourceUID)
    }

    private func selectedInputStatusText(_ availability: SelectedInputAvailability) -> String {
        switch availability {
        case .automatic:
            return "Input status: ⚪ Auto (default input)"
        case let .online(name):
            return "Input status: 🟢 Online (\(name))"
        case .offline:
            return "Input status: 🔴 Offline (waiting for selected device)"
        }
    }

    private func persistConfigAndSignalDaemon() {
        if config.targetDeviceUID != defaultVirtualTargetUID {
            config.targetDeviceUID = defaultVirtualTargetUID
        }
        do {
            try configStore.save(config)
        } catch {
            BridgeLogger.log(.error, "Failed to save config: \(error)")
        }

        if let pid = daemonPID() {
            kill(pid, SIGHUP)
        }
    }

    private func daemonPID() -> pid_t? {
        guard
            let pidString = try? String(contentsOf: BridgePaths.pidPath, encoding: .utf8),
            let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid
    }

    private func updateStatusItemAppearance(
        daemonState: BridgeRuntimeState?,
        bridgeEnabled: Bool,
        inputAvailability: SelectedInputAvailability
    ) {
        guard let button = statusItem.button else { return }

        let tooltip: String
        let badgeColor: NSColor
        if bridgeEnabled, case .offline = inputAvailability {
            badgeColor = .systemOrange
            tooltip = "MicBridge: Selected input offline (waiting for reconnect)"
        } else {
            switch daemonState {
            case .running where bridgeEnabled:
                badgeColor = .systemGreen
                tooltip = "MicBridge: Running"
            case .running:
                badgeColor = .systemRed
                tooltip = "MicBridge: Running (Bridge Disabled)"
            case .starting, .restarting:
                badgeColor = .systemOrange
                tooltip = "MicBridge: Recovering"
            case .error:
                badgeColor = .systemRed
                tooltip = "MicBridge: Error"
            case .stopped:
                badgeColor = .systemRed
                tooltip = "MicBridge: Stopped"
            case .none:
                badgeColor = .systemRed
                tooltip = "MicBridge: Unknown"
            }
        }

        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MicBridge microphone")
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel("MicBridge — \(tooltip)")
        button.toolTip = tooltip

        // Overlay a colored badge while leaving the microphone a template image,
        // so macOS still renders it correctly on light/dark and highlighted menus.
        if statusBadge.superview == nil {
            statusBadge.translatesAutoresizingMaskIntoConstraints = false
            statusBadge.wantsLayer = true
            statusBadge.layer?.cornerRadius = 2.5
            statusBadge.setAccessibilityElement(false)
            button.addSubview(statusBadge)
            NSLayoutConstraint.activate([
                statusBadge.widthAnchor.constraint(equalToConstant: 5),
                statusBadge.heightAnchor.constraint(equalToConstant: 5),
                statusBadge.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 6),
                statusBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 2)
            ])
        }
        statusBadge.layer?.backgroundColor = badgeColor.cgColor
    }

    private func configureUpdateService() {
        guard let repoSlug = githubRepoSlug() else {
            updateState = .unavailable(reason: "No GitHub origin")
            updateService = nil
            return
        }

        let channel = UpdateChannel.resolve(currentVersion: currentVersion)
        updateService = GitHubReleaseUpdateService(
            repoSlug: repoSlug,
            currentVersion: currentVersion,
            channel: channel
        )
        updateState = .idle(channel: channel)
    }

    private func refreshUpdateStatus(interactive: Bool) {
        guard let updateService else {
            if interactive, let fallbackURL = updatesURL() {
                NSWorkspace.shared.open(fallbackURL)
            }
            return
        }

        updateProgressStatus = nil
        updateState = .checking(channel: updateService.updateChannel)
        rebuildMenu()

        updateService.check { [weak self] result in
            DispatchQueue.main.async {
                self?.applyUpdateResult(result, interactive: interactive)
            }
        }
    }

    private func applyUpdateResult(_ result: UpdateCheckResult, interactive: Bool) {
        stopUpdateProgressMonitor()
        let channel: UpdateChannel
        switch updateState {
        case let .idle(existingChannel),
             let .checking(existingChannel),
             let .upToDate(existingChannel, _),
             let .updateAvailable(existingChannel, _, _, _, _),
             let .failed(existingChannel, _):
            channel = existingChannel
        case .unavailable:
            channel = UpdateChannel.resolve(currentVersion: currentVersion)
        }

        switch result {
        case let .upToDate(latestVersion):
            updateState = .upToDate(channel: channel, latestVersion: latestVersion)
        case let .updateAvailable(latestVersion, releaseURL, archiveURL, checksumURL):
            updateState = .updateAvailable(
                channel: channel,
                latestVersion: latestVersion,
                releaseURL: releaseURL,
                archiveURL: archiveURL,
                checksumURL: checksumURL
            )
        case let .unavailable(reason):
            updateState = .unavailable(reason: reason)
        case let .failed(message):
            updateState = .failed(channel: channel, message: message)
        }

        updateProgressStatus = nil
        rebuildMenu()

        guard interactive else { return }
        showUpdateResultAlert(result)
    }

    private func showUpdateResultAlert(_ result: UpdateCheckResult) {
        let alert = NSAlert()

        switch result {
        case let .upToDate(latestVersion):
            alert.alertStyle = .informational
            alert.messageText = "MicBridge is up to date"
            alert.informativeText = "Installed version \(currentVersion), latest \(latestVersion)."
            alert.addButton(withTitle: "OK")

        case let .updateAvailable(latestVersion, releaseURL, archiveURL, checksumURL):
            alert.alertStyle = .informational
            alert.messageText = "Update available: \(latestVersion)"
            let canInstallInternally = canRunInternalUpdater()
            if canInstallInternally {
                alert.informativeText = "A newer MicBridge release is available. Install it now or open the release page."
                alert.addButton(withTitle: "Install Now")
                alert.addButton(withTitle: "Open Release")
                alert.addButton(withTitle: "Copy Driver Update Cmd")
                alert.addButton(withTitle: "Cancel")
            } else {
                alert.informativeText = "A newer MicBridge release is available on GitHub."
                alert.addButton(withTitle: "Open Release")
                alert.addButton(withTitle: "Cancel")
            }
            let response = alert.runModal()
            if canInstallInternally, response == .alertFirstButtonReturn {
                runInternalUpdater(
                    version: latestVersion,
                    releaseURL: releaseURL,
                    archiveURL: archiveURL,
                    checksumURL: checksumURL
                )
                return
            }
            if canInstallInternally, response == .alertThirdButtonReturn {
                copyDriverUpdateCommand(version: latestVersion)
                return
            }
            if response == .alertSecondButtonReturn || (!canInstallInternally && response == .alertFirstButtonReturn) {
                NSWorkspace.shared.open(releaseURL)
            }
            return

        case let .unavailable(reason):
            alert.alertStyle = .warning
            alert.messageText = "Updates unavailable"
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")

        case let .failed(message):
            alert.alertStyle = .warning
            alert.messageText = "Update check failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }

        alert.runModal()
    }

    private func runInternalUpdater(version: String, releaseURL: URL, archiveURL: URL?, checksumURL: URL?) {
        guard let root = repoRoot else {
            NSWorkspace.shared.open(releaseURL)
            return
        }

        guard let scriptURL = internalUpdaterScriptURL() else {
            NSWorkspace.shared.open(releaseURL)
            return
        }

        guard let slug = githubRepoSlug() else {
            NSWorkspace.shared.open(releaseURL)
            return
        }

        let channel = currentUpdateChannel()
        updateState = .checking(channel: channel)
        updateProgressStatus = "Updates: Preparing install..."
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            var arguments = [scriptURL.path, "--version", version, "--repo", slug]
            if let archiveURL {
                arguments.append(contentsOf: ["--archive-url", archiveURL.absoluteString])
            }
            if let checksumURL {
                arguments.append(contentsOf: ["--checksum-url", checksumURL.absoluteString])
            }
            let progressFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("micbridge-update-progress-\(UUID().uuidString).txt")
            arguments.append(contentsOf: ["--progress-file", progressFileURL.path])
            process.arguments = arguments
            process.currentDirectoryURL = root

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                DispatchQueue.main.async {
                    self?.startUpdateProgressMonitor(progressFileURL: progressFileURL)
                }
                process.waitUntilExit()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                try? FileManager.default.removeItem(at: progressFileURL)

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.stopUpdateProgressMonitor()
                    if process.terminationStatus == 0 {
                        self.currentVersion = version
                        self.updateState = .upToDate(channel: channel, latestVersion: version)
                        self.updateProgressStatus = nil
                        self.rebuildMenu()

                        let success = NSAlert()
                        success.alertStyle = .informational
                        success.messageText = "Update installed"
                        success.informativeText = "MicBridge \(version) was installed. If launched manually, relaunch menubar to run the new binary."
                        success.addButton(withTitle: "OK")
                        success.runModal()
                    } else {
                        self.updateState = .failed(channel: channel, message: "Internal update failed")
                        self.updateProgressStatus = nil
                        self.rebuildMenu()
                        self.showInternalUpdateFailure(output: output, releaseURL: releaseURL)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: progressFileURL)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.stopUpdateProgressMonitor()
                    self.updateState = .failed(channel: channel, message: "Internal update failed")
                    self.updateProgressStatus = nil
                    self.rebuildMenu()
                    self.showInternalUpdateFailure(output: error.localizedDescription, releaseURL: releaseURL)
                }
            }
        }
    }

    private func startUpdateProgressMonitor(progressFileURL: URL) {
        stopUpdateProgressMonitor()
        updateProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let raw = try? String(contentsOf: progressFileURL, encoding: .utf8) else { return }
            let stage = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let mapped = self.mapUpdateProgress(stage: stage)
            if mapped != self.updateProgressStatus {
                self.updateProgressStatus = mapped
                self.rebuildMenu()
            }
        }
    }

    private func stopUpdateProgressMonitor() {
        updateProgressTimer?.invalidate()
        updateProgressTimer = nil
    }

    private func mapUpdateProgress(stage: String) -> String {
        switch stage {
        case "downloading":
            return "Updates: Downloading..."
        case "verifying":
            return "Updates: Verifying..."
        case "extracting":
            return "Updates: Preparing package..."
        case "installing":
            return "Updates: Installing..."
        case "restarting":
            return "Updates: Restarting services..."
        case "validating":
            return "Updates: Validating health..."
        case "completed":
            return "Updates: Completed"
        case "failed":
            return "Updates: Failed"
        default:
            return "Updates: Working..."
        }
    }

    private func showInternalUpdateFailure(output: String, releaseURL: URL) {
        let trimmed = output
            .split(separator: "\n")
            .suffix(12)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Automatic install failed"
        if trimmed.isEmpty {
            alert.informativeText = "Open release page and install manually."
        } else {
            alert.informativeText = "Open release page and install manually.\n\n\(trimmed)"
        }
        alert.addButton(withTitle: "Open Release")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private func copyDriverUpdateCommand(version: String) {
        guard let slug = githubRepoSlug() else { return }

        let command: String
        if let root = repoRoot {
            command = "sudo \(quoted(root.path))/scripts/internal-update.sh --version \(version) --repo \(slug) --apply-driver-update"
        } else {
            command = "sudo ./scripts/internal-update.sh --version \(version) --repo \(slug) --apply-driver-update"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Driver update command copied"
        alert.informativeText = command
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func currentUpdateChannel() -> UpdateChannel {
        switch updateState {
        case let .idle(channel),
             let .checking(channel),
             let .upToDate(channel, _),
             let .updateAvailable(channel, _, _, _, _),
             let .failed(channel, _):
            return channel
        case .unavailable:
            return UpdateChannel.resolve(currentVersion: currentVersion)
        }
    }

    private func canRunInternalUpdater() -> Bool {
        guard repoRoot != nil else { return false }
        guard githubRepoSlug() != nil else { return false }
        return internalUpdaterScriptURL() != nil
    }

    private func internalUpdaterScriptURL() -> URL? {
        guard let root = repoRoot else { return nil }
        let candidate = root.appendingPathComponent("scripts/internal-update.sh")
        guard FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func updatesURL() -> URL? {
        if let repoURL = githubRepoURL() {
            return repoURL.appendingPathComponent("releases/latest")
        }
        return URL(string: "https://github.com")
    }

    private func githubRepoSlug() -> String? {
        if let bundledSlugRaw = Bundle.main.object(forInfoDictionaryKey: "MicBridgeRepoSlug") as? String {
            let bundledSlug = bundledSlugRaw.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines))
            if bundledSlug.contains("/") {
                return bundledSlug
            }
        }

        guard let root = repoRoot else { return nil }
        guard let remote = runShellAndCapture("cd \(quoted(root.path)) && git remote get-url origin"), !remote.isEmpty else {
            return nil
        }

        let normalizedRemote: String
        if remote.hasPrefix("git@github.com:") {
            normalizedRemote = remote.replacingOccurrences(of: "git@github.com:", with: "")
        } else if remote.hasPrefix("https://github.com/") {
            normalizedRemote = remote.replacingOccurrences(of: "https://github.com/", with: "")
        } else if remote.hasPrefix("http://github.com/") {
            normalizedRemote = remote.replacingOccurrences(of: "http://github.com/", with: "")
        } else {
            return nil
        }

        let trimmed = normalizedRemote
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return trimmed.contains("/") ? trimmed : nil
    }

    private func githubRepoURL() -> URL? {
        guard let slug = githubRepoSlug() else { return nil }
        return URL(string: "https://github.com/\(slug)")
    }

    private func resolveCurrentVersion() -> String {
        if let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleVersion.isEmpty
        {
            return bundleVersion
        }

        if
            let root = repoRoot,
            let envVersion = versionFromEnvFile(root.appendingPathComponent("version.env"))
        {
            return envVersion
        }

        return "0.0.0-dev"
    }

    private func versionFromEnvFile(_ path: URL) -> String? {
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }

        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("MARKETING_VERSION=") else { continue }
            let raw = trimmed.replacingOccurrences(of: "MARKETING_VERSION=", with: "")
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines))
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func runShellAndCapture(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            BridgeLogger.log(.error, "Shell command failed: \(error)")
            return nil
        }
    }

    private func resolveRepoRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["MICBRIDGE_REPO_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }

        if let bundledRoot = Bundle.main.object(forInfoDictionaryKey: "MicBridgeRepoRoot") as? String, !bundledRoot.isEmpty {
            let url = URL(fileURLWithPath: bundledRoot, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd
        }

        var current = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func quoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

let app = NSApplication.shared
let delegate = MenuBarController()
app.delegate = delegate
app.run()
