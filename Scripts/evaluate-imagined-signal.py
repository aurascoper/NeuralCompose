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
from sklearn.model_selection import StratifiedKFold
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


def evaluate(trials: list[Trial], folds: int, seed: int) -> dict:
    X = np.vstack([trial_features(t) for t in trials])
    y = np.array([t.target for t in trials])
    classes, counts = np.unique(y, return_counts=True)
    class_counts = dict(zip(classes.tolist(), counts.tolist()))

    skf = StratifiedKFold(n_splits=folds, shuffle=True, random_state=seed)
    fold_scores: list[float] = []
    all_true: list[str] = []
    all_pred: list[str] = []
    for fold_idx, (train_idx, test_idx) in enumerate(skf.split(X, y)):
        pipe = Pipeline([
            ("scaler", StandardScaler()),
            ("svm", LinearSVC(C=1.0, dual="auto", max_iter=5000)),
        ])
        pipe.fit(X[train_idx], y[train_idx])
        pred = pipe.predict(X[test_idx])
        score = balanced_accuracy_score(y[test_idx], pred)
        fold_scores.append(score)
        all_true.extend(y[test_idx].tolist())
        all_pred.extend(pred.tolist())

    mean = float(np.mean(fold_scores))
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
    print(f"CV folds:          {args.folds} (stratified, seed={args.seed})")
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
    bacc_ok = bacc >= GATE_BALANCED_ACCURACY
    count_ok = min_count >= GATE_MIN_PER_CLASS

    print(f"Pre-registration gate:")
    print(f"    balanced_accuracy ≥ {GATE_BALANCED_ACCURACY:.2f}: "
          f"{bacc:.4f}  {'✓' if bacc_ok else '✗'}")
    print(f"    min trials/class  ≥ {GATE_MIN_PER_CLASS}:    "
          f"{min_count}  {'✓' if count_ok else '✗'}")
    print()
    if bacc_ok and count_ok:
        print("[PRE-REGISTRATION GATE PASSED]")
        return True
    else:
        print("[GATE FAILED - INSUFFICIENT SIGNAL]")
        return False


def main() -> int:
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
