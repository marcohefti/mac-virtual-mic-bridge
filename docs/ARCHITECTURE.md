# Architecture

## Runtime Components

1. HAL Driver (`drivers/micbridge-hal`)
- Owns virtual input device presented to apps.
- Exposes duplex streams (output for injection, input for app capture).
- Performs ring-buffer loopback between output and input in real-time callbacks.
- No UI or policy logic.

2. Bridge Daemon (`services/bridge-daemon`)
- Captures physical input and pushes to target path.
- Owns restart/recovery policy.
- Writes status heartbeat for operator visibility.

3. Menu Bar (`apps/menubar`)
- Select source input device.
- Show readonly route (`input -> virtual input`).
- Provide operator actions (`Check for Updates`, `About`, `Quit`) and status icon.
- Performs control-plane update checks against GitHub releases (stable/beta channel aware).

4. Shared Core (`packages/bridge-core`)
- Config/status data contracts.
- CoreAudio registry helpers.
- Audio ring buffer and bridge engine.

## Reliability Invariants
- Force 48kHz canonical path unless explicit override is validated.
- Keep driver callback path lock-minimal and allocation-free.
- Handle sleep/wake by explicit stop/restart cycle.
- Treat device loss as expected event; auto-recover.
