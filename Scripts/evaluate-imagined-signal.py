#!/usr/bin/env python3
"""
evaluate-imagined-signal.py — Pre-registration gate for NeuralCompose Track B.

Reads imagined-speech calibration sessions written by TrackBRecorder, extracts
band-power features per channel per trial, runs 5-fold within-subject CV with
a linear SVM, and prints the pass/fail gate text.

Pre-registration gate (locked in design discussion 2026-05-25):
    PASS iff balanced_accuracy >= 0.65
        AND  min(class_count) >= 50.

A pass means "Track B has detectable signal on this hardware/subject — Core ML
export is justified." A fail means "park Track B until either the protocol,
the hardware (aux electrodes!), or the subject changes." Do NOT promote on
the basis of training accuracy, only the held-out balanced accuracy.

Usage:
    ./Scripts/evaluate-imagined-signal.py
        # default: all sessions under
        # ~/Documents/NeuralCompose/Calibration/TrackB_Imagined/

    ./Scripts/evaluate-imagined-signal.py path/to/session
    ./Scripts/evaluate-imagined-signal.py s1/ s2/ s3/      # union

    ./Scripts/evaluate-imagined-signal.py --classes yes,no
    ./Scripts/evaluate-imagined-signal.py --folds 5 --seed 1337

Output is human-readable; the gate verdict is printed on the very last line so
shell scripts can grep for it.

Requires: numpy, scipy, scikit-learn, pandas. Install in your venv with:
    python -m pip install numpy scipy scikit-learn pandas
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import signal
from sklearn.metrics import balanced_accuracy_score, confusion_matrix
from sklearn.model_selection import GroupKFold, StratifiedKFold
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import LinearSVC

# Pre-registration gate constants — DO NOT change without invalidating prior runs.
GATE_BALANCED_ACCURACY = 0.65
GATE_MIN_PER_CLASS = 50

BANDS: dict[str, tuple[float, float]] = {
    "theta": (4.0, 8.0),
    "alpha": (8.0, 13.0),
    "beta":  (13.0, 30.0),
    "gamma": (30.0, 50.0),  # capped at 50 to avoid line-noise band on US hardware
}


@dataclass
class Trial:
    """One labeled imagined-speech trial extracted from a session."""
    session_id: str
    trial_index: int
    target: str
    channels: np.ndarray   # shape (n_channels, n_samples)
    sample_rate: float


def discover_sessions(paths: list[Path], default_root: Path) -> list[Path]:
    """Return one Path per session directory."""
    if not paths:
        if not default_root.exists():
            print(f"[error] Default root not found: {default_root}", file=sys.stderr)
            print(f"        Run a Track B session in the app first.", file=sys.stderr)
            sys.exit(2)
        return sorted(p for p in default_root.iterdir()
                      if p.is_dir() and (p / "imagined_events.csv").exists())
    sessions: list[Path] = []
    for p in paths:
        if (p / "imagined_events.csv").exists():
            sessions.append(p)
        else:
            sessions.extend(sorted(s for s in p.iterdir()
                                   if s.is_dir() and (s / "imagined_events.csv").exists()))
    return sessions


def load_session_trials(session_dir: Path, target_classes: set[str]) -> list[Trial]:
    """Parse one session directory into per-trial EEG blocks.

    Segmentation priority (post-2026-05-25 bugfix):
        1. If `trial_index` column is present, group by it. This is the new
           schema written by `TrackBRecorder` — exact, clock-skew-immune.
        2. Else if `wall_time` is present, mask by event.active_start/end
           against `wall_time`.
        3. Else (legacy sessions) mask by `t_seconds`, the old single-clock
           column. May silently drop sessions where stream clock ≠ protocol
           clock; that's the bug the new schema avoids.
    """
    events_path = session_dir / "imagined_events.csv"
    eeg_path = session_dir / "imagined_eeg.csv"
    meta_path = session_dir / "metadata.json"
    if not events_path.exists() or not eeg_path.exists():
        print(f"[warn] Skipping {session_dir.name}: missing events/eeg CSV", file=sys.stderr)
        return []
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    sample_rate = float(meta.get("sample_rate", 256.0))

    try:
        events = pd.read_csv(events_path)
    except pd.errors.EmptyDataError:
        print(f"[warn] Skipping {session_dir.name}: imagined_events.csv is empty",
              file=sys.stderr)
        return []
    if events.empty:
        return []
    try:
        eeg = pd.read_csv(eeg_path)
    except pd.errors.EmptyDataError:
        print(f"[warn] Skipping {session_dir.name}: imagined_eeg.csv is empty — "
              f"the recorder produced 0 active samples for this session.",
              file=sys.stderr)
        return []
    if eeg.empty:
        return []

    meta_cols = {"wall_time", "sample_timestamp", "trial_index", "target", "t_seconds"}
    channel_cols = [c for c in eeg.columns if c not in meta_cols]
    if not channel_cols:
        print(f"[warn] Skipping {session_dir.name}: no channel columns in imagined_eeg.csv",
              file=sys.stderr)
        return []
    data = eeg[channel_cols].to_numpy(dtype=np.float64).T   # (n_channels, n_samples)
    if data.size == 0:
        return []

    min_samples = int(sample_rate * 0.5)
    trials: list[Trial] = []

    if "trial_index" in eeg.columns:
        # New schema: each row already carries the trial it belongs to.
        # Build a target lookup from the events table; the recorder writes
        # `target` per EEG row but events is the canonical source.
        target_by_trial = {int(r["trial_index"]): str(r["target"]).strip().lower()
                           for _, r in events.iterrows()}
        for trial_idx, block_df in eeg.groupby("trial_index"):
            try:
                trial_idx_int = int(trial_idx)
            except (TypeError, ValueError):
                continue
            target = target_by_trial.get(trial_idx_int,
                                         str(block_df["target"].iloc[0]).strip().lower())
            if target not in target_classes:
                continue
            if len(block_df) < min_samples:
                continue
            block = block_df[channel_cols].to_numpy(dtype=np.float64).T
            trials.append(Trial(
                session_id=meta.get("session_id", session_dir.name),
                trial_index=trial_idx_int,
                target=target,
                channels=block,
                sample_rate=sample_rate,
            ))
        return trials

    # Legacy fallback: time-range mask. Pick the column whose range overlaps
    # the events' active_start..active_end the most.
    if "wall_time" in eeg.columns:
        timestamps = eeg["wall_time"].to_numpy()
    elif "t_seconds" in eeg.columns:
        timestamps = eeg["t_seconds"].to_numpy()
    else:
        print(f"[warn] Skipping {session_dir.name}: no recognizable time column",
              file=sys.stderr)
        return []

    for _, row in events.iterrows():
        target = str(row["target"]).strip().lower()
        if target not in target_classes:
            continue
        t0, t1 = float(row["active_start"]), float(row["active_end"])
        if t1 <= t0:
            continue
        mask = (timestamps >= t0) & (timestamps <= t1)
        if mask.sum() < min_samples:
            continue
        block = data[:, mask]
        trials.append(Trial(
            session_id=str(row["session_id"]),
            trial_index=int(row["trial_index"]),
            target=target,
            channels=block,
            sample_rate=sample_rate,
        ))
    return trials


def bandpass(x: np.ndarray, low: float, high: float, fs: float, order: int = 4) -> np.ndarray:
    """Zero-phase Butterworth band-pass on the last axis."""
    nyq = 0.5 * fs
    low_n = max(0.01, low / nyq)
    high_n = min(0.99, high / nyq)
    if high_n <= low_n:
        return x
    b, a = signal.butter(order, [low_n, high_n], btype="bandpass")
    return signal.filtfilt(b, a, x, axis=-1)


def trial_features(trial: Trial) -> np.ndarray:
    """log band-power per channel per band, flattened.

    Shape: (n_channels * n_bands,) — e.g. 4ch × 4 bands = 16 features.
    """
    fs = trial.sample_rate
    x = trial.channels
    x = x - x.mean(axis=-1, keepdims=True)
    feats: list[float] = []
    for (low, high) in BANDS.values():
        filt = bandpass(x, low, high, fs)
        power = np.mean(filt ** 2, axis=-1)        # one value per channel
        feats.extend(np.log10(power + 1e-12).tolist())
    return np.array(feats, dtype=np.float64)


def time_blocks(trials: list[Trial], n_blocks: int) -> np.ndarray:
    """Contiguous acquisition-time blocks, used as CV groups.

    Trials arrive in acquisition order within a session. Grouping by contiguous
    runs — rather than shuffling — is what keeps a fold's test trials from being
    temporally neighboured by their own training data.
    """
    order = np.lexsort(([t.trial_index for t in trials],
                        [t.session_id for t in trials]))
    groups = np.empty(len(trials), dtype=int)
    groups[order] = np.floor(np.arange(len(trials)) * n_blocks / len(trials)).astype(int)
    return groups


def _cv_score(X, y, splitter, split_args) -> tuple[float, list[float], list, list]:
    fold_scores: list[float] = []
    all_true: list = []
    all_pred: list = []
    for train_idx, test_idx in splitter.split(*split_args):
        pipe = Pipeline([
            ("scaler", StandardScaler()),
            ("svm", LinearSVC(C=1.0, dual="auto", max_iter=5000)),
        ])
        pipe.fit(X[train_idx], y[train_idx])
        pred = pipe.predict(X[test_idx])
        fold_scores.append(balanced_accuracy_score(y[test_idx], pred))
        all_true.extend(y[test_idx].tolist())
        all_pred.extend(pred.tolist())
    return float(np.mean(fold_scores)), fold_scores, all_true, all_pred


def evaluate(trials: list[Trial], folds: int, seed: int) -> dict:
    X = np.vstack([trial_features(t) for t in trials])
    y = np.array([t.target for t in trials])
    classes, counts = np.unique(y, return_counts=True)
    class_counts = dict(zip(classes.tolist(), counts.tolist()))

    # Blocked, not shuffled. StratifiedKFold(shuffle=True) scatters temporally
    # adjacent trials across train and test, so anything drifting slowly within a
    # session — impedance, electrode temperature, alertness, headband slip — is
    # partially learnable rather than held out, and the classifier can score above
    # chance without decoding imagined speech at all. Whole contiguous runs are
    # held out together instead. Same defect, and same fix, as the eyes-open/closed
    # block confound in validate-muse-physiology.py; see
    # docs/reviews/time-leakage-2026-08-06.md.
    groups = time_blocks(trials, folds)
    gkf = GroupKFold(n_splits=folds)
    mean, fold_scores, all_true, all_pred = _cv_score(X, y, gkf, (X, y, groups))

    # Time-index control on the SAME folds: trial position as the only feature.
    # A gate that does not check this cannot tell decoding from drift — it is the
    # same instrument as the alpha time-index baseline, pointed at the same risk.
    t_index = np.arange(len(trials), dtype=float).reshape(-1, 1)
    time_mean, _, _, _ = _cv_score(t_index, y, gkf, (t_index, y, groups))

    sd = float(np.std(fold_scores, ddof=1)) if len(fold_scores) > 1 else 0.0
    # Wilson 95% CI on the pooled accuracy.
    n = len(all_true)
    p = mean
    z = 1.96
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    ci_low, ci_high = max(0.0, center - half), min(1.0, center + half)

    cm_labels = sorted(set(all_true))
    cm = confusion_matrix(all_true, all_pred, labels=cm_labels).tolist()

    return {
        "balanced_accuracy_mean": mean,
        "time_index_balanced_accuracy": time_mean,
        "beats_time_index": bool(mean > time_mean),
        "cv": f"GroupKFold({folds}) on contiguous acquisition blocks",
        "balanced_accuracy_sd": sd,
        "fold_scores": fold_scores,
        "wilson_ci_95": (ci_low, ci_high),
        "class_counts": class_counts,
        "confusion_labels": cm_labels,
        "confusion_matrix": cm,
        "n_trials": int(X.shape[0]),
        "n_features": int(X.shape[1]),
    }


def print_report(sessions: list[Path], trials: list[Trial], result: dict, args) -> bool:
    """Print human-readable report. Returns True iff the gate passed."""
    print("=" * 72)
    print(f"NeuralCompose Track B — Imagined Speech Signal Evaluator")
    print("=" * 72)
    print(f"Sessions analyzed: {len(sessions)}")
    for s in sessions:
        print(f"  • {s.name}")
    print(f"Target classes:    {sorted(set(t.target for t in trials))}")
    print(f"Trials (total):    {result['n_trials']}")
    for cls, n in sorted(result["class_counts"].items()):
        print(f"    {cls:>8s}: {n}")
    print(f"Feature dim:       {result['n_features']}  ({len(BANDS)} bands × per-channel log-power)")
    print(f"CV folds:          {args.folds} ({result['cv']})")
    print()
    print(f"Per-fold balanced accuracy:")
    for i, s in enumerate(result["fold_scores"]):
        print(f"    fold {i+1}: {s:.4f}")
    print(f"Mean: {result['balanced_accuracy_mean']:.4f}   "
          f"SD: {result['balanced_accuracy_sd']:.4f}   "
          f"95% CI (Wilson): [{result['wilson_ci_95'][0]:.4f}, {result['wilson_ci_95'][1]:.4f}]")
    print()
    print("Confusion matrix (rows = true, cols = predicted):")
    labels = result["confusion_labels"]
    header = "    " + "".join(f"{l:>10s}" for l in labels)
    print(header)
    for i, l in enumerate(labels):
        row = f"{l:>4s}" + "".join(f"{result['confusion_matrix'][i][j]:>10d}" for j in range(len(labels)))
        print(row)
    print()

    # Gate evaluation.
    min_count = min(result["class_counts"].values()) if result["class_counts"] else 0
    bacc = result["balanced_accuracy_mean"]
    time_bacc = result["time_index_balanced_accuracy"]
    bacc_ok = bacc >= GATE_BALANCED_ACCURACY
    count_ok = min_count >= GATE_MIN_PER_CLASS
    time_ok = result["beats_time_index"]

    print(f"Pre-registration gate:")
    print(f"    balanced_accuracy ≥ {GATE_BALANCED_ACCURACY:.2f}: "
          f"{bacc:.4f}  {'✓' if bacc_ok else '✗'}")
    print(f"    min trials/class  ≥ {GATE_MIN_PER_CLASS}:    "
          f"{min_count}  {'✓' if count_ok else '✗'}")
    print(f"    beats time-index baseline:    "
          f"{bacc:.4f} vs {time_bacc:.4f}  {'✓' if time_ok else '✗'}")
    if not time_ok:
        print("      ** trial position predicts the label as well as the EEG does.")
        print("         Whatever this is measuring, it is not imagined speech.")
    print()
    if bacc_ok and count_ok and time_ok:
        print("[PRE-REGISTRATION GATE PASSED]")
        return True
    else:
        print("[GATE FAILED - INSUFFICIENT SIGNAL]")
        return False


def _drift_trials(n=160, fs=256.0, run_len=4, seed=0) -> list[Trial]:
    """Trials whose only structure is drift + the run structure of a shuffled order.

    This is the real leak, not a caricature of it. Trial order is a 50/50 shuffle
    (as ImaginedSpeechProtocol.buildTrialOrder produces), which by chance yields
    RUNS of same-class trials. Amplitude drifts monotonically with acquisition
    position and carries no class information whatsoever.

    Within one run, the drift value is nearly constant and identifies that run —
    and the run identifies the class. So a shuffled split, which puts a trial's
    immediate neighbours in the training set, can read the label off the drift.
    A blocked split holds whole runs out together and cannot.
    """
    rng = np.random.default_rng(seed)
    labels: list[str] = []
    while len(labels) < n:
        lab = "yes" if len(labels) // run_len % 2 == 0 else "no"
        labels.extend([lab] * run_len)
    labels = labels[:n]
    rng.shuffle(labels)   # keeps the 50/50 balance, keeps runs by chance
    trials = []
    for i, lab in enumerate(labels):
        amp = 10.0 * (1.0 + 0.05 * i)           # depends on POSITION, never on lab
        ch = rng.normal(0.0, amp, (4, int(fs)))
        trials.append(Trial(session_id="synthetic", trial_index=i, target=lab,
                            channels=ch, sample_rate=fs))
    return trials


def demo() -> int:
    """Self-check, no hardware: ./evaluate-imagined-signal.py --self-check

    NOTE what this does and does not assert. It asserts the gate rejects data with
    no class signal. It does NOT assert that the old shuffled-fold evaluator
    inflated the score, because that could not be demonstrated — see the measured
    non-result printed below and docs/reviews/time-leakage-2026-08-06.md.
    """
    ok = True
    for seed in range(4):
        trials = _drift_trials(seed=seed)
        X = np.vstack([trial_features(t) for t in trials])
        y = np.array([t.target for t in trials])
        groups = time_blocks(trials, 5)

        blocked, *_ = _cv_score(X, y, GroupKFold(n_splits=5), (X, y, groups))
        t_index = np.arange(len(trials), dtype=float).reshape(-1, 1)
        time_only, *_ = _cv_score(t_index, y, GroupKFold(n_splits=5), (t_index, y, groups))
        leaky, *_ = _cv_score(X, y, StratifiedKFold(5, shuffle=True, random_state=1337), (X, y))

        # The property that matters: no class signal in, no pass out.
        assert not (blocked >= GATE_BALANCED_ACCURACY and blocked > time_only), (
            f"seed {seed}: drift-only data passed the gate — "
            f"blocked={blocked:.4f} time-index={time_only:.4f}")
        if leaky >= GATE_BALANCED_ACCURACY:
            ok = False
            print(f"  seed {seed}: shuffled CV DID clear the gate ({leaky:.4f}) — "
                  "the leak reproduces after all; update the review doc")
        print(f"  seed {seed}: blocked={blocked:.4f} time-index={time_only:.4f} "
              f"shuffled={leaky:.4f}")

    print("self-check ok — drift-only data is rejected by the gate.")
    if ok:
        print("Measured non-result: shuffled CV did NOT clear the 0.65 gate on drift-only "
              "data either. LinearSVC on 16 global band-power features has too little "
              "capacity to exploit fold-local structure, so no inflation was demonstrated. "
              "GroupKFold is kept as the conservative design, not as a fix for a measured "
              "defect.")
    return 0


def main() -> int:
    if "--self-check" in sys.argv:
        return demo()
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", type=Path,
                        help="Session directories (or roots containing sessions).")
    parser.add_argument("--classes", default="yes,no",
                        help="Comma-separated active classes to evaluate. Default: yes,no")
    parser.add_argument("--folds", type=int, default=5)
    parser.add_argument("--seed", type=int, default=1337)
    args = parser.parse_args()

    default_root = Path.home() / "Documents" / "NeuralCompose" / "Calibration" / "TrackB_Imagined"
    target_classes = {c.strip().lower() for c in args.classes.split(",") if c.strip()}
    if len(target_classes) < 2:
        print("[error] Need ≥2 active classes to classify; got: "
              f"{target_classes}", file=sys.stderr)
        return 2

    sessions = discover_sessions(args.paths, default_root)
    if not sessions:
        print("[error] No sessions with imagined_events.csv found.", file=sys.stderr)
        return 2

    trials: list[Trial] = []
    for s in sessions:
        trials.extend(load_session_trials(s, target_classes))
    if not trials:
        print("[error] No usable trials extracted. Check session contents.", file=sys.stderr)
        # Emit the gate sentinel too so shell wrappers can grep one line.
        print("[GATE FAILED - INSUFFICIENT SIGNAL]")
        return 1
    # Need at least N trials per class for CV to be meaningful.
    classes, counts = np.unique([t.target for t in trials], return_counts=True)
    if len(classes) < 2:
        print(f"[error] Only saw class(es) {classes.tolist()} — need at least two.",
              file=sys.stderr)
        return 2
    if counts.min() < args.folds:
        print(f"[error] Smallest class has {counts.min()} trials, fewer than "
              f"--folds={args.folds}. Use --folds {max(2, int(counts.min()))} "
              "or collect more data.", file=sys.stderr)
        return 2

    result = evaluate(trials, folds=args.folds, seed=args.seed)
    passed = print_report(sessions, trials, result, args)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
