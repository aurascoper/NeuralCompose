"""M0 and M1 model implementations with fold-local fitting only."""

from __future__ import annotations

import random
import time
from dataclasses import dataclass
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

from .dataset import CanonicalDataset
from .provenance import sha256_bytes, sha256_json


@dataclass(frozen=True)
class Fold:
    held_out_session: str
    train_index: np.ndarray
    test_index: np.ndarray
    grouping: str = "session"


def leave_one_session_out(dataset: CanonicalDataset) -> list[Fold]:
    """Generate the default pilot split policy: a complete held-out session."""
    return grouped_folds(dataset, "session")


def grouped_folds(dataset: CanonicalDataset, grouping: str) -> list[Fold]:
    """Build confirmation-ready grouped folds without ever splitting a session."""
    attributes = {
        "session": dataset.session_ids,
        "recording_date": dataset.recording_dates,
        "participant": dataset.participant_ids,
        "device": dataset.device_ids,
        "headset_fit": dataset.headset_fit_ids,
    }
    if grouping not in attributes:
        raise ValueError(f"unsupported grouping {grouping!r}")
    groups = attributes[grouping]
    group_ids = sorted(str(value) for value in np.unique(groups))
    if len(group_ids) < 2:
        raise ValueError(f"need at least two {grouping} groups for grouped evaluation")
    folds: list[Fold] = []
    for group_id in group_ids:
        test_index = np.flatnonzero(groups == group_id)
        train_index = np.flatnonzero(groups != group_id)
        if not len(test_index) or not len(train_index):
            raise ValueError("invalid empty grouped split")
        train_sessions = set(dataset.session_ids[train_index].tolist())
        test_sessions = set(dataset.session_ids[test_index].tolist())
        if train_sessions & test_sessions:
            raise AssertionError("complete sessions must never be shared across a split")
        folds.append(Fold(group_id, train_index, test_index, grouping))
    return folds


def split_manifest(dataset: CanonicalDataset, folds: list[Fold]) -> dict[str, Any]:
    """Describe a grouped split without exposing raw EEG or window values.

    Every evaluator persists this exact representation. It lets the final
    comparison reject results that happen to share a dataset hash but held out
    different sessions, dates, or fits.
    """
    return {
        "grouping": folds[0].grouping if folds else None,
        "folds": [
            {
                "held_out_group_id": fold.held_out_session,
                "train_session_ids": sorted(set(dataset.session_ids[fold.train_index].tolist())),
                "test_session_ids": sorted(set(dataset.session_ids[fold.test_index].tolist())),
                "train_window_count": int(len(fold.train_index)),
                "test_window_count": int(len(fold.test_index)),
            }
            for fold in folds
        ],
    }


def split_manifest_sha256(dataset: CanonicalDataset, folds: list[Fold]) -> str:
    return sha256_json(split_manifest(dataset, folds))


def _probabilities_in_global_class_order(model: LogisticRegression, values: np.ndarray, class_count: int) -> np.ndarray:
    partial = model.predict_proba(values)
    probabilities = np.zeros((len(values), class_count), dtype=np.float64)
    probabilities[:, model.classes_.astype(int)] = partial
    return probabilities


def fit_predict_m0(
    features: np.ndarray,
    labels: np.ndarray,
    fold: Fold,
    *,
    class_count: int,
    regularization_c: float = 1.0,
) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
    """Fit M0 with a scaler learned from train rows only."""
    train_x, test_x = features[fold.train_index], features[fold.test_index]
    train_y = labels[fold.train_index]
    if len(np.unique(train_y)) < 2:
        raise ValueError(f"{fold.held_out_session}: training partition has fewer than two labels")
    training_started = time.perf_counter()
    scaler = StandardScaler()
    train_scaled = scaler.fit_transform(train_x)
    test_scaled = scaler.transform(test_x)
    model = LogisticRegression(
        C=regularization_c,
        class_weight="balanced",
        max_iter=2000,
        random_state=42,
    )
    model.fit(train_scaled, train_y)
    training_seconds = time.perf_counter() - training_started
    inference_started = time.perf_counter()
    probabilities = _probabilities_in_global_class_order(model, test_scaled, class_count)
    inference_seconds = time.perf_counter() - inference_started
    predictions = probabilities.argmax(axis=1).astype(np.int64)
    scaler_hash = sha256_bytes(
        scaler.mean_.astype("<f8", copy=False).tobytes() + scaler.scale_.astype("<f8", copy=False).tobytes()
    )
    return predictions, probabilities, {
        "model": "M0-deterministic-features-logistic-regression",
        "regularization_c": regularization_c,
        "feature_count": int(features.shape[1]),
        "train_only_standardizer_sha256": scaler_hash,
        "train_row_count": int(len(fold.train_index)),
        "checkpoint_size_bytes": int(model.coef_.nbytes + model.intercept_.nbytes + scaler.mean_.nbytes + scaler.scale_.nbytes),
        "training_seconds": training_seconds,
        "inference_seconds": inference_seconds,
        "per_window_inference_ms": inference_seconds * 1000.0 / max(len(test_x), 1),
    }


