#!/usr/bin/env python3
"""Forward metric panel for the WorldModel JEPA on synthetic-1/f data (Phase B).

Trains a small JEPA (`eeg_jepa.EEGJEPAModule`) on `synthetic_1f` transitions, then
reports a PANEL of forward-quality metrics. No single number is trusted — the panel
is the point (see RESEARCH_spectral_geometry.md §"No label-free metric is a trusted
oracle"). This iteration establishes the panel infrastructure; the A/B over
transform arms is a later iteration that reuses `evaluate()`.

Metrics:
  - pred_error_1step  : MSE between the predictor's next-latent and the EMA target
                        encoder's next-latent (the JEPA's own forward objective,
                        measured on held-out data). The forward-prediction anchor.
  - rollout_error     : closed-loop multi-step latent rollout error — roll the
                        predictor feeding its own output back in, MSE per horizon vs
                        the EMA-target encoding of the true state.
  - mpc_success       : goal-conditioned CEM planning success — plan an action
                        sequence in latent space (predictor as forward model),
                        execute it in the TRUE env, score whether it reaches the goal
                        pos. success_rate + mean_final_distance + a random-action
                        baseline. rollout_error and mpc_success are the two forward
                        numbers the transform-A/B decision rule anchors on (alongside
                        factor recovery).
  - factor_recovery   : held-out linear-probe R² for each KNOWN latent factor
                        {pos, vel, chi, peak_amp, offset} — INCLUDING the aperiodic
                        exponent `chi`, the information-destruction detector.
  - rankme            : Garrido et al. 2023 — entropy-based effective rank of the
                        latent singular-value spectrum (collapse detector).
  - alpha_req         : Agrawal et al. 2022 — power-law decay exponent of the latent
                        covariance eigenspectrum.
  - vicreg_var / _cov : VICReg variance (higher = less collapse) & covariance
                        (lower = more decorrelated) terms.
  - alignment / uniformity : Wang & Isola 2020, on L2-normalized latents.

DEFERRED (ledgered):
  - LiDAR (Thilak et al. 2024)        (needs the clean/augmented surrogate-class setup)

Synthetic only. No real EEG, no hardware, no app wiring, no network. Seeded → reproducible.

Usage:
  venv/bin/python WorldModel/forward_eval.py --n 512 --epochs 30 --seed 0 --mode signal
  venv/bin/python WorldModel/forward_eval.py --smoke-test
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parent))
from eeg_jepa import (  # noqa: E402
    EEGJEPAConfig,
    JEPATransitionDataset,
    resolve_device,
    train_jepa,
)
from frame_diagnostic import frame_diagnostic  # noqa: E402
import random  # noqa: E402
from synthetic_1f import (  # noqa: E402
    generate,
    write_jsonl,
    _sample_latent,
    _step,
    _render_state,
    SEQUENCE_LENGTH,
)

FACTOR_NAMES = ["pos", "vel", "chi", "peak_amp", "offset"]
# action[2] is the mode bit. `_step` never reads it, so it is a NEGATIVE CONTROL:
# a probe that "recovers" it is fitting noise and its other numbers mean nothing.
ACTION_NAMES = ["ax", "ay", "mode_bit"]


def _seed_everything(seed: int) -> None:
    torch.manual_seed(seed)
    np.random.seed(seed)


def _read_factors(records: list[dict[str, Any]]) -> np.ndarray:
    """Ground-truth latent factors per record, in FACTOR_NAMES order. (N, 5)."""
    return np.array(
        [[float(r["_latent"][name]) for name in FACTOR_NAMES] for r in records],
        dtype=np.float64,
    )


@torch.no_grad()
def _encode_all(model, dataset, device) -> tuple[torch.Tensor, torch.Tensor]:
    """Online-encoder latent of every pre-window and target-encoder latent of every
    post-window: (Z_pre, Z_post), each (N, latent_dim)."""
    model.encoder.eval()
    model.target_encoder.eval()
    pres, posts = [], []
    for i in range(len(dataset)):
        pre, _, post = dataset[i]
        pres.append(model.encoder(pre.unsqueeze(0).to(device)).squeeze(0).cpu())
        posts.append(model.target_encoder(post.unsqueeze(0).to(device)).squeeze(0).cpu())
    return torch.stack(pres), torch.stack(posts)


@torch.no_grad()
def _pred_error_1step(model, dataset, device) -> float:
    """MSE(predictor(z_pre, a), target_encoder(z_post)) — the forward objective."""
    model.encoder.eval()
    model.predictor.eval()
    errs = []
    for i in range(len(dataset)):
        pre, action, post = dataset[i]
        pred = model.forward_online(pre.unsqueeze(0).to(device), action.unsqueeze(0).to(device))
        tgt = model.forward_target(post.unsqueeze(0).to(device))
        errs.append(F.mse_loss(pred, tgt).item())
    return float(np.mean(errs))


def _factor_recovery(Z: torch.Tensor, factors: np.ndarray, seed: int) -> dict[str, float]:
    """Held-out linear-probe R² per factor (80/20 split). Bias column included."""
    X = Z.double().numpy()
    rng = np.random.default_rng(seed)
    idx = rng.permutation(len(X))
    cut = max(1, int(0.8 * len(X)))
    tr, te = idx[:cut], idx[cut:]
    if len(te) == 0:  # tiny-N fallback: evaluate in-sample
        te = tr
    Xtr = np.concatenate([X[tr], np.ones((len(tr), 1))], axis=1)
    Xte = np.concatenate([X[te], np.ones((len(te), 1))], axis=1)
    out: dict[str, float] = {}
    for k, name in enumerate(FACTOR_NAMES):
        w, *_ = np.linalg.lstsq(Xtr, factors[tr, k], rcond=None)
        pred = Xte @ w
        ss_res = float(((factors[te, k] - pred) ** 2).sum())
        ss_tot = float(((factors[te, k] - factors[te, k].mean()) ** 2).sum())
        out[name] = 1.0 - ss_res / ss_tot if ss_tot > 1e-12 else 0.0
    return out


def _action_recovery(
    Z_pre: torch.Tensor, Z_post: torch.Tensor, actions: np.ndarray, seed: int
) -> dict[str, float]:
    """Held-out linear-probe R^2 for each action dimension from (z_pre, z_post).

    How much of WHICH ACTION WAS TAKEN survives into the representation. The
    panel measured how well the latent recovers the state factors, but control
    depends on the action channel and nothing scored it — so ten nodes of
    representation work optimised metrics dominated by `chi`, `peak_amp` and
    `offset`, which are per-trajectory CONSTANTS, while the action channel went
    unmeasured (node 17).

    Read against two anchors that come free with it:
      * `mode_bit` is action[2], which `_step` never reads. It MUST come out at
        or below zero. A positive value means the probe is fitting noise.
      * the same probe on the TRUE (pre, post) states recovers `ay` at R^2 =
        1.000 exactly — the algebra makes it linear — so the ceiling is known
        and any shortfall is the representation's, not the probe's.
    """
    X = np.concatenate([Z_pre.double().numpy(), Z_post.double().numpy()], axis=1)
    rng = np.random.default_rng(seed)
    idx = rng.permutation(len(X))
    cut = max(1, int(0.8 * len(X)))
    tr, te = idx[:cut], idx[cut:]
    if len(te) == 0:
        te = tr
    Xtr = np.concatenate([X[tr], np.ones((len(tr), 1))], axis=1)
    Xte = np.concatenate([X[te], np.ones((len(te), 1))], axis=1)
    out: dict[str, float] = {}
    for k, name in enumerate(ACTION_NAMES):
        w, *_ = np.linalg.lstsq(Xtr, actions[tr, k], rcond=None)
        pred = Xte @ w
        ss_res = float(((actions[te, k] - pred) ** 2).sum())
        ss_tot = float(((actions[te, k] - actions[te, k].mean()) ** 2).sum())
        out[name] = 1.0 - ss_res / ss_tot if ss_tot > 1e-12 else 0.0
    return out


def _rankme(Z: torch.Tensor, eps: float = 1e-7) -> float:
    """Garrido 2023 effective rank: exp(entropy of normalized singular values)."""
    s = torch.linalg.svdvals(Z - Z.mean(0, keepdim=True))
    p = s / (s.sum() + eps)
    entropy = -(p * torch.log(p + eps)).sum()
    return float(torch.exp(entropy))


def _alpha_req(Z: torch.Tensor, eps: float = 1e-12) -> float:
    """Agrawal 2022: power-law slope of the covariance eigenspectrum (log-log fit).

    The fit is a closed-form OLS slope, not `torch.linalg.lstsq`. On a design
    matrix of [log(rank), 1] the two are the same estimator, but lstsq's LAPACK
    path is NOT bit-reproducible: on fixed input it returned two distinct values
    across six calls, differing in the last ULP (…3686 vs …3690). Isolated by
    repeating each step on one fixed Z — `Zc.T @ Zc` and `eigvalsh` were both
    byte-identical, lstsq alone varied.

    That single ULP was enough to fail `smoke_test`'s exact-JSON determinism
    assertion, which compares two `evaluate()` runs. The assertion is right and
    worth keeping strict; the estimator was the defect. Fixing the source rather
    than loosening the check keeps the gate able to catch real non-determinism —
    an unseeded RNG or a dict-ordering change would still trip it.
    """
    Zc = (Z - Z.mean(0, keepdim=True)).double()
    cov = (Zc.T @ Zc) / max(1, len(Z) - 1)
    eig = torch.linalg.eigvalsh(cov).flip(0).clamp_min(eps)  # descending
    x = torch.log(torch.arange(1, len(eig) + 1, dtype=torch.float64))
    y = torch.log(eig)
    dx = x - x.mean()
    # Degenerate only at len(eig) == 1, where dx is all-zero and the numerator
    # vanishes too; the clamp keeps that case finite (slope 0) instead of nan,
    # which smoke_test's isfinite assertion would otherwise reject.
    denom = (dx * dx).sum().clamp_min(1e-300)
    slope = (dx * (y - y.mean())).sum() / denom
    return float(-slope)


def _vicreg_terms(Z: torch.Tensor, eps: float = 1e-4) -> tuple[float, float]:
    """VICReg variance term (mean per-dim std; higher=less collapse) and covariance
    term (mean squared off-diagonal covariance per dim; lower=more decorrelated)."""
    Zc = Z - Z.mean(0, keepdim=True)
    var_term = float(torch.sqrt(Zc.var(0) + eps).mean())
    n, d = Z.shape
    cov = (Zc.T @ Zc) / max(1, n - 1)
    off = cov - torch.diag(torch.diagonal(cov))
    cov_term = float((off ** 2).sum() / d)
    return var_term, cov_term


def _alignment_uniformity(Z_pre: torch.Tensor, Z_post: torch.Tensor, t: float = 2.0) -> tuple[float, float]:
    """Wang & Isola 2020 on L2-normalized latents. Positive pairs = (pre, post) of
    the same transition. Uniformity is measured on the pre-latents' spread."""
    a = F.normalize(Z_pre, dim=1)
    b = F.normalize(Z_post, dim=1)
    alignment = float(((a - b) ** 2).sum(1).mean())
    sq = torch.pdist(a) ** 2
    uniformity = float(torch.log(torch.exp(-t * sq).mean() + 1e-12)) if sq.numel() else 0.0
    return alignment, uniformity


