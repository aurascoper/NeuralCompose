#!/usr/bin/env python3
"""mpc.py — sampling-based latent Model Predictive Control (MPPI-style).

Day 4 of the World Model (JEPA + MPC) research spike (see
`WorldModel/README.md`): freeze the Day 3 checkpoint and use it to steer
`ParticleNavigatorEnv` toward a sampled goal in closed loop.

Why sampling, not gradient descent: backpropagating through the predictor
at every control step to find an optimal action sequence doesn't fit a
tight control loop. Random shooting / MPPI instead samples a large batch
of candidate action sequences, scores all of them in a single batched
forward pass through the frozen predictor, and blends the best ones -- no
backward pass anywhere in this file.

Cost has exactly two terms: distance to a goal latent (summed over the
whole horizon, not just the final step -- a running cost-to-go) and an
action-smoothness penalty. There is deliberately no "utility reward" term
(no analog to rewarding high-bandwidth actions in a physics task) and no
"fatigue barrier" term (no fatigue-latent-cluster analog here) -- this
task doesn't need either.

Which encoder produces which latent is easy to get backwards:
`JEPAModule.forward_online` always feeds the predictor a latent from the
ONLINE `encoder`, never `target_encoder` -- that's what the predictor was
actually trained to consume as input. `target_encoder` only ever appears
as a comparison target (`forward_target`, and `train.py::rollout_check`'s
final-state comparison). So z_start (seeding the imagined rollout) uses
`encoder`; z_goal (the fixed comparison anchor) uses `target_encoder`.
Swapping these would feed the predictor a latent from a geometry it was
never trained to receive as input.

Horizon defaults to 10, well under Day 3's verified ~15-step
trustworthy-rollout finding (see README) -- not budgeted right up to that
edge, since cost sums over every step of the horizon and even nominally
"still informative but degrading" steps 11-15 would otherwise pollute the
signal.

Usage:
  ./WorldModel/mpc.py               # requires a Day 3 checkpoint; run train.py first
  ./WorldModel/mpc.py --horizon 25  # beyond the trustworthy limit -- see what happens
"""
from __future__ import annotations

import argparse
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from dataloader import resolve_device
from env import ACTION_DIM, EnvConfig, ParticleNavigatorEnv, sample_goal
from models import JEPAConfig, JEPAModule
from train import DEFAULT_CHECKPOINT

GOAL_TOLERANCE = 0.1  # matches dataset.py's WAYPOINT_REACHED_DIST


@dataclass(frozen=True)
class MPCConfig:
    horizon: int = 10
    num_candidates: int = 512
    temperature: float = 1.0
    state_cost_weight: float = 1.0
    smoothness_cost_weight: float = 0.1


def sample_candidate_actions(
    rng: np.random.Generator, num_candidates: int, horizon: int, max_accel: float
) -> torch.Tensor:
    """(N, H, ACTION_DIM) i.i.d. uniform actions within the env's own
    actuation bounds -- every sampled action is already valid, no mass
    wasted on values `step()` would clip anyway."""
    actions = rng.uniform(-max_accel, max_accel, size=(num_candidates, horizon, ACTION_DIM))
    return torch.from_numpy(actions.astype(np.float32))


@torch.no_grad()
def score_candidates(
    model: JEPAModule,
    z_start: torch.Tensor,
    z_goal: torch.Tensor,
    candidate_actions: torch.Tensor,
    prev_action: torch.Tensor | None,
    config: MPCConfig,
) -> torch.Tensor:
    """Total cost per candidate sequence, shape (N,): summed per-step
    latent distance to the goal (a running cost-to-go, not just the final
    step) plus an action-smoothness penalty. `prev_action` (the action
    actually executed on the previous real step) is prepended so the
    smoothness term stays continuous across replans; `None` only on an
    episode's very first step, when there's nothing to be continuous
    with yet.
    """
    n = candidate_actions.shape[0]
    z = z_start.unsqueeze(0).expand(n, -1)
    state_cost = torch.zeros(n, device=z.device)
    for t in range(config.horizon):
        z = model.predictor(z, candidate_actions[:, t])
        state_cost = state_cost + (z - z_goal.unsqueeze(0)).norm(dim=-1)

    full = candidate_actions
    if prev_action is not None:
        prev = prev_action.view(1, 1, -1).expand(n, 1, -1)
        full = torch.cat([prev, candidate_actions], dim=1)
    smoothness_cost = (full[:, 1:] - full[:, :-1]).norm(dim=-1).sum(dim=1)

    return config.state_cost_weight * state_cost + config.smoothness_cost_weight * smoothness_cost


