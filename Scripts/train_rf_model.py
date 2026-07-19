#!/usr/bin/env python3
"""
train_rf_model.py — S-3 Milestone 2: Random Forest trainer for the
4-class synthetic sleep-stage dataset.

Consumes `Scripts/generate_synthetic_sleep.py` as a Python API (each
generator call with a different seed IS one "session" for Leave-One-
Session-Out CV), engineers a scannable feature matrix from the raw
Dirichlet band powers, runs a grid search with LOSO cross-validation,
and reports per-seed macro F1 plus mean±std across seeds.

This is **offline-only** Stage 3.5 tooling. It does not import or
interact with any BCI* module, BCILLM, MLX, or BCIBridge. The CoreML
export step is the next integration hook and stays held behind the
boundary contract (per `Evaluation/reports/decision_registry.md` entry 7)
until S-3 milestone 3 / Stage 4 evidence gates open.

**Scope discipline:** the pasted S-3 sketch used mock data with
string labels and an invented `session_id`. This implementation
(a) calls the actual generator via its Python API, (b) uses integer
labels matching the generator's `ground_truth_stage` output, and
(c) treats each seed run as one session (so the seed-sweep doubles
as the LOSO group axis). No mock data, no string labels, no
invented columns.

**Hyperparameter grid:** the pasted grid has
`n_estimators × max_depth × min_samples_split × class_weight`
= 3 × 4 × 3 × 2 = 72 combinations. That times 10 LOSO folds times
10 seeds = 7,200 fits for a full run. With `n_jobs=-1` on M-series
hardware this is hours. The `--quick` flag runs a 4-point reduced
grid (the four corners of the search space) on 3 sessions for a
smoke test that finishes in minutes. The full grid is opt-in via
the absence of `--quick`.

Usage:
  ./Scripts/train_rf_model.py --quick                 # smoke test
  ./Scripts/train_rf_model.py --n-sessions 10         # full LOSO sweep
  ./Scripts/train_rf_model.py --quick --n-sessions 3  # explicit small smoke test
  ./Scripts/train_rf_model.py --n-jobs 4              # cap parallelism

Importable:
  from train_rf_model import (
      generate_session_dataframe, engineer_features,
      run_loso_grid_search, score_seed, summarize_seed_sweep,
      PARAM_GRID_QUICK, PARAM_GRID_FULL, STAGE_NAMES,
  )
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

# sklearn is a third-party dep shared by the existing training pipeline
# (Scripts/train-intent-classifier.py already imports it). No new deps.
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import GridSearchCV, LeaveOneGroupOut
from sklearn.metrics import (
    classification_report,
    confusion_matrix,
    f1_score,
)

# The generator lives in the same Scripts/ directory. Make it importable
# when this script is run directly (./Scripts/train_rf_model.py) AND
# when imported as a module from elsewhere.
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from generate_synthetic_sleep import (  # noqa: E402
    DEFAULT_K,
    NonHomogeneousSleepGenerator,
    SleepStage,
    STAGE_NAMES,
)


logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger("train_rf_model")


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Integer label lookup, indexed by the SleepStage IntEnum's value.
# The generator emits `ground_truth_stage` as int(0|1|2|3); the trainer
# uses those ints directly. STAGE_NAMES (indexed by raw value) is the
# human-readable name.
STAGE_LABEL_NAMES = list(STAGE_NAMES)  # ("Wake", "N1", "N2/N3", "REM")


# Full parameter grid per the S-3 spec. 3 × 4 × 3 × 3 × 2 = 216 fits
# per LOSO fold (we add min_samples_leaf vs the original sketch).
# At 10 sessions × 10 seeds = 216,000 RF fits — opt-in via --full.
PARAM_GRID_FULL = {
    "n_estimators":      [50, 100, 200],
    "max_depth":         [5, 8, 12, None],
    "min_samples_split": [2, 5, 10],
    "min_samples_leaf":  [1, 2, 5],
    "class_weight":      ["balanced", None],
}


# Reduced "smoke" grid: four corners of the search space. The smoke
# test is meant to prove the pipeline works end-to-end, not to find
# the best hyperparameters — use --full for the real sweep.
PARAM_GRID_QUICK = {
    "n_estimators":      [100],
    "max_depth":         [8, None],
    "min_samples_split": [5],
    "min_samples_leaf":  [2],
    "class_weight":      ["balanced"],
}


# Default seed list. 10 distinct seeds, biased toward small ints
# (cheap, reproducible) and including 7 (which the generator's
# smoke test identified as the seed that best matches real-adult
# hypnogram fractions).
DEFAULT_SEEDS = [1, 7, 42, 100, 256, 512, 1024, 2048, 4096, 8192]


# ---------------------------------------------------------------------------
# Data: generate one or all sessions as DataFrames
# ---------------------------------------------------------------------------

def generate_session_dataframe(seed: int, total_hours: float = 8.0) -> pd.DataFrame:
    """
    Generate one synthetic sleep session via the generator's Python API
    and return a pandas DataFrame ready for feature engineering.

    Columns: session_id, epoch, label, delta, theta, alpha, beta.

    `session_id` is set to the seed (so each seed run IS one session
    for LOSO grouping). The generator's nested `features.relative_*`
    JSON shape is flattened to top-level columns.
    """
    gen = NonHomogeneousSleepGenerator(seed=seed, k_concentration=DEFAULT_K)
    epochs = gen.generate_session(total_hours=total_hours)

    rows: list[dict] = []
    for e in epochs:
        feats = e["features"]
        rows.append({
            "session_id": int(seed),
            "epoch":      int(e["epoch_index"]),
            "label":      int(e["ground_truth_stage"]),
            "delta":      float(feats["relative_delta"]),
            "theta":      float(feats["relative_theta"]),
            "alpha":      float(feats["relative_alpha"]),
            "beta":       float(feats["relative_beta"]),
        })
    return pd.DataFrame(rows)


def generate_all_sessions(seeds: list[int], total_hours: float = 8.0) -> pd.DataFrame:
    """
    Generate and concatenate one synthetic session per seed into a single
    DataFrame. The concatenated frame is what the LOSO grid search runs
    on; per-seed scores are extracted from the per-fold LOSO results.
    """
    frames = [generate_session_dataframe(seed=s, total_hours=total_hours) for s in seeds]
    return pd.concat(frames, ignore_index=True)


# ---------------------------------------------------------------------------
# Feature engineering
# ---------------------------------------------------------------------------

def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Transform raw Dirichlet band powers into the scannable feature matrix.

    Per-epoch static features:
      - Raw relative powers (delta, theta, alpha, beta) passed through
      - wake_rem_ratio  = (alpha + beta) / (delta + theta + eps)
      - slow_sleep_ratio = theta / (delta + eps)

    Temporal context features (rolling 3-epoch window, session-bounded):
      - {band}_ma3   = 3-epoch moving average
      - {band}_diff  = t - (t-1) diff (causal, no look-ahead)

    Session-bounded via groupby('session_id') so cross-session
    boundaries don't leak temporal features across the CV split.
    """
    df = df.copy().sort_values(["session_id", "epoch"]).reset_index(drop=True)

    # 1. Static cross-band ratios. Epsilons prevent division-by-zero on
    #    pathological epochs (e.g. all-zero band powers from a dead signal).
    eps = 1e-6
    df["wake_rem_ratio"]   = (df["alpha"] + df["beta"]) / (df["delta"] + df["theta"] + eps)
    df["slow_sleep_ratio"] = df["theta"] / (df["delta"] + eps)

    # 2. Temporal context features, bounded by session_id.
    bands = ["delta", "theta", "alpha", "beta"]
    for band in bands:
        df[f"{band}_ma3"] = (
            df.groupby("session_id")[band]
              .transform(lambda x: x.rolling(window=3, min_periods=1).mean())
        )
        df[f"{band}_diff"] = (
            df.groupby("session_id")[band]
              .transform(lambda x: x.diff().fillna(0.0))
        )

    return df


