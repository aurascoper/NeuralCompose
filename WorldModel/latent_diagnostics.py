#!/usr/bin/env python3
"""latent_diagnostics.py — directional latent-distance-vs-position-distance
checks, on demand.

The "r≈0.63" latent-to-position correlation diagnostic (WorldModel/README.md,
Day 4) was, per the README's own account, never committed to the repo either
-- this is that measurement, made reusable, plus a `--along-line` mode
specifically for checking whether the JEPA latent space treats a hard,
persistently-failing diagonal any differently than a working one.

Usage:
  ./WorldModel/latent_diagnostics.py --along-line --start-x 0.8 --start-y -0.8 --goal-x -0.8 --goal-y 0.8
  ./WorldModel/latent_diagnostics.py --along-line --start-x 0.8 --start-y 0.8 --goal-x -0.8 --goal-y -0.8
  ./WorldModel/latent_diagnostics.py  # aggregate r, 500 random states vs one fixed goal
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

from dataloader import resolve_device
from env import EnvConfig, sample_goal
from models import JEPAConfig, JEPAModule
from train import DEFAULT_CHECKPOINT


def load_model(checkpoint: Path, device: torch.device) -> JEPAModule:
    ckpt = torch.load(checkpoint, map_location=device)
    model = JEPAModule(JEPAConfig(**ckpt["jepa_config"])).to(device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)
    return model


@torch.no_grad()
def along_line(model: JEPAModule, start_xy, goal_xy, device, n_points=21) -> None:
    goal_state = torch.tensor([*goal_xy, 0.0, 0.0], dtype=torch.float32, device=device)
    goal_latent = model.forward_target(goal_state.unsqueeze(0)).squeeze(0)

    ts = np.linspace(0.0, 1.0, n_points)
    pos_dists = []
    lat_dists = []
    for t in ts:
        x = start_xy[0] + t * (goal_xy[0] - start_xy[0])
        y = start_xy[1] + t * (goal_xy[1] - start_xy[1])
        state = torch.tensor([x, y, 0.0, 0.0], dtype=torch.float32, device=device)
        z = model.encoder(state.unsqueeze(0)).squeeze(0)
        pos_dists.append(float(np.hypot(x - goal_xy[0], y - goal_xy[1])))
        lat_dists.append(float((z - goal_latent).norm().item()))

    pos_dists = np.array(pos_dists)
    lat_dists = np.array(lat_dists)
    # Position distance decreases monotonically by construction (it's a
    # straight line to the goal) -- the question is whether latent distance
    # tracks it monotonically too, or has bumps/plateaus a planner would
    # perceive as "no progress available" partway along the line.
    diffs = np.diff(lat_dists)
    n_non_monotonic = int(np.sum(diffs > 0))
    r = float(np.corrcoef(pos_dists, lat_dists)[0, 1])
    print(f"  line ({start_xy}) -> ({goal_xy}):")
    print(f"    latent-vs-position correlation r={r:.3f}")
    print(f"    latent distance non-monotonic steps: {n_non_monotonic}/{len(diffs)} (0 = perfectly monotonic)")
    print(f"    latent distance at t=0/0.5/1.0: {lat_dists[0]:.3f} / {lat_dists[n_points // 2]:.3f} / {lat_dists[-1]:.3f}")


@torch.no_grad()
def aggregate_correlation(model: JEPAModule, device, n_samples=500, seed=0) -> None:
    rng = np.random.default_rng(seed)
    cfg = EnvConfig()
    goal = sample_goal(rng, cfg)
    goal_t = torch.from_numpy(goal).to(device)
    goal_latent_online = model.encoder(goal_t.unsqueeze(0)).squeeze(0)
    goal_latent_target = model.forward_target(goal_t.unsqueeze(0)).squeeze(0)

    states = rng.uniform(-cfg.arena_half_extent, cfg.arena_half_extent, size=(n_samples, 2))
    vel = rng.uniform(-cfg.max_speed, cfg.max_speed, size=(n_samples, 2))
    full_states = np.concatenate([states, vel], axis=1).astype(np.float32)
    states_t = torch.from_numpy(full_states).to(device)

    z_online = model.encoder(states_t)
    z_target = model.target_encoder(states_t)

    pos_dist = np.linalg.norm(states - goal[:2], axis=1)
    lat_dist_online = (z_online - goal_latent_online.unsqueeze(0)).norm(dim=-1).cpu().numpy()
    lat_dist_target = (z_target - goal_latent_target.unsqueeze(0)).norm(dim=-1).cpu().numpy()

    r_online = float(np.corrcoef(pos_dist, lat_dist_online)[0, 1])
    r_target = float(np.corrcoef(pos_dist, lat_dist_target)[0, 1])
    print(f"  aggregate ({n_samples} random states, one fixed goal): r_online={r_online:.3f} r_target={r_target:.3f}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    ap.add_argument("--along-line", action="store_true")
    ap.add_argument("--start-x", type=float, default=0.8)
    ap.add_argument("--start-y", type=float, default=-0.8)
    ap.add_argument("--goal-x", type=float, default=-0.8)
    ap.add_argument("--goal-y", type=float, default=0.8)
    ap.add_argument("--n-points", type=int, default=21)
    args = ap.parse_args()

    if not args.checkpoint.exists():
        raise SystemExit(f"{args.checkpoint} not found — run ./WorldModel/train.py first")

    device = resolve_device()
    model = load_model(args.checkpoint, device)

    print(f"latent_diagnostics.py: device={device} checkpoint={args.checkpoint}")
    if args.along_line:
        along_line(model, (args.start_x, args.start_y), (args.goal_x, args.goal_y), device, args.n_points)
    else:
        aggregate_correlation(model, device)


if __name__ == "__main__":
    main()