@torch.no_grad()
def plan_step(
    model: JEPAModule,
    state: torch.Tensor,
    goal_latent: torch.Tensor,
    prev_action: torch.Tensor | None,
    config: MPCConfig,
    rng: np.random.Generator,
    max_accel: float,
    device: torch.device,
) -> tuple[torch.Tensor, dict]:
    """One MPPI planning step: sample candidates, score them, blend via a
    temperature-scaled softmax (not greedy argmin) -- a convex combination
    of in-bounds action sequences stays in-bounds, no re-clipping needed.
    Returns the first action of the blended sequence (receding horizon)
    plus diagnostics for sanity-checking `temperature` calibration.
    """
    candidate_actions = sample_candidate_actions(
        rng, config.num_candidates, config.horizon, max_accel
    ).to(device)

    z_start = model.encoder(state.unsqueeze(0)).squeeze(0)
    cost = score_candidates(model, z_start, goal_latent, candidate_actions, prev_action, config)
    assert torch.isfinite(cost).all(), "non-finite cost in MPC candidate scoring"

    weights = F.softmax(-(cost - cost.min()) / config.temperature, dim=0)
    blended = (weights.view(-1, 1, 1) * candidate_actions).sum(dim=0)  # (H, ACTION_DIM)
    assert torch.isfinite(blended).all(), "non-finite blended action"

    diagnostics = {
        "cost_min": cost.min().item(),
        "cost_mean": cost.mean().item(),
        "cost_max": cost.max().item(),
        # ESS near 1 -> effectively greedy (temperature too low); ESS near
        # num_candidates -> no discrimination between candidates (too high).
        "effective_sample_size": (1.0 / (weights ** 2).sum()).item(),
    }
    return blended[0], diagnostics


def _sample_random_action(rng: np.random.Generator, max_accel: float) -> np.ndarray:
    return rng.uniform(-max_accel, max_accel, size=ACTION_DIM).astype(np.float32)


