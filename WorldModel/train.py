#!/usr/bin/env python3
"""train.py — wire the dataset, JEPA architecture, and VICReg loss into a
training loop.

Day 3 of the World Model (JEPA + MPC) research spike (see
`WorldModel/README.md`). Trains `models.py::JEPAModule`'s online `encoder`
and `predictor` against `loss.py::vicreg_loss`; `target_encoder` is updated
only via `update_target_ema()`, never by gradient descent (it's excluded
from the optimizer's parameter list). Watches `std_target_mean` every
epoch as the collapse-detection signal -- loss decreasing is not, by
itself, evidence of a healthy representation, since a collapsed encoder
trivially drives MSE toward zero too.

After training, runs `rollout_check()`: since JEPA has no decoder back to
raw state, the Day 3 deliverable ("a predictor that unrolls latent
trajectories across a multi-step horizon without diverging") is validated
purely in latent space -- self-feeding the predictor for K steps with no
teacher forcing, then checking finiteness, latent-norm growth, and drift
against the true final state's target encoding (relative to a
random-trajectory-pair baseline, since a bare drift number has no inherent
scale without a decoder to compare against raw state directly).

Saves a checkpoint dict (weights + configs, not a bare state_dict --
`JEPAModule.__init__` needs `latent_dim`/`hidden_dim` before
`load_state_dict()` can work) to `WorldModel/checkpoints/jepa.pt` by
default -- what Day 4 will load and freeze.

Usage:
  ./WorldModel/train.py
  ./WorldModel/train.py --epochs 15 --var-weight 0 --cov-weight 0 \\
      --checkpoint /tmp/ablation-throwaway.pt   # negative control: should collapse
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from pathlib import Path

import torch
import torch.optim as optim

from dataloader import DEFAULT_DATA_DIR, TrajectoryDataset, make_dataloader, resolve_device
from env import ACTION_DIM, STATE_DIM
from loss import VICRegConfig, vicreg_loss
from models import JEPAConfig, JEPAModule

DEFAULT_CHECKPOINT = Path(__file__).resolve().parent / "checkpoints" / "jepa.pt"


@dataclass(frozen=True)
class TrainConfig:
    epochs: int = 75
    lr: float = 1e-3
    batch_size: int = 256
    seed: int = 0
    rollout_horizon: int = 20
    rollout_n_trajectories: int = 64


def run_epoch(
    model: JEPAModule,
    loader,
    vicreg_config: VICRegConfig,
    device: torch.device,
    optimizer: optim.Optimizer | None = None,
) -> dict[str, float]:
    """One pass over `loader`. Trains (backward + EMA update) if
    `optimizer` is given, otherwise runs a no_grad validation pass.
    Shared between train/val so both follow byte-for-byte the same forward
    path -- only whether gradients flow differs."""
    training = optimizer is not None
    model.encoder.train(training)
    model.predictor.train(training)
    # target_encoder deliberately never has .train()/.eval() called on it
    # here -- calling bare model.train() would recurse into it too (it's a
    # registered submodule), but it has no mode-dependent behavior to begin
    # with (LayerNorm carries no running buffers, see models.py) and is
    # never part of this loop's backward pass.

    totals = {"loss": 0.0, "inv": 0.0, "var": 0.0, "cov": 0.0, "std_target_mean": 0.0}
    n_batches = 0

    grad_context = torch.enable_grad() if training else torch.no_grad()
    with grad_context:
        for s_t, a_t, s_next in loader:
            s_t, a_t, s_next = s_t.to(device), a_t.to(device), s_next.to(device)

            if training:
                optimizer.zero_grad()

            z_pred = model.forward_online(s_t, a_t)
            z_target = model.forward_target(s_next)
            losses = vicreg_loss(z_pred, z_target, vicreg_config)

            if training:
                losses["loss"].backward()
                optimizer.step()
                model.update_target_ema()

            for key in totals:
                totals[key] += losses[key].item()
            n_batches += 1

    return {key: total / n_batches for key, total in totals.items()}


@torch.no_grad()
def rollout_check(
    model: JEPAModule,
    dataset: TrajectoryDataset,
    horizon: int,
    n_trajectories: int,
    device: torch.device,
) -> dict:
    """Validate the Day 3 deliverable in latent space: self-feed the
    predictor `horizon` steps (no teacher forcing) and check it doesn't
    diverge. Reaches directly into `dataset.states`/`.actions` (bypassing
    the flattened per-transition `__getitem__`) since it needs whole
    trajectories, not individual transitions.
    """
    horizon = min(horizon, dataset.horizon)
    n_trajectories = min(n_trajectories, dataset.n_trajectories)

    idx = torch.randperm(dataset.n_trajectories)[:n_trajectories].numpy()
    s0 = torch.from_numpy(dataset.states[idx, 0]).to(device)
    actions = torch.from_numpy(dataset.actions[idx, :horizon]).to(device)

    z = model.encoder(s0)
    norm_trace = [z.norm(dim=-1).mean().item()]
    for t in range(horizon):
        z = model.predictor(z, actions[:, t])
        norm_trace.append(z.norm(dim=-1).mean().item())

    finite = bool(torch.isfinite(z).all())

    s_final_true = torch.from_numpy(dataset.states[idx, horizon]).to(device)
    z_final_target = model.target_encoder(s_final_true)
    drift = (z - z_final_target).norm(dim=-1).mean().item()

    # Context baseline: distance between two independently sampled
    # trajectories' target latents at t=0, so `drift` has a scale to be
    # judged against instead of being a bare, uninterpretable number.
    other_idx = torch.randperm(dataset.n_trajectories)[:n_trajectories].numpy()
    z_a = model.target_encoder(torch.from_numpy(dataset.states[idx, 0]).to(device))
    z_b = model.target_encoder(torch.from_numpy(dataset.states[other_idx, 0]).to(device))
    baseline = (z_a - z_b).norm(dim=-1).mean().item()

    return {
        "horizon": horizon,
        "finite": finite,
        "norm_trace": norm_trace,
        "final_drift_vs_target": drift,
        "random_pair_baseline": baseline,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)

    ap.add_argument("--epochs", type=int, default=TrainConfig().epochs)
    ap.add_argument("--lr", type=float, default=TrainConfig().lr)
    ap.add_argument("--batch-size", type=int, default=TrainConfig().batch_size)
    ap.add_argument("--seed", type=int, default=TrainConfig().seed)
    ap.add_argument("--rollout-horizon", type=int, default=TrainConfig().rollout_horizon)
    ap.add_argument("--rollout-trajectories", type=int, default=TrainConfig().rollout_n_trajectories)

    ap.add_argument("--latent-dim", type=int, default=JEPAConfig().latent_dim)
    ap.add_argument("--hidden-dim", type=int, default=JEPAConfig().hidden_dim)
    ap.add_argument("--ema-tau", type=float, default=JEPAConfig().ema_tau)

    ap.add_argument("--inv-weight", type=float, default=VICRegConfig().inv_weight)
    ap.add_argument("--var-weight", type=float, default=VICRegConfig().var_weight)
    ap.add_argument("--cov-weight", type=float, default=VICRegConfig().cov_weight)
    ap.add_argument("--gamma", type=float, default=VICRegConfig().gamma)
    ap.add_argument("--eps", type=float, default=VICRegConfig().eps)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    train_config = TrainConfig(
        epochs=args.epochs,
        lr=args.lr,
        batch_size=args.batch_size,
        seed=args.seed,
        rollout_horizon=args.rollout_horizon,
        rollout_n_trajectories=args.rollout_trajectories,
    )
    jepa_config = JEPAConfig(latent_dim=args.latent_dim, hidden_dim=args.hidden_dim, ema_tau=args.ema_tau)
    vicreg_config = VICRegConfig(
        inv_weight=args.inv_weight,
        var_weight=args.var_weight,
        cov_weight=args.cov_weight,
        gamma=args.gamma,
        eps=args.eps,
    )
    device = resolve_device()

    train_npz = args.data_dir / "train.npz"
    val_npz = args.data_dir / "val.npz"
    if not train_npz.exists() or not val_npz.exists():
        raise SystemExit(f"{args.data_dir} missing train/val.npz — run ./WorldModel/dataset.py first")

    train_loader = make_dataloader(train_npz, batch_size=train_config.batch_size, shuffle=True)
    val_loader = make_dataloader(val_npz, batch_size=train_config.batch_size, shuffle=False)
    val_dataset: TrajectoryDataset = val_loader.dataset  # type: ignore[assignment]

    model = JEPAModule(jepa_config).to(device)
    # Only the trainable submodules -- target_encoder is EMA-updated only,
    # never by gradient descent (see models.py::update_target_ema).
    optimizer = optim.Adam(
        list(model.encoder.parameters()) + list(model.predictor.parameters()), lr=train_config.lr
    )

    print(f"train.py: state_dim={STATE_DIM} action_dim={ACTION_DIM} device={device}")
    print(f"  jepa_config: {jepa_config}")
    print(f"  vicreg_config: {vicreg_config}")
    print(f"  train_config: {train_config}")

    val_metrics: dict[str, float] = {}
    for epoch in range(1, train_config.epochs + 1):
        train_metrics = run_epoch(model, train_loader, vicreg_config, device, optimizer=optimizer)
        val_metrics = run_epoch(model, val_loader, vicreg_config, device, optimizer=None)

        print(
            f"epoch {epoch:3d}/{train_config.epochs}  "
            f"train: loss={train_metrics['loss']:.4f} inv={train_metrics['inv']:.4f} "
            f"var={train_metrics['var']:.4f} cov={train_metrics['cov']:.4f} | "
            f"val: loss={val_metrics['loss']:.4f} inv={val_metrics['inv']:.4f} "
            f"var={val_metrics['var']:.4f} cov={val_metrics['cov']:.4f} "
            f"std_target_mean={val_metrics['std_target_mean']:.4f}"
        )
        if val_metrics["std_target_mean"] < 0.1 * vicreg_config.gamma:
            print("  WARNING: std_target_mean has collapsed toward 0 — representation collapse likely")

    args.checkpoint.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "model_state_dict": model.state_dict(),
            "jepa_config": asdict(jepa_config),
            "vicreg_config": asdict(vicreg_config),
            "epochs_trained": train_config.epochs,
            "final_val_std_target_mean": val_metrics["std_target_mean"],
            "final_val_loss": val_metrics["loss"],
        },
        args.checkpoint,
    )
    print(f"  checkpoint saved to {args.checkpoint}")

    check = rollout_check(
        model, val_dataset, train_config.rollout_horizon, train_config.rollout_n_trajectories, device
    )
    norm_ratio = check["norm_trace"][-1] / max(check["norm_trace"][0], 1e-8)
    print(
        f"rollout_check: horizon={check['horizon']} finite={check['finite']} "
        f"norm[0]={check['norm_trace'][0]:.4f} norm[-1]={check['norm_trace'][-1]:.4f} ratio={norm_ratio:.2f}"
    )
    print(
        f"  final_drift_vs_target={check['final_drift_vs_target']:.4f} "
        f"random_pair_baseline={check['random_pair_baseline']:.4f}"
    )
    if norm_ratio > 5.0:
        print("  WARNING: latent norm grew >5x over the rollout horizon — predictor may be diverging")
    if not check["finite"]:
        print("  WARNING: rollout produced non-finite latents")


if __name__ == "__main__":
    main()
