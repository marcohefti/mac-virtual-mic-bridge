# Validation Strategy

This project uses layered validation so a fixed bug is captured as a regression check and cannot silently return.

For the concrete end-of-task gate command and exact checks, see:
- `docs/reference/validation-gate.md`

## Principle

When a bug is found:
1. Capture the current CoreAudio device surface into a fixture.
2. Add or update validator assertions that fail before the fix.
3. Implement the fix.
4. Run validation and keep the fixture/assertions in repo.

## Layers

## 1) Fixture Capture (Bug Intake)
- Command: `./scripts/capture-fixture.sh <fixture-name>`
- Runs: `micbridge-capture-fixture`
- Output: `packages/bridge-core/fixtures/<fixture-name>.json`
- Purpose: freeze the exact device graph from the failure machine as regression input.

## 2) Fixture Validation (Fast, Deterministic)
- Command: `./scripts/validate.sh`
- Runs: `micbridge-fixture-validate`
- Sources:
  - fixtures: `packages/bridge-core/fixtures/*.json`
  - table-driven case definitions: `packages/bridge-core/fixtures/validation_cases.json`
- Purpose: lock selection/recovery behavior independent of machine state.

Current assertions include:
- Missing configured source UID returns no source (daemon waits for that selected device to come back).
- Missing target UID falls back to preferred virtual mic name.
- Without preferred target, MicBridge UID/name is preferred over random outputs.
- Deterministic fallback when no virtual target exists.

## 3) Live Stack Validation (Machine-Specific)
- Command: `./scripts/validate.sh --live`
- Underlying script: `./scripts/validate-live-stack.sh`
- Purpose: check that the local CoreAudio graph currently exposes the target UID from status/config and daemon status is healthy.
- This script is intentionally non-destructive (no daemon/coreaudiod restart).

## 3b) Optional Audio Round-Trip Validation (Machine-Specific)
- Command: `./scripts/validate-audio-e2e.sh`
- Underlying executable: `micbridge-audio-e2e-validate`
- Purpose: inject deterministic tone by output device UID, capture by input device UID, and verify waveform similarity/error thresholds.
- This script restores daemon config after completion and does not change macOS global default audio devices.

## 3c) Optional Install/Uninstall Lifecycle Validation (Machine-Specific)
- Command: `./scripts/validate-e2e-lifecycle.sh`
- Purpose: run safe install (test-name), validate driver visibility, run live + audio checks, uninstall, and assert driver absence.
- If a MicBridge driver was present before the run, the script restores that pre-existing bundle at the end.

## 4) Manual Resilience Matrix
- Document: `docs/runbooks/test-matrix.md`
- Purpose: sleep/wake, replug cycles, and long soak validation for operational confidence.

## CI

GitHub Actions runs `./scripts/validate.sh` on each push/PR to enforce fixture-based regressions in automation.