def _generate_trajectories(n_traj: int, length: int, mode: str, seed: int) -> list[dict[str, Any]]:
    """`n_traj` independent trajectories, each `length` CHAINED single-step
    transitions (post_i == pre_{i+1}), flattened in trajectory-major order into the
    JEPATransition record schema. Reuses the synthetic_1f dynamics so multi-step
    rollout is measured on the same generator the JEPA trained on. Trajectory t
    occupies records [t*length : (t+1)*length]."""
    rng = random.Random(seed)
    records: list[dict[str, Any]] = []
    for traj in range(n_traj):
        z = _sample_latent(rng)
        for step in range(length):
            action = [rng.uniform(-1.0, 1.0), rng.uniform(-1.0, 1.0), float(step % 2)]
            z_next = _step(z, action, mode)
            records.append({
                "id": f"00000000-0000-0000-{traj % 10000:04d}-{step:012d}",
                "timestamp": 1_700_000_000.0 + traj * length + step,
                "preActionWindow": [_render_state(z, t) for t in range(SEQUENCE_LENGTH)],
                "actionVector": action,
                "postActionWindow": [_render_state(z_next, t) for t in range(SEQUENCE_LENGTH)],
                "_latent": {k: z[k] for k in ("pos", "vel", "chi", "peak_amp", "offset")},
            })
            z = z_next
    return records


