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
1. Sleep/wake (3 cycles)
- Sleep 30-60s each cycle.
- Verify daemon returns to `running` within 10s.

2. Replug source interface (5 cycles)
- Unplug USB interface 5s.
- Replug and confirm auto recovery.

3. Long soak
- Keep bridge active 8h.
- Verify no growing distortion/drift and no daemon crash.

## Observability
- Status: `~/Library/Application Support/MacVirtualMicBridge/status.json`
- Logs: `~/Library/Logs/MacVirtualMicBridge/daemon.log`, `~/Library/Logs/MacVirtualMicBridge/menubar.log`
- Support bundle: `./scripts/collect-support-bundle.sh`

## Exit Criteria
- No daemon crash in 8h soak.
- Reconnect recovery success >= 95% across cycles.
- No sustained noise artifacts after wake/replug.
