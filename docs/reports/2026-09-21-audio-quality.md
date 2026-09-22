# Audio quality investigation — 2026-09-21

## Subsequent silence incident

The user subsequently reported complete silence in multiple apps. A new simultaneous capture confirmed a nonzero Audient input while the virtual input was entirely zero, despite `state=running`. Restarting the daemon restored audio. The earlier sample-perfect comparison was valid only for its capture interval; it did not establish restart reliability.

A deterministic read-before-write test exposed the missing input scheduling margin: the driver advertised zero input safety offset, allowing the HAL to request a timestamp before output had written it. The installed correction advertises one maximum IO buffer (2048 frames at 48 kHz) of input safety margin. The isolated waveform test then measured 64 ms with unity gain, correlation 1, and zero normalized error. This addresses scheduling headroom but **did not resolve the entire silence incident**: a subsequent disable/test/enable cycle again produced zero virtual samples while physical input remained nonzero.

A full daemon restart restored signal. Added `input_peak`/`output_peak` diagnostics distinguish captured from consumed samples without saving microphone recordings. Subsequent repeated disable/test/enable cycles passed, but no causal fix for the intermittent silent state has yet been established. Do not interpret these successful retries as proof of restart reliability.

Live validation now checks physical/virtual signal presence rather than relying solely on device visibility and status. If the physical input is silent, it explicitly reports an inconclusive result.

## Original comparison result

The repaired, installed bridge passed Audient iD14 input 1 through unchanged in a simultaneous 30-second capture. After alignment, all **1,437,360 overlapping Float32 samples** (29.945 seconds) matched exactly: unity gain, zero maximum error, no inserted zero samples, no clipped samples. Timestamp-adjusted source-to-virtual delay was approximately **27.8 ms**. This establishes transparency for this recording, not an all-day or sleep/wake guarantee.

## Before the fixes

- Input 1 carried the mic (RMS -31.65 dBFS); input 2 was essentially silent (-112.61 dBFS).
- Averaging inputs 1 and 2 reduced the mic by 6.02 dB. The virtual capture measured -37.94 dBFS overall.
- The 30-second virtual recording contained 119 interior all-zero runs of at least 32 samples, totalling 1.291 seconds. The direct input did not contain those gaps. Most recurred approximately every 250 ms.
- A five-second isolated driver test failed: full correlation 0.4249, normalized error 2.1306. The previous quarter-second test was too short to catch recurring resets reliably.
- The driver clock seed incorrectly advanced with every timestamp period. Apple's AudioServerPlugIn.h documents that changing the seed signals a new timeline requiring resynchronization. An isolated test of the actual implementation reproduced this without any configuration change.
- Fixing the clock exposed a separate queue problem: a stopped/reopened capture could replay old samples. The waveform became exact but one test took 1109 ms to arrive. The original FIFO also consumed data on each read.

## Changes applied

1. Explicit, persistent `sourceInputChannel` (one-based; old configurations default to 1), with a **Microphone Channel** menu. Capture all source channels and copy only the chosen one at unity gain. Switching source devices resets to input 1; invalid selections fail explicitly. No automatic loudness-based switching or implicit mixing.
2. Keep the driver clock seed stable during normal clock progress.
3. Address driver samples by the HAL input/output sample timestamps. Reads no longer consume history or another reader's samples. Preallocated lock-free atomic slots reject overwritten/unwritten timestamps rather than replaying stale audio.
4. Add routing, clock, stale-history, multiple-reader, wraparound and concurrent-access regression checks. Extend the waveform test to five seconds, tighten correlation/error thresholds, and enforce a 100 ms latency ceiling.
5. Keep the earlier bounded daemon queue and 30-second audio-health logging. Dropping frames remains an emergency latency safeguard, not transparent long-term clock-drift correction.

Both failing clock and stale-history tests were observed failing before their fixes. The channel regression also failed with the original averaging behavior.

## Verification

- Debug and release builds of all Swift products; default and live validation gates.
- Installed driver using the safe installer with rollback and post-install visibility checks.
- Final five-second isolated virtual-driver test: correlation 1.0000, gain 1.000000, normalized error 0.0000, delay 21.33 ms.
- Final simultaneous physical/virtual recording: exact sample equality across the aligned overlap at approximately 27.8 ms delay. Raw recordings are temporary; retained results contain numeric measurements only.
- Peak level in both final paths: -6.41 dBFS; no clipping.

The paired recordings used the existing HAL capture implementation from the audio validator, with source channels retained separately. Alignment used waveform correlation and the first capture timestamps; start-time offsets between the two capture units were accounted for. The final equality check compared raw, unnormalized samples across the full overlapping interval. Unaligned whole-recording RMS differs slightly because the two streams cover different edge intervals; it is not a gain change.

## Remaining work

Run the documented sleep/replug and multi-hour soak matrix. Monitor underflow and dropped-frame counts: if they continue rising during steady use, add smooth clock-drift compensation rather than routinely cutting audio. Matching nominal sample rates alone does not synchronize independent device clocks; see [Apple's drift-correction guidance](https://support.apple.com/en-hk/guide/audio-midi-setup/ams094c7edb4/mac).

This test excludes Discord's processing, codec, network, and playback path. It does not establish performance at other sample rates or with other hardware. The bridge remains a 48 kHz mono microphone, rather than a multichannel recording interface.