@torch.no_grad()
def _multi_step_rollout(model, train_mean, train_std, device, *,
                        n_traj: int = 32, length: int = 8, mode: str = "signal",
                        seed: int = 1, log_features: bool = False,
                        log_epsilon: float = 1e-6, symlog: bool = False) -> dict[str, Any]:
    """Closed-loop latent rollout error. Encode the first window of each trajectory,
    roll the predictor `length` steps feeding its OWN output back in (with the true
    actions), and MSE each predicted latent against the EMA-target encoding of the
    true state at that horizon. Trajectory windows are z-scored on the TRAIN stats
    so they live in the JEPA's input space. Returns per-horizon mean error, 1..length
    (error typically grows with the horizon as prediction error compounds)."""
    model.encoder.eval()
    model.predictor.eval()
    model.target_encoder.eval()
    records = _generate_trajectories(n_traj, length, mode, seed)
    with tempfile.TemporaryDirectory(prefix="neuralcompose-rollout-") as directory:
        path = write_jsonl(records, Path(directory) / "traj.jsonl")
        traj = JEPATransitionDataset(path, mean=train_mean, std=train_std,
                                     log_features=log_features, log_epsilon=log_epsilon, symlog=symlog)
        horizon_err: list[list[float]] = [[] for _ in range(length)]
        for t in range(n_traj):
            base = t * length
            pre0, _, _ = traj[base]
            z_pred = model.encoder(pre0.unsqueeze(0).to(device))
            for h in range(length):
                _, action, post = traj[base + h]
                z_pred = model.predictor(z_pred, action.unsqueeze(0).to(device))
                target = model.target_encoder(post.unsqueeze(0).to(device))
                horizon_err[h].append(F.mse_loss(z_pred, target).item())
    per_horizon = [float(np.mean(errors)) for errors in horizon_err]
    return {
        "per_horizon": per_horizon,
        "step1": per_horizon[0],
        "final_step": per_horizon[-1],
        "mean": float(np.mean(per_horizon)),
    }