def resolve_torch_device(requested: str = "auto") -> str:
    import torch

    if requested != "auto":
        return requested
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _seed_torch(seed: int) -> None:
    import torch

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(seed)
    torch.use_deterministic_algorithms(True, warn_only=True)


class EEGNet:
    """Compact EEGNet-style M1 with an explicit missing-channel mask head."""

    def __new__(cls, *args: Any, **kwargs: Any):  # pragma: no cover - construction delegated to torch lazily
        import torch
        import torch.nn as nn

        class _EEGNet(nn.Module):
            def __init__(self, class_count: int, dropout: float = 0.25):
                super().__init__()
                f1, depthwise_multiplier, f2 = 8, 2, 16
                self.temporal = nn.Sequential(
                    nn.Conv2d(1, f1, (1, 64), padding=(0, 32), bias=False),
                    nn.BatchNorm2d(f1),
                    nn.Conv2d(f1, f1 * depthwise_multiplier, (4, 1), groups=f1, bias=False),
                    nn.BatchNorm2d(f1 * depthwise_multiplier),
                    nn.ELU(),
                    nn.AvgPool2d((1, 4)),
                    nn.Dropout(dropout),
                    nn.Conv2d(f1 * depthwise_multiplier, f2, (1, 16), padding=(0, 8), groups=f1 * depthwise_multiplier, bias=False),
                    nn.Conv2d(f2, f2, (1, 1), bias=False),
                    nn.BatchNorm2d(f2),
                    nn.ELU(),
                    nn.AvgPool2d((1, 8)),
                    nn.Dropout(dropout),
                    nn.AdaptiveAvgPool2d((1, 1)),
                )
                self.classifier = nn.Linear(f2 + 4, class_count)

            def forward(self, windows, masks):
                features = self.temporal(windows.unsqueeze(1)).flatten(1)
                return self.classifier(torch.cat((features, masks), dim=1))

        return _EEGNet(*args, **kwargs)


def fit_predict_m1(
    dataset: CanonicalDataset,
    fold: Fold,
    *,
    class_count: int,
    seed: int = 42,
    epochs: int = 20,
    batch_size: int = 32,
    learning_rate: float = 1e-3,
    device: str = "auto",
) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
    """Train EEGNet only on the fold's training sessions and score one held-out session."""
    import torch
    from torch.utils.data import DataLoader, TensorDataset

    _seed_torch(seed)
    resolved = resolve_torch_device(device)
    training_started = time.perf_counter()
    model = EEGNet(class_count).to(resolved)
    train_x = torch.from_numpy(dataset.windows[fold.train_index]).float()
    train_mask = torch.from_numpy(dataset.missing_channel_masks[fold.train_index]).float()
    train_y = torch.from_numpy(dataset.labels[fold.train_index]).long()
    test_x = torch.from_numpy(dataset.windows[fold.test_index]).float()
    test_mask = torch.from_numpy(dataset.missing_channel_masks[fold.test_index]).float()
    counts = np.bincount(dataset.labels[fold.train_index], minlength=class_count).astype(np.float32)
    if int((counts > 0).sum()) < 2:
        raise ValueError(f"{fold.held_out_session}: training partition has fewer than two labels")
    class_weights = np.zeros(class_count, dtype=np.float32)
    present = counts > 0
    class_weights[present] = counts[present].sum() / (present.sum() * counts[present])
    loader = DataLoader(TensorDataset(train_x, train_mask, train_y), batch_size=batch_size, shuffle=True, generator=torch.Generator().manual_seed(seed))
    optimizer = torch.optim.Adam(model.parameters(), lr=learning_rate)
    loss_function = torch.nn.CrossEntropyLoss(weight=torch.from_numpy(class_weights).to(resolved))
    model.train()
    for _ in range(epochs):
        for batch_x, batch_mask, batch_y in loader:
            batch_x, batch_mask, batch_y = batch_x.to(resolved), batch_mask.to(resolved), batch_y.to(resolved)
            optimizer.zero_grad(set_to_none=True)
            loss = loss_function(model(batch_x, batch_mask), batch_y)
            loss.backward()
            optimizer.step()
    training_seconds = time.perf_counter() - training_started
    model.eval()
    with torch.no_grad():
        inference_started = time.perf_counter()
        logits = model(test_x.to(resolved), test_mask.to(resolved))
        probabilities = torch.softmax(logits, dim=1).cpu().numpy().astype(np.float64)
        inference_seconds = time.perf_counter() - inference_started
    predictions = probabilities.argmax(axis=1).astype(np.int64)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    return predictions, probabilities, {
        "model": "M1-eegnet-from-scratch",
        "device": resolved,
        "seed": seed,
        "epochs": epochs,
        "batch_size": batch_size,
        "learning_rate": learning_rate,
        "train_row_count": int(len(fold.train_index)),
        "trainable_parameter_count": int(parameter_count),
        "checkpoint_size_bytes": int(sum(parameter.numel() * parameter.element_size() for parameter in model.parameters())),
        "training_seconds": training_seconds,
        "inference_seconds": inference_seconds,
        "per_window_inference_ms": inference_seconds * 1000.0 / max(len(test_x), 1),
        "missing_channel_mask": "explicit-mask-concatenated-at-classifier",
    }
