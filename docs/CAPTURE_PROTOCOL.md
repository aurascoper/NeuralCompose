# Capture Protocol & Session Consumption

Tooling to run a two-regime Muse S capture session and consume it the next day —
bridging the Phase 3.6 spectral encoder (see
[PHASE_3_6_JOINT_EMBEDDING.md](evaluation/PHASE_3_6_JOINT_EMBEDDING.md)) toward
Phase 4.0 (state-modulated prompting) and Phase 5.0 (sequence modelling).

## One-command ritual (quickest path)

```sh
./Scripts/dream-session.sh    # tonight: preflight → keep-awake → telemetry → blink-tag cues
# (put on the Muse and start the app recording when it prompts you)
/dream neuralcompose          # tomorrow, from this repo: full review + memory consolidation
```

`dream-session.sh` chains the support scripts and reminds you to start the recording — it can't
drive BLE/UI. `/dream` (the NeuralCompose branch of the global dream command) runs
`overnight-review.py` + `consume-session.py` on the latest `night-*` dir, then consolidates the
project memory and reports. `./Scripts/dream-session.sh --dry-run` rehearses without waits. The
manual equivalents are below.

## The protocol

One continuous recording (the app streams to `~/Documents/NeuralCompose/Recordings/`),
with segments delimited by a **5-hard-blink marker** the wearer performs at each boundary:

1. **Part 1 — active split:** 5-blink tag → 10 min *focus* → 5-blink tag → 10 min *drowsy*.
   Behavioral ground truth to fit the `eeg_spectral.py` β/α & θ/α cut-points to this wearer.
2. **Part 2 — sleep:** 5-blink tag → lights off → 6.5 h overnight.
   Sequence data for the eventual Phase 5.0 state model; a first (heuristic) hypnogram look now.

The **primary** segment markers are the blink bursts recovered directly from the EEG (robust
to any clock offset). The cue helper's JSON log is a secondary cross-check.

## Tonight: guide + timestamp the protocol

`Scripts/run-session-protocol.py` runs alongside the app's recording (it does not touch the
stream). It prompts each segment, reminds you to blink-tag, counts down, and logs every
transition (ISO + Unix-epoch) to `Recordings/protocol-<ts>.json`.

```sh
# start the app recording first, then:
venv/bin/python3 Scripts/run-session-protocol.py            # focus 10m, drowsy 10m, sleep (Ctrl-C to end)
venv/bin/python3 Scripts/run-session-protocol.py --segments focus:600 drowsy:600 sleep:0
venv/bin/python3 Scripts/run-session-protocol.py --dry-run  # fast-forward timers (no waits)
```

Practical (per the overnight preflight): run `Scripts/overnight-preflight.sh` first, keep the
Mac awake, headset at 100 %, and expect impedance to drift after hours — which is exactly what
`eeg_channel_quality.py`'s paired-channel substitution rescues at consumption time.

## Tomorrow: consume the recording

`Scripts/consume-session.py` recovers the blink markers, segments the session, tunes the
thresholds against the *behavioral* blocks, and emits a heuristic sleep timeline.

```sh
venv/bin/python3 Scripts/consume-session.py <session-dir-or-eeg.csv> \
    --labels focus drowsy sleep --protocol Recordings/protocol-<ts>.json
venv/bin/python3 Scripts/consume-session.py <path> --active-split   # Part 1 only
venv/bin/python3 Scripts/consume-session.py <path> --sleep-timeline # Part 2 only
```

Outputs `session-review.json` + a console summary:
- **Markers / segments** recovered from ≥4-blink bursts (reconciled against the protocol log).
- **Part 1 tuning:** focus×descriptor cross-tab + a β/α and θ/α threshold **sweep** that reports
  the cut-points best separating focus from drowsy (balanced accuracy). *Suggestions only* —
  review, then edit `Scripts/eeg_spectral.py::descriptor_for_ratios` yourself. If
  `Models/EEGEncoder/` exists it also reports a focus/drowsy latent silhouette.
- **Part 2 timeline:** a coarse 30-s-epoch `wake/light/deep/rem` hypnogram.

## Honest caveats (do not oversell)

- **Part 1 is partly circular.** The descriptor is *already* a function of β/α, θ/α, so a latent
  focus/drowsy split is partly guaranteed. The load-bearing signal is whether the *behavioral*
  blocks agree with the descriptor labels — the cross-tab + sweep, not a latent plot.
- **The hypnogram is UNVALIDATED.** Frontal AF7/AF8 do pick up EOG and slow-wave/REM signatures
  are real on Muse-class hardware, but 4-class staging from a dry frontal montage is noisy. REM
  is detected as *phasic* frontal eye-movements on a desynchronized background; deep sleep as
  *sustained* delta. This is exploratory, not clinical staging, and one night cannot "prove" any
  downstream forecaster.
- Thresholds are **not auto-applied** — one session, your brain, your call.
- **Artifacts are rejected, not modelled.** Spectral features use Welch (Hann-tapered,
  DC-detrended by default) and descriptors are *ratios* (which cancel broadband impedance
  drift). But a blink is band-*specific* — it dumps huge energy into delta and survives ratio
  normalization — so windows swinging beyond ±150 µV (`eeg_spectral.py::window_is_clean`) are
  dropped before the focus/drowsy tuning.

## Reuse / provenance
Reuses `analyze-eeg-session.py` (loaders + `detect_blinks` + band-power helpers, via importlib,
left untouched), `eeg_channel_quality.py` (substitution), and `eeg_spectral.py` (descriptors).
Complements the existing engineering tools (`overnight-telemetry.py`, `overnight-review.py`,
`validate-muse-physiology.py`), which never consume the raw EEG physiologically.
