#!/usr/bin/env python3
"""Controllable synthetic 1/f transition generator for the WorldModel forward benchmark.

Produces `JEPATransition` JSONL in the exact schema `eeg_jepa.JEPATransitionDataset`
consumes (id / timestamp / preActionWindow / actionVector / postActionWindow, each
window state = alphaPower, betaPower, thetaPower, channelPowers[2] → 5 features), but
with a **dial-able aperiodic exponent**, an injectable oscillatory peak, and **known
ground-truth latent factors** — so we can measure whether the 1/f log-transform is
compressing *signal* or *nuisance* (see `RESEARCH_spectral_geometry.md`).

Latent factors per trajectory  z = {pos, vel, chi, peak_amp, offset}:
  - `pos`, `vel`  — the TASK factors: evolve under the action; `pos` is what
    goal-conditioned MPC targets. These are the signal the JEPA must predict.
  - `chi`         — the aperiodic exponent (the 1/f slope). This is the dial:
      * mode="signal"   → chi modulates the velocity decay, so it drives dynamics.
      * mode="nuisance" → chi never affects pos/vel; it only colours the spectrum.
    That contrast is what makes "is 1/f signal?" *measurable*.
  - `peak_amp`    — an additive oscillatory peak on the alpha band (distractor).
  - `offset`      — the aperiodic offset (overall log-power level).

Observation render is deterministic: band power(f) = 10^offset · f^(-chi) (+ peak on
alpha), so a linear probe CAN recover `chi` from the observation — the aperiodic
factor-recovery target the decision rule guards.

Synthetic only. No real EEG, no hardware. Seeded → reproducible.

Usage:
  venv/bin/python WorldModel/synthetic_1f.py --out data/synth_1f.jsonl --n 512 --mode signal --seed 0
  venv/bin/python WorldModel/synthetic_1f.py --smoke-test
"""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any

# Representative band centre frequencies (Hz). Order matters only for the 1/f slope.
BANDS = {"theta": 6.0, "alpha": 10.0, "beta": 21.0}
SEQUENCE_LENGTH = 5
DT = 0.1


def _render_state(z: dict[str, float], t: int) -> dict[str, Any]:
    """Deterministically render the 5-feature band-power observation from latent z."""
    base = 10.0 ** z["offset"]
    theta = base * BANDS["theta"] ** (-z["chi"])
    alpha = base * BANDS["alpha"] ** (-z["chi"]) + z["peak_amp"]
    beta = base * BANDS["beta"] ** (-z["chi"])
    # Two "electrode" channels carry the task factors, so pos/vel are also
    # observable. ADDITIVE and independent of the 1/f carrier, since the earlier
    # multiplicative form defeated that stated intent: c0 = alpha*(1 + 0.10*pos)
    # left pos at 0.845% of c0's variance and vel at 0.0106% of c1's (node 19),
    # with 8.2:1 carrier leverage, so the encoder learned the held factors
    # (peak_amp 0.997, chi 0.950) and left vel at 0.033 (node 18). It also made
    # the nuisance impossible to perturb without destroying the task signal --
    # the minimum jitter depth that removed the free-prediction subsidy already
    # injected noise the size of the entire pos modulation (node 20).
    #
    # No gain constant here, deliberately: JEPATransitionDataset z-scores every
    # feature on train statistics, so any gain divides straight back out. The
    # 1.0 is a DC offset for positivity and is removed by the same z-scoring.
    c0 = 1.0 + z["pos"]
    c1 = 1.0 + z["vel"]
    return {
        "timestamp": 1_700_000_000.0 + t,
        "alphaPower": alpha,
        "betaPower": beta,
        "thetaPower": theta,
        "channelPowers": [c0, c1],
    }


def _step(z: dict[str, float], action: list[float], mode: str) -> dict[str, float]:
    """One transition. chi drives the velocity decay only in mode='signal'."""
    ax, ay = action[0], action[1]
    # In signal mode a steeper 1/f slope (higher chi) damps velocity more — chi is signal.
    decay = 0.90 - (0.30 * (z["chi"] - 1.0) if mode == "signal" else 0.0)
    decay = max(0.0, min(1.0, decay))
    vel = z["vel"] * decay + ax * DT
    pos = z["pos"] + vel * DT + 0.5 * ay * DT
    # chi / peak / offset are per-trajectory factors (held); only pos/vel evolve.
    return {"pos": pos, "vel": vel, "chi": z["chi"], "peak_amp": z["peak_amp"], "offset": z["offset"]}


def _sample_latent(rng: random.Random) -> dict[str, float]:
    return {
        "pos": rng.uniform(-1.0, 1.0),
        "vel": rng.uniform(-0.5, 0.5),
        "chi": rng.uniform(0.5, 2.0),          # aperiodic exponent range
        "peak_amp": rng.uniform(0.0, 0.5),      # oscillatory-peak amplitude (0 = none)
        "offset": rng.uniform(0.0, 0.5),        # aperiodic offset (log-power level)
    }


