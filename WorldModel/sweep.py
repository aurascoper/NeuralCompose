#!/usr/bin/env python3
"""sweep.py — reusable hard-case MPC sweep.

This is the third time WorldModel/README.md has needed a multi-seed x
multi-hard-case sweep over `mpc.py::run_episode` (the original 35-trial
sweep, the 2026-07-18 time/horizon/accel parameter sweep, and now the
adaptive-temperature calibration sweep) and the second time the README
explicitly flagged the previous one as "ad hoc... not committed to the
repo." This script replaces that pattern: a fixed, documented `HARD_CASES`
list (so a future rerun reproduces exactly, not approximately) plus a
thin CLI over every `MPCConfig` field, reusing `mpc.py::run_episode`
directly rather than duplicating any simulation logic.

The four corner-to-corner diagonals are exactly the ones already narrated
in WorldModel/README.md's "Fixing the receding-horizon stall" section,
each direction kept separate since that asymmetry (one direction failing
completely, the reverse direction partially succeeding) is itself an open
question this script exists partly to keep re-testable. The three
"large-but-non-maximal" cases are NEW, freshly-documented coordinates
(~1.7 units apart, off the main diagonal) -- the original 35-trial sweep's
three cases in this category were never recorded with exact coordinates,
so this script does not pretend to reconstruct them; it defines its own
reproducible set instead.

Usage:
  ./WorldModel/sweep.py
  ./WorldModel/sweep.py --temperature 0.5 --terminal-cost-weight 0
  ./WorldModel/sweep.py --seeds 0,1,2,3,4 --max-episode-steps 50
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

from dataloader import resolve_device
from env import EnvConfig, ParticleNavigatorEnv
from mpc import GOAL_TOLERANCE, MPCConfig, run_episode
from models import JEPAConfig, JEPAModule
from train import DEFAULT_CHECKPOINT

# (name, start_xy, goal_xy). Corner-to-corner diagonals first (both
# directions of both diagonals, distance 2.263 -- the arena's diagonal
# maximum), then three fresh, non-maximal "large distance" cases
# (distance ~1.70-1.77, off the main diagonal, exact coordinates chosen
# once here and never regenerated randomly, so reruns are exact reruns).
HARD_CASES: list[tuple[str, tuple[float, float], tuple[float, float]]] = [
    ("corner_pp_to_nn", (0.8, 0.8), (-0.8, -0.8)),
    ("corner_nn_to_pp", (-0.8, -0.8), (0.8, 0.8)),
    ("corner_pn_to_np", (0.8, -0.8), (-0.8, 0.8)),
    ("corner_np_to_pn", (-0.8, 0.8), (0.8, -0.8)),
    ("large_a", (0.7, 0.6), (-0.6, -0.6)),
    ("large_b", (-0.6, 0.7), (0.6, -0.5)),
    ("large_c", (0.6, -0.7), (-0.5, 0.6)),
]

DEFAULT_SEEDS = [0, 1, 2, 3, 4]


def parse_seeds(raw: str) -> list[int]:
    return [int(s.strip()) for s in raw.split(",") if s.strip()]


def run_sweep(
    model: JEPAModule,
    env: ParticleNavigatorEnv,
    config: MPCConfig,
    seeds: list[int],
    max_episode_steps: int,
    goal_tolerance: float,
    device: torch.device,
) -> list[dict]:
    """One row per (case, seed). `rng` only feeds candidate sampling
    (start/goal are fixed by HARD_CASES), so varying seed varies the MPPI
    candidate draws only -- exactly what isolates planner-luck from a
    genuinely unreachable case."""
    rows = []
    for name, start_xy, goal_xy in HARD_CASES:
        start = np.array([*start_xy, 0.0, 0.0], dtype=np.float32)
        goal = np.array([*goal_xy, 0.0, 0.0], dtype=np.float32)
        for seed in seeds:
            torch.manual_seed(seed)
            rng = np.random.default_rng(seed)
            result = run_episode(
                env, model, "mpc", start, goal, config,
                max_episode_steps, goal_tolerance, device, rng,
            )
            ess = (
                float(np.mean([d["effective_sample_size"] for d in result["diagnostics"]]))
                if result["diagnostics"]
                else float("nan")
            )
            rows.append(
                {
                    "case": name,
                    "seed": seed,
                    "reached": result["reached"],
                    "final_distance": result["final_distance"],
                    "mean_ess": ess,
                }
            )
    return rows


def print_report(rows: list[dict], num_candidates: int) -> None:
    print(f"| case | seed | reached | final_distance | mean_ess |")
    print(f"|---|---:|---:|---:|---:|")
    for r in rows:
        print(
            f"| {r['case']} | {r['seed']} | {r['reached']} | "
            f"{r['final_distance']:.4f} | {r['mean_ess']:.1f}/{num_candidates} |"
        )

    print()
    by_case: dict[str, list[dict]] = {}
    for r in rows:
        by_case.setdefault(r["case"], []).append(r)
    print("| case | success_rate | mean_final_distance | mean_ess |")
    print("|---|---:|---:|---:|")
    for name, case_rows in by_case.items():
        success = sum(r["reached"] for r in case_rows) / len(case_rows)
        mean_dist = float(np.mean([r["final_distance"] for r in case_rows]))
        mean_ess = float(np.mean([r["mean_ess"] for r in case_rows]))
        print(f"| {name} | {success:.2f} | {mean_dist:.4f} | {mean_ess:.1f}/{num_candidates} |")

    total = len(rows)
    successes = sum(r["reached"] for r in rows)
    print()
    print(
        f"Aggregate: {successes}/{total} ({successes / total:.1%}) literal successes, "
        f"mean_final_distance={float(np.mean([r['final_distance'] for r in rows])):.4f}, "
        f"mean_ess={float(np.mean([r['mean_ess'] for r in rows])):.1f}/{num_candidates}"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    ap.add_argument("--seeds", type=str, default=",".join(str(s) for s in DEFAULT_SEEDS))
    ap.add_argument("--max-episode-steps", type=int, default=50)
    ap.add_argument("--goal-tolerance", type=float, default=GOAL_TOLERANCE)
    ap.add_argument("--max-accel", type=float, default=EnvConfig().max_accel)

    ap.add_argument("--horizon", type=int, default=MPCConfig().horizon)
    ap.add_argument("--num-candidates", type=int, default=MPCConfig().num_candidates)
    ap.add_argument("--temperature", type=float, default=MPCConfig().temperature)
    ap.add_argument("--state-cost-weight", type=float, default=MPCConfig().state_cost_weight)
    ap.add_argument("--smoothness-cost-weight", type=float, default=MPCConfig().smoothness_cost_weight)
    ap.add_argument("--terminal-cost-weight", type=float, default=MPCConfig().terminal_cost_weight)
    ap.add_argument("--stall-velocity-threshold", type=float, default=MPCConfig().stall_velocity_threshold)
    ap.add_argument("--stall-distance-threshold", type=float, default=MPCConfig().stall_distance_threshold)
    ap.add_argument("--stall-variance-multiplier", type=float, default=MPCConfig().stall_variance_multiplier)
    ap.add_argument("--stall-widen-fraction", type=float, default=MPCConfig().stall_widen_fraction)
    ap.add_argument(
        "--adaptive-temperature",
        action=argparse.BooleanOptionalAction,
        default=MPCConfig().adaptive_temperature,
    )
    ap.add_argument("--min-cost-scale", type=float, default=MPCConfig().min_cost_scale)
    ap.add_argument(
        "--normalize-running-cost-by-horizon",
        action=argparse.BooleanOptionalAction,
        default=MPCConfig().normalize_running_cost_by_horizon,
    )
    args = ap.parse_args()

    if not args.checkpoint.exists():
        raise SystemExit(f"{args.checkpoint} not found — run ./WorldModel/train.py first")

    config = MPCConfig(
        horizon=args.horizon,
        num_candidates=args.num_candidates,
        temperature=args.temperature,
        state_cost_weight=args.state_cost_weight,
        smoothness_cost_weight=args.smoothness_cost_weight,
        terminal_cost_weight=args.terminal_cost_weight,
        stall_velocity_threshold=args.stall_velocity_threshold,
        stall_distance_threshold=args.stall_distance_threshold,
        stall_variance_multiplier=args.stall_variance_multiplier,
        stall_widen_fraction=args.stall_widen_fraction,
        adaptive_temperature=args.adaptive_temperature,
        min_cost_scale=args.min_cost_scale,
        normalize_running_cost_by_horizon=args.normalize_running_cost_by_horizon,
    )
    seeds = parse_seeds(args.seeds)
    device = resolve_device()

    ckpt = torch.load(args.checkpoint, map_location=device)
    model = JEPAModule(JEPAConfig(**ckpt["jepa_config"])).to(device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)

    env = ParticleNavigatorEnv(EnvConfig(max_accel=args.max_accel))

    print(f"sweep.py: device={device} checkpoint={args.checkpoint}")
    print(f"  config: {config}")
    print(f"  {len(HARD_CASES)} cases x {len(seeds)} seeds = {len(HARD_CASES) * len(seeds)} trials")
    print()

    rows = run_sweep(model, env, config, seeds, args.max_episode_steps, args.goal_tolerance, device)
    print_report(rows, config.num_candidates)


if __name__ == "__main__":
    main()
