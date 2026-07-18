#!/usr/bin/env python3
"""loss.py — VICReg-style representation loss: invariance, variance, covariance.

Day 3 of the World Model (JEPA + MPC) research spike (see
`WorldModel/README.md`): the piece Day 2's `models.py` docstring explicitly
deferred. The encoder's final LayerNorm normalizes per sample, across the
latent_dim axis -- a batch of identical latent vectors still satisfies that
constraint, so it does nothing to stop representation collapse (every state
mapped to the same constant latent, trivially driving prediction MSE to
zero without learning real dynamics). VICReg's anti-collapse terms operate
on a different axis entirely: per feature, across the batch.

Three terms, computed over a batch of predicted latents `z_pred` (from
`JEPAModule.forward_online`) and target latents `z_target` (from
`JEPAModule.forward_target`):

- Invariance: MSE(z_pred, z_target) -- the actual prediction objective.
- Variance: a hinge loss forcing each latent dimension's per-batch std
  toward at least `gamma` -- the term that directly prevents collapse.
- Covariance: penalizes off-diagonal covariance between latent dimensions
  -- catches a subtler failure mode where variance stays high but every
  dimension collapses onto one shared direction (redundant, not collapsed).

`z_target` arrives already detached in practice (`forward_target` is
`@torch.no_grad()`-decorated), so the var/cov terms computed on it carry no
gradient -- they're diagnostics (`std_target_mean` especially, the
collapse-detection metric `train.py` watches every epoch), not optimization
pressure on the target encoder. Only the z_pred-side terms backprop into
`encoder`/`predictor`. That's intentional, not a bug to "fix" with a
redundant no_grad() wrapper.

Run directly for a structural smoke test: a deliberately collapsed batch of
latents should show high `var`, near-zero `std_target_mean`; a healthy
random batch should show the reverse; a batch that's high-variance but
every dimension a scalar multiple of the same direction should show high
`cov` even though collapse-style variance looks mostly fine -- proving the
covariance term catches redundancy the variance term alone would miss.

Usage:
  ./WorldModel/loss.py
  ./WorldModel/loss.py --var-weight 0 --cov-weight 0
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass

import torch
import torch.nn.functional as F

from dataloader import resolve_device


@dataclass(frozen=True)
class VICRegConfig:
    inv_weight: float = 10.0
    var_weight: float = 10.0
    cov_weight: float = 1.0
    gamma: float = 1.0
    eps: float = 1e-4


def off_diagonal(x: torch.Tensor) -> torch.Tensor:
    """Flattened off-diagonal elements of a square matrix, autograd-safe.

    Avoids in-place masking (e.g. `x.fill_diagonal_(0)`), which autograd
    rejects on a tensor that requires grad, via a reshape stride trick:
    drop the last element, reshape to (n-1, n+1) so the diagonal lands in
    column 0 of every row, then drop that column.
    """
    n, m = x.shape
    assert n == m
    return x.flatten()[:-1].view(n - 1, n + 1)[:, 1:].flatten()


def _variance_term(z: torch.Tensor, gamma: float, eps: float) -> torch.Tensor:
    """Hinge loss: mean(relu(gamma - std(z, dim=0))), per feature across
    the batch. eps inside the sqrt keeps the gradient finite as a
    dimension's variance approaches zero (d/dx sqrt(x) -> inf at x=0)."""
    std = torch.sqrt(z.var(dim=0) + eps)
    return F.relu(gamma - std).mean()


def _covariance_term(z: torch.Tensor) -> torch.Tensor:
    """Sum of squared off-diagonal covariance entries, normalized by
    latent_dim. Bessel's correction (N-1) for an unbiased estimator."""
    batch_size, latent_dim = z.shape
    z_centered = z - z.mean(dim=0)
    cov = (z_centered.T @ z_centered) / (batch_size - 1)
    return (off_diagonal(cov) ** 2).sum() / latent_dim


