#!/usr/bin/env python3
"""models.py — JEPA core: Encoder, EMA target encoder, latent Predictor.

Day 2 of the World Model (JEPA + MPC) research spike (see
`WorldModel/README.md`): three networks that predict entirely in latent
space, never reconstructing raw state.

- `Encoder` E_theta: raw state -> latent z_t. Gradients active.
- `JEPAModule.target_encoder` E_theta_bar: a `copy.deepcopy` of `Encoder`,
  frozen (`requires_grad=False`) and updated only by `update_target_ema()`,
  never by backprop. Gives the predictor a stable target instead of a
  moving, jointly-optimized one — the standard BYOL/I-JEPA trick.
- `LatentPredictor` P_phi: (z_t, a_t) -> latent-space estimate of z_{t+1}.

LayerNorm, not BatchNorm, throughout. Two reasons: (1) `TrajectoryDataset`
transitions are shuffled i.i.d. by the DataLoader, so batch statistics would
leak across otherwise-independent transitions — the same failure mode
BYOL's analysis flags for two-tower online/EMA setups; (2) LayerNorm works
correctly even at batch_size=1, BatchNorm doesn't.

One thing the final LayerNorm on the encoder's latent output does NOT do:
prevent representation collapse. It normalizes per sample, across the
latent_dim axis — a batch of identical latent vectors still satisfies that
constraint. Day 3's anti-collapse term (VICReg-style) operates on a
different axis entirely (per feature, across the batch). Collapse-avoidance
is Day 3's job, not this file's.

Run directly for a structural smoke test against real STATE_DIM/ACTION_DIM:
forward shapes, a real gradient step on the online encoder, then confirm
`update_target_ema()` actually moves the target weights (a no-op EMA step
against an unmoved online encoder wouldn't test anything).

Usage:
  ./WorldModel/models.py
  ./WorldModel/models.py --ema-tau 0.9 --seed 1
"""
from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass

import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim

from dataloader import resolve_device
from env import ACTION_DIM, STATE_DIM


@dataclass(frozen=True)
class JEPAConfig:
    latent_dim: int = 32
    hidden_dim: int = 128
    ema_tau: float = 0.99


class Encoder(nn.Module):
    """Raw state -> latent. LayerNorm/GELU stack, no BatchNorm (see module docstring)."""

    def __init__(self, config: JEPAConfig = JEPAConfig()):
        super().__init__()
        d = config.hidden_dim
        self.net = nn.Sequential(
            nn.Linear(STATE_DIM, d),
            nn.LayerNorm(d),
            nn.GELU(),
            nn.Linear(d, d),
            nn.LayerNorm(d),
            nn.GELU(),
            nn.Linear(d, config.latent_dim),
            nn.LayerNorm(config.latent_dim),
        )

    def forward(self, state: torch.Tensor) -> torch.Tensor:
        return self.net(state)


class LatentPredictor(nn.Module):
    """(z_t, a_t) -> predicted z_{t+1}, entirely within latent space."""

    def __init__(self, config: JEPAConfig = JEPAConfig()):
        super().__init__()
        d = config.hidden_dim
        self.net = nn.Sequential(
            nn.Linear(config.latent_dim + ACTION_DIM, d),
            nn.LayerNorm(d),
            nn.GELU(),
            nn.Linear(d, d),
            nn.LayerNorm(d),
            nn.GELU(),
            nn.Linear(d, config.latent_dim),  # no final LayerNorm -- see module docstring
        )

    def forward(self, z: torch.Tensor, action: torch.Tensor) -> torch.Tensor:
        return self.net(torch.cat([z, action], dim=-1))


class JEPAModule(nn.Module):
    """Owns the online encoder, EMA target encoder, and predictor as one unit."""

    def __init__(self, config: JEPAConfig = JEPAConfig()):
        super().__init__()
        self.config = config
        self.encoder = Encoder(config)
        self.predictor = LatentPredictor(config)

        self.target_encoder = copy.deepcopy(self.encoder)
        for p in self.target_encoder.parameters():
            p.requires_grad = False
        self.target_encoder.eval()

    def forward_online(self, s_t: torch.Tensor, a_t: torch.Tensor) -> torch.Tensor:
        return self.predictor(self.encoder(s_t), a_t)

    @torch.no_grad()
    def forward_target(self, s_next: torch.Tensor) -> torch.Tensor:
        return self.target_encoder(s_next)

    @torch.no_grad()
    def update_target_ema(self) -> None:
        """theta_bar <- tau * theta_bar + (1 - tau) * theta.

        Only .parameters() need updating -- LayerNorm carries no running
        buffers (unlike BatchNorm-based EMA targets in classic BYOL/MoCo),
        so there's nothing else to sync.
        """
        tau = self.config.ema_tau
        for target_p, online_p in zip(self.target_encoder.parameters(), self.encoder.parameters()):
            target_p.data.mul_(tau).add_(online_p.data, alpha=1.0 - tau)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--latent-dim", type=int, default=JEPAConfig().latent_dim)
    ap.add_argument("--hidden-dim", type=int, default=JEPAConfig().hidden_dim)
    ap.add_argument("--ema-tau", type=float, default=JEPAConfig().ema_tau)
    ap.add_argument("--lr", type=float, default=0.1,
                     help="deliberately large -- smoke test, not real training")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    config = JEPAConfig(latent_dim=args.latent_dim, hidden_dim=args.hidden_dim, ema_tau=args.ema_tau)
    device = resolve_device()

    model = JEPAModule(config).to(device)
    print(f"JEPAModule: state_dim={STATE_DIM} action_dim={ACTION_DIM} "
          f"latent_dim={config.latent_dim} hidden_dim={config.hidden_dim} ema_tau={config.ema_tau}")
    print(f"  device: {device}")

    s_t = torch.randn(args.batch_size, STATE_DIM, device=device)
    a_t = torch.randn(args.batch_size, ACTION_DIM, device=device)
    s_next = torch.randn(args.batch_size, STATE_DIM, device=device)

    z_pred = model.forward_online(s_t, a_t)
    z_target = model.forward_target(s_next)
    print(f"  forward_online -> {tuple(z_pred.shape)}, forward_target -> {tuple(z_target.shape)}")
    assert z_pred.shape == (args.batch_size, config.latent_dim)
    assert z_target.shape == (args.batch_size, config.latent_dim)
    assert torch.isfinite(z_pred).all() and torch.isfinite(z_target).all()
    assert all(not p.requires_grad for p in model.target_encoder.parameters())
    print("  shape/finiteness/frozen-target checks passed")

    # One real gradient step on the ONLINE encoder only -- gives EMA
    # something nonzero to pull toward. A no-op EMA step against an
    # unmoved online encoder wouldn't test anything.
    target_snapshot = [p.detach().clone() for p in model.target_encoder.parameters()]
    optimizer = optim.SGD(model.encoder.parameters(), lr=args.lr)
    loss = F.mse_loss(z_pred, z_target.detach())
    loss.backward()
    optimizer.step()
    print(f"  online-encoder MSE loss before EMA step: {loss.item():.6f}")

    model.update_target_ema()
    deltas = [(after - before).abs().max().item()
              for before, after in zip(target_snapshot, model.target_encoder.parameters())]
    moved = sum(d > 0 for d in deltas)
    all_finite = all(torch.isfinite(p).all() for p in model.target_encoder.parameters())
    print(f"  update_target_ema: {moved}/{len(deltas)} target param tensors moved, "
          f"max |delta|={max(deltas):.6g}, all finite={all_finite}")
    assert moved > 0
    assert all_finite

    print("smoke test passed")


if __name__ == "__main__":
    main()
