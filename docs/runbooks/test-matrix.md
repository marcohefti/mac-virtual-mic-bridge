# Test Matrix

## Automated Gate
1. End-of-task quality gate:
   - `./scripts/validate.sh`
2. Local live stack check:
   - `./scripts/validate.sh --live`
3. Optional deterministic audio loop integrity check:
   - `./scripts/validate-audio-e2e.sh`
4. Optional full lifecycle integrity check (safe install + audio e2e + uninstall + post-uninstall assert):
   - `./scripts/validate-e2e-lifecycle.sh`

## Smoke
1. Build all:
   - `./scripts/build-all.sh`
2. Install driver:
   - `sudo ./scripts/install-driver.sh`
3. Start daemon:
   - `./scripts/start-daemon.sh`
4. Start menubar:
   - `./scripts/run-menubar.sh`
5. Select source input in menubar and confirm route shows `input -> MicBridge Virtual Mic`.
6. In Discord/GeForce NOW, choose input device `MicBridge Virtual Mic`.

## Resilience
1. Sleep/wake (20 cycles)
- Sleep 30-60s each cycle.
- Verify real virtual microphone signal returns within 10s of the physical interface becoming available; a `running` status alone is insufficient.

2. Replug source interface (20 cycles)
- Unplug USB interface 5s.
- Replug and confirm actual signal recovery with Discord and a second reader left open; do not reselect the microphone.

3. Long soak
- Keep bridge active 8h.
- Verify no growing distortion/drift and no daemon crash.

## Observability
- Status: `~/Library/Application Support/MacVirtualMicBridge/status.json`
- Logs: `~/Library/Logs/MacVirtualMicBridge/daemon.log`, `~/Library/Logs/MacVirtualMicBridge/menubar.log`
- Support bundle: `./scripts/collect-support-bundle.sh`

## Exit Criteria
- No daemon crash in 8h soak.
- Reconnect recovery success 100% across all recorded cycles; measure from interface availability, target <= 10 seconds.
- No sustained noise artifacts after wake/replug.

## Automated lifecycle coverage

Run `./scripts/validate-recovery.py --cycles 10` for missing source/target, invalid channel, disable/enable, reload, and process-crash recovery. Run native transport concurrency/drift tests through the main gate. Record physical sleep/replug results separately; fixture tests do not replace hardware cycles.

## Soak acceptance

Collect passive telemetry with `scripts/soak-monitor.py`. Review callback progress, driver delivery, cumulative underflows/drops, memory, CPU and queue depth. Startup/sleep discontinuities must be distinguished from steady-state glitches. A completed telemetry file alone is not a pass: evaluate its summary and counters against transition records. Do not claim full completion before the eight-hour interval has elapsed.
