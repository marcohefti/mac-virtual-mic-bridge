# Development Workflow

This runbook defines how we implement work so bugs do not repeat.

## Standard Task Flow

1. Locate the subsystem
- Use `docs/INDEX.md` and `AGENTS.md` to route to architecture/runbooks.

2. Implement the change
- Keep driver realtime path deterministic.
- Keep policy in daemon/core, not in the HAL callback path.

3. Run quality gate
- `./scripts/validate.sh`

4. If task touches runtime behavior, run live checks
- `./scripts/validate.sh --live`

## Bugfix Flow (Fixture-First TDD)

Detailed bugfix checklist:
- `docs/runbooks/bugfix-guidelines.md`

1. Capture the failing machine surface
- `./scripts/capture-fixture.sh <bug_name>`

2. Add or update validator assertions
- Edit `packages/bridge-core/Validation/FixtureValidator/main.swift`.
- Add/update case entries in `packages/bridge-core/fixtures/validation_cases.json`.
- Ensure new assertions fail before the fix.

3. Implement fix in production code
- Common files:
  - `packages/bridge-core/Sources/BridgeCore/CoreAudioDeviceRegistry.swift`
  - `packages/bridge-core/Sources/BridgeCore/AudioBridgeEngine.swift`
  - `services/bridge-daemon/Sources/MicBridgeDaemon/main.swift`

4. Re-run gates
- `./scripts/validate.sh`
- `./scripts/validate.sh --live` (when relevant)

5. Keep fixture + assertions in repo
- Regression coverage is part of done criteria.

## Done Criteria

- Task-specific behavior works.
- `./scripts/validate.sh` passes.
- For device/recovery/runtime changes, `./scripts/validate.sh --live` passes locally.
- Any new bug scenario has durable fixture/assertion coverage.
