#!/usr/bin/env python3
"""dataset.py — generate synthetic ParticleNavigator trajectories.

Day 1 deliverable #2 of the World Model spike (see `WorldModel/README.md`):
"a script to generate thousands of random-walk and heuristic-driven
trajectories, saving them as (state, action, next_state) tuples."

Each trajectory is independently seeded off one `np.random.Generator` for
full-run reproducibility (matching this repo's existing deterministic-
synthetic convention, e.g. `SyntheticEEGStream`). Two action policies:

- "random": i.i.d. uniform acceleration each step. Cheap coverage, but pure
  noise tends to drive the particle into a wall and hug it (an unbounded
  random walk in a bounded box spends disproportionate time at the
  boundary), so it alone would under-represent open-arena dynamics.
- "heuristic": a simple PD controller steering toward a waypoint that gets
  resampled periodically (or on arrival). Produces smoother, more varied
  coverage of the interior.

Each generated trajectory independently rolls a coin (`--policy-mix`) to use
one policy or the other, so the saved dataset is a blend of both — matching
what was actually asked for, not one or the other.

Usage:
  ./WorldModel/dataset.py
  ./WorldModel/dataset.py --n-trajectories 200 --horizon 50   # quick smoke test
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from env import ACTION_DIM, STATE_DIM, EnvConfig, ParticleNavigatorEnv

WAYPOINT_RESAMPLE_STEPS = 20
WAYPOINT_REACHED_DIST = 0.1
WAYPOINT_KP = 3.0
WAYPOINT_KD = 1.0


def _random_action(rng: np.random.Generator, env: ParticleNavigatorEnv) -> np.ndarray:
    c = env.config
    return rng.uniform(-c.max_accel, c.max_accel, size=ACTION_DIM).astype(np.float32)


def _heuristic_action(env: ParticleNavigatorEnv, state: np.ndarray, waypoint: np.ndarray) -> np.ndarray:
    pos, vel = state[:2], state[2:]
    accel = WAYPOINT_KP * (waypoint - pos) - WAYPOINT_KD * vel
    return np.clip(accel, -env.config.max_accel, env.config.max_accel).astype(np.float32)


def rollout(
    env: ParticleNavigatorEnv,
    rng: np.random.Generator,
    horizon: int,
    use_heuristic: bool,
) -> tuple[np.ndarray, np.ndarray]:
    """One trajectory: horizon+1 states, horizon actions."""
    states = np.zeros((horizon + 1, STATE_DIM), dtype=np.float32)
    actions = np.zeros((horizon, ACTION_DIM), dtype=np.float32)

    state = env.reset(rng)
    states[0] = state
    waypoint = rng.uniform(-env.config.arena_half_extent, env.config.arena_half_extent, size=2)

    for t in range(horizon):
        if use_heuristic:
            reached = np.linalg.norm(state[:2] - waypoint) < WAYPOINT_REACHED_DIST
            if t % WAYPOINT_RESAMPLE_STEPS == 0 or reached:
                waypoint = rng.uniform(-env.config.arena_half_extent, env.config.arena_half_extent, size=2)
            action = _heuristic_action(env, state, waypoint)
        else:
            action = _random_action(rng, env)

        state = env.step(state, action)
        states[t + 1] = state
        actions[t] = action

    return states, actions


def generate_trajectories(
    env: ParticleNavigatorEnv,
    n_trajectories: int,
    horizon: int,
    seed: int,
    policy_mix: float = 0.5,
) -> tuple[np.ndarray, np.ndarray, int]:
    """Returns (states [N, horizon+1, 4], actions [N, horizon, 2], n_heuristic)."""
    rng = np.random.default_rng(seed)
    all_states = np.zeros((n_trajectories, horizon + 1, STATE_DIM), dtype=np.float32)
    all_actions = np.zeros((n_trajectories, horizon, ACTION_DIM), dtype=np.float32)

    n_heuristic = 0
    for i in range(n_trajectories):
        use_heuristic = bool(rng.random() < policy_mix)
        n_heuristic += int(use_heuristic)
        states, actions = rollout(env, rng, horizon, use_heuristic)
        all_states[i] = states
        all_actions[i] = actions

    return all_states, all_actions, n_heuristic


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n-trajectories", type=int, default=2000)
    ap.add_argument("--horizon", type=int, default=50)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--policy-mix", type=float, default=0.5,
                     help="fraction of trajectories using the heuristic waypoint-seeking policy")
    ap.add_argument("--val-fraction", type=float, default=0.2)
    ap.add_argument("--out-dir", type=Path, default=Path(__file__).resolve().parent / "data")
    args = ap.parse_args()

    env = ParticleNavigatorEnv(EnvConfig())
    states, actions, n_heuristic = generate_trajectories(
        env, args.n_trajectories, args.horizon, args.seed, args.policy_mix
    )

    n_val = max(1, int(args.n_trajectories * args.val_fraction))
    n_train = args.n_trajectories - n_val
    args.out_dir.mkdir(parents=True, exist_ok=True)

    np.savez(args.out_dir / "train.npz", states=states[:n_train], actions=actions[:n_train])
    np.savez(args.out_dir / "val.npz", states=states[n_train:], actions=actions[n_train:])

    print(f"generated {args.n_trajectories} trajectories "
          f"({n_heuristic} heuristic / {args.n_trajectories - n_heuristic} random, horizon={args.horizon})")
    print(f"  train: {n_train} trajectories -> {args.out_dir / 'train.npz'}")
    print(f"  val:   {n_val} trajectories -> {args.out_dir / 'val.npz'}")
    print(f"  states shape: [N, {args.horizon + 1}, {STATE_DIM}]  actions shape: [N, {args.horizon}, {ACTION_DIM}]")


if __name__ == "__main__":
    main()
