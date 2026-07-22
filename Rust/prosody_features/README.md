# NeuralCompose Prosody Features

Phase 0 Rust utility crate for deterministic prosody measurement.

This crate is Engineering infrastructure, not a Science model and not
Swift runtime behavior. It accepts mono audio samples and returns stable
measurement features that can be normalized into the NeuralCompose
prosody feature contract.

```text
Swift acquires/orchestrates
Rust measures
Julia explains
```

The current kernel is dependency-free and intentionally small. It
computes acoustic and timing features such as RMS, pause density,
zero-crossing rate, spectral centroid, pitch-confidence proxy,
voicing probability, and optional syllable-rate fields.

It does not infer mental state, choose a voice, clone a voice, or
change spoken behavior.