# ---------------------------------------------------------------------------
# LOSO grid search across all sessions
# ---------------------------------------------------------------------------

def run_loso_grid_search(
    df: pd.DataFrame,
    param_grid: dict,
    n_jobs: int = -1,
) -> dict:
    """
    Run a Leave-One-Session-Out GridSearchCV over the concatenated dataset.

    The DataFrame must contain all sessions concatenated (one per row in
    `session_id`). LOSO holds out one session at a time, trains on the
    rest, and scores on the held-out session. With N sessions this gives
    N folds, and the per-fold F1 scores are mappable back to individual
    seeds (see `per_fold_score_for_seed`).

    Returns:
      best_score       : float — mean LOSO macro F1 of the best estimator
      best_params      : dict  — the best hyperparameter set
      best_estimator   : RandomForestClassifier — refit on the full input
      feature_names    : list[str] — column order of the feature matrix
      per_fold_scores  : list[float] — per-fold (per-session) F1, ordered
                          by `cv.split(...)` iteration (deterministic given
                          LeaveOneGroupOut)
      per_fold_sessions: list[int] — the held-out session_id for each fold,
                          in the same order as per_fold_scores
    """
    drop_cols = ["session_id", "epoch", "label"]
    feature_cols = [c for c in df.columns if c not in drop_cols]
    X = df[feature_cols]
    y = df["label"]
    groups = df["session_id"]

    logo = LeaveOneGroupOut()
    rf = RandomForestClassifier(random_state=42, n_jobs=1)  # n_jobs=1 inside; parallelism is in GridSearchCV

    clf = GridSearchCV(
        estimator=rf,
        param_grid=param_grid,
        cv=logo,
        scoring="f1_macro",
        n_jobs=n_jobs,
        refit=True,  # refit the best estimator on the full input so the caller gets a usable model
        verbose=0,
    )
    clf.fit(X, y, groups=groups)

    # Compute per-fold scores for the best estimator so the caller can
    # report the seed's LOSO score (not just the CV mean). The order of
    # `logo.split` is deterministic for LeaveOneGroupOut — the held-out
    # session for each fold is the unique group value of the test indices.
    best_est = clf.best_estimator_
    per_fold_scores: list[float] = []
    per_fold_sessions: list[int] = []
    for train_idx, test_idx in logo.split(X, y, groups):
        # Re-fit per fold to get unbiased per-fold scores (GridSearchCV's
        # best_score_ is the CV mean, not the per-fold list).
        fold_est = RandomForestClassifier(
            random_state=42, n_jobs=1, **clf.best_params_
        )
        # Defensive .iloc coercion: numpy integer arrays satisfy Hashable
        # but not slice, so Pyright can't narrow them. Wrapping in list()
        # gives pandas an explicit integer-list indexer it accepts.
        fold_est.fit(X.iloc[list(train_idx)], y.iloc[list(train_idx)])
        y_pred = fold_est.predict(X.iloc[list(test_idx)])
        per_fold_scores.append(f1_score(y.iloc[list(test_idx)], y_pred, average="macro"))
        # All test rows in this fold share a single session_id (by LOSO definition).
        per_fold_sessions.append(int(groups.iloc[list(test_idx)[0]]))

    return {
        "best_score":        float(clf.best_score_),
        "best_params":       dict(clf.best_params_),
        "best_estimator":    best_est,
        "feature_names":     feature_cols,
        "per_fold_scores":   per_fold_scores,
        "per_fold_sessions": per_fold_sessions,
    }