def generate(n: int, mode: str, seed: int) -> list[dict[str, Any]]:
    """Return `n` transition records (dicts) with known latent factors attached under `_latent`."""
    if mode not in ("signal", "nuisance"):
        raise ValueError(f"mode must be 'signal' or 'nuisance', got {mode!r}")
    rng = random.Random(seed)
    records: list[dict[str, Any]] = []
    for index in range(n):
        z = _sample_latent(rng)
        action = [rng.uniform(-1.0, 1.0), rng.uniform(-1.0, 1.0), float(index % 2)]
        pre = [_render_state(z, t) for t in range(SEQUENCE_LENGTH)]
        z_next = _step(z, action, mode)
        post = [_render_state(z_next, t) for t in range(SEQUENCE_LENGTH)]
        records.append({
            "id": f"00000000-0000-0000-0000-{index:012d}",
            "timestamp": 1_700_000_000.0 + index,
            "preActionWindow": pre,
            "actionVector": action,
            "postActionWindow": post,
            # Ground-truth latent factors — read by the Phase-B factor-recovery probes,
            # ignored by JEPATransitionDataset (which only reads the window/action fields).
            "_latent": {"pos": z["pos"], "vel": z["vel"], "chi": z["chi"],
                        "peak_amp": z["peak_amp"], "offset": z["offset"]},
        })
    return records


def write_jsonl(records: list[dict[str, Any]], path: str | Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as output:
        for record in records:
            output.write(json.dumps(record) + "\n")
    return path


def smoke_test() -> None:
    """Determinism, JEPATransitionDataset-loadability, and chi recoverability."""
    import sys
    import tempfile

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import torch  # noqa: E402
    from eeg_jepa import JEPATransitionDataset  # noqa: E402

    # 1. Determinism: same seed → identical bytes.
    a = json.dumps(generate(16, "signal", seed=0))
    b = json.dumps(generate(16, "signal", seed=0))
    assert a == b, "generator is not deterministic under a fixed seed"
    c = json.dumps(generate(16, "signal", seed=1))
    assert a != c, "different seeds should differ"

    with tempfile.TemporaryDirectory(prefix="neuralcompose-synth1f-") as directory:
        records = generate(64, "signal", seed=0)
        path = write_jsonl(records, Path(directory) / "synth.jsonl")

        # 2. Loadable by the real dataset with the expected shapes.
        dataset = JEPATransitionDataset(path)
        pre, action, post = dataset[0]
        assert pre.shape == (SEQUENCE_LENGTH, 5), f"pre shape {tuple(pre.shape)}"
        assert action.shape == (3,), f"action shape {tuple(action.shape)}"
        assert post.shape == (SEQUENCE_LENGTH, 5), f"post shape {tuple(post.shape)}"
        assert torch.isfinite(pre).all() and torch.isfinite(post).all()

        # 3. chi is linearly recoverable from the observation (factor-recovery target is
        #    well-posed). Fit least-squares chi ~ flattened pre-window; report R².
        xs = torch.stack([dataset[i][0].reshape(-1) for i in range(len(dataset))])
        xs = torch.cat([xs, torch.ones(len(dataset), 1)], dim=1)  # bias
        chi = torch.tensor([r["_latent"]["chi"] for r in records]).unsqueeze(1)
        weights = torch.linalg.lstsq(xs, chi).solution
        residual = chi - xs @ weights
        r2 = 1.0 - (residual.var() / chi.var()).item()
        assert r2 > 0.5, f"chi should be recoverable from the observation, R²={r2:.3f}"

        # 4. In 'signal' mode chi affects the post-state; in 'nuisance' it must not
        #    (same pos/vel evolution regardless of chi).
        z = {"pos": 0.2, "vel": 0.3, "chi": 1.8, "peak_amp": 0.1, "offset": 0.2}
        z_lo = {**z, "chi": 0.6}
        act = [0.5, -0.2, 0.0]
        sig_hi, sig_lo = _step(z, act, "signal"), _step(z_lo, act, "signal")
        nui_hi, nui_lo = _step(z, act, "nuisance"), _step(z_lo, act, "nuisance")
        assert abs(sig_hi["vel"] - sig_lo["vel"]) > 1e-6, "signal mode: chi must affect dynamics"
        assert abs(nui_hi["vel"] - nui_lo["vel"]) < 1e-9, "nuisance mode: chi must NOT affect dynamics"

        print(f"smoke test passed (chi-recovery R²={r2:.3f}, n={len(dataset)})")


def main() -> None:
    parser = argparse.ArgumentParser(description="Synthetic 1/f transition generator")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--out", type=str, default="data/synth_1f.jsonl")
    parser.add_argument("--n", type=int, default=512)
    parser.add_argument("--mode", type=str, default="signal", choices=["signal", "nuisance"])
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()

    if args.smoke_test:
        smoke_test()
        return
    base = Path(__file__).resolve().parent
    out = Path(args.out)
    if not out.is_absolute():
        out = base / out
    records = generate(args.n, args.mode, args.seed)
    write_jsonl(records, out)
    print(f"wrote {len(records)} records → {out}  (mode={args.mode}, seed={args.seed})")


if __name__ == "__main__":
    main()
