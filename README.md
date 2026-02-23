# Mac Virtual Mic Bridge

First-party monorepo for a resilient macOS virtual microphone bridge.

No external virtual-audio dependency is used. The virtual mic driver is implemented in-repo.

## Problem Statement

On macOS, several Electron/WebRTC apps (for example Discord and GeForce NOW) often fail to work reliably with external audio interfaces like Audient devices. The physical interface works in many native apps, but these apps may not see or handle the input correctly.

Existing workarounds were not reliable enough:
- Routing through Audio MIDI + Carla could work initially, but after 30-60+ minutes it would sometimes degrade into noise artifacts.
- Routing through Voicemod was more stable short-term, but frequently crashed after sleep/standby wake with critical errors and required manual restarts.

The operator need is simple: pick a real input, expose a stable virtual microphone, and keep it running through normal laptop behavior (sleep/wake, reconnects, long sessions) with minimal friction.

This project exists to provide a small, resilient, open-source, native macOS solution with a menu bar UX and first-party control over the full audio path.

## Monorepo

- `drivers/micbridge-hal`: C++/ObjC++ HAL virtual device (`AudioServerPlugIn`)
- `services/bridge-daemon`: Swift bridge daemon with sleep/wake + reconnect recovery
- `apps/menubar`: Swift menu bar operator UI
- `packages/bridge-core`: shared Swift runtime logic
- `docs`: architecture, runbooks, design decisions
- `AGENTS.md`: fast onboarding map for new coding agents

## Reliability Stack

- Driver path is isolated and deterministic.
- Daemon owns resilience policy and restarts.
- UI remains thin and operationally focused.

## Build

```bash
./scripts/build-all.sh
```

Or build Swift binaries only:

```bash
swift build -c release --product micbridge-daemon --product micbridge-menubar
```

## Validation

Default end-of-task quality gate (typecheck/build + driver build + fixture checks):

```bash
./scripts/validate.sh
```

Include live local daemon/device checks:

```bash
./scripts/validate.sh --live
```

Run split validation steps directly:

```bash
./scripts/validate-swift.sh
./scripts/validate-driver-build.sh
./scripts/validate-release-artifacts.sh
./scripts/validate-internal-update.sh
```

Run deterministic audio end-to-end validation (inject by UID, capture by UID, restore config afterward, no default-device mutation):

```bash
./scripts/validate-audio-e2e.sh
```

Run full lifecycle validation (safe install -> live -> audio e2e -> uninstall) with a dedicated test driver name and automatic restore of any pre-existing driver bundle:

```bash
./scripts/validate-e2e-lifecycle.sh
```

Fixture files live in:
- `packages/bridge-core/fixtures`
- `packages/bridge-core/fixtures/validation_cases.json` (table-driven validation scenarios)

Capture a new fixture from your current local CoreAudio stack:

```bash
./scripts/capture-fixture.sh <fixture-name>
```

Validation strategy is documented in:
- `docs/reference/validation-strategy.md`

Validation gate details are documented in:
- `docs/reference/validation-gate.md`

Development methodology and operations are documented in:
- `docs/runbooks/development-workflow.md`
- `docs/runbooks/bugfix-guidelines.md`
- `docs/runbooks/operations.md`
- `docs/INDEX.md`

## Driver Install

```bash
sudo ./scripts/install-driver.sh
```

Safer transactional install (auto rollback if post-install health checks fail):

```bash
sudo ./scripts/safe-install-driver.sh
```

Custom name (defaults to `MicBridge Virtual Mic`):

```bash
sudo ./scripts/install-driver.sh --device-name "Marco Virtual Mic"
```

Safe install with custom name:

```bash
sudo ./scripts/safe-install-driver.sh --device-name "Marco Virtual Mic"
```

## Dev Sudo Bootstrap (Optional)

If you want Codex to run install/uninstall driver tests without prompting for a password each time, install a narrow local sudo rule:

```bash
./scripts/setup-dev-sudo.sh
```

This grants passwordless sudo only for:
- `scripts/install-driver.sh`
- `scripts/uninstall-driver.sh`
- `scripts/safe-install-driver.sh`

Remove it anytime:

```bash
./scripts/remove-dev-sudo.sh
```

Uninstall:

```bash
sudo ./scripts/uninstall-driver.sh
```

## Install via Homebrew Cask (Private Tap)

Install MicBridge into `/Applications` from the private tap:

```bash
brew tap marcohefti/homebrew-micbridge
brew install --cask marcohefti/homebrew-micbridge/micbridge
```

