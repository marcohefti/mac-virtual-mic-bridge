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

## Microphone Channel

- Choose the interface under **Input Source**, then the physical socket under **Microphone Channel** (numbered from 1).
- A single microphone uses one selected channel at unity gain. Inputs are not averaged or automatically switched based on loudness.
- Existing configurations default to input 1. `sourceInputChannel` persists the selection; selecting a different device resets it to 1.
- An unavailable channel produces an error instead of silently capturing a different socket.
- The bridge captures the device's input channels and copies only the selected channel into the virtual microphone; stereo targets receive the same selected mono signal on both sides.

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
- Audio latency diagnostics:
  - Status `message` includes `queued_ms` (daemon queue only), `underflow`, and `dropped` frame counters.
  - The daemon logs an `Audio health` snapshot every 30 seconds while running.
  - `input_peak` and `output_peak` show the most recent captured and consumed block levels (linear Float32 amplitude). These help locate silence inside the daemon, but do not prove that a consuming application received audio. Run `./scripts/validate-live-stack.sh` to compare actual physical and virtual signal presence.
  - The live queue trims stale audio above 40 ms or two capture callbacks, whichever is larger, keeping 10 ms or one callback. This bounds accumulated clock drift; occasional discarded audio is preferable to continuously delayed speech.
  - These counters do not measure the virtual driver, Bluetooth output, or application playback delay.
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
- Package cask app assets (app zip + checksum):
  - `./scripts/package-cask-assets.sh`
- Create draft GitHub release:
  - `./scripts/release.sh`
- Dry-run release (no GitHub release):
  - `./scripts/release.sh --dry-run`
- Verify release assets:
  - `./scripts/check-release-assets.sh v<version>`
- Publish/update private tap cask:
  - `./scripts/publish-homebrew-cask.sh`
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


## Recovery supervision and diagnostics

The daemon waits for macOS microphone authorization before creating capture AudioUnits. Pending/denied access is an explicit error, not a running/silent bridge. Ad-hoc development updates may prompt again.

Audio lifecycle work runs on a serial worker. Sleep suspends retries; stale delayed wake work is cancelled by generation checks. A separate watchdog terminates a worker stalled for 45 seconds, allowing launchd to replace the process. Three repeated health restarts within a minute also escalate to process replacement. The installed login service enforces a single instance.

`input_callbacks`, `output_callbacks`, `delivery_callbacks`, `errors`, `last_error`, and `delivered_peak` supplement queue/capture telemetry. The virtual-input delivery monitor stores no recordings. Three health ticks without progress, or output signal with zero delivered signal, request recovery. Quiet input alone is healthy.

The native SPSC transport uses a 32-tap windowed-sinc resampler for gradual clock correction, reported as `correction_ppm`. Its scheduling target is 30 ms or three output callbacks, whichever is larger. Hard trimming is reserved for queues exceeding 80 ms or four output callbacks. The physical interface must be set to 48 kHz; the bridge does not change a shared source clock automatically.

- Automated reversible lifecycle checks: `./scripts/validate-recovery.py --cycles 10`
- Post-install waveform plus restored microphone check: `./scripts/verify-installed-audio.sh`
- Passive soak: `./scripts/soak-monitor.py --hours 8 --output /path/to/soak.jsonl`
- Native concurrent transport and drift regression: `./scripts/validate-transport.sh`
- `--check-live-signal` returns 2 for inconclusive silence; this is not an audio pass.
- Driver rollback bundles are retained under `/Library/Application Support/MicBridge/driver-backups`.

The menu reads channel names/counts from CoreAudio, remembers each device's channel selection, and offers an explicit five-second activity check. The loudest channel is only a suggestion. “Quit Menu” leaves audio running; “Stop Bridge” stops capture.
