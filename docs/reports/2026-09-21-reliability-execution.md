# Reliability execution — 2026-09-21

## Scope and baseline

User authorized the complete reliability plan, including implementation, installation, recovery checks, real hardware transitions, and an eight-hour soak. Hardware interaction and elapsed soak time are acceptance requirements, not replaceable by synthetic tests.

Baseline `./scripts/validate.sh --live` passed before these changes. Saved installed runtime, driver, configuration, and status under `~/Library/Application Support/MacVirtualMicBridge/backups/reliability-20260921-124934`.

## Implemented

- Strict configured target matching; no arbitrary physical-output fallback. Reject MicBridge as its own source. Fixture test observed failing before fix.
- Partial AudioUnit setup cleanup; stop partially started sessions on errors.
- Explicit suspended recovery state, generation checks for delayed wake work, dedicated serial lifecycle worker, independent 45-second watchdog, and singleton lock.
- Capture/render progress, render-error and delivered-signal monitoring. Three stalled/silent-delivery health ticks request recovery; three health restarts in a minute escalate to process replacement. Normal quiet input is not a failure.
- Native preallocated SPSC transport with atomic telemetry and no callback mutex. Consumer owns backlog trimming. Windowed-sinc, 32-tap fractional resampling slews correction within ±2000 ppm; extreme backlog trimming remains a safety fallback.
- Driver timestamp callback no longer takes configuration mutex. Unchanged sample-rate writes do not reset clock seed; buffer-size changes do not reset timeline; notifications outside setter mutex. Regression observed failing before fix.
- Persistent launchd services, retirement of transient jobs, supervisor-aware start/stop, duplicate-process protection, normal menu quit no longer immediately respawns.
- Freshness-aware UI, CoreAudio channel names, per-device channel choices, explicit start/stop/restart, five-second local activity check. No automatic loudest-channel routing.
- Explicit 48 kHz hardware compatibility check instead of changing shared source clock. Nominal-rate API skips redundant writes.
- Per-device enumeration error isolation.
- Validation distinguishes inconclusive signal checks, enforces gain/polarity/full correlation, and verifies restored microphone routing. Installer retains rollback bundles and requires waveform plus restored signal checks.

## New finding during installation

The persistent daemon initially reported advancing callbacks but exact-zero captured samples while an independently launched capture process saw physical microphone signal. Unified logs showed microphone authorization being requested during AudioUnit setup, with authorization completing after setup began. A separate first-start microphone authorization gate was added with an embedded usage-description plist. The daemon now reports pending/denied authorization explicitly and starts AudioUnits only after authorization succeeds. Logs then showed permission granted followed by real source and virtual signal.

This establishes an observed permission/startup failure and recovery. It does not prove that every prior silence incident had the same cause. Ad-hoc development binaries may require authorization again after an update; signed distribution remains separate work.

The first safe-driver install rejected silent restored audio and automatically rolled back. The next install, after the permission gate, passed waveform integrity and restored microphone checks. Rollback retained at `/Library/Application Support/MicBridge/driver-backups/backup.ufWF9M`.

## Validation evidence so far

- Baseline and revised Swift debug/release builds, fixture assertions and driver tests passed.
- Concurrent transport test: 2,560,000 ramp samples transferred between producer/consumer threads without corruption.
- Simulated 128-second runs at −500/0/+500 ppm: zero drops, no underflows after priming, measured correction converged to injected drift, 997 Hz RMS within 0.0001 of reference.
- Installed isolated driver: 5-second waveform correlation 1, unity gain, zero normalized error, 64 ms latency.
- Installed physical/virtual signal comparison passed after permission gating and after driver installation.

## Outstanding acceptance evidence

Automated lifecycle repetitions, full daemon waveform/latency measurement, load and sanitizer checks, 20 physical unplug/replug cycles, 20 real sleep/wake cycles, logout/login behavior, and eight-hour soak must be recorded before declaring end-to-end completion. The input safety offset remains 2048 frames until measurement justifies reducing it; no unverified lower-latency claim is made.

## Automated recovery results

`./scripts/validate-recovery.py --cycles 10` passed recovery from a missing configured source, a missing configured target, an invalid channel, ten disable/enable cycles, SIGHUP, and forced daemon process death. launchd replaced the killed process and real signal returned. Numeric evidence is in `2026-09-21-recovery-results.json`.

Two short post-transition captures had transient zero samples (4.35% and 1.03% of the sampled interval). The presence test passed, but these are not clean continuity passes. Steady-state and application-open stress need separate dropout analysis.

Native transport ThreadSanitizer run passed the concurrent transfer and three clock-drift simulations without a race report. Release packaging and internal-update checksum/rollback checks passed.

## Final continuity adjustment

The first 30-second paired capture exposed 1,824 zero samples (longest run 1,024 frames) despite good level/correlation. Increased the adaptive transport target from one output callback/10 ms to three output callbacks/30 ms. Added simulated delayed capture callbacks to the clock-drift regression: all three ±500/0 ppm runs pass without post-priming underflow or drops.

The subsequent 30-second paired capture had zero inserted zero samples after warmup, no clipping, measured gain −0.006 to +0.001 dB, per-window correlation 0.999282–1.000000, and timestamp-adjusted physical-to-virtual latency 56.566–58.378 ms. These are short-window, current-hardware results, not an all-day guarantee. Numeric evidence is in `2026-09-21-reliability-quality-final.json`. Temporary raw captures were deleted.

## User steering

The user declined manual USB and sleep/wake testing and asked to rely on logs if an issue recurs. Those physical acceptance tests and logout/login validation remain unverified; do not claim them as passed. Passive soak monitoring is authorized by the original plan and requires no physical actions. Its completion must be judged after elapsed time, not at launch.

## Final handoff checks

Final installed-runtime recovery rerun passed missing source/target, invalid channel, three stop/start cycles, SIGHUP, and launchd recovery from a forced kill. All final signal captures had zero exact-zero samples in their evaluated windows. Duplicate daemon invocation was rejected by the singleton lock. See `2026-09-21-recovery-final.json`.

Passive eight-hour diagnostics started as a one-shot launchd job `ch.hefti.micbridge.soak`, writing `~/Library/Logs/MacVirtualMicBridge/soak-2026-09-21.jsonl`. This is running, not a completed soak pass. Its summary is written alongside the log when finished. It does not change routing, record audio, or prevent sleep.

Final `./scripts/validate.sh --live` passed after lifecycle testing completed. Support bundle collection succeeded at `/tmp/micbridge-final-diagnostics/micbridge-support-20260921_131457.tar.gz`. The first attempted concurrent live gate ran during an intentional disabled phase of the recovery test and correctly failed; final gating was then run after restoration.