Upgrade:

```bash
brew upgrade --cask marcohefti/homebrew-micbridge/micbridge
```

Uninstall:

```bash
brew uninstall --cask marcohefti/homebrew-micbridge/micbridge
```

Note:
- This tap is private to the MicBridge project (not Homebrew core).
- Unsigned builds may require first-launch approval in `System Settings > Privacy & Security`.

## Run

```bash
./scripts/start-daemon.sh
./scripts/run-menubar.sh
```

Runtime binaries are installed into:
- `~/Library/Application Support/MacVirtualMicBridge/bin/current`

Install/update runtime binaries from the current repo build:

```bash
./scripts/install-runtime-binaries.sh
```

Stop daemon:

```bash
./scripts/stop-daemon.sh
```

Install daemon as launchd user service (autostart + restart):

```bash
./scripts/install-daemon-service.sh
```

Check launchd service status:

```bash
./scripts/daemon-service-status.sh
```

Remove launchd service:

```bash
./scripts/uninstall-daemon-service.sh
```

Install menubar as launchd user service (autostart + restart):

```bash
./scripts/install-menubar-service.sh
```

Check menubar launchd service status:

```bash
./scripts/menubar-service-status.sh
```

Remove menubar launchd service:

```bash
./scripts/uninstall-menubar-service.sh
```

Disable bridge audio:

```bash
./scripts/stop-daemon.sh
```

Quitting the menubar app only closes the UI; it does not stop the daemon.

## Updates

- `Check for Updates...` now performs an in-app GitHub release check (instead of only opening the Releases page).
- Release channel is resolved as:
  1. `MICBRIDGE_UPDATE_CHANNEL` env var (`stable` or `beta`) if set.
  2. `UserDefaults` key `micbridge.updateChannel` if present.
  3. Auto-detected default from version string (`beta/alpha/rc/dev` => beta, otherwise stable).
- If a newer release is found:
  - when running from repo with `scripts/internal-update.sh`, menu can install the update in place (download + checksum verify + rollback-safe binary replacement),
  - otherwise it opens the GitHub release page.

Run internal updater directly:

```bash
./scripts/internal-update.sh --version <version> --repo <owner/repo>
```

The internal updater now:
- uses a single-update lock (`~/Library/Application Support/MacVirtualMicBridge/update.lock`),
- installs into versioned runtime dirs under `bin/releases`,
- atomically repoints `bin/current`,
- restarts services and runs `./scripts/validate-live-stack.sh`,
- auto-rolls back to the previous runtime if post-update health fails.

Optional driver update from downloaded release bundle (requires sudo):

```bash
sudo ./scripts/internal-update.sh --version <version> --repo <owner/repo> --apply-driver-update
```

## Releasing

Version metadata is tracked in:

```bash
version.env
```

Package release artifacts:

```bash
./scripts/package-release.sh
```

Run full release flow (validate + package + draft GitHub release):

```bash
./scripts/release.sh
```

Dry run (no tag/release):

```bash
./scripts/release.sh --dry-run
```

Create internal ad-hoc signed app bundle:

```bash
./scripts/package-app.sh
```

Build app zip + checksum assets used by Homebrew cask releases:

```bash
./scripts/package-cask-assets.sh
```

Verify release assets on GitHub:

```bash
./scripts/check-release-assets.sh v<version>
```

Publish/update the private tap cask to the latest release:

```bash
./scripts/publish-homebrew-cask.sh
```

Optional pre-commit hook (`./scripts/validate.sh` on commit):

```bash
./scripts/install-pre-commit-hook.sh
```

## Runtime Files

- config/status: `~/Library/Application Support/MacVirtualMicBridge`
- runtime binaries: `~/Library/Application Support/MacVirtualMicBridge/bin/current`
- updater lock: `~/Library/Application Support/MacVirtualMicBridge/update.lock`
- logs (auto-rotated, 5 MiB each, 4 archives kept):
  - `~/Library/Logs/MacVirtualMicBridge/daemon.log`
  - `~/Library/Logs/MacVirtualMicBridge/menubar.log`
  - archives: `*.log.1` .. `*.log.4`
- support bundle for maintainer triage:
  - `./scripts/collect-support-bundle.sh`

## Current Phase

- In-repo HAL driver is installable and exposes a duplex virtual device.
- Driver loopbacks its output stream into its input stream with an internal ring buffer.
- Daemon can target `MicBridge Virtual Mic` output while apps read from `MicBridge Virtual Mic` input.
