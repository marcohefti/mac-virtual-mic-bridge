import AppKit
import BridgeCore
import Darwin
import Foundation

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
            daemonState: status?.state,
            bridgeEnabled: config.enabled,
            inputAvailability: inputAvailability
        )

        let routeItem = NSMenuItem(
            title: "\(currentInputName()) -> \(config.virtualMicrophoneName)",
            action: nil,
            keyEquivalent: ""
        )
        routeItem.isEnabled = false
        menu.addItem(routeItem)

        let selectedInputStatusItem = NSMenuItem(title: selectedInputStatusText(inputAvailability), action: nil, keyEquivalent: "")
        selectedInputStatusItem.isEnabled = false
        menu.addItem(selectedInputStatusItem)

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

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard inputDevices.indices.contains(sender.tag) else { return }
        config.sourceDeviceUID = inputDevices[sender.tag].uid
        persistConfigAndSignalDaemon()
        rebuildMenu()
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
            return name
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

        let indicator: String
        let tooltip: String
        if bridgeEnabled, case .offline = inputAvailability {
            indicator = "🔴"
            tooltip = "MicBridge: Selected input offline (waiting for reconnect)"
        } else {
            switch daemonState {
            case .running where bridgeEnabled:
                indicator = "🟢"
                tooltip = "MicBridge: Running"
            case .running:
                indicator = "⚪"
                tooltip = "MicBridge: Running (Bridge Disabled)"
            case .starting, .restarting:
                indicator = "🟡"
                tooltip = "MicBridge: Recovering"
            case .error:
                indicator = "🔴"
                tooltip = "MicBridge: Error"
            case .stopped:
                indicator = "⚪"
                tooltip = "MicBridge: Stopped"
            case .none:
                indicator = "⚪"
                tooltip = "MicBridge: Unknown"
            }
        }

        button.image = nil
        button.title = indicator
        button.toolTip = tooltip
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
