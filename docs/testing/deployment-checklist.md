# Deployment Checklist

Validation steps for a live deployment of NeuralCompose, organized by
the subsystem that owns the check. A failure in a step points to the
subsystem whose row it lives in.

Status icons: `□` unchecked · `✓` confirmed

---

## Transport

The network path between the Muse (or the playback file) and the
Mac's `EEGStreaming` consumer.

- `□` Muse S paired to the host Mac over BLE (heartbeat LED
  pulse-orange, not fast-blinking)
- `□` BrainFlow session started (banner shows "Live · Muse BLE/USB",
  not "Reconnecting…")
- `□` Remote Muse: Mind Monitor sending OSC over Tailscale, banner
  shows "EEG: OSC Remote (network) (UDP <port> · utun*)"
- `□` Bound network interface is the expected VPN (Tailscale:
  `utun*`, not `en0` or `bridge*`)
- `□` Packet rate stable at the source's nominal rate (~256 Hz for
  Muse 2/S, 500 Hz for Muse S Athena)
- `□` Sample timestamps monotonic (no out-of-order, no duplicates)

## Acquisition

The first stage of the pipeline: the stream enters
`AsyncMulticastChannel`, the channel-health provider starts emitting,
and the recorder (if enabled) begins writing.

- `□` Channel health badges transition from "no data" to current
  values within 2 seconds of first packet
- `□` 2D plotter updates (raw EEG trace visible, 4 channels stacked
  or overlaid)
- `□` No "dropped packet" warnings in `BCILog.eeg.error` (a single
  warning is acceptable; sustained warnings indicate a real problem)
- `□` Recorder (if enabled) writing at the expected byte rate
  (~14 MB/hour for 4 channels at 256 Hz, 32-bit float)

## Interpretation

The middle stages: the classifier, the band-power feature extractor,
and (when shipped) the sentence embedder.

- `□` Classifier produces non-uniform predictions after the first
  30 seconds of stable signal
- `□` 3D workspace updates: electrode nodes change brightness
  (broadband RMS) and elevation (theta-band power) within 1 second
  of a meaningful signal change
- `□` Edge tint/pulse reflects classifier state (a real classifier
  on a live Muse will produce visible variation; a stuck classifier
  produces a stuck UI)

## Lifecycle

The supervisor and shutdown path: the parts of the system that
should be invisible when everything is working.

- `□` Clean shutdown via Cmd-Q releases the UDP port (verify with
  `lsof -iUDP:<port>` after quit)
- `□` Reconnect after source interruption: kill the Muse (or Mind
  Monitor, for the OSC source) for 10 seconds, restart it, verify
  the supervisor reconnects without an app relaunch
- `□` Privacy indicator updates correctly after a source change
  (Live → Playback → Live should all reflect in the banner)

---

## Running this as a script

This checklist is currently a markdown document for human
verification. A future PR will encode it as a runnable validation
script (the "Deployment checklist automation" item in the
architectural roadmap): each check becomes either a shell command
that exits non-zero on failure (`lsof -iUDP:5000`, `system_profiler
SPBluetoothDataType`) or a unit test against the relevant
`StreamDiagnostics` field. The script becomes a CI gate for
deployment validation, not just a manual pre-flight list.
