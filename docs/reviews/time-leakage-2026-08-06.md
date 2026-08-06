# Time leakage in two EEG evaluations — 2026-08-06

Two places where a design cannot separate signal from elapsed time. One was a real defect,
measured and fixed. The other looked like the same disease and did not survive measurement.

That asymmetry is the point of the document. Both were argued from the same reasoning; only
one of them reproduced when a synthetic check was pointed at it.

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

## 2. Imagined-speech CV — CHANGED, but the leak did not reproduce

**Correction to the first draft of this document.** It stated that the 0.65 gate is
"inflated by an unknown amount" and that a pre-registered threshold evaluated with a
leaky estimator is void. The first half of that is not supported by measurement, and
this section is rewritten accordingly.

`Scripts/evaluate-imagined-signal.py:238`:

```python
skf = StratifiedKFold(n_splits=folds, shuffle=True, random_state=seed)
```

Trials arrive in acquisition order. `shuffle=True` scatters temporally adjacent trials
across train and test, so a fold's test set is neighboured in time by its own training
data. Anything that drifts slowly within a session — impedance, electrode temperature,
alertness, headband slip — is then partially learnable rather than held out, and a
classifier can score above chance without decoding anything about imagined speech.

### What was measured

Synthetic trials with **no class signal at all**: amplitude drifts monotonically with
acquisition position, labels are a 50/50 shuffle (the order
`ImaginedSpeechProtocol.buildTrialOrder` actually produces), which by chance yields runs
of same-class trials. If shuffled folds leak, this is the data that should show it — a
trial's immediate neighbours sit in the training set at nearly the same drift level.

Four seeds, `--self-check`:

| seed | blocked (GroupKFold) | time-index only | **shuffled (old design)** |
| --- | --- | --- | --- |
| 0 | 0.4688 | 0.5250 | 0.4375 |
| 1 | 0.4914 | 0.5000 | 0.4500 |
| 2 | 0.4571 | 0.5000 | 0.5000 |
| 3 | 0.4912 | 0.5000 | 0.5750 |

**The shuffled evaluator did not clear the 0.65 gate on drift-only data.** It sat at
chance, like the blocked one. The reason is capacity: `LinearSVC` on 16 global band-power
features cannot exploit fold-local structure — it has no way to memorise a
drift-level → label association for interleaved runs. Shuffled-CV leakage is real for
high-capacity estimators; it was not demonstrated for this one.

A second construction, with labels deliberately correlated with acquisition position
(long same-class runs), also failed to pass: blocked 0.4656, time-index 0.5250. Blocked CV
holds out contiguous drift ranges the model has never seen, so it is inherently robust to
this failure mode.

**So the claim that the 0.65 threshold is inflated is withdrawn.** No measurement here
supports it. The prior draft asserted it from the design smell alone — the same move as
citing 0.883, one section down.

### What changed anyway, and why

- `GroupKFold` on contiguous acquisition blocks replaces `StratifiedKFold(shuffle=True)`.
  Kept as the **conservative design**, not as a fix for a measured defect: shuffled folds
  over time-ordered trials remain bad practice, the swap costs nothing, and it forecloses
  the failure mode if the estimator is ever given more capacity.
- A **time-index control on the same folds** now runs alongside: the identical pipeline
  trained on trial position alone. Both numbers print, and the gate requires the EEG score
  to exceed the time-only score. On the evidence above this is currently redundant with
  blocked CV — it is cheap insurance, and it makes the check explicit rather than implicit
  in the splitter choice.
- `--self-check` asserts only what reproduces: drift-only data does not pass the gate. It
  prints the shuffled number every run, and says so loudly if the leak ever *does* appear,
  so this non-result is re-tested rather than remembered.

Trial order in `Sources/BCIEEG/Calibration/ImaginedSpeechProtocol.swift:199-208` is a
seeded shuffle with the seed recorded to `metadata.json`; the acquisition side was already
sound.

### What remains true

Any balanced accuracy this script reports is still from **zero real sessions** — Track B
has no collected corpus. The gate has never been evaluated against data. That, not
leakage, is what stands between Track B and a defensible result.

## Note on provenance

The drift concern was argued for several sessions from a claim that *time-index alone
classifies eyes-open vs eyes-closed at 0.883*. **That figure has no preserved artifact** —
no recording, script output, or log in this repo contains it. It entered a working session
as prose and was carried forward as established fact, load-bearing for a design decision.
The nearest values on disk (`Scripts/dream_extraction.py:335`, rho 0.8827/0.8857) are a
different metric on a different analysis, already annotated there as small-n artifacts.

Both changes above stand on defects visible in the source, and the first is demonstrated by
a runnable regression. Neither needs 0.883, and it should not be cited again.

The §2 correction is the same error caught one step earlier: "the gate is inflated by an
unknown amount" was asserted from a design smell, in a document written to warn against
exactly that. It was withdrawn because the check was run, and the check disagreed.