@torch.no_grad()
def _encode_states(model, states, train_mean, train_std, device, use_target: bool = False,
                   *, log_features: bool = False, log_epsilon: float = 1e-6, symlog: bool = False) -> torch.Tensor:
    """Encode a list of latent states into JEPA latents, normalized on the TRAIN
    stats (routed through JEPATransitionDataset so normalization matches training
    exactly). Goal states use the target encoder (the predictor's output space);
    start states use the online encoder."""
    records = [{
        "id": f"00000000-0000-0000-0000-{i:012d}",
        "timestamp": 1_700_000_000.0 + i,
        "preActionWindow": [_render_state(z, t) for t in range(SEQUENCE_LENGTH)],
        "actionVector": [0.0, 0.0, 0.0],
        "postActionWindow": [_render_state(z, t) for t in range(SEQUENCE_LENGTH)],
        "_latent": {k: z[k] for k in ("pos", "vel", "chi", "peak_amp", "offset")},
    } for i, z in enumerate(states)]
    encoder = model.target_encoder if use_target else model.encoder
    encoder.eval()
    with tempfile.TemporaryDirectory(prefix="neuralcompose-encstate-") as directory:
        path = write_jsonl(records, Path(directory) / "s.jsonl")
        ds = JEPATransitionDataset(path, mean=train_mean, std=train_std,
                                   log_features=log_features, log_epsilon=log_epsilon, symlog=symlog)
        return torch.stack([
            encoder(ds[i][0].unsqueeze(0).to(device)).squeeze(0) for i in range(len(ds))
        ])


@torch.no_grad()
def _cem_plan(model, z0_lat, zg_lat, device, *, horizon, cem_iters, n_samples, elite_frac, gen) -> torch.Tensor:
    """CEM over `horizon`-step action sequences (2 continuous dims + a fixed mode
    bit = step%2), using the predictor as the latent forward model; minimize the
    rolled-out final latent's distance to the goal latent. Sampling is on CPU (a
    seeded Generator → deterministic); the predictor rollout runs on `device`.
    Returns the best (horizon, 3) action sequence."""
    mean = torch.zeros(horizon, 2)
    std = torch.ones(horizon, 2)
    n_elite = max(1, int(elite_frac * n_samples))
    mode_bits = torch.tensor([[float(h % 2)] for h in range(horizon)])  # (horizon, 1)
    best = torch.zeros(horizon, 2)
    for _ in range(cem_iters):
        noise = torch.randn(n_samples, horizon, 2, generator=gen)
        samples = (mean.unsqueeze(0) + std.unsqueeze(0) * noise).clamp(-1.0, 1.0)  # CPU
        z = z0_lat.unsqueeze(0).expand(n_samples, -1).contiguous().to(device)
        for h in range(horizon):
            act = torch.cat([samples[:, h, :].to(device),
                             mode_bits[h].expand(n_samples, 1).to(device)], dim=1)
            z = model.predictor(z, act)
        costs = ((z - zg_lat.unsqueeze(0).to(device)) ** 2).sum(dim=1).cpu()
        elite = samples[torch.topk(-costs, n_elite).indices]
        mean = elite.mean(dim=0)
        std = elite.std(dim=0).clamp_min(1e-3)
        best = samples[int(torch.argmin(costs))]
    return torch.cat([best, mode_bits], dim=1)  # (horizon, 3)