def per_fold_score_for_seed(per_fold_sessions: list[int], per_fold_scores: list[float], seed: int) -> Optional[float]:
    """Look up the LOSO F1 score for a specific held-out session (seed)."""
    for sess, score in zip(per_fold_sessions, per_fold_scores):
        if sess == seed:
            return float(score)
    return None


# ---------------------------------------------------------------------------
# Per-seed experiment wrapper (build full dataset once, run LOSO once)
# ---------------------------------------------------------------------------

def run_seed_sweep(
    seeds: list[int],
    param_grid: dict,
    total_hours: float = 8.0,
    n_jobs: int = -1,
) -> dict:
    """
    Generate one session per seed, concatenate, engineer features, run a
    single LOSO grid search across all sessions.

    Per-seed F1 is the LOSO score on the fold where that seed is held out.
    Aggregate mean ± std is reported over those per-seed scores.
    """
    t0 = time.time()
    # 1. Generate all sessions and engineer features once.
    raw = generate_all_sessions(seeds=seeds, total_hours=total_hours)
    df_feat = engineer_features(raw)
    log.info("Generated %d sessions (%d total epochs); engineered feature matrix shape %s",
             len(seeds), len(df_feat), df_feat.shape)

    # 2. Run the single LOSO grid search across all sessions.
    loso = run_loso_grid_search(df_feat, param_grid=param_grid, n_jobs=n_jobs)
    elapsed = time.time() - t0

    # 3. Per-seed scores: look up the LOSO fold for each seed.
    per_seed: list[dict] = []
    for seed in seeds:
        score = per_fold_score_for_seed(loso["per_fold_sessions"], loso["per_fold_scores"], seed=seed)
        per_seed.append({
            "seed":         int(seed),
            "loso_f1":     score,
        })

    return {
        "elapsed_sec":   float(elapsed),
        "n_sessions":    len(seeds),
        "epoch_count":   int(len(df_feat)),
        "stage_counts":  {STAGE_NAMES[k]: int(v) for k, v in
                          pd.Series([int(x) for x in df_feat["label"]]).value_counts().sort_index().items()},
        "best_params":   loso["best_params"],
        "best_score":    loso["best_score"],   # mean across folds
        "per_fold_scores":   loso["per_fold_scores"],
        "per_fold_sessions": loso["per_fold_sessions"],
        "per_seed":      per_seed,
        "best_estimator":  loso["best_estimator"],
        "feature_names":   loso["feature_names"],
        "df_all":         df_feat,  # kept for the confusion-matrix diagnostic on the best estimator
    }


