# AGENTS Map

This file is the entrypoint for new agents. Treat it as a router to the right docs/runbooks for the task at hand.

## Mission
Ship a resilient virtual mic bridge that survives sleep/wake, USB reconnects, and long Electron/WebRTC sessions.

## Initialization Sequence

1. Open `docs/INDEX.md`.
2. Route to the task-specific doc(s).
3. Run baseline quality gate before and after changes:
   - `./scripts/validate.sh`

## Task Router

- Architecture or subsystem boundaries:
  - `docs/ARCHITECTURE.md`
- Why driver is C++/ObjC++ and control-plane is Swift:
  - `docs/reference/language-decision.md`
- End-of-task validation rules and commands:
  - `docs/reference/validation-gate.md`
- Bugfix execution checklist (fixture-first, regression-locked):
  - `docs/runbooks/bugfix-guidelines.md`
- Bugfix methodology / fixture-first TDD workflow:
  - `docs/runbooks/development-workflow.md`
- Local install/run/recovery operations:
  - `docs/runbooks/operations.md`
- Manual resilience/soak scenarios:
  - `docs/runbooks/test-matrix.md`
- Release packaging and publication flow:
  - `docs/runbooks/releasing.md`
- Future signed distribution plan (docs only):
  - `docs/runbooks/signed-distribution-plan.md`
- Fixture strategy details:
  - `docs/reference/validation-strategy.md`

## Monorepo Layout

- `drivers/micbridge-hal`: HAL driver (`AudioServerPlugIn`)
- `services/bridge-daemon`: daemon runtime and recovery loop
- `apps/menubar`: operator UI
- `packages/bridge-core`: shared config/status + core audio logic
- `scripts`: build/install/run/validate entrypoints
- `docs`: architecture, references, runbooks

## Mechanics Quick Reference

- End-of-task quality gate:
  - `./scripts/validate.sh`
- End-of-task gate + live local checks:
  - `./scripts/validate.sh --live`
- Deterministic audio e2e waveform check:
  - `./scripts/validate-audio-e2e.sh`
- Full install/audio/uninstall lifecycle check (test driver name + restore):
  - `./scripts/validate-e2e-lifecycle.sh`
- Release packaging smoke check:
  - `./scripts/validate-release-artifacts.sh`
- Internal updater integrity check:
  - `./scripts/validate-internal-update.sh`
- Package release archive:
  - `./scripts/package-release.sh`
- Package internal ad-hoc app bundle:
  - `./scripts/package-app.sh`
- Create GitHub release:
  - `./scripts/release.sh`
- Verify release assets:
  - `./scripts/check-release-assets.sh v<version>`
- Capture a bug fixture from current machine:
  - `./scripts/capture-fixture.sh <name>`
- Collect support bundle (status/config/logs + launchd diagnostics):
  - `./scripts/collect-support-bundle.sh`
- Build all:
  - `./scripts/build-all.sh`
- Install runtime binaries:
  - `./scripts/install-runtime-binaries.sh`
- Install driver:
  - `sudo ./scripts/install-driver.sh`
- Safe install driver (auto rollback on failed post-install health):
  - `sudo ./scripts/safe-install-driver.sh`
- Install driver from prebuilt bundle:
  - `sudo ./scripts/install-driver-bundle.sh /path/to/MicBridge.driver`
- Internal update (download + checksum + rollback):
  - `./scripts/internal-update.sh --version <version> --repo <owner/repo>`
- Start/stop daemon:
  - `./scripts/start-daemon.sh`
  - `./scripts/stop-daemon.sh`
- Install/remove launchd daemon service:
  - `./scripts/install-daemon-service.sh`
  - `./scripts/uninstall-daemon-service.sh`
- Install/remove launchd menubar service:
  - `./scripts/install-menubar-service.sh`
  - `./scripts/menubar-service-status.sh`
  - `./scripts/uninstall-menubar-service.sh`
- Run menubar:
  - `./scripts/run-menubar.sh`
- Optional pre-commit validate hook:
  - `./scripts/install-pre-commit-hook.sh`

## Non-Negotiable Invariants

- Driver callback path must remain deterministic and allocation-free.
- Recovery policy belongs in daemon/core, not in driver callbacks.
- Menubar stays UX/control-plane only (no DSP path logic).
- `BridgeConfig`/`BridgeStatus` contracts remain stable:
  - `packages/bridge-core/Sources/BridgeCore/BridgeConfig.swift`
