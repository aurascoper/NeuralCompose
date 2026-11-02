#!/usr/bin/env python3
"""benchmark_reference.py — validate that the control measure can discriminate.

Ledger node 9. Through node 8 every objective arm scored 0/35 on `reached`,
and five consecutive representation-side improvements produced no movement in
that number. Two explanations were live and the harness could not tell them
apart:

  (a) the task is not achievable within max_steps, so 0/35 is correct and
      uninformative; or
  (b) the planner is failing at something achievable.

A benchmark that cannot separate those is not measuring the thing it is being
read for. This script settles it by running REFERENCE policies -- an analytic
PD controller on true state (upper reference) and random/zero (lower
references) -- over the same `HARD_CASES` the objective arms use.

The validation gate is deliberately about the MEASURE, not about any model:
a measure that cannot rank policies already known to differ cannot be trusted
to rank policies whose difference is the open question. If the oracle does not
separate from random under a metric, that metric is rejected regardless of what
it says about a checkpoint.

Reported per policy:
  reached                 the historical binary criterion
  normalized_progress     (initial - closest approach) / initial, per case
  best_distance           closest approach, NOT the final position

Usage:
  ./WorldModel/benchmark_reference.py --checkpoint <ckpt>
  ./WorldModel/benchmark_reference.py --checkpoint <ckpt> --unbounded
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch

from dataloader import resolve_device
from env import EnvConfig, ParticleNavigatorEnv
from mpc import GOAL_TOLERANCE, MPCConfig
from models import JEPAConfig, JEPAModule
from sweep import HARD_CASES, DEFAULT_SEEDS, parse_seeds, run_sweep
from train import DEFAULT_CHECKPOINT

# mpc last: the references establish the scale it is then read against.
POLICIES = ["oracle", "random", "zero", "mpc"]


def summarize(rows: list[dict]) -> dict[str, float]:
    """Case-level aggregation.

    Seeds within a case vary only the MPPI candidate draws -- start and goal
    are fixed by HARD_CASES -- so seeds are NOT independent environments.
    Node 8 established case-level as the reporting unit; means are taken
    within case first so a case with a lucky seed cannot outvote a case
    without one.
    """
    by_case: dict[str, list[dict]] = {}
    for r in rows:
        by_case.setdefault(r["case"], []).append(r)
    per_case_reached = [float(np.mean([r["reached"] for r in v])) for v in by_case.values()]
    per_case_progress = [float(np.mean([r["normalized_progress"] for r in v])) for v in by_case.values()]
    per_case_best = [float(np.mean([r["best_distance"] for r in v])) for v in by_case.values()]
    return {
        "reached": float(np.mean(per_case_reached)),
        "normalized_progress": float(np.mean(per_case_progress)),
        "best_distance": float(np.mean(per_case_best)),
        "n_cases": len(by_case),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    ap.add_argument("--seeds", type=str, default=",".join(str(s) for s in DEFAULT_SEEDS))
    ap.add_argument("--max-episode-steps", type=int, default=50)
    ap.add_argument("--goal-tolerance", type=float, default=GOAL_TOLERANCE)
    ap.add_argument("--unbounded", action="store_true")
    args = ap.parse_args()

    seeds = parse_seeds(args.seeds)
    device = resolve_device()
    env = ParticleNavigatorEnv(EnvConfig(bounded=not args.unbounded))
    config = MPCConfig()

    ckpt = torch.load(args.checkpoint, map_location=device)
    model = JEPAModule(JEPAConfig(**ckpt["jepa_config"])).to(device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()

    print(f"checkpoint={args.checkpoint}  objective={ckpt.get('objective', 'vicreg')}  "
          f"arena={'unbounded' if args.unbounded else 'bounded'}")
    print(f"{len(HARD_CASES)} cases x {len(seeds)} seeds, tolerance={args.goal_tolerance}\n")

    results = {}
    for policy in POLICIES:
        rows = run_sweep(
            model, env, config, seeds, args.max_episode_steps,
            args.goal_tolerance, device, policy=policy,
        )
        results[policy] = summarize(rows)

    print(f"{'policy':10s}{'reached':>10s}{'progress':>11s}{'best_dist':>11s}")
    for policy in POLICIES:
        s = results[policy]
        print(f"{policy:10s}{s['reached']:>10.3f}{s['normalized_progress']:>11.3f}{s['best_distance']:>11.4f}")

    # --- validation gates ------------------------------------------------
    # Each asks whether the METRIC can see a difference that is known to be
    # real, not whether any particular policy is good.
    oracle, random_, zero, mpc = (results[p] for p in ("oracle", "random", "zero", "mpc"))
    lower = max(random_["normalized_progress"], zero["normalized_progress"])
    failures = []

    if oracle["reached"] <= max(random_["reached"], zero["reached"]):
        failures.append(
            "binary `reached` does not separate the oracle from random/zero — the task may be "
            "unachievable in max_steps, or the tolerance is too tight to be reachable at all"
        )
    if oracle["normalized_progress"] <= lower:
        failures.append(
            "`normalized_progress` does not separate the oracle from random/zero — the graded "
            "measure is no better than the binary one and must not be adopted"
        )

    print()
    if failures:
        for f in failures:
            print(f"REJECTED: {f}")
        sys.exit(1)

    span = oracle["normalized_progress"] - lower
    position = (mpc["normalized_progress"] - lower) / span if span > 0 else float("nan")
    print(f"measure validated: oracle separates from the lower references on both criteria")
    print(f"  usable span (oracle - best lower reference) = {span:.3f} normalized progress")
    print(f"  mpc sits at {position:.1%} of that span")
    if mpc["reached"] == 0.0:
        print("  NOTE: mpc scores 0 on the binary criterion while the oracle solves every case —")
        print("        that is a planner result, not a task property, and no representation")
        print("        objective can be credited or blamed for it.")


if __name__ == "__main__":
    main()