# ---------------------------------------------------------------------------
# Aggregate reporting
# ---------------------------------------------------------------------------

def summarize_seed_sweep(result: dict) -> dict:
    """
    Aggregate per-seed LOSO results into a mean ± std report.
    """
    scores = np.array([s["loso_f1"] for s in result["per_seed"] if s["loso_f1"] is not None], dtype=float)
    return {
        "n_seeds":             result["n_sessions"],
        "per_seed_scores":     [s["loso_f1"] for s in result["per_seed"]],
        "per_seed_params":     [result["best_params"]] * result["n_sessions"],  # one set of best params per LOSO run
        "macro_f1_mean":       float(scores.mean()),
        "macro_f1_std":        float(scores.std(ddof=0)),
        "macro_f1_min":        float(scores.min()),
        "macro_f1_max":        float(scores.max()),
        "per_fold_score_mean": float(np.mean(result["per_fold_scores"])),
        "per_fold_score_std":  float(np.std(result["per_fold_scores"], ddof=0)),
    }


# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------

def print_feature_importances(estimator, feature_names, top_n: int = 5) -> list[tuple[str, float]]:
    """Log the top-N feature importances and return them as a sorted list."""
    importances = np.asarray(estimator.feature_importances_, dtype=float)
    order = np.argsort(importances)[::-1]
    top: list[tuple[str, float]] = []
    log.info("Top-%d feature importances (best model):", top_n)
    for i in range(min(top_n, len(order))):
        name = feature_names[order[i]]
        imp = float(importances[order[i]])
        top.append((name, imp))
        log.info("  %2d. %-22s %.4f", i + 1, name, imp)
    return top


