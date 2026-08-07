# Session events — structured references into a recording

`nc-eeg-session-event-v0`. One JSON line per observation, in
`<recording>/session-events.jsonl`.

## Why a reference and not a copy

An event carries the SHA-256 of the `eeg.csv` it points into plus a sample
range. It does not carry signal. Anyone holding the recording can re-derive the
window and recompute what was observed; anyone without it learns nothing.

That indirection is the whole design. It means one artifact serves every
consumer — a spectral routine today, EEGNet or a future encoder later — because
none of them is baked into the record. Storing a latent vector instead would
bind the log to whichever model produced it, and the log would expire when the
model did.

It also makes the artifact falsifiable. `observed` is recomputable, so a claim in
the log can be checked against the recording rather than believed.

## What it does not say

**These are signal observations. Nothing here is a sleep stage, and nothing is an
intervention outcome.**

- Detection is gated behind the Sleep Validation Toolkit — `SLEEP_CYCLE_DESIGN.md`
  §21, *"Gate to Phase C: 5+ clean sessions through the toolkit, no false
  readings, all features observable"*, with *"do not start classifier work until
  the toolkit is stable"* stated three times in that document.
- Intervention efficacy is gated behind the D8 OSF pre-registration —
  `Evaluation/reports/decision_registry.md` entry 8 calls the hypnagogic loop
  *"engineering scaffolding, not a validated intervention"* and the
  pre-registration *"non-negotiable"*.
- The Muse montage has no chin EMG (`SLEEP_CYCLE_DESIGN.md` §291, risk R1), so
  nothing may imply REM.

This artifact is **upstream of both gates and touches neither.** It shortens
neither: five clean toolkit sessions still means five. But every session run for
that gate yields a structured event log for free, which is the point — the
gates need data, and this is how a night becomes data.

`Scripts/session_event_contract.py` enforces the boundary rather than leaving it
to review. A record asserting a stage, an efficacy outcome, or an embedding is
rejected, at any nesting depth.

## Event kinds

All four are mechanical and recomputable from the referenced window.

| kind | fires when |
|---|---|
| `zero_throughput` | a gap in the sample clock exceeds `gap_factor` × nominal — the condition `HealthSnapshot`'s `eeg-zero-throughput` raises live, recorded here as a referenceable span |
| `channel_health_change` | a channel's clipped fraction crosses `clip_fraction_trigger`, or its RMS reaches `rms_ratio_trigger` × its in-session baseline |
| `band_excursion` | theta/alpha/beta power reaches `band_ratio_trigger` × its in-session baseline |
| `artifact_burst` | a channel has ≥ `burst_min_samples` above `burst_sigma` × **its own** baseline RMS |

Baselines are the median over the opening windows of the *same* session. A
cross-session baseline would silently import another night's headset fit.

### Detector eligibility

`artifact_burst` is deliberately per-channel. A cross-channel envelope makes one
bad electrode trip it on every window: the first run against a real recording had
a saturated AF7 (~900 µV against ~20 µV elsewhere) producing a burst almost every
second, restating a fault `channel_health_change` already reported. A burst is a
departure from a channel's own norm, so the norm must be its own.

**A suppressed detector is not a clean channel.** When a channel's baseline is
itself pathological, the comparison is vacuous — nothing exceeds `burst_sigma` ×
a rail — so it emits no `artifact_burst`. On a real recording a saturated AF7 did
exactly that. An absent record is ambiguous between *clean*, *no transient*, and
*never eligible*, so eligibility is stated rather than inferred from silence:

```json
"channels": {
  "AF7":  {"detector_status": "suppressed", "suppressed_reason": "channel_saturated"},
  "TP9":  {"detector_status": "eligible",   "suppressed_reason": null}
}
```

in `session-events-manifest.json` beside the log. The validator rejects a
manifest that omits any channel, because a missing entry restores the ambiguity.
`suppressed_reason` is one of `channel_saturated` or `channel_silent`.

## The manifest's dispositions

All negative, all pinned, all enforced:

```
contains_signal              false
science_status               pipeline_only
label_status                 heuristic_observation
live_control                 false
promotion_status             not_eligible
clean_session_gate_credited  false
```

The last is the important one. Running an extractor over a recording credits
nothing toward the §21 five-clean-session gate — whether a session was *clean* is
a judgement about the recording, not about whether a script parsed it.

`science_status: pipeline_only` and `label_status: heuristic_observation` set the
standard of proof. The 750-event run over a real recording is **pipeline
validation** — evidence the extractor runs, is deterministic, and replays. It is
not evidence that 750 heuristic observations are individually correct.

## Sample intervals

Half-open, `[start_sample, start_sample + sample_count)`, non-empty, and within
`recording_sample_count`. The convention is declared in the manifest as
`sample_interval_convention` rather than left to the reader. Events may overlap —
the window stride is shorter than the window — and are not deduplicated: two
kinds firing on one window are two observations of it, and `event_id` separates
them because the kind and the observation are both in the hash.

## Determinism

The same file yields byte-identical output. Nothing consults the clock, the
filesystem order, or a random seed. `event_id` is derived from content, so
re-running produces the same ids and a diff shows only real change.

Every record carries `params_sha256` over the pinned `PARAMS` block. Two logs are
comparable only if that digest matches — changing a threshold changes the events,
and the record says so.

Editing one sample changes `recording_sha256`, which invalidates every reference
into that file rather than silently re-pointing it at different signal.

## Usage

```sh
python3 Scripts/extract_session_events.py Recordings/<session>
python3 Scripts/extract_session_events.py Recordings/<session> --stdout
python3 Tests/eval/test_session_events.py
```

Standard library only — no numpy. Band power uses Goertzel over the integer bins
of each band, which is O(n) per bin where a hand-rolled DFT would be O(n²) per
window. The system interpreter on a clean runner has no numpy, and this needs to
stay runnable there.

## Relationship to `JEPATransition`

`Sources/BCICore/Models/JEPATransition.swift` stores band energies plus
per-channel RMS² — compact derived state, the right shape for its own purpose and
the wrong one for anything wanting raw signal. It is unchanged; this is additive.

A future action-conditioned artifact can pair a session-event reference with an
action vector, and any encoder derives its own states offline from the same
recording. That is the same model-agnostic reference the encoder research track
needs, reached from the capture side.
