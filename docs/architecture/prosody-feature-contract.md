# Prosody Feature Contract

> Status: Draft (2026-07-22). This document defines the
> measurement contract between speech/audio acquisition, deterministic
> feature extraction, telemetry, and science modeling. It is not a
> behavioral inference model and does not add Julia or Rust to the
> Swift runtime path.

## Purpose

Prosody modeling needs stable measured targets before Science can ask
whether dialogue state predicts cadence. The feature contract sits
below metrics:

```text
audio or requested controls
  -> feature extraction
  -> feature contract
  -> metrics
  -> ResearchHypothesis
```

The contract keeps implementation details out of Julia. A feature may
come from Swift-requested controls today, an AVFoundation measurement
tomorrow, or a deterministic Rust DSP kernel later. The field names
and semantics should remain stable.

## Division of Labor

```text
Swift
  acquires signals, orchestrates speech, records telemetry

Rust
  measures signals with deterministic feature extraction

Julia
  explains signals by fitting and falsifying scientific models
```

Rust can begin before Julia models mature when the work is
measurement infrastructure: timestamp processing, audio windows,
energy envelopes, pause detection, pitch confidence, and other
deterministic features. Rust should not infer that a cadence means
"contemplation" or "continuity"; those are Science-layer hypotheses.

Rust is a computational layer, not a hardware layer. The Phase 0
prosody crate is a CPU/deterministic kernel. It does not own MLX,
Metal, Core ML, the GPU, or the ANE. Swift remains the owner of Apple
framework orchestration; Rust returns reproducible numeric features
through stable interfaces.

## Contract Shape

The runtime representation is `ProsodyFeatureVector`, encoded in
`ProsodyTraceEvent` as snake-case JSON fields:

```text
speech_rate
pause_before
pause_after
mean_pitch
pitch_variance
energy
duration
voiced_duration
syllables_per_second
articulation_rate
pause_density
rms
zero_crossing_rate
spectral_centroid
pitch_confidence
voicing_probability
energy_entropy
emphasis
hesitation
cadence_class
```

The same shape can represent three phases:

- `requested`: controls Swift asked the synthesizer to use.
- `predicted`: controls produced by a future `ProsodyPredicting`
  model.
- `measured`: acoustic features measured from rendered or recorded
  speech.

`SpokenGenerationLoop` currently emits the requested phase when a
`ProsodyTraceLogging` sink is injected. That is a baseline, not a
measurement of real audio.

## Phase 0 Rust Boundary

The repo-side Phase 0 crate is `Rust/prosody_features`. It exposes a
deterministic measurement kernel shaped like:

```rust
ProsodyFeatures analyze_mono(audio_frame, sample_rate_hz, config)
```

Current outputs include:

```text
duration
rms
zero_crossing_rate
spectral_centroid
pitch_confidence
voicing_probability
pause_density
pause_duration
voiced_duration
energy_entropy
speech_rate / syllables_per_second
articulation_rate
```

Those kernel outputs must be normalized into the feature contract
before reaching metrics or Julia. Swift remains responsible for
acquisition and orchestration; Rust returns numbers; Julia decides
whether those numbers explain dialogue dynamics.

## Determinism Requirements

Feature extraction implementations should record enough provenance to
make a measurement reproducible:

- sample rate
- channel count or mono/downmix rule
- window size and hop size
- timestamp origin and clock source
- algorithm id and version
- units for every scalar
- handling of silence, clipping, missing samples, and non-speech

Two runs over the same input artifact and algorithm version should
emit byte-equivalent feature JSON modulo explicit floating-point
tolerance documented by the kernel.

The Phase 0 crate currently verifies determinism in unit tests by
running the same input through the same configuration twice and
requiring exact feature equality.

## Science Questions Enabled

Once requested and measured prosody features exist, Julia can consume
telemetry without processing raw audio. Example questions:

```text
Does continuation pressure correlate with pause length?
Does synthesis emerge after reduced speaking rate?
Is semantic inertia preceded by decreasing pitch variance?
Are there attractors in joint state:
  (coherence, novelty, continuation_pressure,
   speech_rate, pause_density)?
```

These are hypotheses to falsify. The feature contract does not encode
their answers.

## Non-Goals

This contract does not clone voices, choose a TTS provider, infer
mental state from cadence, or change spoken behavior. It only fixes
the measurable target shape so Engineering can record cadence
reproducibly and Science can test models against telemetry.