@torch.no_grad()
def _mpc_success(model, train_mean, train_std, device, *, n_episodes=200, horizon=6,
                 cem_iters=3, n_samples=64, elite_frac=0.2, mode="signal",
                 episode_seed=2, goal_offset=0.4, goal_tol=0.15, baseline_reps=100,
                 log_features: bool = False,
                 log_epsilon: float = 1e-6, symlog: bool = False) -> dict[str, Any]:
    """Goal-conditioned latent MPC/CEM planning success. Per episode: sample a start
    state + a goal `pos`, plan with CEM (the JEPA predictor as forward model), then
    EXECUTE the plan in the TRUE synthetic_1f env (`_step`) and score whether the
    true final pos reached the goal. A random-action policy is the baseline — the
    JEPA-planned success rate beating it is the signal that the latent dynamics are
    useful for control. Returns success_rate, mean_final_distance, random_baseline."""
    # The episode set, the baseline draws and the planner's sampling noise all
    # derive from `episode_seed` and NOTHING else. Previously `evaluate()` passed
    # `seed = model_seed + 2`, so every model seed scored a DIFFERENT episode set:
    # "which episodes" was confounded with "which model", and the between-set
    # difficulty spread (sd 0.0853, measured) was being read as model variance.
    # The benchmark's episodes are a property of the benchmark, not of the run.
    rng = random.Random(episode_seed)
    starts = [_sample_latent(rng) for _ in range(n_episodes)]
    goal_pos = [starts[i]["pos"] + rng.uniform(-goal_offset, goal_offset) for i in range(n_episodes)]
    goals = [{**starts[i], "pos": goal_pos[i]} for i in range(n_episodes)]
    z0 = _encode_states(model, starts, train_mean, train_std, device, use_target=False,
                        log_features=log_features, log_epsilon=log_epsilon, symlog=symlog)
    zg = _encode_states(model, goals, train_mean, train_std, device, use_target=True,
                        log_features=log_features, log_epsilon=log_epsilon, symlog=symlog)

    # z0 is ONLINE and zg is TARGET, while goals[i] differs from starts[i] in
    # `pos` alone -- so encoder disagreement enters the cost as a near-constant
    # offset the planner cannot reduce by acting. Measured here because starts
    # and goals are already matched by construction. See frame_diagnostic.py.
    def _enc(states, use_target: bool = False):
        return _encode_states(model, states, train_mean, train_std, device, use_target,
                              log_features=log_features, log_epsilon=log_epsilon, symlog=symlog)

    frame = frame_diagnostic(_enc, starts, goals)

    successes, dists = 0, []
    rand_per_episode: list[float] = []
    start_dists: list[float] = []
    log_ratios: list[float] = []
    for i in range(n_episodes):
        # A generator PER EPISODE, seeded from the episode identity alone. A
        # single generator consumed sequentially made the planning noise on
        # episode i depend on how many draws episodes 0..i-1 had taken, which is
        # a function of n_samples * cem_iters * horizon. Any arm that touched a
        # CEM knob therefore got different noise on the SAME episode, silently
        # defeating pairing even with the episode set fixed. Nothing in the panel
        # would have revealed it.
        gen = torch.Generator()
        gen.manual_seed(episode_seed * 1_000_003 + i)
        plan = _cem_plan(model, z0[i], zg[i], device, horizon=horizon, cem_iters=cem_iters,
                         n_samples=n_samples, elite_frac=elite_frac, gen=gen)
        z = dict(starts[i])
        for h in range(horizon):
            z = _step(z, plan[h].tolist(), mode)
        d = abs(z["pos"] - goal_pos[i])
        dists.append(d)
        if d < goal_tol:
            successes += 1
        # Paired continuous endpoint: log(d_final / d_start), per episode.
        #
        # `success_rate` thresholds a continuous distance at goal_tol=0.15 and
        # throws away everything else. Simulating a 10% distance improvement
        # with shared episode difficulty, power at n=20 is 17.7% for a paired
        # continuous statistic against 0.5% for paired binary; at n=200 it is
        # 85.1% against 23.4%. The distance is already computed and returned --
        # it simply was not the adjudicator.
        #
        # The RATIO, not the difference: episodes differ enormously in how far
        # the goal starts, so a raw difference is dominated by episode
        # difficulty. The log makes "halved the distance" the same effect size
        # wherever it happens, which is what pairing needs. Both terms are
        # clamped because goal_offset can draw a start essentially on top of
        # its goal, and log(0) would take the whole panel with it.
        d0 = max(abs(starts[i]["pos"] - goal_pos[i]), 1e-6)
        start_dists.append(d0)
        log_ratios.append(math.log(max(d, 1e-6) / d0))
    # The random baseline is estimated AFTER the model arm, over
    # `baseline_reps` rollouts per episode rather than one. It touches no
    # encoder, no predictor and no CEM — only `_step` with uniform actions —
    # so its cost is env steps alone and precision here is nearly free.
    #
    # Estimating it at one draw per episode made a scalar with a binomial
    # standard error of ~0.10 at n=20 the thing every arm was compared
    # against, and re-drawing it per seed injected that sampling noise into
    # every comparison as if it were model variance. The 0.15-0.45 swing
    # recorded in ledger node 14 needs no model explanation: five draws from
    # Binomial(20, 0.30) have a median range of 0.25.
    #
    # Kept episode-paired rather than moved to an independent episode set:
    # what a paired comparison needs is P(random succeeds | THIS episode),
    # and per-episode rates are returned so a later paired analysis can use
    # them as a difficulty covariate instead of re-deriving them.
    for i in range(n_episodes):
        hits = 0
        for _ in range(baseline_reps):
            z = dict(starts[i])
            for h in range(horizon):
                z = _step(z, [rng.uniform(-1.0, 1.0), rng.uniform(-1.0, 1.0), float(h % 2)], mode)
            if abs(z["pos"] - goal_pos[i]) < goal_tol:
                hits += 1
        rand_per_episode.append(hits / baseline_reps)
    rand_mean = float(np.mean(rand_per_episode))
    # SE of the mean over episodes, so a reader can see the pin held rather
    # than take it on faith.
    rand_se = float(np.std(rand_per_episode, ddof=1) / math.sqrt(n_episodes)) \
        if n_episodes > 1 else float("nan")

    return {
        "success_rate": successes / n_episodes,
        "mean_final_distance": float(np.mean(dists)),
        "random_baseline_success": rand_mean,
        "random_baseline_stderr": rand_se,
        "random_baseline_reps": baseline_reps,
        "random_baseline_per_episode": rand_per_episode,
        # Primary candidate for the repaired benchmark. Reported alongside
        # success_rate rather than replacing it -- adopting it as THE adjudicator
        # is a separate, pre-registered decision, and switching endpoints while
        # also changing the episode set would confound the two.
        # Per-episode finals, so a downstream paired analysis can compute EITHER
        # endpoint exactly instead of approximating the binary one from the two
        # marginal rates. Without this the paired binary sd has to be guessed.
        "final_distance_per_episode": dists,
        "log_distance_ratio_mean": float(np.mean(log_ratios)),
        "log_distance_ratio_per_episode": log_ratios,
        "start_distance_per_episode": start_dists,
        "episode_seed": episode_seed,
        "frame": frame,
    }


