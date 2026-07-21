#!/usr/bin/env python3
"""Train an offline JEPA from the native Swift transition-capture JSONL.

This module is intentionally an offline consumer of
`JEPATransition` records written by `TransitionCaptureManager`. It has no
runtime connection to the macOS app: collect locally, inspect the resulting
JSONL, then train this model separately before considering any Core ML export.

Each data row has:
  preActionWindow:  [time][alphaPower, betaPower, thetaPower, channelPowers...]
  actionVector:     [maxCandidates / 3, temperature, hasStylePrompt]
  postActionWindow: same shape as preActionWindow

The encoder is a 1-D convolutional network suitable for later Core ML
conversion. The target encoder is an EMA copy with frozen gradients, and its
BatchNorm buffers are updated with the same EMA so target statistics do not
go stale while the online encoder learns.

Usage:
  venv/bin/python WorldModel/eeg_jepa.py --dataset ~/Documents/NeuralCompose/JEPATransitions/jepa_transitions.jsonl
  venv/bin/python WorldModel/eeg_jepa.py --smoke-test
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset


BASE_STATE_FIELDS = ("alphaPower", "betaPower", "thetaPower")


def resolve_device() -> torch.device:
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


class JEPATransitionDataset(Dataset[tuple[torch.Tensor, torch.Tensor, torch.Tensor]]):
    """Loads the Swift JSONL data set into validated, normalized tensors.

    Window tensors are returned as `(time_steps, channels)`, so a DataLoader
    yields `(batch, time_steps, channels)`, the public contract consumed by
    `JEPADynamicsEncoder`. Statistics include both sides of each transition,
    avoiding an arbitrary distinction between pre- and post-action signal
    scales while retaining a single stable normalization transform.
    """

    def __init__(self, jsonl_path: str | Path, normalize: bool = True,
                 mean: torch.Tensor | None = None, std: torch.Tensor | None = None,
                 clip_sigma: float = 8.0, log_features: bool = False,
                 log_epsilon: float = 1e-6, symlog: bool = False):
        if clip_sigma <= 0:
            raise ValueError(f"clip_sigma must be positive, got {clip_sigma}")
        if log_epsilon <= 0:
            raise ValueError(f"log_epsilon must be positive, got {log_epsilon}")
        if log_features and symlog:
            raise ValueError("log_features and symlog are mutually exclusive input-space transforms")
        self.path = Path(jsonl_path)
        self.normalize = normalize
        self.clip_sigma = clip_sigma
        self.log_features = log_features
        self.log_epsilon = log_epsilon
        self.symlog = symlog
        self.transitions = self._load_records()
        self.pre_action_windows, self.actions, self.post_action_windows = self._make_tensors()

        if log_features:
            # EEG band/channel powers are heavy-tailed (~1/f): raw theta energy dwarfs
            # beta, so a plain z-score lets high-power bands swamp low-power ones. Log-
            # compress the dynamic range first. Powers are >= 0, but clamp_min(0) guards
            # any future/FP negative before log; the stats below are then computed in
            # log-space and __getitem__ normalizes the (now log-space) stored windows.
            self.pre_action_windows = torch.log(self.pre_action_windows.clamp_min(0.0) + self.log_epsilon)
            self.post_action_windows = torch.log(self.post_action_windows.clamp_min(0.0) + self.log_epsilon)
        elif symlog:
            # Signed log1p: same heavy-tail compression as log_features, but WITHOUT the
            # epsilon-floor artifact. log_features maps a zero/near-dead channel to
            # log(log_epsilon) ~= -13.8, a large negative outlier the z-score then
            # amplifies; log1p(0)=0 preserves it exactly. sign() keeps it valid for any
            # FP-negative power. Stats below are computed in this space and __getitem__
            # normalizes the (now symlog-space) stored windows.
            self.pre_action_windows = torch.sign(self.pre_action_windows) * torch.log1p(self.pre_action_windows.abs())
            self.post_action_windows = torch.sign(self.post_action_windows) * torch.log1p(self.post_action_windows.abs())

        self.sequence_length = self.pre_action_windows.shape[1]
        self.state_dim = self.pre_action_windows.shape[2]
        self.action_dim = self.actions.shape[1]
        spatial_channels = self.state_dim - len(BASE_STATE_FIELDS)
        self.state_feature_names = list(BASE_STATE_FIELDS) + [
            f"channelPower[{index}]" for index in range(spatial_channels)
        ]

        if (mean is None) != (std is None):
            raise ValueError("provide both mean and std, or neither")
        if mean is not None:
            # Reuse externally-supplied statistics (e.g. the TRAIN set's) so a
            # validation/holdout split is z-scored on the *same* scale rather
            # than recomputing its own — recomputing leaks the val distribution
            # into its own normalization and makes val loss optimistic.
            mean = torch.as_tensor(mean, dtype=torch.float32)
            std = torch.as_tensor(std, dtype=torch.float32)
            if mean.shape != (self.state_dim,) or std.shape != (self.state_dim,):
                raise ValueError(
                    f"mean/std must have shape ({self.state_dim},) to match state_dim, "
                    f"got {tuple(mean.shape)}/{tuple(std.shape)}"
                )
            self.mean = mean
            self.std = std.clamp_min(1e-6)
        else:
            all_states = torch.cat(
                [
                    self.pre_action_windows.reshape(-1, self.state_dim),
                    self.post_action_windows.reshape(-1, self.state_dim),
                ],
                dim=0,
            )
            self.mean = all_states.mean(dim=0)
            self.std = all_states.std(dim=0, unbiased=False).clamp_min(1e-6)

    def _load_records(self) -> list[dict[str, Any]]:
        if not self.path.is_file():
            raise FileNotFoundError(f"JEPA transition JSONL not found: {self.path}")

        records: list[dict[str, Any]] = []
        with self.path.open("r", encoding="utf-8") as source:
            for line_number, line in enumerate(source, start=1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as error:
                    raise ValueError(f"invalid JSON at {self.path}:{line_number}: {error.msg}") from error
                if not isinstance(record, dict):
                    raise ValueError(f"expected object at {self.path}:{line_number}")
                records.append(record)

        if not records:
            raise ValueError(f"no transitions found in {self.path}")
        return records

    @staticmethod
    def _state_vector(state: Any, line_number: int, window_name: str, index: int) -> list[float]:
        if not isinstance(state, dict):
            raise ValueError(f"{window_name}[{index}] at JSONL line {line_number} must be an object")
        try:
            vector = [float(state[name]) for name in BASE_STATE_FIELDS]
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(
                f"{window_name}[{index}] at JSONL line {line_number} is missing a valid band-power field"
            ) from error

        channel_powers = state.get("channelPowers", [])
        if not isinstance(channel_powers, list):
            raise ValueError(f"{window_name}[{index}].channelPowers at JSONL line {line_number} must be an array")
        try:
            vector.extend(float(value) for value in channel_powers)
        except (TypeError, ValueError) as error:
            raise ValueError(
                f"{window_name}[{index}].channelPowers at JSONL line {line_number} contains a non-numeric value"
            ) from error

        if not vector or not all(math.isfinite(value) for value in vector):
            raise ValueError(f"{window_name}[{index}] at JSONL line {line_number} contains a non-finite value")
        return vector

    @staticmethod
    def _action_vector(action: Any, line_number: int) -> list[float]:
        if not isinstance(action, list) or not action:
            raise ValueError(f"actionVector at JSONL line {line_number} must be a non-empty array")
        try:
            vector = [float(value) for value in action]
        except (TypeError, ValueError) as error:
            raise ValueError(f"actionVector at JSONL line {line_number} contains a non-numeric value") from error
        if not all(math.isfinite(value) for value in vector):
            raise ValueError(f"actionVector at JSONL line {line_number} contains a non-finite value")
        return vector

    def _make_tensors(self) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        pre_windows: list[list[list[float]]] = []
        actions: list[list[float]] = []
        post_windows: list[list[list[float]]] = []
        expected_sequence_length: int | None = None
        expected_state_dim: int | None = None
        expected_action_dim: int | None = None

        for line_number, record in enumerate(self.transitions, start=1):
            pre = record.get("preActionWindow")
            post = record.get("postActionWindow")
            if not isinstance(pre, list) or not isinstance(post, list) or not pre or not post:
                raise ValueError(f"JSONL line {line_number} must contain non-empty preActionWindow and postActionWindow arrays")
            if len(pre) != len(post):
                raise ValueError(f"JSONL line {line_number} has unequal pre/post window lengths")

            pre_vectors = [self._state_vector(state, line_number, "preActionWindow", index) for index, state in enumerate(pre)]
            post_vectors = [self._state_vector(state, line_number, "postActionWindow", index) for index, state in enumerate(post)]
            if any(len(vector) != len(pre_vectors[0]) for vector in pre_vectors + post_vectors):
                raise ValueError(f"JSONL line {line_number} has inconsistent state feature widths")
            action = self._action_vector(record.get("actionVector"), line_number)

            if expected_sequence_length is None:
                expected_sequence_length = len(pre_vectors)
                expected_state_dim = len(pre_vectors[0])
                expected_action_dim = len(action)
            elif (
                len(pre_vectors) != expected_sequence_length
                or len(pre_vectors[0]) != expected_state_dim
                or len(action) != expected_action_dim
            ):
                raise ValueError(
                    f"JSONL line {line_number} does not match the first row's fixed window/action schema"
                )

            pre_windows.append(pre_vectors)
            actions.append(action)
            post_windows.append(post_vectors)

        return (
            torch.tensor(pre_windows, dtype=torch.float32),
            torch.tensor(actions, dtype=torch.float32),
            torch.tensor(post_windows, dtype=torch.float32),
        )

    def __len__(self) -> int:
        return len(self.transitions)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        pre = self.pre_action_windows[index]
        post = self.post_action_windows[index]
        if self.normalize:
            # Clamp the z-scored output: a near-dead channel whose std sits just
            # above the 1e-6 floor would otherwise divide a tiny deviation by a
            # tiny std and emit pathologically large (but finite) magnitudes that
            # dominate the latent space. The floor stops NaNs; this stops blowups.
            pre = ((pre - self.mean) / self.std).clamp(-self.clip_sigma, self.clip_sigma)
            post = ((post - self.mean) / self.std).clamp(-self.clip_sigma, self.clip_sigma)
        return pre, self.actions[index], post

    def export_normalization_constants(self, filepath: str | Path = "eeg_norm_stats.json") -> Path:
        """Write the per-feature normalization constants to JSON, for inspection.

        Reproducibility / cross-checking only — deliberately NOT for the live
        app. The shipping intent classifier (`CoreMLIntentClassifier`) consumes
        raw 512-sample electrode windows, not these band-power/channel-power
        features, so these stats do not belong on that path. A real-EEG JEPA
        needs its own separately-validated encoder before anything on-device
        consumes it (see WorldModel/EEG_INTEGRATION_DESIGN.md).
        """
        path = Path(filepath)
        path.write_text(json.dumps({
            "state_feature_names": self.state_feature_names,
            "mean": self.mean.tolist(),
            "std": self.std.tolist(),
            "clip_sigma": self.clip_sigma,
            "log_features": self.log_features,
            "log_epsilon": self.log_epsilon,
        }, indent=2))
        return path


@dataclass(frozen=True)
class EEGJEPAConfig:
    latent_dim: int = 64
    hidden_dim: int = 128
    ema_tau: float = 0.99


class JEPADynamicsEncoder(nn.Module):
    """ANE-friendly Conv1d encoder from `(batch, time, channels)` to latent."""

    def __init__(self, in_channels: int, latent_dim: int = 64):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv1d(in_channels, 32, kernel_size=5, stride=1, padding=2),
            nn.BatchNorm1d(32),
            nn.GELU(),
            nn.Conv1d(32, 64, kernel_size=5, stride=2, padding=2),
            nn.BatchNorm1d(64),
            nn.GELU(),
            nn.Conv1d(64, latent_dim, kernel_size=3, stride=2, padding=1),
            nn.BatchNorm1d(latent_dim),
            nn.GELU(),
            nn.AdaptiveAvgPool1d(1),
        )

    def forward(self, window: torch.Tensor) -> torch.Tensor:
        if window.ndim != 3:
            raise ValueError(f"expected (batch, time, channels), received {tuple(window.shape)}")
        return self.net(window.transpose(1, 2)).squeeze(-1)


class LatentPredictor(nn.Module):
    """Maps `(z_t, action)` to the predicted future latent."""

    def __init__(self, latent_dim: int = 64, action_dim: int = 3, hidden_dim: int = 128):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(latent_dim + action_dim, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.GELU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.LayerNorm(hidden_dim),
            nn.GELU(),
            nn.Linear(hidden_dim, latent_dim),
        )

    def forward(self, latent: torch.Tensor, action: torch.Tensor) -> torch.Tensor:
        return self.net(torch.cat([latent, action], dim=-1))


class EEGJEPAModule(nn.Module):
    """Online encoder, frozen EMA target encoder, and latent predictor."""

    def __init__(self, state_dim: int, action_dim: int, config: EEGJEPAConfig = EEGJEPAConfig()):
        super().__init__()
        self.config = config
        self.encoder = JEPADynamicsEncoder(state_dim, config.latent_dim)
        self.predictor = LatentPredictor(config.latent_dim, action_dim, config.hidden_dim)
        self.target_encoder = copy.deepcopy(self.encoder)
        for parameter in self.target_encoder.parameters():
            parameter.requires_grad = False
        self.target_encoder.eval()

    def forward_online(self, pre_window: torch.Tensor, action: torch.Tensor) -> torch.Tensor:
        return self.predictor(self.encoder(pre_window), action)

    @torch.no_grad()
    def forward_target(self, post_window: torch.Tensor) -> torch.Tensor:
        return self.target_encoder(post_window)

    @torch.no_grad()
    def update_target_ema(self) -> None:
        tau = self.config.ema_tau
        for target, online in zip(self.target_encoder.parameters(), self.encoder.parameters()):
            target.mul_(tau).add_(online, alpha=1.0 - tau)
        # BatchNorm's running statistics are buffers, not parameters. Copying
        # integer counters and EMA-updating float buffers keeps this target a
        # true slow-moving version of the online encoder.
        for target, online in zip(self.target_encoder.buffers(), self.encoder.buffers()):
            if target.is_floating_point():
                target.mul_(tau).add_(online, alpha=1.0 - tau)
            else:
                target.copy_(online)


def train_jepa(
    dataloader: DataLoader[tuple[torch.Tensor, torch.Tensor, torch.Tensor]],
    state_dim: int,
    action_dim: int,
    config: EEGJEPAConfig = EEGJEPAConfig(),
    epochs: int = 50,
    learning_rate: float = 1e-3,
    device: torch.device | None = None,
) -> tuple[EEGJEPAModule, list[float]]:
    """Trains the online path against the frozen EMA target encoder."""
    if epochs < 1:
        raise ValueError("epochs must be at least 1")
    if not 0 < config.ema_tau < 1:
        raise ValueError("ema_tau must be in (0, 1)")

    device = device or resolve_device()
    model = EEGJEPAModule(state_dim, action_dim, config).to(device)
    optimizer = torch.optim.AdamW(
        list(model.encoder.parameters()) + list(model.predictor.parameters()),
        lr=learning_rate,
        weight_decay=1e-4,
    )
    history: list[float] = []

    for epoch in range(epochs):
        model.encoder.train()
        model.predictor.train()
        total_loss = 0.0
        batches = 0
        for pre_window, action, post_window in dataloader:
            pre_window = pre_window.to(device)
            action = action.to(device)
            post_window = post_window.to(device)
            optimizer.zero_grad(set_to_none=True)

            predicted = model.forward_online(pre_window, action)
            target = model.forward_target(post_window)
            loss = F.mse_loss(predicted, target)
            if not torch.isfinite(loss):
                raise RuntimeError(f"non-finite loss at epoch {epoch + 1}")
            loss.backward()
            optimizer.step()
            model.update_target_ema()

            total_loss += loss.item()
            batches += 1

        if batches == 0:
            raise ValueError("dataloader produced no batches")
        average_loss = total_loss / batches
        history.append(average_loss)
        print(f"epoch {epoch + 1}/{epochs} loss={average_loss:.6f}")

    return model, history


def _smoke_record(index: int, sequence_length: int = 5,
                  saturated_channel: int | None = None) -> dict[str, Any]:
    def state(time: int, offset: float) -> dict[str, Any]:
        value = float(index * 10 + time) + offset
        channel_powers = [value + 1.5, value + 2.0]
        if saturated_channel is not None:
            channel_powers[saturated_channel] = 7.0
        return {
            "timestamp": 1_700_000_000.0 + value,
            "alphaPower": value,
            "betaPower": value + 0.5,
            "thetaPower": value + 1.0,
            "channelPowers": channel_powers,
        }

    return {
        "id": f"00000000-0000-0000-0000-{index:012d}",
        "timestamp": 1_700_000_000.0 + index,
        "preActionWindow": [state(time, 0) for time in range(sequence_length)],
        "actionVector": [1.0 if index % 2 else 2.0 / 3.0, 0.7, float(index % 2)],
        "postActionWindow": [state(time, 0.25) for time in range(sequence_length)],
    }


def smoke_test() -> None:
    """Exercises JSONL parsing, normalization, forward shapes, and one epoch."""
    with tempfile.TemporaryDirectory(prefix="neuralcompose-eeg-jepa-") as temporary_directory:
        path = Path(temporary_directory) / "transitions.jsonl"
        with path.open("w", encoding="utf-8") as output:
            for index in range(8):
                output.write(json.dumps(_smoke_record(index)) + "\n")

        dataset = JEPATransitionDataset(path)
        loader = DataLoader(dataset, batch_size=4, shuffle=False)
        pre, action, post = next(iter(loader))
        assert pre.shape == (4, 5, 5)
        assert action.shape == (4, 3)
        assert post.shape == (4, 5, 5)

        # Leakage-free stats: a second dataset built with the first's mean/std
        # must reuse them verbatim instead of recomputing its own.
        shared = JEPATransitionDataset(path, mean=dataset.mean, std=dataset.std)
        assert torch.equal(shared.mean, dataset.mean) and torch.equal(shared.std, dataset.std)
        assert torch.isfinite(shared[0][0]).all()
        try:
            JEPATransitionDataset(path, mean=dataset.mean[:-1], std=dataset.std[:-1])
        except ValueError:
            pass
        else:
            raise AssertionError("mismatched mean/std shape must raise ValueError")
        norm_path = dataset.export_normalization_constants(Path(temporary_directory) / "eeg_norm_stats.json")
        stats = json.loads(norm_path.read_text())
        assert len(stats["mean"]) == dataset.state_dim and len(stats["std"]) == dataset.state_dim
        assert stats["clip_sigma"] == dataset.clip_sigma

        # Saturated / near-dead channel: one channelPowers slot is pinned constant,
        # so its variance is zero. clamp_min(1e-6) keeps it finite, and the output
        # clip bounds every feature — proving a dead AF7 can't blow up the latents.
        saturated_path = Path(temporary_directory) / "saturated.jsonl"
        with saturated_path.open("w", encoding="utf-8") as output:
            for index in range(8):
                output.write(json.dumps(_smoke_record(index, saturated_channel=1)) + "\n")
        clamped = JEPATransitionDataset(saturated_path, clip_sigma=1.0)
        bounded = torch.stack([clamped[i][0] for i in range(len(clamped))])
        assert torch.isfinite(bounded).all()
        assert bounded.abs().max().item() <= 1.0 + 1e-5
        # The clip must actually engage: the same data unclamped exceeds the bound.
        unclamped = JEPATransitionDataset(saturated_path, clip_sigma=1e9)
        wide = torch.stack([unclamped[i][0] for i in range(len(unclamped))])
        assert wide.abs().max().item() > 1.0

        # Log-feature path: log-compress heavy-tailed powers, then z-score. Must stay
        # finite (log_epsilon guards log(0)) even with a saturated channel and zero-valued
        # features, and stay bounded by the output clip.
        logged = JEPATransitionDataset(saturated_path, log_features=True, clip_sigma=8.0)
        logged_states = torch.stack([logged[i][0] for i in range(len(logged))])
        assert torch.isfinite(logged_states).all()
        assert logged_states.abs().max().item() <= 8.0 + 1e-5
        log_norm_path = logged.export_normalization_constants(
            Path(temporary_directory) / "eeg_norm_log.json")
        log_stats = json.loads(log_norm_path.read_text())
        assert log_stats["log_features"] is True and log_stats["log_epsilon"] > 0

        model, history = train_jepa(
            loader,
            state_dim=dataset.state_dim,
            action_dim=dataset.action_dim,
            config=EEGJEPAConfig(latent_dim=16, hidden_dim=32),
            epochs=1,
        )
        with torch.no_grad():
            predicted = model.forward_online(pre.to(resolve_device()), action.to(resolve_device()))
            target = model.forward_target(post.to(resolve_device()))
        assert predicted.shape == target.shape == (4, 16)
        assert torch.isfinite(predicted).all() and torch.isfinite(target).all()
        assert len(history) == 1 and math.isfinite(history[0])
        print("smoke test passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, help="Swift-generated jepa_transitions.jsonl")
    parser.add_argument("--epochs", type=int, default=50)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--latent-dim", type=int, default=64)
    parser.add_argument("--hidden-dim", type=int, default=128)
    parser.add_argument("--ema-tau", type=float, default=0.99)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--output", type=Path, default=Path("WorldModel/checkpoints/eeg_jepa.pt"))
    parser.add_argument("--val-dataset", type=Path, default=None,
                        help="held-out jepa_transitions.jsonl, z-scored with the TRAIN mean/std (leakage-free)")
    parser.add_argument("--export-norm", type=Path, default=None,
                        help="also write the normalization constants JSON to this path (inspection only)")
    parser.add_argument("--no-normalize", action="store_true")
    parser.add_argument("--clip-sigma", type=float, default=8.0,
                        help="cap normalized band-power magnitude at ±clip_sigma; guards a "
                             "near-dead channel whose std sits just above the 1e-6 floor")
    parser.add_argument("--log-features", action="store_true",
                        help="log-compress heavy-tailed (~1/f) band/channel powers before "
                             "z-scoring, so high-power bands don't swamp low-power ones")
    parser.add_argument("--log-epsilon", type=float, default=1e-6,
                        help="additive constant inside log(x+eps) when --log-features is set")
    parser.add_argument("--smoke-test", action="store_true")
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    if args.smoke_test:
        smoke_test()
        return
    if args.dataset is None:
        parser.error("--dataset is required unless --smoke-test is used")

    dataset = JEPATransitionDataset(args.dataset, normalize=not args.no_normalize,
                                    clip_sigma=args.clip_sigma,
                                    log_features=args.log_features, log_epsilon=args.log_epsilon)
    dataloader = DataLoader(dataset, batch_size=args.batch_size, shuffle=True)
    config = EEGJEPAConfig(
        latent_dim=args.latent_dim,
        hidden_dim=args.hidden_dim,
        ema_tau=args.ema_tau,
    )
    device = resolve_device()
    print(
        f"loaded {len(dataset)} transitions: window={dataset.sequence_length} "
        f"state_dim={dataset.state_dim} action_dim={dataset.action_dim} device={device}"
    )
    model, history = train_jepa(
        dataloader,
        state_dim=dataset.state_dim,
        action_dim=dataset.action_dim,
        config=config,
        epochs=args.epochs,
        learning_rate=args.learning_rate,
        device=device,
    )

    if args.val_dataset is not None:
        # Normalize the held-out set with the TRAIN mean/std — never its own.
        val_dataset = JEPATransitionDataset(
            args.val_dataset, normalize=not args.no_normalize,
            mean=dataset.mean, std=dataset.std, clip_sigma=args.clip_sigma,
            log_features=args.log_features, log_epsilon=args.log_epsilon,
        )
        val_loader = DataLoader(val_dataset, batch_size=args.batch_size, shuffle=False)
        model.encoder.eval()
        model.predictor.eval()
        total, batches = 0.0, 0
        with torch.no_grad():
            for pre_window, action, post_window in val_loader:
                predicted = model.forward_online(pre_window.to(device), action.to(device))
                target = model.forward_target(post_window.to(device))
                total += F.mse_loss(predicted, target).item()
                batches += 1
        print(f"val loss (train-normalized, {len(val_dataset)} transitions): "
              f"{total / max(batches, 1):.6f}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "format": "neuralcompose.eeg-jepa.v1",
            "config": asdict(config),
            "state_feature_names": dataset.state_feature_names,
            "action_dim": dataset.action_dim,
            "sequence_length": dataset.sequence_length,
            "normalization_mean": dataset.mean,
            "normalization_std": dataset.std,
            "normalization_clip_sigma": dataset.clip_sigma,
            "normalization_log_features": dataset.log_features,
            "normalization_log_epsilon": dataset.log_epsilon,
            "encoder_state_dict": model.encoder.state_dict(),
            "predictor_state_dict": model.predictor.state_dict(),
            "final_loss": history[-1],
        },
        args.output,
    )
    print(f"saved checkpoint: {args.output}")

    if args.export_norm is not None:
        dataset.export_normalization_constants(args.export_norm)
        print(f"wrote normalization constants: {args.export_norm}")


if __name__ == "__main__":
    main()
