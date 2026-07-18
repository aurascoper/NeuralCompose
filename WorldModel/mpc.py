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

Cost has three terms: distance to a goal latent summed over the whole
horizon (a running cost-to-go), a squared terminal-state distance (see
below), and an action-smoothness penalty. There is deliberately no
"utility reward" term (no analog to rewarding high-bandwidth actions in a
physics task) and no "fatigue barrier" term (no fatigue-latent-cluster
analog here) -- this task doesn't need either.

Receding-horizon myopia and its fix: with a goal farther away than
`horizon` steps can close, every candidate's horizon-summed running cost
looks similarly "can't get there" -- so the (deliberately small)
smoothness penalty starts controlling the softmax ranking instead of
goal-directedness, and the planner settles into doing very little. The
terminal-state term (`terminal_cost_weight`, squared distance at step H
only, not summed) restores discrimination by isolating the one point in
the sequence candidates have actually had a chance to diverge by, rather
than diluting that signal across the near-invariant early steps. Squared
only for this single-point term, not the running term -- squaring a
signal summed over every step would quadratically amplify noise in the
already-only-moderately-reliable (`r≈0.63`, see README) latent-distance
proxy at every one of those steps.

Stall detection uses real position-space state (velocity, distance to
goal from `env.py`'s own `[x,y,vx,vy]`), not a latent-space threshold --
`r≈0.63` isn't reliable enough to calibrate a fresh magic number in an
opaque 32-dim space when real, already-interpretable quantities are
sitting right there. When stalled, a minority of the candidate batch
(`stall_widen_fraction`) can be sampled at a wider action range
(`stall_variance_multiplier`); the rest stays at the normal range. Full
widening of the whole batch was deliberately avoided -- the frozen
predictor's behavior outside its presumably-training-range actions is
unmeasured, unlike the well-measured ~15-step horizon boundary, so hedging
keeps most of the batch trustworthy while still letting the existing cost
function's honest signal (not a new reward term) decide whether the wider
candidates pay off. `stall_detected`/`stall_variance_multiplier` are still
wired through and reported in diagnostics for visibility either way, but
`stall_variance_multiplier` defaults to 1.0 (a no-op) -- an ablation found
the terminal-cost term alone drives essentially all of the measured
improvement, and widening added no aggregate benefit while actively
hurting the hardest tested case when combined with it (see README). Left
configurable for future tuning, not deleted, but not proven enough to
default on.

Effective-sample-size collapse and the adaptive-temperature fix: the MPPI
softmax (`plan_step`) weights candidates by `-(cost - cost.min()) /
temperature`. What actually controls how peaky that softmax gets is the
SPREAD of `cost - cost.min()` relative to `temperature`, not cost's
absolute size. Two independent, already-measured changes inflate that
spread while `temperature` stayed fixed at `1.0`: raising `horizon` alone
(effective sample size 157/512 -> 6/512 at horizon 25, since the running
cost is summed per step) and adding `terminal_cost_weight` on top of the
existing horizon-10 running cost (157/512 -> ~13/512) -- both are the same
underlying "cost scale outpaces fixed temperature" problem, not two bugs
(see README, "Fixing the receding-horizon stall"). `adaptive_temperature`
rescales the softmax by the candidate batch's own cost spread every
planning step (`temperature_effective = temperature * cost.std()`), so a
fixed dimensionless `temperature` keeps producing a comparable effective
sample size regardless of how `terminal_cost_weight`/`horizon` move the
raw cost scale -- standard MPPI practice (cost-scale-normalized softmax),
not new to this codebase. `min_cost_scale` floors the scale statistic so a
near-degenerate batch (`cost.std() ~ 0`, every candidate scores almost
identically) can't blow `temperature_effective` toward zero and collapse
effective sample size from the OPPOSITE direction (a vanishing
denominator, not an inflated cost scale). This is a calibration-layer fix
inside `plan_step` only -- it does not change any value `score_candidates`
returns, so it doesn't touch why the terminal term is squared-once vs. the
running term summed, or the stall-widening default, discussed above.
`normalize_running_cost_by_horizon` is a separate, off-by-default lever
that instead rescales `score_candidates`' running cost itself (dividing by
`horizon` so `state_cost_weight`'s meaning stays comparable across horizon
values); left configurable rather than defaulted on since it hasn't been
validated together with the existing `state_cost_weight=1.0` /
`terminal_cost_weight=2.0` tuning -- `adaptive_temperature` alone is the
required fix, this is an optional secondary one.

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
    # Under adaptive_temperature=True (default), this is a dimensionless
    # multiplier of the candidate batch's own cost.std(), not an absolute
    # cost-scale value -- 0.45 was found empirically (see README, "Temperature/
    # cost-scale calibration"): at horizon=10 with terminal_cost_weight=0 it
    # reproduces the original pre-terminal-cost effective-sample-size
    # reference (~157/512); with terminal_cost_weight=2.0 re-enabled at this
    # same value, effective sample size stays in the 150-200+/512 range
    # (no collapse) across horizons 5/10/25, at the cost of a measurably
    # smaller (not larger) hard-case success/distance improvement than the
    # collapsed-ESS configuration showed on this specific small (n=35) hard
    # case sample -- see README for the full, honestly-reported trade-off.
    temperature: float = 0.45
    state_cost_weight: float = 1.0
    smoothness_cost_weight: float = 0.1
    # Terminal-state term and stall-triggered widening -- see module
    # docstring for why each exists. terminal_cost_weight/
    # stall_variance_multiplier/stall_widen_fraction have no existing
    # codebase quantity to anchor to (unlike the two thresholds below) --
    # first-pass values, not pre-calibrated.
    terminal_cost_weight: float = 2.0
    stall_velocity_threshold: float = 0.1  # 5% of EnvConfig.max_speed=2.0
    stall_distance_threshold: float = 0.5  # matches the --min-goal-distance default
    # 1.0 is a deliberate no-op default (still detects/reports stall_detected
    # for visibility, just doesn't widen the sampling range) -- an ablation
    # this session found stall-widening adds no measurable aggregate benefit
    # and can actively hurt when combined with the terminal cost term on hard
    # cases (see README). terminal_cost_weight alone is the evidenced win;
    # widening is left wired up and CLI-configurable for future tuning, not
    # deleted, but shouldn't be on by default until it's actually proven.
    stall_variance_multiplier: float = 1.0
    stall_widen_fraction: float = 0.25
    # Scale-adaptive softmax temperature -- see module docstring
    # "Effective-sample-size collapse and the adaptive-temperature fix" for
    # why this is the required fix for the terminal-cost-added/horizon-25
    # effective-sample-size collapses. Default True; new `temperature`
    # default under this scheme must be found empirically (see
    # WorldModel/sweep.py and README), not guessed -- this is a genuine
    # rescaling of what `temperature` means, not a no-op toggle.
    adaptive_temperature: bool = True
    min_cost_scale: float = 1e-3
    # Optional, off by default -- see module docstring. Not validated
    # together with state_cost_weight/terminal_cost_weight yet.
    normalize_running_cost_by_horizon: bool = False


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
) -> tuple[torch.Tensor, dict]:
    """Total cost per candidate sequence, shape (N,), plus a component
    breakdown: summed per-step latent distance to the goal (a running
    cost-to-go, not just the final step), a squared terminal-state
    distance (see module docstring for why only this term is squared),
    and an action-smoothness penalty. `prev_action` (the action actually
    executed on the previous real step) is prepended so the smoothness
    term stays continuous across replans; `None` only on an episode's
    very first step, when there's nothing to be continuous with yet.
    """
    n = candidate_actions.shape[0]
    z = z_start.unsqueeze(0).expand(n, -1)
    state_cost = torch.zeros(n, device=z.device)
    for t in range(config.horizon):
        z = model.predictor(z, candidate_actions[:, t])
        state_cost = state_cost + (z - z_goal.unsqueeze(0)).norm(dim=-1)

    # z is now the t=horizon state -- already computed by the loop above,
    # captured here (not recomputed) for a second, separately-weighted,
    # squared appearance. Intentional double appearance, not a bug: the
    # running term is a cost-to-go over the whole horizon; this term
    # specifically sharpens discrimination at the one point candidates
    # have actually had a chance to diverge by (see module docstring).
    terminal_cost = (z - z_goal.unsqueeze(0)).norm(dim=-1) ** 2

    full = candidate_actions
    if prev_action is not None:
        prev = prev_action.view(1, 1, -1).expand(n, 1, -1)
        full = torch.cat([prev, candidate_actions], dim=1)
    smoothness_cost = (full[:, 1:] - full[:, :-1]).norm(dim=-1).sum(dim=1)

    if config.normalize_running_cost_by_horizon:
        state_cost = state_cost / config.horizon
    weighted_state = config.state_cost_weight * state_cost
    weighted_smoothness = config.smoothness_cost_weight * smoothness_cost
    weighted_terminal = config.terminal_cost_weight * terminal_cost

    total = weighted_state + weighted_smoothness + weighted_terminal
    components = {
        "state_cost_mean": weighted_state.mean().item(),
        "smoothness_cost_mean": weighted_smoothness.mean().item(),
        "terminal_cost_mean": weighted_terminal.mean().item(),
    }
    return total, components


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
    velocity: float,
    distance_to_goal: float,
) -> tuple[torch.Tensor, dict]:
    """One MPPI planning step: sample candidates, score them, blend via a
    temperature-scaled softmax (not greedy argmin). Returns the first
    action of the blended sequence (receding horizon) plus diagnostics for
    sanity-checking `temperature` calibration and stall detection.

    `velocity`/`distance_to_goal` are real position-space quantities (see
    module docstring) used to detect a receding-horizon stall: low
    velocity while still far from goal. When stalled, a minority
    (`stall_widen_fraction`) of the candidate batch is sampled at a wider
    action range (`stall_variance_multiplier`) instead of uniformly
    widening the whole batch -- see module docstring for why. Note this
    means the "convex combination of in-bounds sequences stays in-bounds"
    property no longer strictly holds during a stalled step (the blended
    action can exceed `max_accel` if softmax weight concentrates on wide
    candidates) -- harmless since `env.step` already clips before
    executing, but worth knowing rather than assuming re-clipping is
    always unnecessary.
    """
    stalled = velocity < config.stall_velocity_threshold and distance_to_goal > config.stall_distance_threshold
    if stalled:
        # stall_widen_fraction has no range validation at the CLI/dataclass
        # level (a value outside [0, 1] is a real, reachable misconfiguration
        # via --stall-widen-fraction) -- clamp defensively here so num_normal
        # can never go negative and crash sample_candidate_actions with
        # "negative dimensions are not allowed".
        num_wide = min(max(int(round(config.num_candidates * config.stall_widen_fraction)), 0), config.num_candidates)
        num_normal = config.num_candidates - num_wide
        normal_candidates = sample_candidate_actions(rng, num_normal, config.horizon, max_accel)
        wide_candidates = sample_candidate_actions(
            rng, num_wide, config.horizon, max_accel * config.stall_variance_multiplier
        )
        candidate_actions = torch.cat([normal_candidates, wide_candidates], dim=0).to(device)
    else:
        candidate_actions = sample_candidate_actions(
            rng, config.num_candidates, config.horizon, max_accel
        ).to(device)

    z_start = model.encoder(state.unsqueeze(0)).squeeze(0)
    cost, cost_components = score_candidates(
        model, z_start, goal_latent, candidate_actions, prev_action, config
    )
    assert torch.isfinite(cost).all(), "non-finite cost in MPC candidate scoring"

    if config.adaptive_temperature:
        cost_scale = cost.std(unbiased=False).clamp_min(config.min_cost_scale)
    else:
        cost_scale = torch.ones((), device=cost.device)
    temperature_effective = config.temperature * cost_scale
    weights = F.softmax(-(cost - cost.min()) / temperature_effective, dim=0)
    blended = (weights.view(-1, 1, 1) * candidate_actions).sum(dim=0)  # (H, ACTION_DIM)
    assert torch.isfinite(blended).all(), "non-finite blended action"

    diagnostics = {
        "cost_min": cost.min().item(),
        "cost_mean": cost.mean().item(),
        "cost_max": cost.max().item(),
        "cost_std": cost.std(unbiased=False).item(),
        "temperature_effective": temperature_effective.item(),
        # ESS near 1 -> effectively greedy (temperature too low); ESS near
        # num_candidates -> no discrimination between candidates (too high).
        "effective_sample_size": (1.0 / (weights ** 2).sum()).item(),
        "stall_detected": stalled,
        "effective_max_accel": max_accel * config.stall_variance_multiplier if stalled else max_accel,
        **cost_components,
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
        distance_to_goal = float(np.linalg.norm(state[:2] - goal[:2]))
        if distance_to_goal < goal_tolerance:
            reached = True
            break
        steps_used = step + 1

        if policy == "mpc":
            state_t = torch.from_numpy(state).to(device)
            velocity = float(np.linalg.norm(state[2:]))
            t0 = time.perf_counter()
            action_t, diag = plan_step(
                model, state_t, goal_latent, prev_action, config, rng, env.config.max_accel, device,
                velocity, distance_to_goal,
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

    ap.add_argument("--episodes", type=int, default=50)
    ap.add_argument("--max-episode-steps", type=int, default=50)
    ap.add_argument("--max-accel", type=float, default=EnvConfig().max_accel)
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
        terminal_cost_weight=args.terminal_cost_weight,
        stall_velocity_threshold=args.stall_velocity_threshold,
        stall_distance_threshold=args.stall_distance_threshold,
        stall_variance_multiplier=args.stall_variance_multiplier,
        stall_widen_fraction=args.stall_widen_fraction,
        adaptive_temperature=args.adaptive_temperature,
        min_cost_scale=args.min_cost_scale,
        normalize_running_cost_by_horizon=args.normalize_running_cost_by_horizon,
    )
    device = resolve_device()

    ckpt = torch.load(args.checkpoint, map_location=device)
    model = JEPAModule(JEPAConfig(**ckpt["jepa_config"])).to(device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)

    env = ParticleNavigatorEnv(EnvConfig(max_accel=args.max_accel))

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
                stall_rate = np.mean([d["stall_detected"] for d in all_diag])
                print(
                    f"  MPPI diagnostics: cost_min~{cost_min.mean():.3f} "
                    f"cost_mean~{cost_mean.mean():.3f} "
                    f"effective_sample_size mean={ess.mean():.1f}/{config.num_candidates}"
                )
                print(f"  stall_detected on {stall_rate:.1%} of planning steps")
                if config.adaptive_temperature:
                    temp_eff = np.array([d["temperature_effective"] for d in all_diag])
                    cost_std = np.array([d["cost_std"] for d in all_diag])
                    print(
                        f"  adaptive temperature: cost_std mean={cost_std.mean():.3f} "
                        f"temperature_effective mean={temp_eff.mean():.3f}"
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
