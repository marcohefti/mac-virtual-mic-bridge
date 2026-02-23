# Bugfix Guidelines

Use this runbook for every bug report.

## Objective

Fix the bug once, and prevent recurrence with durable regression coverage.

## Required Flow

1. Define the bug clearly
- Record expected behavior vs actual behavior.
- Record trigger conditions (sleep/wake, reconnect, specific app, timing, etc).

2. Reproduce on current state
- Confirm the issue is reproducible before changing code.
- Capture logs/status needed for diagnosis.

3. Capture regression input
- Freeze current CoreAudio surface:
  - `./scripts/capture-fixture.sh <bug_name>`
- Store fixture in `packages/bridge-core/fixtures`.

4. Write failing regression assertion first
- Add/update assertions in:
  - `packages/bridge-core/Validation/FixtureValidator/main.swift`
- Add/update scenario rows in:
  - `packages/bridge-core/fixtures/validation_cases.json`
- Ensure assertion fails before fix.

5. Implement minimal fix
- Patch the smallest layer that owns the behavior.
- Keep boundaries intact:
  - driver: realtime callback path only
  - daemon/core: policy/recovery decisions
  - menubar: operator UX only

6. Validate end-to-end
- Mandatory:
  - `./scripts/validate.sh`
- For runtime/device/recovery bugs:
  - `./scripts/validate.sh --live`

7. Close with evidence
- Document:
  - root cause
  - fix summary
  - fixture/assertions added
  - validation commands/results

## Severity Triage

- Critical: data corruption, system audio breakage, persistent crash.
- High: frequent failure in normal workflows.
- Medium: recoverable failure with manual action.
- Low: cosmetic or minor operator friction.

Prioritize Critical/High first; avoid broad refactors unless directly required for reliability.

## Rules

- No bugfix is complete without regression coverage (fixture + assertion).
- Do not ship “works on my machine” without `validate` gate evidence.
- Prefer deterministic checks over manual-only verification.
