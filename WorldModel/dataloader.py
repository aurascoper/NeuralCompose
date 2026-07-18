#!/usr/bin/env python3
"""dataloader.py — PyTorch Dataset/DataLoader over generated trajectories.

Day 1 deliverable #3 of the World Model spike (see `WorldModel/README.md`):
"A PyTorch DataLoader that can aggressively batch these sequences." Flattens
each (states, actions) trajectory array into individual (s_t, a_t, s_next)
transitions — the exact shape Day 2's JEPA predictor loss will consume
(`P_phi(E_theta(s_t), a_t)` vs. `E_theta_bar(s_next)`).

Run directly for a sanity check against a generated split (run
`dataset.py` first): batch shapes/dtypes, which `torch` device a training
loop would select, and basic state/action range stats as a smoke test that
the data isn't degenerate.

Device note: this repo targets Apple Silicon (`CLAUDE.md`), so the GPU
backend is `mps`, not `cuda`.

Usage:
  ./WorldModel/dataloader.py
  ./WorldModel/dataloader.py --split val --batch-size 64
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, Dataset

DEFAULT_DATA_DIR = Path(__file__).resolve().parent / "data"


class TrajectoryDataset(Dataset):
    """Flattens (states[N,T+1,D], actions[N,T,A]) into (s_t, a_t, s_next) transitions."""

    def __init__(self, npz_path: Path):
        data = np.load(npz_path)
        self.states = data["states"]    # [N, T+1, state_dim]
        self.actions = data["actions"]  # [N, T, action_dim]
        n, t_plus_1, _ = self.states.shape
        self.n_trajectories = n
        self.horizon = t_plus_1 - 1

    def __len__(self) -> int:
        return self.n_trajectories * self.horizon

    def __getitem__(self, idx: int):
        traj_idx, t = divmod(idx, self.horizon)
        s_t = torch.from_numpy(self.states[traj_idx, t])
        a_t = torch.from_numpy(self.actions[traj_idx, t])
        s_next = torch.from_numpy(self.states[traj_idx, t + 1])
        return s_t, a_t, s_next


def make_dataloader(npz_path: Path, batch_size: int = 256, shuffle: bool = True) -> DataLoader:
    return DataLoader(TrajectoryDataset(npz_path), batch_size=batch_size, shuffle=shuffle)


def resolve_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    ap.add_argument("--split", choices=["train", "val"], default="train")
    ap.add_argument("--batch-size", type=int, default=256)
    args = ap.parse_args()

    npz_path = args.data_dir / f"{args.split}.npz"
    if not npz_path.exists():
        raise SystemExit(f"{npz_path} not found — run ./WorldModel/dataset.py first")

    loader = make_dataloader(npz_path, batch_size=args.batch_size)
    dataset: TrajectoryDataset = loader.dataset  # type: ignore[assignment]

    print(f"loaded {npz_path}")
    print(f"  trajectories={dataset.n_trajectories} horizon={dataset.horizon} -> {len(dataset)} transitions")

    device = resolve_device()
    print(f"  device: {device} (mps available: {torch.backends.mps.is_available()})")

    s_t, a_t, s_next = next(iter(loader))
    print(f"  batch shapes: s_t={tuple(s_t.shape)} a_t={tuple(a_t.shape)} s_next={tuple(s_next.shape)}")
    print(f"  dtypes: s_t={s_t.dtype} a_t={a_t.dtype} s_next={s_next.dtype}")

    all_states = dataset.states.reshape(-1, dataset.states.shape[-1])
    all_actions = dataset.actions.reshape(-1, dataset.actions.shape[-1])
    print("  state range (x, y, vx, vy):")
    print(f"    min: {all_states.min(axis=0)}")
    print(f"    max: {all_states.max(axis=0)}")
    print("  action range (ax, ay):")
    print(f"    min: {all_actions.min(axis=0)}")
    print(f"    max: {all_actions.max(axis=0)}")

    pos_std = all_states[:, :2].std(axis=0)
    if np.any(pos_std < 1e-3):
        print(f"  WARNING: position std {pos_std} looks degenerate (collapsed trajectories?)")
    else:
        print(f"  position std (x, y): {pos_std} -- looks non-degenerate")


if __name__ == "__main__":
    main()
