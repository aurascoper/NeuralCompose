# ADR-011: Biofeedback egress: derived features out over MIDI and OSC, health gated, off by default

**Status**: Accepted
**Date**: 2026-11-06

## Context

NeuralCompose already consumes the first half of the "Muse controls a
DAW" chain that Mind Monitor users build: `MindMonitorOSCStream` receives
`/muse/eeg`, `/muse/acc` and `/muse/gyro` over UDP (ADR-004), the
pipeline windows it, and `ChannelHealthThresholds` classifies every
electrode as healthy, saturated, dead or stale. What the codebase lacks
is the second half: a way for anything outside the process to react to
what the pipeline computed. The pipeline terminates at text, speech and
the 3D workspace.

The community chain is Muse to Mind Monitor (paid phone app) to OSC on
UDP 7000 to the Muse Port Max for Live device (Live Suite only, licensed
CC BY-NC-SA) to mapped Live parameters, with a second device for MIDI
notes. It has a property worth fixing rather than copying: Muse Port
displays contact quality (Mind Monitor's "horseshoe") but keeps mapping
band powers while an electrode is bad, so the music follows the
artifact. NeuralCompose's own AF7 pad is a live example of why that
matters.

Adding egress collides with the project's first invariant, "No network
at runtime" (CLAUDE.md, PRINCIPLES.md Principle 5). ADR-004 made the
inbound OSC listener an explicit, indicated exception. Decision registry
entry 8 made `BCICloudBridge` the first deliberate exception for
outbound traffic, scoped to the opt-in hypnagogic loop, and entry 9 added
`BCIPeerBridge` for the opt-in two-machine Tailscale dialectic bridge.
Egress of EEG-derived numbers is a new kind of outbound traffic and needs
its own decision (entry 10), not a quiet widening of entries 8 or 9.

Two more constraints shape the design. CONTRIBUTING requires a protocol
to ship with only a stub, and concrete adapters in follow-up PRs. And the
project's evidence discipline (ADR-002, Principle 3) wants deterministic
replay before live validation: anything that drives a synthesizer must be
reproducible from a recording.

## Decision

1. **A new target, `BCIBiofeedback`, owns the egress.** It depends on
   `BCICore` and `BCIEEG` only, is imported only by `NeuralComposeApp`,
   and may never become a dependency of another `BCI*` target. Network
   (`Network.framework`) and CoreMIDI are system frameworks used behind
   `canImport`; no third-party dependency is added.

2. **Only derived features leave the process.** The egress boundary is
   `BiofeedbackFrame`: per-channel band powers (µV², emitted as Bels),
   per-channel health, the two Track A events, and IMU readings when the
   transport has them. No raw EEG, no text, no transcript, no identity is
   reachable from a frame. Raw EEG re-broadcast in Mind Monitor's
   `/muse/eeg` format exists as a separate, explicit toggle implemented
   by `MindMonitorMirror.rawEEG(_:)`, which takes an `EEGSample`, so the
   one call site that forwards raw samples is greppable.

3. **Three transport tiers, each a separate user choice:**
   - *MIDI virtual source* (`CoreMIDIVirtualSource`): in-machine IPC, not
     network. The default transport when the feature is enabled.
   - *OSC to loopback* (`OSCUDPSender` with host `127.0.0.1`): UDP, but
     the datagrams never leave the machine. Default OSC destination.
   - *OSC to a LAN host*: any other host. Surfaced in the privacy
     indicator with the destination, and logged at `.notice` on start,
     mirroring what ADR-004 requires of the inbound listener.
   The feature as a whole is off by default; while off, the app wires
   `NullBiofeedbackSink` so the mapper path stays exercised with nothing
   leaving the process.

4. **Health gating is mandatory and lives in one place.** Every
   `BiofeedbackMapping` carries a `HealthPolicy` (`holdLast` by default,
   plus `decayToRest`, `mute`, and an explicit `passthrough` that
   reproduces Mind Monitor behaviour by choice rather than by omission).
   `FeatureMapper` applies it; transports never see health. The one
   deliberate exception is `MindMonitorMirror`, whose job is wire
   compatibility: it emits ungated band powers alongside the horseshoe,
   because that is what a Mind Monitor consumer expects, with an option
   to average only over healthy channels.

5. **Speak Mind Monitor's protocol, copy nothing from Muse Port.** The
   address scheme and payload shapes come from Mind Monitor's published
   FAQ table and are reproduced exactly, including its band edges and its
   theta/alpha overlap, so existing patches work unchanged. Muse Port is
   CC BY-NC-SA and nothing from it enters this MIT repository.

6. **Deterministic by construction.** `BandPowerEstimator` is pure Swift
   (Hann, radix-2 FFT, physical-unit PSD scaling) with no Accelerate, and
   `FeatureMapper` takes time from frame timestamps, never from a clock.
   The same recording through the same mapping set yields byte-identical
   OSC and MIDI, which is what the golden-recording regression (follow-up
   issue) pins.

7. **Protocol first.** `BiofeedbackSink` ships with `NullBiofeedbackSink`
   (the stub), `RecordingBiofeedbackSink` (tests and fixtures) and
   `CompositeBiofeedbackSink`. The two production adapters are in the
   tree behind `canImport` but are wired into `AppContainer` only in the
   follow-up PRs that add their settings and privacy-indicator strings.

## Alternatives Considered

**Add OSC output to `BCIEEG` next to the inbound stream.** Smallest
diff, but it puts egress in the acquisition module and makes "does this
target send anything?" a per-file question. A dedicated target keeps the
answer to the egress audit a `grep` over one directory. Rejected.

**Reuse `BCICloudBridge` as the egress home.** It is already the sanctioned
outbound module. But its contract is cloud text through the `claude`
CLI, and mixing in LAN UDP of EEG features would blur the one thing
entry 8 kept sharp. Separate targets, separate registry entries.
Rejected.

**MIDI only, no OSC.** Avoids the network question entirely and covers
every DAW. But the installed base of brain-to-music patches is OSC
(Max, TouchDesigner, SuperCollider, Bitwig), and the Mind Monitor
compatibility story is OSC. Loopback OSC is the compromise: UDP without
leaving the machine. Rejected as the only path; kept as the default
transport.

**Gate inside the transports.** Would let `MindMonitorMirror` be gated
too. But then a transport knows about health, and the mapper's policy
would be duplicated in two places. Gating in one pure function that
tests can drive is worth the mirror being ungated by design. Rejected.

**Stream raw EEG by default for maximum compatibility.** Mind Monitor
sends `/muse/eeg` at 256 Hz and some patches consume it. But raw EEG is
the one payload with real privacy weight, and nothing in the music use
case needs it. Explicit toggle, off by default. Rejected as default.

**Accelerate (vDSP) for the FFT.** Faster, and macOS-only is already the
platform. But the fixtures need bit-stable results across machines and
toolchain versions, and the window sizes here (256 samples at 10 Hz) do
not need the speed. Pure Swift now; vDSP later behind the same signature
with the fixtures as acceptance. Rejected for now.

## What this prevents

- A patch or synthesizer driven by a tarnished electrode: the default
  policy holds the last healthy value, and the user has to choose
  `passthrough` to get the Mind Monitor behaviour.
- Egress creeping into other targets: the only `NWConnection` sender and
  the only CoreMIDI client in `Sources/` live in `BCIBiofeedback`, and
  the Package.swift comment forbids other `BCI*` targets from depending
  on it.
- Raw EEG leaving the machine by accident: it is not derivable from a
  frame, and the one helper that produces it is named for what it does.
- Silent widening of the network invariant: registry entry 10 records
  this exception with the same scope guard language as entries 8 and 9.
- Untestable music mappings: every behaviour in `FeatureMapper` has a
  fixture-style test, and the replay path makes a recording the unit of
  validation.

## When this rule does not apply

- **Inbound OSC** is ADR-004's domain. Nothing here changes how
  `MindMonitorOSCStream` binds or what it accepts.
- **Cloud egress** stays exclusively in `BCICloudBridge` under entry 8.
  `BCIBiofeedback` has no HTTP client and must not grow one; a future
  "send features to a web service" idea is a new ADR, not a new host
  string.
- **Research exports** (CSV, JSON written to disk for analysis) are not
  egress in this sense and are governed by ADR-005's local logging
  rules.
- **Network MIDI sessions** (macOS's RTP-MIDI) are a system feature a
  user can enable in Audio MIDI Setup, which would carry the virtual
  source over the network. This ADR does not enable it and the app does
  not detect it; the privacy indicator describes what the app does, not
  what the OS might forward.
- **The World Model and Laya latents** are not features yet. Exposing a
  learned state vector as a control signal is attractive and is listed
  as a follow-up, but it waits for a benchmarked encoder; nothing here
  pre-commits to it.

## Related implementation

- `Sources/BCIBiofeedback/EEGBand.swift`: Mind Monitor band edges.
- `Sources/BCIBiofeedback/BandPowerEstimator.swift`: periodogram in µV²,
  `BandPowers` with Bels and relative helpers.
- `Sources/BCIBiofeedback/BiofeedbackFrame.swift`: the egress boundary.
- `Sources/BCIBiofeedback/BiofeedbackFeature.swift`: the mappable scalars
  and their health semantics.
- `Sources/BCIBiofeedback/BiofeedbackMapping.swift`: targets, curves,
  smoothing, rate limit, `HealthPolicy`.
- `Sources/BCIBiofeedback/FeatureMapper.swift`: deterministic shaping and
  gating; the only place health policy is applied.
- `Sources/BCIBiofeedback/MindMonitorMirror.swift`: compatibility
  output and the explicit `rawEEG` helper.
- `Sources/BCIBiofeedback/MIDIEvent.swift`: classic bytes and UMP words.
- `Sources/BCIBiofeedback/BiofeedbackSink.swift`: protocol, null,
  recording and composite sinks.
- `Sources/BCIBiofeedback/OSCUDPSender.swift`,
  `CoreMIDIVirtualSource.swift`: the two transports.
- `Sources/BCIEEG/OSC/OSCEncoder.swift`: the production encoder, mirror
  of `MuseOSCDecoder`.
- Tests: `Tests/BCIBiofeedbackTests/*`, `Tests/BCIEEGTests/OSCEncoderTests.swift`.
- `Evaluation/reports/decision_registry.md` entry 10.

## Change protocol for this ADR

- Adding a transport (a file writer, a WebSocket, anything) requires
  amending section 3 and registry entry 10, and the new transport must
  conform to `BiofeedbackSink` without touching `FeatureMapper`.
- Adding a feature case to `BiofeedbackFeature` is additive (Principle
  4) and needs: its units in the doc comment, its `requiredChannels` and
  `isHealthy` semantics, and tests in `BiofeedbackFeatureTests`.
- Changing a band edge breaks Mind Monitor compatibility and needs a
  version note in `MindMonitorMirror`'s doc comment plus a fixture
  update.
- Any change that lets raw EEG reach a frame, or any payload that is not
  a function of a frame, supersedes this ADR rather than amending it.
