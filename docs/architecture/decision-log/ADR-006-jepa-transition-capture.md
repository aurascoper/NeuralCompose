# ADR-006: JEPA transition capture is a separate, explicit local data set

**Status**: Accepted
**Date**: 2026-07-18

## Context

`ADR-005` deliberately limited `TelemetryEvent` to a word commit, its text
context, and a coarse classified state label. That record is not a valid
training example for a temporal JEPA: it has neither a window before the
action nor a measured window after it. Widening `TelemetryEvent` would break
its privacy contract and make its name misleading.

The app already produces validated `EEGWindow` values on its background EEG
pipeline and already has one real action surface, `GenerationAdaptation`.
The missing piece was a bounded, opt-in way to align those two signals and
persist the result for an offline trainer. This is a data-harvesting decision,
not authorization to drive the app with an unvalidated latent model.

## Decision

Add a separate JEPA transition capture path with its own consent boundary:

- `JEPASpectralState` holds a timestamp, aggregate alpha/beta/theta energy
  proxies, and per-electrode RMS-squared values. It deliberately does not
  reuse `SpectralState`, which is the existing five-way heuristic label enum.
- `JEPASpectralStateRingBuffer` has fixed capacity and a concurrent
  reader/writer queue. It returns `nil` until a complete chronological window
  is present, so a partial startup window cannot become training data.
- `TransitionCaptureManager` snapshots `W_t` on a genuine word commit, waits
  five seconds without blocking the UI or EEG stream, snapshots `W_t+1`, and
  serializes one `JEPATransition` per JSONL line at
  `~/Documents/NeuralCompose/JEPATransitions/jepa_transitions.jsonl`.
- The recorded action is a fixed three-float vector derived only from the
  `GenerationAdaptation` actually applied to generation:
  `[maxCandidates / 3, temperature, hasStylePrompt]`. It never writes prompt
  text, the committed word, or a newly invented UI control.
- `AppViewModel.jepaTransitionCaptureEnabled` defaults to `false`. While it
  is off, the manager receives no feature states and writes nothing. The
  privacy panel shows a separate persistent `JEPA capture` badge while it is
  on; it is not hidden under the ordinary interaction-log toggle.
- `WorldModel/eeg_jepa.py` is an offline PyTorch reader/trainer for this exact
  JSONL schema. It has no live Swift/Python bridge, network call, or runtime
  role in the app.

The production windower currently emits a 2-second raw EEG window every
second. The capture buffer is therefore five derived feature states by
default, not an invented 10 Hz stream. Its capacity is computed from the
configured window stride, so a future cadence change preserves the intended
five-second collection span.

## Consequences

This makes high-integrity local examples available after an explicit opt-in
and a warm-up period. It does not produce a usable training corpus by itself:
collection volume, action diversity, data-quality review, train/validation
splitting, and any model-validation threshold are still required before a
trained model can inform user-facing behavior.

`TelemetryEvent` and `interactionLoggingEnabled` retain their existing
contract unchanged. The JEPA data set contains more sensitive measured signal
features, so it remains visibly separate even though both files are local and
never transmitted.

## Explicitly not decided here

- loading a JEPA checkpoint in the app or converting one to Core ML;
- MPC, latent anchoring, or any automatic generation adaptation based on this
  data set;
- reusing or fine-tuning the BGE-aligned `SpectralEncoderModel`;
- changing the no-network-at-runtime rule.