def evaluate(
    n: int = 512,
    mode: str = "signal",
    seed: int = 0,
    epochs: int = 30,
    latent_dim: int = 32,
    batch_size: int = 64,
    rollout_traj: int = 32,
    rollout_len: int = 8,
    mpc_episodes: int = 200,
    mpc_horizon: int = 6,
    mpc_cem_iters: int = 3,
    mpc_n_samples: int = 64,
    mpc_elite_frac: float = 0.2,
    log_features: bool = False,
    log_epsilon: float = 1e-6,
    symlog: bool = False,
    device: torch.device | None = None,
    verbose: bool = True,
) -> dict[str, Any]:
    """Train a JEPA on freshly-generated synthetic_1f data and return the panel.

    `log_features` and `symlog` select the input space fed to the encoder: raw
    z-scored band/channel power (default), log-compressed-then-z-scored (the 1/f
    log-transform, node-33 arm), or signed-log1p-then-z-scored (`symlog`, node-7
    arm — same compression without log_features' epsilon-floor outlier at dead
    channels). They are mutually exclusive and each threaded identically into the
    train, rollout, and MPC-encode datasets so all three encode in ONE space —
    otherwise the model trains on transformed windows while rollout/MPC feed raw
    ones. Each is a transform arm: measured forward, kept only if it improves
    rollout+MPC without degrading chi-recovery.
    """
    _seed_everything(seed)
    device = device or resolve_device()

    records = generate(n, mode, seed)
    with tempfile.TemporaryDirectory(prefix="neuralcompose-fwdeval-") as directory:
        path = write_jsonl(records, Path(directory) / "data.jsonl")
        dataset = JEPATransitionDataset(path, log_features=log_features, log_epsilon=log_epsilon, symlog=symlog)
        loader = DataLoader(dataset, batch_size=min(batch_size, len(dataset)), shuffle=True)
        pre0, action0, _ = dataset[0]
        state_dim, action_dim = pre0.shape[-1], action0.shape[-1]

        config = EEGJEPAConfig(latent_dim=latent_dim)
        model, history = train_jepa(
            loader, state_dim, action_dim, config=config, epochs=epochs, device=device
        )

        factors = _read_factors(records)
        action_vectors = np.array([r["actionVector"] for r in records], dtype=np.float64)
        Z_pre, Z_post = _encode_all(model, dataset, device)
        var_term, cov_term = _vicreg_terms(Z_pre)
        alignment, uniformity = _alignment_uniformity(Z_pre, Z_post)
        rollout = _multi_step_rollout(
            model, dataset.mean, dataset.std, device,
            n_traj=rollout_traj, length=rollout_len, mode=mode, seed=seed + 1,
            log_features=log_features, log_epsilon=log_epsilon, symlog=symlog,
        )
        mpc = _mpc_success(
            model, dataset.mean, dataset.std, device,
            n_episodes=mpc_episodes, horizon=mpc_horizon, mode=mode,
            cem_iters=mpc_cem_iters, n_samples=mpc_n_samples, elite_frac=mpc_elite_frac,
            log_features=log_features, log_epsilon=log_epsilon, symlog=symlog,
        )

        panel = {
            "config": {"n": n, "mode": mode, "seed": seed, "epochs": epochs,
                       "latent_dim": latent_dim, "log_features": log_features,
                       "symlog": symlog, "mpc_cem_iters": mpc_cem_iters,
                       "mpc_n_samples": mpc_n_samples, "mpc_elite_frac": mpc_elite_frac,
                       "final_train_loss": history[-1]},
            "pred_error_1step": _pred_error_1step(model, dataset, device),
            "rollout_error": rollout,
            "mpc_success": mpc,
            "factor_recovery": _factor_recovery(Z_pre, factors, seed),
            "action_recovery": _action_recovery(Z_pre, Z_post, action_vectors, seed),
            "rankme": _rankme(Z_pre),
            "alpha_req": _alpha_req(Z_pre),
            "vicreg_var": var_term,
            "vicreg_cov": cov_term,
            "alignment": alignment,
            "uniformity": uniformity,
        }

    if verbose:
        print(json.dumps(panel, indent=2))
    return panel


