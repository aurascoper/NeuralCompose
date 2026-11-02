"""Run M4 BENDR as a frozen encoder with a fold-local Muse adapter.

This is a checkpoint-pinned external scientific worker. It uses the official
release's convolutional feature encoder, not BENDR's legacy training stack;
only a four-channel adapter and linear head are trainable in each grouped fold.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn

from .bendr_adapter import DEFAULT_BENDR_CONFIG_PATH, FrozenBENDRConvEncoder, LearnedMuseToBENDRAdapter, load_bendr_geometry
from .contracts import ContractError
from .dataset import CanonicalDataset, load_dataset
from .evaluate import DEFAULT_EXPERIMENT_CONFIG_PATH, _load_metadata, load_experiment_configuration
from .evaluate_external_fold_predictions import _hash_window_set
from .models import Fold, grouped_folds, resolve_torch_device
from .provenance import offline_deployment_outcome, sha256_file, sha256_json, summarize_runtime_outcomes
from .run_eegpt_fold_worker import WORKER_SCHEMA, _fixed_argument, _module_sha256, _seed, _worker_manifest


WORKER_VERSION = "nc-bendr-fold-worker-v0"


def _load_backbone(*, checkpoint: Path | None, initialization: str, seed: int) -> tuple[nn.Module, str]:
    geometry = load_bendr_geometry()
    torch.manual_seed(seed)
    backbone = FrozenBENDRConvEncoder(geometry)
    if initialization == "pretrained":
        if checkpoint is None:
            raise ContractError("pretrained BENDR condition requires the pinned encoder checkpoint")
        checkpoint_sha256 = backbone.load_pinned_checkpoint(checkpoint)
    elif initialization == "random":
        checkpoint_sha256 = _module_sha256(backbone)
        for parameter in backbone.parameters():
            parameter.requires_grad_(False)
        backbone.eval()
    else:
        raise ContractError("initialization must be pretrained or random")
    return backbone, checkpoint_sha256


class BENDRFoldClassifier(nn.Module):
    """Frozen BENDR convolutional features with a fold-local adapter and head."""

    def __init__(self, backbone: nn.Module, class_count: int) -> None:
        super().__init__()
        self.adapter = LearnedMuseToBENDRAdapter()
        self.backbone = backbone
        for parameter in self.backbone.parameters():
            parameter.requires_grad_(False)
        self.backbone.eval()
        self.head = nn.Linear(512, class_count)

    def train(self, mode: bool = True) -> "BENDRFoldClassifier":
        super().train(mode)
        self.backbone.eval()
        return self

    def forward(self, windows: torch.Tensor, observed_channels: torch.Tensor) -> torch.Tensor:
        adapted, _ = self.adapter(windows, observed_channels)
        # Do not use torch.no_grad here. Parameters are frozen, but gradients
        # must reach the fold-local adapter through the frozen feature encoder.
        features = self.backbone(adapted)
        return self.head(features.mean(dim=-1))


def _fit_fold(
    dataset: CanonicalDataset,
    fold: Fold,
    *,
    backbone: nn.Module,
    class_count: int,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    device: str,
    seed: int,
) -> tuple[np.ndarray, str, dict[str, float | int]]:
    _seed(seed)
    model = BENDRFoldClassifier(backbone, class_count).to(device)
    if any(parameter.requires_grad for parameter in model.backbone.parameters()):
        raise AssertionError("BENDR backbone must remain frozen")
    trainable = [parameter for parameter in model.parameters() if parameter.requires_grad]
    optimizer = torch.optim.Adam(trainable, lr=learning_rate)
    labels = dataset.labels[fold.train_index]
    counts = np.bincount(labels, minlength=class_count).astype(np.float32)
    if int((counts > 0).sum()) < 2:
        raise ContractError(f"{fold.held_out_session}: training partition has fewer than two labels")
    class_weights = np.zeros(class_count, dtype=np.float32)
    present = counts > 0
    class_weights[present] = counts[present].sum() / (present.sum() * counts[present])
    loss_function = nn.CrossEntropyLoss(weight=torch.from_numpy(class_weights).to(device))
    train_windows = torch.from_numpy(dataset.windows[fold.train_index]).float()
    train_masks = torch.from_numpy(dataset.missing_channel_masks[fold.train_index]).float()
    train_labels = torch.from_numpy(labels).long()
    training_started = time.perf_counter()
    model.train()
    for _ in range(epochs):
        order = torch.randperm(len(train_labels))
        for offset in range(0, len(order), batch_size):
            index = order[offset : offset + batch_size]
            optimizer.zero_grad(set_to_none=True)
            logits = model(train_windows[index].to(device), train_masks[index].to(device))
            loss = loss_function(logits, train_labels[index].to(device))
            loss.backward()
            optimizer.step()
    training_seconds = time.perf_counter() - training_started
    model.eval()
    test_windows = torch.from_numpy(dataset.windows[fold.test_index]).float().to(device)
    test_masks = torch.from_numpy(dataset.missing_channel_masks[fold.test_index]).float().to(device)
    inference_started = time.perf_counter()
    with torch.no_grad():
        probabilities = torch.softmax(model(test_windows, test_masks), dim=1).cpu().numpy().astype(np.float64)
    inference_seconds = time.perf_counter() - inference_started
    adapter_hash = _module_sha256(nn.ModuleList([model.adapter, model.head]))
    return probabilities, adapter_hash, {
        "training_seconds": training_seconds,
        "inference_seconds": inference_seconds,
        "per_window_inference_ms": inference_seconds * 1000.0 / max(len(fold.test_index), 1),
        "checkpoint_size_bytes": int(sum(parameter.numel() * parameter.element_size() for parameter in model.parameters())),
    }


def run_worker(
    dataset: CanonicalDataset,
    *,
    checkpoint: Path | None,
    initialization: str,
    split_unit: str,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    device: str,
    seed: int,
) -> tuple[np.ndarray, dict[str, Any]]:
    geometry = load_bendr_geometry()
    backbone, checkpoint_sha256 = _load_backbone(checkpoint=checkpoint, initialization=initialization, seed=seed)
    resolved_device = resolve_torch_device(device)
    backbone = backbone.to(resolved_device)
    probabilities = np.zeros((len(dataset.labels), len(dataset.label_order)), dtype=np.float64)
    fold_provenance: list[dict[str, Any]] = []
    fold_runtime: list[dict[str, float | int]] = []
    started = time.monotonic()
    for fold_number, fold in enumerate(grouped_folds(dataset, split_unit)):
        values, adapter_hash, runtime = _fit_fold(
            dataset,
            fold,
            backbone=backbone,
            class_count=len(dataset.label_order),
            epochs=epochs,
            batch_size=batch_size,
            learning_rate=learning_rate,
            device=resolved_device,
            seed=seed + fold_number + 1,
        )
        probabilities[fold.test_index] = values
        fold_runtime.append(runtime)
        fold_provenance.append(
            {
                "held_out_group_id": fold.held_out_session,
                "train_raw_window_hashes_sha256": _hash_window_set(dataset.raw_window_hashes[fold.train_index]),
                "test_raw_window_hashes_sha256": _hash_window_set(dataset.raw_window_hashes[fold.test_index]),
                "backbone_frozen": True,
                "trainable_modules": ["four_channel_adapter", "linear_head"],
                "adapter_checkpoint_sha256": adapter_hash,
            }
        )
    extractor_sha256 = sha256_json(
        {
            "worker": sha256_file(Path(__file__)),
            "adapter": sha256_file(Path(__file__).with_name("bendr_adapter.py")),
            "config": sha256_file(DEFAULT_BENDR_CONFIG_PATH),
        }
    )
    return probabilities, {
        "schema_version": WORKER_SCHEMA,
        "representation": {
            "schema_version": "nc-eeg-external-embeddings-v0",
            "dataset_sha256": dataset.artifact_sha256(),
            "model_id": "bendr",
            "initialization": initialization,
            "model_revision": geometry.upstream_revision,
            "checkpoint_sha256": checkpoint_sha256,
            "extractor_version": WORKER_VERSION,
            "extractor_sha256": extractor_sha256,
            "channel_adapter": "four_channel_learned_adapter",
            "missing_channel_mask": "explicit",
            "adapter_training_scope": "fold_train_only",
            "backbone_scope": "official_bendr_v0_1_alpha_frozen_conv_encoder_only",
        },
        "fold_provenance": fold_provenance,
        "runtime_outcomes": summarize_runtime_outcomes(fold_runtime, elapsed_seconds=time.monotonic() - started),
        "deployment": offline_deployment_outcome(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--initialization", choices=("pretrained", "random"), required=True)
    parser.add_argument("--split-unit", choices=("session", "recording_date", "participant", "device", "headset_fit"), default="session")
    parser.add_argument("--experiment-config", type=Path, default=DEFAULT_EXPERIMENT_CONFIG_PATH)
    parser.add_argument("--epochs", type=int)
    parser.add_argument("--batch-size", type=int)
    parser.add_argument("--learning-rate", type=float)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--seed", type=int)
    parser.add_argument("--predictions-output", required=True, type=Path)
    parser.add_argument("--metadata-output", required=True, type=Path)
    args = parser.parse_args(argv)
    if args.initialization == "random" and args.checkpoint is not None:
        raise SystemExit("random initialization must not receive a pretrained checkpoint")
    if args.initialization == "pretrained" and args.checkpoint is None:
        raise SystemExit("pretrained initialization requires --checkpoint")
    configuration = load_experiment_configuration(args.experiment_config)
    budget = configuration["m4"]
    epochs = int(_fixed_argument(args.epochs, configured=int(budget["epochs"]), field="epochs"))
    batch_size = int(_fixed_argument(args.batch_size, configured=int(budget["batch_size"]), field="batch_size"))
    learning_rate = float(_fixed_argument(args.learning_rate, configured=float(budget["learning_rate"]), field="learning_rate"))
    seed = int(_fixed_argument(args.seed, configured=int(budget["seed"]), field="seed"))
    dataset = load_dataset(args.dataset)
    _load_metadata(args.metadata, dataset)
    probabilities, worker_metadata = run_worker(
        dataset,
        checkpoint=args.checkpoint,
        initialization=args.initialization,
        split_unit=args.split_unit,
        epochs=epochs,
        batch_size=batch_size,
        learning_rate=learning_rate,
        device=args.device,
        seed=seed,
    )
    root = Path(__file__).resolve().parents[3]
    worker_metadata["representation"]["input_archive_sha256"] = sha256_file(args.dataset)
    worker_metadata["representation"]["worker_run_manifest"] = _worker_manifest(root, seed)
    worker_metadata["input_sha256"] = {"dataset": sha256_file(args.dataset), "metadata": sha256_file(args.metadata)}
    worker_metadata["experiment_configuration_sha256"] = sha256_json(configuration)
    worker_metadata["training"] = {
        "configuration_section": "m4",
        "split_unit": args.split_unit,
        "epochs": epochs,
        "batch_size": batch_size,
        "learning_rate": learning_rate,
        "seed": seed,
        "requested_device": args.device,
    }
    args.predictions_output.parent.mkdir(parents=True, exist_ok=True)
    args.metadata_output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.predictions_output, raw_window_hashes=dataset.raw_window_hashes, probabilities=probabilities)
    args.metadata_output.write_text(json.dumps(worker_metadata, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.predictions_output} and {args.metadata_output}; local verification remains required")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
