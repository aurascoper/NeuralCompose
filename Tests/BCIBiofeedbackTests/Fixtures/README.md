# Biofeedback egress fixtures

Derived artifacts only. The recordings they are computed from
(`Recordings/golden/*.eeg.csv`, `Recordings/muse_validation_converted/`,
`Recordings/muse_validation_*.json`) are gitignored and never leave the
machine that recorded them; what is committed here is band powers in
Bels, health codes, and the OSC/MIDI the egress produced from them.

| File | Produced by | Regenerate with |
|---|---|---|
| `golden_egress_v1.json` | `GoldenEgressReplayTests` | `NEURALCOMPOSE_REGENERATE_REFERENCE=1 swift test --filter GoldenEgressReplayTests` |
| `muse_validation_alpha_v1.json` | `MuseValidationAlphaTests` | `NEURALCOMPOSE_REGENERATE_REFERENCE=1 swift test --filter MuseValidationAlphaTests` |

Note on `muse_validation_20260710-004345`: this earliest session has a `-12.19 s` backwards timestamp jump at the `open` to `closed` boundary (`openClosedBoundaryGap = -12.186603`, a ring-buffer read-back of samples already recorded rather than a pause) and has no QC sidecar. It is marked as **overlapping segments, excluded from physiology claims** and is retained in `muse_validation_alpha_v1.json` only as a structural record of the raw directory.

Regeneration is a deliberate act after a DSP or mapping change: inspect
the diff, confirm it is the change you meant, and commit. When the
recordings are absent (fresh checkout, CI) both tests skip; when the
recordings are present and a fixture is absent, the test still runs its
hard-coded pins and then skips with the regenerate instruction.
