"""ParticleNavigatorEnv — synthetic 2D continuous-control environment.

Day 1 of the World Model (JEPA + MPC) research spike (see
`WorldModel/README.md`). Exists to solve the data-starvation problem named
when this spike was scoped: a JEPA needs volume, actions, and temporal
transitions, and real EEG-derived cognitive state currently offers one night
of data and zero logged actions. This environment is cheap to sample from,
has known ground-truth dynamics, and produces genuinely nonlinear
trajectories (via wall collisions) worth predicting — while staying decoupled
from the EEG pipeline entirely, on purpose, until the architecture is proven
here first.

State is [x, y, vx, vy], not just position — velocity carries momentum
across steps, so a one-step-lookahead predictor actually has something
nontrivial to learn (position alone would make next-state prediction close
to a trivial identity map away from walls).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

STATE_DIM = 4  # x, y, vx, vy
ACTION_DIM = 2  # ax, ay


@dataclass(frozen=True)
class EnvConfig:
    arena_half_extent: float = 1.0
    dt: float = 0.1
    max_accel: float = 1.0
    max_speed: float = 2.0
    # Velocity retained (not zeroed) on wall contact, scaled by this factor —
    # keeps collisions informative (nonzero post-bounce velocity) rather than
    # a degenerate "stick to the wall" absorbing state.
    restitution: float = 0.6


class ParticleNavigatorEnv:
    """A point mass in a bounded 2D box, actuated by clipped acceleration."""

    def __init__(self, config: EnvConfig = EnvConfig()):
        self.config = config

    def reset(self, rng: np.random.Generator) -> np.ndarray:
        c = self.config
        pos = rng.uniform(-c.arena_half_extent, c.arena_half_extent, size=2)
        vel = rng.uniform(-0.5, 0.5, size=2) * c.max_speed
        return np.concatenate([pos, vel]).astype(np.float32)

    def step(self, state: np.ndarray, action: np.ndarray) -> np.ndarray:
        c = self.config
        pos = state[:2].copy()
        vel = state[2:].copy()

        accel = np.clip(action, -c.max_accel, c.max_accel)
        vel = vel + accel * c.dt
        speed = float(np.linalg.norm(vel))
        if speed > c.max_speed:
            vel = vel * (c.max_speed / speed)

        new_pos = pos + vel * c.dt
        for dim in range(2):
            if new_pos[dim] > c.arena_half_extent:
                new_pos[dim] = c.arena_half_extent
                vel[dim] = -vel[dim] * c.restitution
            elif new_pos[dim] < -c.arena_half_extent:
                new_pos[dim] = -c.arena_half_extent
                vel[dim] = -vel[dim] * c.restitution

        return np.concatenate([new_pos, vel]).astype(np.float32)
