#!/usr/bin/env python3
"""Forward metric panel for the WorldModel JEPA on synthetic-1/f data (Phase B).

Trains a small JEPA (`eeg_jepa.EEGJEPAModule`) on `synthetic_1f` transitions, then
reports a PANEL of forward-quality metrics. No single number is trusted — the panel
is the point (see RESEARCH_spectral_geometry.md §"No label-free metric is a trusted
oracle"). This iteration establishes the panel infrastructure; the A/B over
transform arms is a later iteration that reuses `evaluate()`.

Metrics (this iteration):
  - pred_error_1step  : MSE between the predictor's next-latent and the EMA target
                        encoder's next-latent (the JEPA's own forward objective,
                        measured on held-out data). The forward-prediction anchor.
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

DEFERRED to the next Benchmark iteration (each needs new machinery, ledgered):
  - multi-step latent rollout error   (needs sequential-trajectory synthetic data)
  - goal-conditioned MPC/CEM success  (needs a latent-space planner + true-env rollout)
  - LiDAR (Thilak et al. 2024)        (needs the clean/augmented surrogate-class setup)

Synthetic only. No real EEG, no hardware, no app wiring, no network. Seeded → reproducible.

Usage:
  venv/bin/python WorldModel/forward_eval.py --n 512 --epochs 30 --seed 0 --mode signal
  venv/bin/python WorldModel/forward_eval.py --smoke-test
"""
from __future__ import annotations

import argparse
import json
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
from synthetic_1f import generate, write_jsonl  # noqa: E402

FACTOR_NAMES = ["pos", "vel", "chi", "peak_amp", "offset"]


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


def _rankme(Z: torch.Tensor, eps: float = 1e-7) -> float:
    """Garrido 2023 effective rank: exp(entropy of normalized singular values)."""
    s = torch.linalg.svdvals(Z - Z.mean(0, keepdim=True))
    p = s / (s.sum() + eps)
    entropy = -(p * torch.log(p + eps)).sum()
    return float(torch.exp(entropy))


def _alpha_req(Z: torch.Tensor, eps: float = 1e-12) -> float:
    """Agrawal 2022: power-law slope of the covariance eigenspectrum (log-log fit)."""
    Zc = (Z - Z.mean(0, keepdim=True)).double()
    cov = (Zc.T @ Zc) / max(1, len(Z) - 1)
    eig = torch.linalg.eigvalsh(cov).flip(0).clamp_min(eps)  # descending
    ranks = torch.arange(1, len(eig) + 1, dtype=torch.float64)
    A = torch.stack([torch.log(ranks), torch.ones_like(ranks)], dim=1)
    sol = torch.linalg.lstsq(A, torch.log(eig).unsqueeze(1)).solution
    return float(-sol[0, 0])


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


def evaluate(
    n: int = 512,
    mode: str = "signal",
    seed: int = 0,
    epochs: int = 30,
    latent_dim: int = 32,
    batch_size: int = 64,
    device: torch.device | None = None,
    verbose: bool = True,
) -> dict[str, Any]:
    """Train a JEPA on freshly-generated synthetic_1f data and return the panel."""
    _seed_everything(seed)
    device = device or resolve_device()

    records = generate(n, mode, seed)
    with tempfile.TemporaryDirectory(prefix="neuralcompose-fwdeval-") as directory:
        path = write_jsonl(records, Path(directory) / "data.jsonl")
        dataset = JEPATransitionDataset(path)
        loader = DataLoader(dataset, batch_size=min(batch_size, len(dataset)), shuffle=True)
        pre0, action0, _ = dataset[0]
        state_dim, action_dim = pre0.shape[-1], action0.shape[-1]

        config = EEGJEPAConfig(latent_dim=latent_dim)
        model, history = train_jepa(
            loader, state_dim, action_dim, config=config, epochs=epochs, device=device
        )

        factors = _read_factors(records)
        Z_pre, Z_post = _encode_all(model, dataset, device)
        var_term, cov_term = _vicreg_terms(Z_pre)
        alignment, uniformity = _alignment_uniformity(Z_pre, Z_post)

        panel = {
            "config": {"n": n, "mode": mode, "seed": seed, "epochs": epochs,
                       "latent_dim": latent_dim, "final_train_loss": history[-1]},
            "pred_error_1step": _pred_error_1step(model, dataset, device),
            "factor_recovery": _factor_recovery(Z_pre, factors, seed),
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
    a = evaluate(n=64, mode="signal", seed=0, epochs=3, latent_dim=16,
                 device=torch.device("cpu"), verbose=False)
    b = evaluate(n=64, mode="signal", seed=0, epochs=3, latent_dim=16,
                 device=torch.device("cpu"), verbose=False)

    # Determinism: same seed → identical panel.
    assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True), "non-deterministic"

    # Finiteness across the whole panel.
    for key in ("pred_error_1step", "rankme", "alpha_req", "vicreg_var",
                "vicreg_cov", "alignment", "uniformity"):
        assert np.isfinite(a[key]), f"{key} not finite: {a[key]}"
    for name, r2 in a["factor_recovery"].items():
        assert np.isfinite(r2), f"factor_recovery[{name}] not finite"

    # RankMe is an effective rank in (0, latent_dim].
    assert 0.0 < a["rankme"] <= 16.0 + 1e-6, f"rankme out of range: {a['rankme']}"
    # VICReg variance term is non-negative.
    assert a["vicreg_var"] >= 0.0
    # The chi probe exists and is reported (the information-destruction detector).
    assert "chi" in a["factor_recovery"]

    print(f"smoke test passed "
          f"(pred_err={a['pred_error_1step']:.4f}, rankme={a['rankme']:.2f}, "
          f"chi_R2={a['factor_recovery']['chi']:.3f}, "
          f"pos_R2={a['factor_recovery']['pos']:.3f})")


def main() -> None:
    parser = argparse.ArgumentParser(description="WorldModel JEPA forward metric panel")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--n", type=int, default=512)
    parser.add_argument("--mode", type=str, default="signal", choices=["signal", "nuisance"])
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--latent-dim", type=int, default=32)
    args = parser.parse_args()

    if args.smoke_test:
        smoke_test()
        return
    evaluate(n=args.n, mode=args.mode, seed=args.seed, epochs=args.epochs,
             latent_dim=args.latent_dim)


if __name__ == "__main__":
    main()
