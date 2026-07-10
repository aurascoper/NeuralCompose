# Deployment Checklist

Validation steps for a live deployment of NeuralCompose, organized by
the subsystem that owns the check. A failure in a step points to the
subsystem whose row it lives in.

Status icons: `□` unchecked · `✓` confirmed

Each row is tagged with how it's actually verified:

- `[auto]` — `./Scripts/deployment-check.sh` checks this against the
  live system and reports PASS/FAIL.
- `[test]` — pinned by a unit test, not a live check (the property
  isn't observable from outside the process).
- `[manual]` — needs a human looking at the screen (or the headband).
  Nothing currently hooks into this from outside the running app.

`[auto]` and `[test]` rows are load-bearing claims, not aspirations —
if a row here says `[auto]`, the script really does check it; see
`Scripts/deployment-check.sh` if a row's behavior looks wrong, since
the doc and the script can drift and the script is the source of truth
for what's actually verified.

---

## Transport

The network path between the Muse (or the playback file) and the
Mac's `EEGStreaming` consumer.

- `□` `[manual]` Muse paired over BLE (heartbeat LED pulse-orange,
  not fast-blinking)
- `□` `[auto]` BrainFlow: Muse visible to macOS Bluetooth and
  connected (`system_profiler SPBluetoothDataType`)
- `□` `[manual]` BrainFlow: banner shows "Live · Muse BLE/USB", not
  "Reconnecting…"
- `□` `[auto]` OSC: packets arriving (`nettop` `bytes_in` growing
  across samples)
- `□` `[manual]` OSC: banner shows "EEG: OSC Remote (network) (UDP
  <port> · utun*)"
- `□` `[auto]` Bound network interface is the expected VPN
  (Tailscale: `utun*`, not `en0` or `bridge*`) — OSC only; BrainFlow
  doesn't bind a network interface
- `□` `[test]` Sample timestamps monotonic (no out-of-order, no
  duplicates) — `testSampleTimestampsAreStrictlyMonotonic` in
  `MindMonitorOSCStreamTests.swift`

## Acquisition

The first stage of the pipeline: the stream enters
`AsyncMulticastChannel`, the channel-health provider starts emitting,
and the recorder (if enabled) begins writing.

- `□` `[manual]` Channel health badges transition from "no data" to
  current values within 2 seconds of first packet
- `□` `[manual]` 2D plotter updates (raw EEG trace visible, 4
  channels stacked or overlaid)
- `□` `[auto]` No "dropped packet" warnings in `BCILog.eeg.error`
  (OSC only today — no equivalent log pattern instrumented for
  BrainFlow yet)
- `□` `[auto]` Recorder (if enabled) writing at the expected byte
  rate — checks the most recently modified `eeg.csv` under
  `~/Documents/Recordings/` grew over ~1.5s; skipped if no recording
  started in the last 5 minutes

## Interpretation

The middle stages: the classifier, the band-power feature extractor,
and (when shipped) the sentence embedder.

- `□` `[manual]` Classifier produces non-uniform predictions after
  the first 30 seconds of stable signal
- `□` `[manual]` 3D workspace updates: electrode nodes change
  brightness (broadband RMS) and elevation (theta-band power) within
  1 second of a meaningful signal change
- `□` `[manual]` Edge tint/pulse reflects classifier state (a real
  classifier on a live Muse will produce visible variation; a stuck
  classifier produces a stuck UI)

None of this section is automatable today — there's no external hook
into classifier or SceneKit state from outside the running process.
`NeuralWorkspaceView`'s `testableEmissionIntensity()` family of
test-support accessors is the mechanism a future in-process debug
dump could build on, but that's a real feature to build, not a script
to write; out of scope until something needs it badly enough.

## Lifecycle

The supervisor and shutdown path: the parts of the system that
should be invisible when everything is working.

- `□` `[auto]` Clean shutdown via Cmd-Q releases the UDP port —
  `./Scripts/deployment-check.sh --after-quit --port <port>`
- `□` `[manual]` Reconnect after source interruption: kill the Muse
  (or Mind Monitor, for the OSC source) for 10 seconds, restart it,
  verify the supervisor reconnects without an app relaunch (a
  heartbeat-watchdog integration test proving this composes with the
  supervisor is tracked as a deferred follow-up, not yet built)
- `□` `[manual]` Privacy indicator updates correctly after a source
  change (Live → Playback → Live should all reflect in the banner)

---

## Running this as a script

`./Scripts/deployment-check.sh` runs every `[auto]` row above against
the live system and reports PASS/FAIL/SKIP, plus lists every
`[manual]` row so nothing is silently assumed to have passed just
because the automated rows did. Auto-detects OSC vs. BrainFlow
transport (or pass `--transport osc|brainflow` explicitly); exits
non-zero if any automated check fails.

```bash
./Scripts/deployment-check.sh                    # auto-detect, default port 5000
./Scripts/deployment-check.sh --port 6000
./Scripts/deployment-check.sh --after-quit --port 5000   # Lifecycle: verify port release after quit
```

`Scripts/check-osc-live.sh` remains as a narrower, OSC-only quick
check (packets arriving + no decode errors) for when the full
walkthrough is more than you need.

Not yet done: wiring this script into CI as an actual gate (it needs
a live Muse or a Mind Monitor session to check anything beyond
`[skip]`, so "CI gate" here means a scheduled/manual deployment job,
not a per-PR check) and the Interpretation section, which has no
external hook to automate against yet.