def run_episode(
    env: ParticleNavigatorEnv,
    model: JEPAModule | None,
    policy: str,
    start_state: np.ndarray,
    goal: np.ndarray,
    config: MPCConfig,
    max_steps: int,
    goal_tolerance: float,
    device: torch.device,
    rng: np.random.Generator,
    record_history: bool = False,
) -> dict:
    """Run one closed-loop episode under `policy` ("mpc" | "zero" |
    "random"). One shared harness for all three so termination/tolerance/
    step-budget logic is identical across MPC and its baselines -- the
    only thing that differs between calls is how the action is chosen.

    `record_history=False` (the default, used by main()'s 100-episode x
    3-policy evaluation loop) returns exactly the summary dict this
    function has always returned. `record_history=True` additionally
    returns a `"history"` key -- one dict per step with the pre-step
    `state` and the `action` taken (plus `latency`/`diagnostics` for
    `"mpc"` steps) -- for callers (e.g. telemetry.py) that need per-step
    detail rather than just the summary. The terminal state isn't stored
    per entry; a caller can reconstruct it exactly by replaying
    `env.step` over the recorded actions, since `step` is stateless.
    """
    assert policy in ("mpc", "zero", "random")

    state = start_state.copy()
    goal_latent = None
    if policy == "mpc":
        assert model is not None
        goal_state = torch.from_numpy(goal).unsqueeze(0).to(device)
        goal_latent = model.forward_target(goal_state).squeeze(0)

    prev_action = None
    latencies: list[float] = []
    diagnostics: list[dict] = []
    history: list[dict] | None = [] if record_history else None
    reached = False
    steps_used = 0

    for step in range(max_steps):
        if float(np.linalg.norm(state[:2] - goal[:2])) < goal_tolerance:
            reached = True
            break
        steps_used = step + 1

        if policy == "mpc":
            state_t = torch.from_numpy(state).to(device)
            t0 = time.perf_counter()
            action_t, diag = plan_step(
                model, state_t, goal_latent, prev_action, config, rng, env.config.max_accel, device
            )
            latencies.append(time.perf_counter() - t0)
            diagnostics.append(diag)
            prev_action = action_t
            action = action_t.cpu().numpy()
        elif policy == "zero":
            action = np.zeros(ACTION_DIM, dtype=np.float32)
        else:  # "random"
            action = _sample_random_action(rng, env.config.max_accel)

        if record_history:
            entry = {"state": state.copy(), "action": action.copy()}
            if policy == "mpc":
                entry["latency"] = latencies[-1]
                entry["diagnostics"] = diag
            history.append(entry)

        state = env.step(state, action)

    if not reached and float(np.linalg.norm(state[:2] - goal[:2])) < goal_tolerance:
        reached = True

    result = {
        "reached": reached,
        "steps_used": steps_used,
        "final_distance": float(np.linalg.norm(state[:2] - goal[:2])),
        "latencies": latencies,
        "diagnostics": diagnostics,
    }
    if record_history:
        result["history"] = history
    return result


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)

    ap.add_argument("--horizon", type=int, default=MPCConfig().horizon)
    ap.add_argument("--num-candidates", type=int, default=MPCConfig().num_candidates)
    ap.add_argument("--temperature", type=float, default=MPCConfig().temperature)
    ap.add_argument("--state-cost-weight", type=float, default=MPCConfig().state_cost_weight)
    ap.add_argument("--smoothness-cost-weight", type=float, default=MPCConfig().smoothness_cost_weight)

    ap.add_argument("--episodes", type=int, default=50)
    ap.add_argument("--max-episode-steps", type=int, default=50)
    ap.add_argument("--goal-tolerance", type=float, default=GOAL_TOLERANCE)
    ap.add_argument("--min-goal-distance", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

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

    print(f"mpc.py: device={device} checkpoint={args.checkpoint}")
    print(f"  config: {config}")
    print(
        f"  episodes={args.episodes} max_episode_steps={args.max_episode_steps} "
        f"goal_tolerance={args.goal_tolerance} min_goal_distance={args.min_goal_distance}"
    )

    # Fixed (start, goal) pairs, sampled once, shared across all three
    # policies -- not just the same seed, literally the same arrays -- so
    # baseline comparisons are apples-to-apples.
    episodes = []
    for _ in range(args.episodes):
        start = env.reset(rng)
        goal = sample_goal(rng, env.config)
        while float(np.linalg.norm(start[:2] - goal[:2])) < args.min_goal_distance:
            goal = sample_goal(rng, env.config)
        episodes.append((start, goal))

    results: dict[str, list[dict]] = {}
    for policy in ("mpc", "zero", "random"):
        episode_results = [
            run_episode(
                env,
                model if policy == "mpc" else None,
                policy,
                start,
                goal,
                config,
                args.max_episode_steps,
                args.goal_tolerance,
                device,
                rng,
            )
            for start, goal in episodes
        ]
        results[policy] = episode_results

        success_rate = sum(r["reached"] for r in episode_results) / len(episode_results)
        distances = [r["final_distance"] for r in episode_results]
        print(
            f"policy={policy:6s}  success_rate={success_rate:.2f}  "
            f"mean_final_distance={float(np.mean(distances)):.4f}  "
            f"median_final_distance={float(np.median(distances)):.4f}"
        )

        if policy == "mpc":
            all_latencies = [lat for r in episode_results for lat in r["latencies"]]
            if all_latencies:
                ms = np.array(all_latencies) * 1000.0
                print(
                    f"  planning latency (ms): mean={ms.mean():.2f} "
                    f"median={np.median(ms):.2f} p95={np.percentile(ms, 95):.2f}"
                )

            all_diag = [d for r in episode_results for d in r["diagnostics"]]
            if all_diag:
                ess = np.array([d["effective_sample_size"] for d in all_diag])
                cost_min = np.array([d["cost_min"] for d in all_diag])
                cost_mean = np.array([d["cost_mean"] for d in all_diag])
                print(
                    f"  MPPI diagnostics: cost_min~{cost_min.mean():.3f} "
                    f"cost_mean~{cost_mean.mean():.3f} "
                    f"effective_sample_size mean={ess.mean():.1f}/{config.num_candidates}"
                )

    mpc_success = sum(r["reached"] for r in results["mpc"]) / len(results["mpc"])
    zero_success = sum(r["reached"] for r in results["zero"]) / len(results["zero"])
    random_success = sum(r["reached"] for r in results["random"]) / len(results["random"])
    if not (mpc_success > zero_success and mpc_success > random_success):
        print(
            "  WARNING: MPC did not clearly beat both baselines "
            f"(mpc={mpc_success:.2f} zero={zero_success:.2f} random={random_success:.2f})"
        )


if __name__ == "__main__":
    main()
