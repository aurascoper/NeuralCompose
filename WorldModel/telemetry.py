#!/usr/bin/env python3
"""telemetry.py — single-episode visualization companion to mpc.py.

Day 4 of the World Model (JEPA + MPC) research spike (see
`WorldModel/README.md`): `mpc.py`'s own evaluation harness only prints
aggregate statistics across 100 episodes. This script runs ONE `"mpc"`
episode with full per-step history recorded and renders a 3-panel figure:
the real spatial trajectory (actual goal position and tolerance radius,
never a fabricated "flow zone"), MPPI diagnostics over time (effective
sample size and mean cost -- real quantities `plan_step` already
computes), and per-step planning latency (measured, not budgeted against
any target -- no "50ms" reference line; that number belongs to a
different, not-yet-real system).

Usage:
  ./WorldModel/telemetry.py
  ./WorldModel/telemetry.py --seed 7 --horizon 5 --output WorldModel/telemetry_h5.png
  ./WorldModel/telemetry.py --start-x 0.8 --start-y 0.8 --goal-x -0.8 --goal-y -0.8
"""
from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch

from dataloader import resolve_device
from env import EnvConfig, ParticleNavigatorEnv, sample_goal
from mpc import GOAL_TOLERANCE, MPCConfig, run_episode
from models import JEPAConfig, JEPAModule
from train import DEFAULT_CHECKPOINT

DEFAULT_OUTPUT = Path(__file__).resolve().parent / "telemetry_run.png"


def reconstruct_trajectory(env: ParticleNavigatorEnv, start: np.ndarray, history: list[dict]):
    """Replay `env.step` over the recorded actions to get the exact
    (x, y) path, including the terminal point history's pre-step states
    don't cover -- exact and deterministic since `step` is stateless."""
    xs = [float(start[0])]
    ys = [float(start[1])]
    state = start
    for entry in history:
        state = env.step(state, entry["action"])
        xs.append(float(state[0]))
        ys.append(float(state[1]))
    return xs, ys


