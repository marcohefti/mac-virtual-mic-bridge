# Operations Runbook

How to install, run, validate, and recover the local stack.

## Build

- Build everything:
  - `./scripts/build-all.sh`
- Install runtime binaries used by daemon/menubar launch scripts:
  - `./scripts/install-runtime-binaries.sh`

## Install / Uninstall Driver

- Install:
  - `sudo ./scripts/install-driver.sh`
- Safe install with automatic rollback if post-install health checks fail:
  - `sudo ./scripts/safe-install-driver.sh`
- Install with custom device name:
  - `sudo ./scripts/install-driver.sh --device-name "Your Virtual Mic Name"`
- Safe install with custom device name:
  - `sudo ./scripts/safe-install-driver.sh --device-name "Your Virtual Mic Name"`
- Uninstall:
  - `sudo ./scripts/uninstall-driver.sh`
- Install driver from a prebuilt bundle:
  - `sudo ./scripts/install-driver-bundle.sh /path/to/MicBridge.driver`

## launchd Service (Daemon Autostart)

- Install/start user LaunchAgent:
  - `./scripts/install-daemon-service.sh`
- Check service state:
  - `./scripts/daemon-service-status.sh`
- Remove service:
  - `./scripts/uninstall-daemon-service.sh`

## launchd Service (Menubar Autostart)

- Install/start user LaunchAgent:
  - `./scripts/install-menubar-service.sh`
- Check service state:
  - `./scripts/menubar-service-status.sh`
- Remove service:
  - `./scripts/uninstall-menubar-service.sh`

## Run / Stop

- Start daemon:
  - `./scripts/start-daemon.sh`
- Run menu bar app:
  - `./scripts/run-menubar.sh`
- Stop daemon:
  - `./scripts/stop-daemon.sh`
- Note:
  - quitting/closing menubar does not disable bridge audio by itself; stopping daemon disables bridging.

## Health Checks

- End-of-task gate:
  - `./scripts/validate.sh`
- Live local health:
  - `./scripts/validate.sh --live`
- Deterministic audio path validation (no global default audio-device change):
  - `./scripts/validate-audio-e2e.sh`
- Full install->audio->uninstall lifecycle validation with explicit pass/fail signals:
  - `./scripts/validate-e2e-lifecycle.sh`
- Release artifact packaging smoke check:
  - `./scripts/validate-release-artifacts.sh`
- Status file:
  - `~/Library/Application Support/MacVirtualMicBridge/status.json`
- Runtime binaries:
  - `~/Library/Application Support/MacVirtualMicBridge/bin/current`
- Log files (auto-rotated, 5 MiB each, 4 archives kept):
  - `~/Library/Logs/MacVirtualMicBridge/daemon.log`
  - `~/Library/Logs/MacVirtualMicBridge/menubar.log`
  - Archives: `*.log.1` .. `*.log.4`
- Collect support bundle (config + status + logs + launchd diagnostics):
  - `./scripts/collect-support-bundle.sh`

## Optional Git Hook

- Install pre-commit hook (`./scripts/validate.sh` on commit):
  - `./scripts/install-pre-commit-hook.sh`
- Uninstall pre-commit hook:
  - `./scripts/uninstall-pre-commit-hook.sh`

## Release

- Package release archive:
  - `./scripts/package-release.sh`
- Package internal ad-hoc signed app bundle:
  - `./scripts/package-app.sh`
- Create draft GitHub release:
  - `./scripts/release.sh`
- Dry-run release (no GitHub release):
  - `./scripts/release.sh --dry-run`
- Verify release assets:
  - `./scripts/check-release-assets.sh v<version>`
- Apply internal in-place update (download + checksum + rollback-safe binary replacement):
  - `./scripts/internal-update.sh --version <version> --repo <owner/repo>`
- Apply internal update and install bundled driver (requires sudo):
  - `sudo ./scripts/internal-update.sh --version <version> --repo <owner/repo> --apply-driver-update`
- Validate internal updater e2e behavior:
  - `./scripts/validate-internal-update.sh`

## Fast Recovery

If audio routing behaves incorrectly after sleep/wake or device changes:

1. Restart daemon
- `./scripts/stop-daemon.sh`
- `./scripts/start-daemon.sh`

2. Re-check status/log
- Confirm `state` is `running` in `status.json`.
- Inspect latest daemon log lines.

3. Validate live stack
- `./scripts/validate.sh --live`

4. If driver visibility is missing, reinstall driver
- `sudo ./scripts/uninstall-driver.sh`
- `sudo ./scripts/install-driver.sh`

5. If issue persists, capture fixture for regression work
- `./scripts/capture-fixture.sh incident_<short_name>`
6. For maintainer handoff, generate support bundle
- `./scripts/collect-support-bundle.sh`
