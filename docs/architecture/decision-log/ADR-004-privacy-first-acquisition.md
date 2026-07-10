# ADR-004: Privacy-first acquisition — local by default, explicit remote

**Status**: Accepted
**Date**: 2026-07-10

## Context

NeuralCompose was originally a local-only BCI tool: the Muse over
BLE, the BrainFlow session, the on-device Core ML classifier, the
on-device MLX predictor. The privacy posture was implicit ("no
network calls at runtime") and the threat model was implicit ("the
Mac is the only thing the headband talks to").

Adding a remote Muse source (Mind Monitor on a phone, OSC over UDP
to a Tailscale peer on the home Mac) breaks the implicit assumption
without changing the explicit policy. The local-only assumption is no
longer true, but the policy still says "no network at runtime."
That contradiction is a problem: it means a future contributor
implementing a new feature cannot tell from the policy whether
"network" is allowed.

The remote-source feature is also the one feature in the codebase
where the user needs to *know* — explicitly, visibly, in the UI —
which transport is active. A local Muse and a remote Muse over the
internet look identical to the pipeline, but they have very different
privacy implications.

## Decision

The default mode is fully local: the Muse over BLE, the BrainFlow
session, no network calls of any kind. This is the policy the README
documents, and the privacy indicator reflects it.

A user may opt in to a remote Muse source (currently: Mind Monitor
over OSC, reached via a private VPN such as Tailscale). The opt-in is
explicit:

- A new `MuseBoardProfile.oscRemote` case, distinct from the local
  Muse profiles, with a `requiresNetwork: true` flag
- A new `PipelineMode.Source.oscRemote` case, surfaced in the
  privacy indicator as "EEG: OSC Remote (network) (UDP <port> ·
  <interface>)" once the listener is bound
- A `.notice`-level log line on listener bind, with the port and a
  reminder that the listener is reachable only via a private VPN
- A `run-osc-remote.sh` script that prints the same reminder before
  launching the app

There is no silent fallback. If the user explicitly chose
`oscRemote` and the UDP bind fails, the app does not transparently
switch to synthetic — the failure is loud and the user sees it.

The local-first default is enforced by:

- No outbound network calls in any production code path
- The `EEGStreamFactory` no-fallback policy for the OSC source
- The privacy indicator showing the active source with its
  transport-level detail

## Alternatives Considered

**Block the OSC source entirely.** Most conservative, but rules out
a use case the project was specifically designed to support (remote
BCI workstation, headband on a phone, processing on a home Mac). The
privacy boundary is the VPN's job, not the app's; excluding the
feature to enforce the boundary from the wrong layer would be
over-restrictive. Rejected.

**Bind the OSC source only to a specific interface (e.g., `utun3`).**
Stricter than `0.0.0.0` bind, but the Tailscale interface name is not
known ahead of time (Tailscale assigns interface names from a pool),
and a hardcoded `utun3` assumption would break on interface
renumbering. The 0.0.0.0 bind is necessary, not a bug; the security
boundary is the VPN, which keeps unwanted traffic out regardless of
which interface this app binds to. The interface name *is* surfaced
in the privacy indicator once packets start arriving, so the user can
verify the traffic is actually coming over the VPN. Rejected.

**Implicit fallback to synthetic on OSC bind failure.** Avoids
crashing the app, but silently substitutes fake data for real data
when the user explicitly chose a real data source. The
`EEGStreamFactory` no-fallback policy treats this as a
correctness-of-instrument issue, not a UX issue. Rejected.

## What this prevents

A future contributor adding a new feature that introduces an
outbound network call, on the assumption that "we already have
remote transport" — when the policy was actually "remote transport
exists, but only as an opt-in user-facing feature, not as a free
network capability for internal use."

It also prevents a contributor from adding a "smart" fallback that
silently substitutes synthetic or playback data when a real source
fails. Silent substitution is dangerous for a research instrument:
the user thinks they're collecting real data when they're collecting
fake data, and the analysis they run on it is invalid.

## When this rule does not apply

Local Muse sources (all `museTwo*`, `museS*` profiles) — these have
no network calls at runtime, only Bluetooth. The privacy policy is
trivially satisfied for them.

Playback and synthetic sources — these are recorded or generated
data with no privacy implications. The privacy indicator shows
"Playback" or "Synthetic" and the user knows what they're looking
at.

Test code. A test that needs to verify the OSC source behavior over
a loopback UDP socket is not making a network call in the
privacy-relevant sense; the loopback is local. The test target's
imports are also exempt from the "no network calls at runtime" rule,
as documented in ADR-003.

## Related implementation

- `Sources/BCICore/Models/MuseBoardProfile.swift` — the `.oscRemote`
  case and its `requiresNetwork` flag
- `Sources/BCICore/Models/PipelineMode.swift` — the `.oscRemote`
  source case and the `transportDetail` field for the privacy
  indicator
- `Sources/BCIEEG/OSC/MindMonitorOSCStream.swift` — the OSC source
  implementation, with the `.notice` log on bind and the
  no-silent-fallback policy
- `Sources/BCIEEG/EEGStreamFactory.swift` — the factory's
  no-fallback policy for the OSC source
- `Scripts/run-osc-remote.sh` — the entrypoint script with the
  VPN-only reminder
- `HARDWARE_SETUP.md` — the "Remote transport: OSC (Mind Monitor)"
  section with the threat model