def plot_telemetry(
    env: ParticleNavigatorEnv,
    start: np.ndarray,
    goal: np.ndarray,
    goal_tolerance: float,
    result: dict,
    num_candidates: int,
    output: Path,
) -> None:
    history = result["history"]
    fig, axes = plt.subplots(1, 3, figsize=(16, 5))

    # --- Panel 1: spatial trajectory ---
    ax = axes[0]
    xs, ys = reconstruct_trajectory(env, start, history)
    ax.plot(xs, ys, "-o", markersize=3, linewidth=1, alpha=0.7, color="steelblue")
    ax.scatter([xs[0]], [ys[0]], color="green", s=100, zorder=5, label="start")
    ax.scatter([xs[-1]], [ys[-1]], color="red", s=100, zorder=5, label="end")
    ax.scatter([goal[0]], [goal[1]], color="black", marker="*", s=150, zorder=5, label="goal")
    ax.add_patch(plt.Circle((goal[0], goal[1]), goal_tolerance, fill=False, linestyle="--", color="black"))
    half = env.config.arena_half_extent
    ax.add_patch(plt.Rectangle((-half, -half), 2 * half, 2 * half, fill=False, linestyle=":", color="gray"))
    ax.set_xlim(-half * 1.2, half * 1.2)
    ax.set_ylim(-half * 1.2, half * 1.2)
    ax.set_aspect("equal")
    ax.set_xlabel("x")
    ax.set_ylabel("y")
    ax.set_title(f"trajectory (reached={result['reached']}, steps={result['steps_used']})")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(True, alpha=0.2)

    # --- Panel 2: MPPI diagnostics over time ---
    ax = axes[1]
    if history:
        steps = list(range(1, len(history) + 1))
        ess = [h["diagnostics"]["effective_sample_size"] for h in history]
        cost_mean = [h["diagnostics"]["cost_mean"] for h in history]
        ax.plot(steps, ess, color="purple", label="effective sample size")
        ax.set_ylim(0, num_candidates)
        ax.set_xlabel("step")
        ax.set_ylabel("effective sample size", color="purple")
        ax.tick_params(axis="y", labelcolor="purple")
        ax2 = ax.twinx()
        ax2.plot(steps, cost_mean, color="darkorange", linestyle="--", label="cost mean")
        ax2.set_ylabel("cost mean", color="darkorange")
        ax2.tick_params(axis="y", labelcolor="darkorange")
        ax.set_title("MPPI diagnostics")
    else:
        ax.text(0.5, 0.5, "no planning steps recorded", ha="center", va="center", transform=ax.transAxes)
        ax.set_title("MPPI diagnostics")
    ax.grid(True, alpha=0.2)

    # --- Panel 3: planning latency over time ---
    ax = axes[2]
    if history:
        steps = list(range(1, len(history) + 1))
        latency_ms = [h["latency"] * 1000.0 for h in history]
        ax.plot(steps, latency_ms, color="teal")
        arr = np.array(latency_ms)
        ax.set_title(
            f"planning latency (mean={arr.mean():.2f}ms median={np.median(arr):.2f}ms "
            f"p95={np.percentile(arr, 95):.2f}ms)"
        )
        ax.set_xlabel("step")
        ax.set_ylabel("latency (ms)")
    else:
        ax.text(0.5, 0.5, "no planning steps recorded", ha="center", va="center", transform=ax.transAxes)
        ax.set_title("planning latency")
    ax.grid(True, alpha=0.2)

    plt.tight_layout()
    fig.savefig(output, dpi=150)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    ap.add_argument("--seed", type=int, default=0)

    ap.add_argument("--horizon", type=int, default=MPCConfig().horizon)
    ap.add_argument("--num-candidates", type=int, default=MPCConfig().num_candidates)
    ap.add_argument("--temperature", type=float, default=MPCConfig().temperature)
    ap.add_argument("--state-cost-weight", type=float, default=MPCConfig().state_cost_weight)
    ap.add_argument("--smoothness-cost-weight", type=float, default=MPCConfig().smoothness_cost_weight)

    ap.add_argument("--max-episode-steps", type=int, default=50)
    ap.add_argument("--goal-tolerance", type=float, default=GOAL_TOLERANCE)
    ap.add_argument("--min-goal-distance", type=float, default=0.5)

    ap.add_argument("--start-x", type=float, default=None)
    ap.add_argument("--start-y", type=float, default=None)
    ap.add_argument("--goal-x", type=float, default=None)
    ap.add_argument("--goal-y", type=float, default=None)

    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = ap.parse_args()

    if (args.start_x is None) != (args.start_y is None):
        raise SystemExit("--start-x and --start-y must be given together")
    if (args.goal_x is None) != (args.goal_y is None):
        raise SystemExit("--goal-x and --goal-y must be given together")

    if not args.checkpoint.exists():
        raise SystemExit(f"{args.checkpoint} not found — run ./WorldModel/train.py first")

    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)

    config = MPCConfig(
        horizon=args.horizon,
        num_candidates=args.num_candidates,
        temperature=args.temperature,
        state_cost_weight=args.state_cost_weight,
        smoothness_cost_weight=args.smoothness_cost_weight,
    )
    device = resolve_device()

    ckpt = torch.load(args.checkpoint, map_location=device)
    model = JEPAModule(JEPAConfig(**ckpt["jepa_config"])).to(device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)

    env = ParticleNavigatorEnv(EnvConfig())

    start = (
        np.array([args.start_x, args.start_y, 0.0, 0.0], dtype=np.float32)
        if args.start_x is not None
        else env.reset(rng)
    )

    if args.goal_x is not None:
        goal = np.array([args.goal_x, args.goal_y, 0.0, 0.0], dtype=np.float32)
        if float(np.linalg.norm(start[:2] - goal[:2])) < args.min_goal_distance:
            print(f"  WARNING: explicit goal is closer than --min-goal-distance={args.min_goal_distance}")
    else:
        goal = sample_goal(rng, env.config)
        while float(np.linalg.norm(start[:2] - goal[:2])) < args.min_goal_distance:
            goal = sample_goal(rng, env.config)

    print(f"telemetry.py: device={device} checkpoint={args.checkpoint}")
    print(f"  start=({start[0]:.3f},{start[1]:.3f}) goal=({goal[0]:.3f},{goal[1]:.3f}) seed={args.seed}")

    result = run_episode(
        env, model, "mpc", start, goal, config,
        args.max_episode_steps, args.goal_tolerance, device, rng,
        record_history=True,
    )

    print(
        f"  reached={result['reached']} steps_used={result['steps_used']} "
        f"final_distance={result['final_distance']:.4f}"
    )
    if result["latencies"]:
        ms = np.array(result["latencies"]) * 1000.0
        print(
            f"  planning latency (ms): mean={ms.mean():.2f} "
            f"median={np.median(ms):.2f} p95={np.percentile(ms, 95):.2f}"
        )

    plot_telemetry(env, start, goal, args.goal_tolerance, result, config.num_candidates, args.output)
    print(f"  wrote {args.output}")


if __name__ == "__main__":
    main()
