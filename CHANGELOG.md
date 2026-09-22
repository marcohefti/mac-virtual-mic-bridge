# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0

- Improve virtual microphone timing and bounded buffering to prevent latency accumulation.
- Preserve a single selected interface channel with per-device channel selection and channel identification.
- Add sleep/reconnect recovery, callback health monitoring, microphone permission checks, and supervised daemon restarts.
- Add rotating diagnostic logs, support bundles, and safer driver installation with rollback.
- Launch the current app consistently at login; show a microphone icon with a colored status badge.
- Keep the menu compact with separate interface and virtual-input signal status, plus scrollable and copyable diagnostics.
- Expand waveform, transport, recovery, and packaging validation; build every Swift product in the quality gate.

Known limitations:
- Real USB unplug/replug and sleep/wake cycle testing remains pending.
- The eight-hour soak kept the daemon running but recorded cumulative underflows and drops; uninterrupted long-session audio is not yet proven.
- App bundles are ad-hoc signed and not notarized.

## 0.1.0

- Initial release baseline:
  - in-repo HAL virtual mic driver
  - daemon bridge and recovery loop
  - minimal menubar control plane
  - deterministic validation scripts (fixture, live, audio e2e, lifecycle)