def vicreg_loss(
    z_pred: torch.Tensor,
    z_target: torch.Tensor,
    config: VICRegConfig = VICRegConfig(),
) -> dict[str, torch.Tensor]:
    """VICReg-style loss over a batch of predicted/target latents.

    `z_target` is expected to already be detached (e.g. from
    `JEPAModule.forward_target()`, which is `@torch.no_grad()`-decorated)
    -- see module docstring for why the var/cov terms on it are diagnostics
    only. `std_target_mean` is the collapse-detection metric: near `gamma`
    means healthy, near zero means the encoder has collapsed.
    """
    inv = F.mse_loss(z_pred, z_target)

    var = _variance_term(z_pred, config.gamma, config.eps) + _variance_term(
        z_target, config.gamma, config.eps
    )
    cov = _covariance_term(z_pred) + _covariance_term(z_target)

    loss = config.inv_weight * inv + config.var_weight * var + config.cov_weight * cov

    std_target_mean = torch.sqrt(z_target.var(dim=0) + config.eps).mean()

    return {"loss": loss, "inv": inv, "var": var, "cov": cov, "std_target_mean": std_target_mean}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--batch-size", type=int, default=256)
    ap.add_argument("--latent-dim", type=int, default=32, help="mirrors JEPAConfig.latent_dim")
    ap.add_argument("--inv-weight", type=float, default=VICRegConfig().inv_weight)
    ap.add_argument("--var-weight", type=float, default=VICRegConfig().var_weight)
    ap.add_argument("--cov-weight", type=float, default=VICRegConfig().cov_weight)
    ap.add_argument("--gamma", type=float, default=VICRegConfig().gamma)
    ap.add_argument("--eps", type=float, default=VICRegConfig().eps)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    config = VICRegConfig(
        inv_weight=args.inv_weight,
        var_weight=args.var_weight,
        cov_weight=args.cov_weight,
        gamma=args.gamma,
        eps=args.eps,
    )
    device = resolve_device()
    B, D = args.batch_size, args.latent_dim
    print(f"vicreg_loss smoke test: batch_size={B} latent_dim={D} device={device}")
    print(f"  config: {config}")

    # off_diagonal correctness: known 3x3 matrix, exact element count and set.
    m = torch.arange(9, dtype=torch.float32, device=device).view(3, 3)
    od = off_diagonal(m)
    assert od.numel() == 3 * 2
    assert set(od.tolist()) == {1.0, 2.0, 3.0, 5.0, 6.0, 7.0}
    print("  off_diagonal: element count and set check passed")

    # Collapsed: near-constant across the batch -> var should be high (near
    # gamma per term), std_target_mean should be near zero.
    z_collapsed = torch.zeros(B, D, device=device) + 1e-6 * torch.randn(B, D, device=device)
    collapsed = vicreg_loss(z_collapsed, z_collapsed, config)
    print(
        f"  collapsed:  var={collapsed['var'].item():.4f} "
        f"cov={collapsed['cov'].item():.4f} std_target_mean={collapsed['std_target_mean'].item():.6f}"
    )
    assert collapsed["std_target_mean"].item() < 0.1
    assert collapsed["var"].item() > config.gamma  # both terms (pred+target) should fire near-fully

    # Healthy: full-variance, roughly decorrelated random latents -> var
    # near zero, std_target_mean near 1.
    z_healthy = torch.randn(B, D, device=device)
    healthy = vicreg_loss(z_healthy, z_healthy, config)
    print(
        f"  healthy:    var={healthy['var'].item():.4f} "
        f"cov={healthy['cov'].item():.4f} std_target_mean={healthy['std_target_mean'].item():.4f}"
    )
    assert healthy["std_target_mean"].item() > 0.5
    assert healthy["var"].item() < 0.3 * config.gamma

    # Correlated-but-not-collapsed: full magnitude, but every dimension is
    # a scalar multiple of the same fixed direction -- variance alone
    # doesn't clearly flag this, cov should catch the redundancy.
    direction = torch.randn(1, D, device=device)
    z_correlated = torch.randn(B, 1, device=device) * direction
    correlated = vicreg_loss(z_correlated, z_correlated, config)
    print(
        f"  correlated: var={correlated['var'].item():.4f} "
        f"cov={correlated['cov'].item():.4f} std_target_mean={correlated['std_target_mean'].item():.4f}"
    )
    assert correlated["cov"].item() > 10 * healthy["cov"].item()

    for name, out in [("collapsed", collapsed), ("healthy", healthy), ("correlated", correlated)]:
        assert torch.isfinite(out["loss"]).all(), f"{name} produced a non-finite loss"

    print("smoke test passed")


if __name__ == "__main__":
    main()