def print_confusion_matrix(estimator, df: pd.DataFrame) -> None:
    """Log a confusion matrix for the best estimator, refit on the full data."""
    drop_cols = ["session_id", "epoch", "label"]
    feature_cols = [c for c in df.columns if c not in drop_cols]
    X = df[feature_cols]
    y = df["label"]
    y_pred = estimator.predict(X)
    cm = confusion_matrix(y, y_pred, labels=list(range(len(STAGE_LABEL_NAMES))))
    log.info("Confusion matrix (rows=true, cols=pred) — refit-on-full is optimistic:")
    header = "          " + "  ".join(f"{n:>7s}" for n in STAGE_LABEL_NAMES)
    log.info(header)
    for i, name in enumerate(STAGE_LABEL_NAMES):
        row = "  ".join(f"{cm[i, j]:7d}" for j in range(len(STAGE_LABEL_NAMES)))
        log.info("  %-7s %s", name, row)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="S-3 Milestone 2: Random Forest trainer with LOSO grid search over synthetic sessions."
    )
    parser.add_argument("--seeds", type=int, nargs="+", default=DEFAULT_SEEDS,
                        help=f"generator seeds (default: {DEFAULT_SEEDS})")
    parser.add_argument("--n-sessions", type=int, default=None,
                        help="alias for --seeds length: take the first N from the default list")
    parser.add_argument("--hours", type=float, default=8.0,
                        help="session duration in hours (default: 8.0)")
    parser.add_argument("--n-jobs", type=int, default=-1,
                        help="parallelism for GridSearchCV (default: -1 = all cores)")
    parser.add_argument("--quick", action="store_true",
                        help="run the reduced 4-point smoke grid instead of the full 216-point grid")
    parser.add_argument("--out", type=Path, default=Path("Data") / "rf_training_report.json",
                        help="output JSON report path (default: Data/rf_training_report.json)")
    args = parser.parse_args(argv)

    seeds = list(args.seeds)
    if args.n_sessions is not None:
        seeds = seeds[: args.n_sessions]

    param_grid = PARAM_GRID_QUICK if args.quick else PARAM_GRID_FULL
    n_combos = int(np.prod([len(v) for v in param_grid.values()]))
    log.info("=== S-3 Milestone 2: Random Forest trainer ===")
    log.info("seeds: %s  (n=%d)", seeds, len(seeds))
    log.info("session duration: %.1f h (%d epochs each)", args.hours, int(args.hours * 120))
    log.info("param grid: %s  -> %d combinations per LOSO fold", "QUICK" if args.quick else "FULL", n_combos)
    log.info("LOSO folds per grid point: %d", len(seeds))
    log.info("n_jobs: %d", args.n_jobs)

    t_start = time.time()
    result = run_seed_sweep(seeds=seeds, param_grid=param_grid, total_hours=args.hours, n_jobs=args.n_jobs)
    elapsed_total = time.time() - t_start

    summary = summarize_seed_sweep(result)

    log.info("=" * 50)
    log.info("S-3 MILESTONE 2: AGGREGATE RESULTS (%d seeds)", len(seeds))
    log.info("=" * 50)
    log.info("LOSO mean (GridSearchCV): %.4f", result["best_score"])
    log.info("Per-seed mean ± std     : %.4f ± %.4f", summary["macro_f1_mean"], summary["macro_f1_std"])
    log.info("Per-seed range          : %.4f .. %.4f", summary["macro_f1_min"], summary["macro_f1_max"])
    log.info("Per-fold mean ± std     : %.4f ± %.4f", summary["per_fold_score_mean"], summary["per_fold_score_std"])
    log.info("Best params             : %s", result["best_params"])
    log.info("Total wall time         : %.1f s (LOSO %.1f s)", elapsed_total, result["elapsed_sec"])

    # Per-seed LOSO breakdown
    for s in result["per_seed"]:
        log.info("  seed %5d  LOSO F1 = %.4f", s["seed"], s["loso_f1"] if s["loso_f1"] is not None else float("nan"))

    # Feature importances for the best estimator
    print_feature_importances(result["best_estimator"], result["feature_names"], top_n=5)

    # Confusion matrix on the best estimator, refit on the union of all seeds
    # (optimistic — for diagnostic only, not a generalization claim).
    print_confusion_matrix(result["best_estimator"], result["df_all"])

    # Persist the report (no estimator pickle — only metrics and params).
    args.out.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "seeds":              seeds,
        "param_grid":         {k: list(v) for k, v in param_grid.items()},
        "param_grid_kind":    "QUICK" if args.quick else "FULL",
        "n_combos":           n_combos,
        "best_params":        result["best_params"],
        "loso_mean_score":    result["best_score"],
        "per_seed":           result["per_seed"],
        "per_fold_scores":    result["per_fold_scores"],
        "per_fold_sessions":  result["per_fold_sessions"],
        "summary":            summary,
        "elapsed_total_sec":  elapsed_total,
        "loso_elapsed_sec":   result["elapsed_sec"],
    }
    with args.out.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, default=str)
    log.info("Wrote %s (%d bytes)", args.out, args.out.stat().st_size)

    # Brief pass/fail against the success criterion from S-3.
    target = 0.60
    if summary["macro_f1_mean"] >= target:
        log.info("✅ Per-seed mean macro F1 %.4f >= target %.2f (S-3 success criterion met on synthetic)", summary["macro_f1_mean"], target)
    else:
        log.info("⚠️  Per-seed mean macro F1 %.4f < target %.2f (S-3 success criterion NOT met on synthetic; investigate before promoting)", summary["macro_f1_mean"], target)
    log.info("[Pending: CoreML export is the next integration step; held behind Stage 4 boundary contract.]")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
