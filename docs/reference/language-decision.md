# Language Decision

## Goal
Maximize runtime reliability for a macOS virtual microphone bridge that must survive:
- sleep/wake
- USB device disconnect/reconnect
- long-running sessions in Electron/WebRTC clients

## Decision
Use a split stack:
- `C++/Objective-C++` for `AudioServerPlugIn` driver (`drivers/micbridge-hal`)
- `Swift` for daemon and menu bar (`services/bridge-daemon`, `apps/menubar`)

## Rationale

1. Driver reliability and determinism
- HAL driver callbacks are hard real-time and low-level C ABI.
- C++/ObjC++ gives strict control over memory layout, lock usage, and callback cost.

2. macOS integration reliability
- Swift is the least-friction choice for sleep/wake notifications, launch ergonomics, and menu bar UX.
- The daemon is control-plane oriented, where Swift clarity improves maintainability.

3. Failure-domain isolation
- Driver is tiny and real-time-safe.
- Daemon owns reconnection strategy and policy.
- UI owns operator controls only.

## Rejected options

- All Swift including driver:
  - Higher risk at HAL boundary and callback-level predictability.

- All C++ including UI/daemon:
  - Lower productivity for macOS UX and service integration, no reliability gain where it matters.
