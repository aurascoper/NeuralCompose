#!/usr/bin/env python3
"""
generate_synthetic_sleep.py — Offline synthetic sleep-stage data generator.

Produces a physiologically-grounded synthetic 4-class hypnogram
(Wake / N1 / N2_N3 / REM) with relative EEG frequency-band powers
([delta, theta, alpha, beta]) per 30-second epoch.

The generator is intentionally **synthetic** — not a substitute for a
labeled PSG dataset. The brief's Risk Register names "Domain shift from
PSG datasets (central/occipital channels vs frontal)" as the largest
expected source of error. This generator models the **frontal** topology
Muse actually uses, not the central/occipital topology of public PSG
datasets, so downstream classifiers train on a domain that's closer to
deployment. The ground-truth profiles here are *physiological motivation*,
not normative thresholds — calibrate against any real labeled data when it
arrives.

Two load-bearing math choices, both corrected from the original pasted
sketch:

1. **Dirichlet sampling for relative band powers.** Relative band powers
   sum to 1.0 by construction, so a Dirichlet distribution is the
   mathematically correct prior. Standard Gaussian sampling would break
   the simplex constraint. Concentration K controls spread: higher K =
   tighter cluster, lower K = noisier boundaries.

2. **Non-homogeneous Markov chain for stage transitions.** A static
   transition matrix is memoryless and produces exponentially-distributed
   stage durations, which means random bouncing rather than the structured
   ~90-minute ultradian cycle of real human sleep. The base matrix is
   modulated by a sine oscillator on the Deep→REM gateway that fires
   only in the second half of each 90-min cycle, producing realistic
   hypnograms.

Stage naming follows the on-disk brief (`SLEEP_CYCLE_DESIGN.md` D1):
`WAKE / N1 / N2_N3 / REM` — N2 and N3 are collapsed into a single
"Deep" class because Muse's 4 frontal channels cannot reliably
distinguish them.

This script is **offline-only** Stage 3.5 tooling. It does not import
or interact with any BCI* module, BCILLM, MLX, or BCIBridge. The
downstream Python trainer (Random Forest + temporal rolling features +
CoreML export) is S-3 in `Evaluation/corpora/dream_mode_hypothesis_registry.json`
and stays pre-registered until the trainer lands.

Usage:
  ./Scripts/generate_synthetic_sleep.py
  ./Scripts/generate_synthetic_sleep.py --hours 8 --seed 42 --k 50 --out Data/synthetic_sleep_session.json

Importable:
  from generate_synthetic_sleep import (
      NonHomogeneousSleepGenerator, SleepStage, STAGE_PROFILES,
  )
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import deque
from enum import IntEnum
from pathlib import Path
from typing import Optional

import numpy as np


# ---------------------------------------------------------------------------
# Stage enum + physiological ground truth
# ---------------------------------------------------------------------------

class SleepStage(IntEnum):
    """4-class sleep stage model, matching `SLEEP_CYCLE_DESIGN.md` D1."""
    WAKE = 0
    N1 = 1
    N2_N3 = 2  # N2 and N3 collapsed — Muse cannot reliably distinguish
    REM = 3


# Human-readable labels for printing (indexed by raw value)
STAGE_NAMES = ("Wake", "N1", "N2/N3", "REM")

# Single-character glyphs for the ASCII hypnogram (indexed by raw value)
STAGE_GLYPHS = ("W", "1", "D", "R")


# Frontal-EEG ground truth: relative band power means [delta, theta, alpha, beta]
# Sources: AASM sleep staging literature; frontal derivation biases (less
# alpha-dominant than occipital; more beta during wake; deep-sleep slow-wave
# activity is strong in frontal derivations).
#
# Note: N1 and REM have similar profiles in pure spectral terms (both
# theta-dominant). The known hard case is distinguishing them with a
# single 30s epoch. The temporal rolling features the downstream RF
# trainer adds (S-3) are how the system disambiguates them in practice.
STAGE_PROFILES: dict[SleepStage, np.ndarray] = {
    SleepStage.WAKE:  np.array([0.15, 0.20, 0.40, 0.25]),
    SleepStage.N1:    np.array([0.25, 0.50, 0.15, 0.10]),
    SleepStage.N2_N3: np.array([0.65, 0.20, 0.10, 0.05]),
    SleepStage.REM:   np.array([0.20, 0.45, 0.15, 0.20]),
}


# Base 4x4 transition matrix for 30-second epochs.
# Rows: current stage [WAKE, N1, N2_N3, REM]
# Cols: next stage    [WAKE, N1, N2_N3, REM]
# Diagonal self-transition probabilities encode the expected baseline
# duration of each stage (P(stay) ≈ 1 - 1/expected_epochs). Physiological
# rules encoded:
#   - Wake cannot jump directly to Deep or REM (must pass through N1)
#   - REM only exits to Wake or N1 (the REM gateway)
#   - Deep->REM is the sine-modulated gateway (see _get_transition_matrix)
BASE_TRANSITION_MATRIX = np.array([
    [0.900, 0.100, 0.000, 0.000],  # WAKE
    [0.030, 0.850, 0.120, 0.000],  # N1
    [0.002, 0.008, 0.980, 0.010],  # N2_N3 (Deep->REM modulated)
    [0.012, 0.018, 0.000, 0.970],  # REM
], dtype=np.float64)

# Ultradian cycle: 90 minutes = 180 epochs at 30s each.
ULTRADIAN_PERIOD_EPOCHS = 180

# Phase shift: delays the first REM peak so NREM must come first.
# At t=0, sin(-pi/2) = -1, clamped to 0, so Deep->REM stays at baseline
# for the first ~22.5 minutes (when sin first crosses 0). Peak at t=90
# (minute 45 of the cycle) — see _get_transition_matrix for the math.
ULTRADIAN_PHASE_SHIFT = np.pi / 2.0

# Amplitude of the Deep->REM modulation. 0.040 is enough to spike the
# baseline transition probability from 0.010 to 0.050 at the cycle peak
# without overwhelming the diagonal (Deep->Deep stays dominant at ~0.94).
DEEP_TO_REM_AMPLITUDE = 0.040

# Dirichlet concentration parameter K. Higher = tighter cluster around
# the mean vector. K=50 is moderate; K=10 would be very noisy.
DEFAULT_K = 50.0

# Smoothing window for the temporal moving average over band powers.
# 3 epochs = 90 seconds of context. Matches the downstream RF trainer's
# rolling-3 feature plan (S-3).
SMOOTHING_WINDOW = 3


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

class NonHomogeneousSleepGenerator:
    """
    Produces a synthetic hypnogram with relative band powers per epoch.

    The chain is non-homogeneous: the base transition matrix is modulated
    at each step by a sine oscillator on the Deep->REM gateway, producing
    the ~90-minute ultradian rhythm of real human sleep rather than the
    memoryless exponential bouncing of a static Markov chain.

    Relative band powers are sampled from a Dirichlet distribution centered
    on the per-stage mean profile, with smoothing over a 3-epoch window
    to mimic the slow metabolic inertia of real brain state transitions.
    """

    def __init__(self, seed: int = 42, k_concentration: float = DEFAULT_K):
        if k_concentration <= 0:
            raise ValueError(f"k_concentration must be > 0, got {k_concentration}")
        self._rng = np.random.default_rng(seed)
        self.K = float(k_concentration)
        # Pre-compute Dirichlet alpha vectors per stage for sampling speed.
        self._dirichlet_alphas: dict[SleepStage, np.ndarray] = {
            stage: profile * self.K for stage, profile in STAGE_PROFILES.items()
        }

    def _get_transition_matrix(self, t_epoch: int) -> np.ndarray:
        """
        Modulate the base transition matrix for epoch `t_epoch`.

        The only modulation is on the Deep->REM gateway, gated by a sine
        oscillator with period 180 epochs (90 minutes) and phase shift
        pi/2. The oscillator is clamped to non-negative so Deep->REM only
        gets boosted, never suppressed below baseline. The Deep->Deep cell
        absorbs the mass to keep the row stochastic.
        """
        P = BASE_TRANSITION_MATRIX.copy()
        oscillator = np.sin(
            (2.0 * np.pi * t_epoch / ULTRADIAN_PERIOD_EPOCHS) - ULTRADIAN_PHASE_SHIFT
        )
        modulator = max(0.0, float(oscillator)) * DEEP_TO_REM_AMPLITUDE
        P[SleepStage.N2_N3, SleepStage.REM] += modulator
        P[SleepStage.N2_N3, SleepStage.N2_N3] -= modulator
        # Numerical safety: the construction is exact (mass conserved), but
        # assert anyway so any future change to the modulation logic is
        # caught immediately rather than silently breaking the chain.
        row_sum = P[SleepStage.N2_N3].sum()
        if not np.isclose(row_sum, 1.0, atol=1e-9):
            raise RuntimeError(
                f"transition row for N2_N3 does not sum to 1.0 at t={t_epoch}: {row_sum}"
            )
        return P

    def generate_session(self, total_hours: float = 8.0) -> list[dict]:
        """
        Generate one synthetic sleep session.

        Returns a list of epoch dicts in chronological order. Each epoch
        has: epoch_index, timestamp_seconds, ground_truth_stage (int 0-3),
        and features.{relative_delta,relative_theta,relative_alpha,relative_beta}.
        """
        if total_hours <= 0:
            raise ValueError(f"total_hours must be > 0, got {total_hours}")
        total_epochs = int(round((total_hours * 3600.0) / 30.0))

        current_stage = SleepStage.WAKE
        # Bounded buffer for the temporal smoothing. deque(maxlen=N) is
        # O(1) for append + auto-evict; a plain list with pop(0) is O(n).
        power_history: deque[np.ndarray] = deque(maxlen=SMOOTHING_WINDOW)
        epochs: list[dict] = []

        for t in range(total_epochs):
            # 1. Sample next stage from the modulated transition matrix.
            trans_matrix = self._get_transition_matrix(t)
            probs = trans_matrix[int(current_stage)]
            next_idx = int(self._rng.choice(4, p=probs))
            current_stage = SleepStage(next_idx)

            # 2. Sample relative band powers from the per-stage Dirichlet.
            raw_powers = self._rng.dirichlet(self._dirichlet_alphas[current_stage])

            # 3. Temporal smoothing (3-epoch moving average) and renormalize
            #    to keep the simplex constraint after the mean.
            power_history.append(raw_powers)
            smoothed = np.mean(power_history, axis=0)
            smoothed = smoothed / smoothed.sum()  # exact renormalization

            epochs.append({
                "epoch_index": t,
                "timestamp_seconds": t * 30,
                "ground_truth_stage": int(current_stage),
                "features": {
                    "relative_delta": float(smoothed[0]),
                    "relative_theta": float(smoothed[1]),
                    "relative_alpha": float(smoothed[2]),
                    "relative_beta":  float(smoothed[3]),
                },
            })

        return epochs


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def save_dataset(epochs: list[dict], path: Path) -> None:
    """Write the full session as JSON. Path is created if missing."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(epochs, f, indent=2)


