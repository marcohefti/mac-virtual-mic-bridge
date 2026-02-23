# Validation Gate

`./scripts/validate.sh` is the default end-of-task quality gate.

## Usage

- Standard (CI-compatible):
  - `./scripts/validate.sh`
- Split steps (used by CI jobs):
  - `./scripts/validate-swift.sh`
  - `./scripts/validate-driver-build.sh`
  - `./scripts/validate-release-artifacts.sh`
  - `./scripts/validate-internal-update.sh`
- Local with live daemon/device checks:
  - `./scripts/validate.sh --live`
- Optional deterministic audio round-trip check (machine-specific, no system-default output mutation):
  - `./scripts/validate-audio-e2e.sh`
- Optional full lifecycle check (requires sudo operations):
  - `./scripts/validate-e2e-lifecycle.sh`

## What It Validates

1. Shell script syntax
- Runs `zsh -n` across:
  - `scripts/*.sh`
  - `drivers/micbridge-hal/scripts/*.sh`
  - `.githooks/pre-commit`

2. Swift debug/release build + fixture checks
- Executes `scripts/validate-swift.sh`.
- Compiles all Swift products in debug and release mode.
- Runs fixture regression assertions.

3. HAL driver build
- Executes `scripts/validate-driver-build.sh`.
- Builds `MicBridge.driver` from source (`AudioServerPlugIn`) and verifies signing output.

4. Fixture regression checks
- Executes `micbridge-fixture-validate` assertions against committed fixtures.
- Uses table-driven scenarios from `packages/bridge-core/fixtures/validation_cases.json`.

5. Optional live local stack checks (`--live`)
- Executes `scripts/validate-live-stack.sh`.
- Verifies local CoreAudio target visibility and daemon status.

6. Optional audio waveform integrity check
- Executes `scripts/validate-audio-e2e.sh`.
- Injects deterministic tone by device UID and captures by device UID.
- Verifies that captured waveform is present and sufficiently similar to the reference tone.
- This check intentionally does not change global macOS default input/output devices.

7. Optional install/uninstall lifecycle integrity check
- Executes `scripts/validate-e2e-lifecycle.sh`.
- Runs safe install with a test driver name, validates visibility, runs live + audio checks, uninstalls, and verifies absence.
- If a MicBridge driver was already present before the run, restores that original bundle at the end.

8. Internal updater integrity check
- Executes `scripts/validate-internal-update.sh`.
- Validates internal updater success path from local release artifact.
- Validates checksum failure path preserves the active runtime symlink (no partial switch).

## Policy

- Every completed coding task should end with `./scripts/validate.sh`.
- Every bugfix should add fixture/assertion coverage before or with the fix.
- Use `--live` before manual QA or when touching device selection/recovery logic.
- CI additionally runs `./scripts/validate-release-artifacts.sh` as packaging smoke coverage.

## Optional Enforcement

- Install a pre-commit hook that runs this gate:
  - `./scripts/install-pre-commit-hook.sh`
