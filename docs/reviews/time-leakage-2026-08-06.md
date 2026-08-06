# Time leakage in two EEG evaluations — 2026-08-06

Two places where a measurement cannot separate signal from elapsed time. One is fixed in
this change; the other is documented here and still open. They are the same disease, and
the open one is the more urgent because it is **currently gating a decision**.

## 1. Muse physiological validation — FIXED

`Scripts/validate-muse-physiology.py` recorded one 30 s eyes-open block followed by one
30 s eyes-closed block, always in that order, and reported
`alpha_closed / alpha_open` against a 1.5× threshold. Condition was perfectly confounded
with block position, so impedance settling, electrode warming, and drowsiness onset all
pushed the ratio the same way real alpha does.

Fix: four counterbalanced blocks (`open, closed, closed, open`, 15 s each — same 60 s of
alpha data), first 2 s of every block discarded for the alpha build-up, cue onset logged
separately from block start, and a **time-index baseline** gate — the identical statistic
computed on the same blocks relabelled by position alone (1–2 vs 3–4), which under ABBA is
orthogonal to condition. A channel passes only if the condition ratio clears 1.5× *and*
exceeds the time-index ratio.

Regression, in `--self-check`: on synthetic data with **zero alpha and pure drift**, the
old sequential statistic reports **7.11×** — a comfortable pass at a 1.5× threshold —
while the new gate rejects it. That assertion is the point of the change; without it the
suite would only prove the new gate works, not that it catches something the old one
missed.

The 2026-07-10 results (TP9 2.98×, TP10 3.88×) were collected under the old protocol and
are now annotated in `docs/Validation.md` as provisional pending re-collection.

## 2. Imagined-speech pre-registration gate — OPEN

`Scripts/evaluate-imagined-signal.py:238`:

```python
skf = StratifiedKFold(n_splits=folds, shuffle=True, random_state=seed)
```

Trials arrive in acquisition order. `shuffle=True` scatters temporally adjacent trials
across train and test, so a fold's test set is neighboured in time by its own training
data. Anything that drifts slowly within a session — impedance, electrode temperature,
alertness, headband slip — is then partially learnable rather than held out, and a
classifier can score above chance without decoding anything about imagined speech.

**Why this is the urgent one.** It feeds the pre-registration gate at `:10`:

```
PASS iff balanced_accuracy >= 0.65 AND min(class_count) >= 50
```

That threshold was pinned in advance precisely so Track B could not be promoted on a soft
judgement (see `CLAUDE.md`, Track B pre-registration gate). But the number being compared
against it is inflated by an unknown amount. A pre-registered threshold evaluated with a
leaky estimator is not a pre-registered threshold. **Any balanced accuracy reported by
this script today is provisional and must not be used to promote Track B past
experimental.**

### Fix owed

- Replace the shuffled `StratifiedKFold` with block-aware splitting — `GroupKFold` (or
  `StratifiedGroupKFold`) with groups derived from acquisition-time blocks, so whole
  contiguous runs of trials are held out together rather than interleaved.
- Add a **time-index control on the same folds**: train and score the identical pipeline
  on trial index alone. Report both numbers; gate on the label-based score exceeding the
  time-only score, exactly as the alpha gate now does. This is the piece that converts
  "we think the CV is clean" into something the script checks.
- Trial order in `Sources/BCIEEG/Calibration/ImaginedSpeechProtocol.swift:199-208` is
  already a seeded shuffle, not strict alternation, and the seed is recorded to
  `metadata.json` — so the acquisition side is sound and only the evaluator needs work.

Not fixed in this change because it was scoped to the Muse validation protocol. Recorded
here so it does not survive only as a line in a plan's exclusions section.

## Note on provenance

The drift concern was argued for several sessions from a claim that *time-index alone
classifies eyes-open vs eyes-closed at 0.883*. **That figure has no preserved artifact** —
no recording, script output, or log in this repo contains it. It entered a working session
as prose and was carried forward as established fact, load-bearing for a design decision.
The nearest values on disk (`Scripts/dream_extraction.py:335`, rho 0.8827/0.8857) are a
different metric on a different analysis, already annotated there as small-n artifacts.

Both fixes above stand on defects visible in the source, and the first is demonstrated by
a runnable regression. Neither needs 0.883, and it should not be cited again.