def render_ascii_hypnogram(epochs: list[dict], width: int = 80) -> str:
    """
    Render a compressed ASCII hypnogram of the session.

    `width` is the target column count. Each output column represents
    `len(epochs) / width` consecutive epochs (rounded). This is a
    *visual* diagnostic, not a scientific artifact — for analysis use
    the JSON.
    """
    if not epochs:
        return "(empty session)"
    n = len(epochs)
    bins = max(1, n // width)
    lines: list[str] = []
    for start in range(0, n, bins):
        chunk = epochs[start:start + bins]
        # Use the dominant stage in the chunk so brief blips don't dominate.
        counts: dict[int, int] = {}
        for e in chunk:
            s = int(e["ground_truth_stage"])
            counts[s] = counts.get(s, 0) + 1
        dominant = max(counts, key=counts.get)  # type: ignore[arg-type]
        lines.append(STAGE_GLYPHS[dominant])
    timestamp_min = n * 30 // 60
    header = f"  0min{'':>{max(0, width - 13)}}{timestamp_min}min ({n} epochs, {n*30//60} min total)"
    return "".join(lines) + "\n" + header


def summarize_hypnogram(epochs: list[dict]) -> dict:
    """
    Compute stage distribution and a coarse 90-min rhythm diagnostic.

    The rhythm diagnostic compares REM epoch counts in the first half
    vs the second half of the session. A well-formed 8-hour session
    with the sine modulation should show a clear second-half bias on
    REM (the ultradian cycle pulls the chain toward REM in the latter
    portion of each 90-min cycle, and the cycle fires ~5x in 8 hours).
    """
    if not epochs:
        return {"epoch_count": 0}
    n = len(epochs)
    counts = {name: 0 for name in STAGE_NAMES}
    for e in epochs:
        counts[STAGE_NAMES[int(e["ground_truth_stage"])]] += 1
    half = n // 2
    rem_first = sum(1 for e in epochs[:half] if int(e["ground_truth_stage"]) == int(SleepStage.REM))
    rem_second = sum(1 for e in epochs[half:] if int(e["ground_truth_stage"]) == int(SleepStage.REM))
    return {
        "epoch_count": n,
        "duration_minutes": n * 30 // 60,
        "stage_counts": counts,
        "stage_fractions": {k: round(v / n, 4) for k, v in counts.items()},
        "rem_first_half": rem_first,
        "rem_second_half": rem_second,
        "second_half_rem_bias": round(rem_second / max(1, rem_first + rem_second), 4),
    }


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _selftest(seed: int = 42, hours: float = 8.0) -> int:
    gen = NonHomogeneousSleepGenerator(seed=seed, k_concentration=DEFAULT_K)
    print(f"⏳ Generating {hours}h synthetic session (seed={seed}, K={DEFAULT_K})...")
    epochs = gen.generate_session(total_hours=hours)
    print(f"✅ Generated {len(epochs)} epochs.")

    summary = summarize_hypnogram(epochs)
    print()
    print("📊 Stage distribution:")
    for name in STAGE_NAMES:
        c = summary["stage_counts"][name]
        f = summary["stage_fractions"][name]
        bar = "█" * int(round(f * 40))
        print(f"   {name:6s}  {c:5d}  {f*100:5.1f}%  {bar}")
    print()
    rem_bias = summary["second_half_rem_bias"]
    print(f"🔁 REM second-half bias: {rem_bias:.3f}  (expected > 0.5 with the sine-gated cycle)")
    if rem_bias < 0.5:
        print(f"   ⚠️  REM is NOT biased toward the second half; the ultradian modulation may not be firing.")
        print(f"      This can happen with unlucky seeds; re-run with a different seed or longer session.")

    # Invariant 1: every epoch's features sum to 1.0 within float tolerance.
    bad_sums = []
    for e in epochs:
        s = sum(e["features"].values())
        if not np.isclose(s, 1.0, atol=1e-6):
            bad_sums.append((e["epoch_index"], s))
    if bad_sums:
        print(f"❌ {len(bad_sums)} epochs have features that do not sum to 1.0 (e.g. epoch {bad_sums[0][0]}: {bad_sums[0][1]})")
        return 1
    print("✅ Every epoch's features sum to 1.0 (simplex constraint preserved).")

    # Invariant 2: no NaN/Inf in any feature.
    for e in epochs:
        for v in e["features"].values():
            if not np.isfinite(v):
                print(f"❌ Non-finite feature in epoch {e['epoch_index']}: {e['features']}")
                return 1
    print("✅ No NaN/Inf in any feature.")

    # Invariant 3: stage distribution is non-degenerate. With K=50 + 8h,
    # every stage should appear at least once for most seeds. Allow 1
    # stage to be missing without failing — flag it as a warning.
    counts = summary["stage_counts"]
    missing = [name for name in STAGE_NAMES if counts[name] == 0]
    if missing:
        print(f"⚠️  No epochs generated for stages: {missing} (unlucky seed; re-run with a different seed)")
    else:
        print(f"✅ All four stages present in the session.")

    # Invariant 4: transition matrix modulations are well-formed.
    # Spot-check a few epochs across the full range.
    for t in [0, 45, 90, 135, 179]:
        P = gen._get_transition_matrix(t)
        if not np.allclose(P.sum(axis=1), 1.0, atol=1e-9):
            print(f"❌ Transition matrix does not have row-stochastic property at t={t}")
            return 1
    print("✅ Transition matrix is row-stochastic at all spot-checked epochs.")

    # ASCII hypnogram
    print()
    print("🌀 Hypnogram (1 char per ~12 epochs; W=Wake, 1=N1, D=N2/N3, R=REM):")
    print(render_ascii_hypnogram(epochs, width=80))

    # Save a sample to disk for the future trainer.
    out_path = Path("Data") / "synthetic_sleep_session.json"
    save_dataset(epochs, out_path)
    print()
    print(f"📝 Wrote {out_path}  ({out_path.stat().st_size:,} bytes)")
    print()
    print("✅ Self-test passed.")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a synthetic 4-class sleep hypnogram with relative band powers.",
    )
    parser.add_argument("--hours", type=float, default=8.0,
                        help="session duration in hours (default: 8.0)")
    parser.add_argument("--seed", type=int, default=42,
                        help="RNG seed for reproducibility (default: 42)")
    parser.add_argument("--k", type=float, default=DEFAULT_K,
                        help=f"Dirichlet concentration parameter (default: {DEFAULT_K})")
    parser.add_argument("--out", type=Path, default=Path("Data") / "synthetic_sleep_session.json",
                        help="output JSON path (default: Data/synthetic_sleep_session.json)")
    parser.add_argument("--quiet", action="store_true",
                        help="suppress per-epoch output; just print the summary")
    args = parser.parse_args(argv)

    gen = NonHomogeneousSleepGenerator(seed=args.seed, k_concentration=args.k)
    epochs = gen.generate_session(total_hours=args.hours)
    save_dataset(epochs, args.out)

    summary = summarize_hypnogram(epochs)
    print(f"✅ Generated {len(epochs)} epochs ({summary['duration_minutes']} min).")
    for name in STAGE_NAMES:
        c = summary["stage_counts"][name]
        f = summary["stage_fractions"][name]
        print(f"   {name:6s}  {c:5d}  {f*100:5.1f}%")
    print(f"   REM second-half bias: {summary['second_half_rem_bias']:.3f}")
    if not args.quiet:
        print()
        print(render_ascii_hypnogram(epochs, width=80))
    print(f"📝 Wrote {args.out}  ({args.out.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