def smoke_test() -> None:
    """Tiny, fast, deterministic run; assert every metric is sane."""
    # Named assertion for the one estimator that has actually broken the
    # whole-panel determinism check below. `torch.linalg.lstsq`'s LAPACK path
    # returned two values differing in the last ULP on fixed input, which is
    # invisible in the panel comparison except as an opaque "non-deterministic".
    # Assert it directly so a regression points at the estimator, not the panel.
    #
    # The shape matters and is not arbitrary. lstsq's non-determinism here is
    # shape-dependent, not intermittent: measured over 256 repeats it is stable
    # at (64,16), (128,8) and (256,16), and reliably yields two distinct values
    # at (384,64) and (512,32). A first draft of this assertion used (256,16)
    # and passed with lstsq restored — i.e. it would have shipped without
    # testing anything. (512,32) is also `evaluate()`'s own default shape.
    _z = torch.randn(512, 32, generator=torch.Generator().manual_seed(0))
    assert len({_alpha_req(_z) for _ in range(16)}) == 1, \
        "alpha_req is not deterministic on fixed input — check the OLS fit"

    a = evaluate(n=64, mode="signal", seed=0, epochs=3, latent_dim=16, rollout_traj=8,
                 rollout_len=4, mpc_episodes=6, mpc_horizon=4, device=torch.device("cpu"), verbose=False)
    b = evaluate(n=64, mode="signal", seed=0, epochs=3, latent_dim=16, rollout_traj=8,
                 rollout_len=4, mpc_episodes=6, mpc_horizon=4, device=torch.device("cpu"), verbose=False)

    # Determinism: same seed → identical panel.
    assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True), "non-deterministic"

    # Finiteness across the whole panel.
    for key in ("pred_error_1step", "rankme", "alpha_req", "vicreg_var",
                "vicreg_cov", "alignment", "uniformity"):
        assert np.isfinite(a[key]), f"{key} not finite: {a[key]}"
    for name, r2 in a["factor_recovery"].items():
        assert np.isfinite(r2), f"factor_recovery[{name}] not finite"

    # Multi-step rollout: per-horizon list of the right length, all finite + non-negative.
    roll = a["rollout_error"]
    assert len(roll["per_horizon"]) == 4, f"rollout horizons: {roll['per_horizon']}"
    assert all(np.isfinite(v) and v >= 0.0 for v in roll["per_horizon"]), roll["per_horizon"]
    assert np.isfinite(roll["step1"]) and np.isfinite(roll["final_step"])

    # MPC/CEM planning success: rates in [0, 1], distance finite + non-negative.
    mpc = a["mpc_success"]
    assert 0.0 <= mpc["success_rate"] <= 1.0, mpc
    assert 0.0 <= mpc["random_baseline_success"] <= 1.0, mpc
    assert np.isfinite(mpc["mean_final_distance"]) and mpc["mean_final_distance"] >= 0.0

    # RankMe is an effective rank in (0, latent_dim].
    assert 0.0 < a["rankme"] <= 16.0 + 1e-6, f"rankme out of range: {a['rankme']}"
    # VICReg variance term is non-negative.
    assert a["vicreg_var"] >= 0.0
    # The chi probe exists and is reported (the information-destruction detector).
    assert "chi" in a["factor_recovery"]

    # The action probe's negative control. action[2] is the mode bit and `_step`
    # never reads it, so it carries no information about the transition. If a
    # probe recovers it, the probe is fitting noise and its ax/ay numbers are
    # meaningless -- which is the only way this metric can silently lie.
    ar = a["action_recovery"]
    assert set(ar) == set(ACTION_NAMES), ar
    assert all(np.isfinite(v) for v in ar.values()), ar
    assert ar["mode_bit"] <= 0.05, \
        f"action probe recovered the unused mode bit (R^2={ar['mode_bit']:.3f}) — it is fitting noise"

    # The log-features (node-33) arm must stay finite end-to-end — a log(0) or a
    # train/rollout input-space mismatch would surface here as NaN/inf.
    c = evaluate(n=64, mode="signal", seed=0, epochs=3, latent_dim=16, rollout_traj=8,
                 rollout_len=4, mpc_episodes=6, mpc_horizon=4, log_features=True,
                 device=torch.device("cpu"), verbose=False)
    assert c["config"]["log_features"] is True
    assert np.isfinite(c["pred_error_1step"]), c["pred_error_1step"]
    assert np.isfinite(c["factor_recovery"]["chi"]), c["factor_recovery"]["chi"]
    assert all(np.isfinite(v) and v >= 0.0 for v in c["rollout_error"]["per_horizon"]), \
        c["rollout_error"]["per_horizon"]

    # The symlog (node-7) arm must likewise stay finite end-to-end; log1p(0)=0 so a
    # dead channel maps to 0 instead of log_features' large-negative epsilon floor.
    s = evaluate(n=64, mode="signal", seed=0, epochs=3, latent_dim=16, rollout_traj=8,
                 rollout_len=4, mpc_episodes=6, mpc_horizon=4, symlog=True,
                 device=torch.device("cpu"), verbose=False)
    assert s["config"]["symlog"] is True
    assert np.isfinite(s["pred_error_1step"]), s["pred_error_1step"]
    assert np.isfinite(s["factor_recovery"]["chi"]), s["factor_recovery"]["chi"]
    assert all(np.isfinite(v) and v >= 0.0 for v in s["rollout_error"]["per_horizon"]), \
        s["rollout_error"]["per_horizon"]

    print(f"smoke test passed "
          f"(pred_err={a['pred_error_1step']:.4f}, "
          f"rollout[1→{len(roll['per_horizon'])}]={roll['step1']:.3f}→{roll['final_step']:.3f}, "
          f"mpc={mpc['success_rate']:.2f} vs rand {mpc['random_baseline_success']:.2f}, "
          f"chi_R2={a['factor_recovery']['chi']:.3f})")


def main() -> None:
    parser = argparse.ArgumentParser(description="WorldModel JEPA forward metric panel")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--n", type=int, default=512)
    parser.add_argument("--mode", type=str, default="signal", choices=["signal", "nuisance"])
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--latent-dim", type=int, default=32)
    parser.add_argument("--log-features", action="store_true",
                        help="feed the encoder log-compressed (1/f) spectral state — the node-33 arm")
    parser.add_argument("--log-epsilon", type=float, default=1e-6)
    parser.add_argument("--symlog", action="store_true",
                        help="feed the encoder signed-log1p spectral state — the node-7 arm (no epsilon floor)")
    parser.add_argument("--mpc-cem-iters", type=int, default=3,
                        help="CEM refinement iterations for the MPC planner (node-10 knob)")
    parser.add_argument("--mpc-n-samples", type=int, default=64,
                        help="CEM population size for the MPC planner (node-10 knob)")
    parser.add_argument("--mpc-elite-frac", type=float, default=0.2)
    args = parser.parse_args()

    if args.smoke_test:
        smoke_test()
        return
    evaluate(n=args.n, mode=args.mode, seed=args.seed, epochs=args.epochs,
             latent_dim=args.latent_dim, log_features=args.log_features,
             log_epsilon=args.log_epsilon, symlog=args.symlog,
             mpc_cem_iters=args.mpc_cem_iters, mpc_n_samples=args.mpc_n_samples,
             mpc_elite_frac=args.mpc_elite_frac)


if __name__ == "__main__":
    main()
