"""Run M2 or M3 EEGPT under the canonical fold-local adapter contract.

This worker is intended for Kaggle or Colab after a canonical archive exists.
It imports the official EEGPT checkout at a pinned revision, keeps its target
encoder frozen, and writes only fold-held-out probabilities plus provenance.
Local `evaluate_external_fold_predictions` remains the authority for scoring.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from functools import partial
from pathlib import Path
from typing import Any

import numpy as np
import torch
import torch.nn as nn

from .contracts import ContractError
from .dataset import CanonicalDataset, load_dataset
from .eegpt_adapter import DEFAULT_MONTAGE_PATH, LearnedMuseToEEGPTAdapter, load_eegpt_montage
from .evaluate import DEFAULT_EXPERIMENT_CONFIG_PATH, _load_metadata, load_experiment_configuration
from .evaluate_external_fold_predictions import _hash_window_set
from .models import Fold, grouped_folds, resolve_torch_device
from .provenance import (
    accelerator_provenance,
    git_commit,
    offline_deployment_outcome,
    sha256_bytes,
    sha256_file,
    sha256_json,
    summarize_runtime_outcomes,
)


WORKER_SCHEMA = "nc-eeg-external-fold-evaluation-input-v0"
WORKER_VERSION = "nc-eegpt-fold-worker-v0"


def _verify_upstream_checkout(upstream_root: Path, expected_revision: str) -> Path:
    downstream = upstream_root / "downstream"
    if not downstream.is_dir():
        raise ContractError(f"EEGPT checkout lacks downstream/: {upstream_root}")
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(upstream_root), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ContractError(f"cannot verify EEGPT checkout revision: {exc}") from exc
    if revision != expected_revision:
        raise ContractError(f"EEGPT checkout revision {revision} does not match pinned {expected_revision}")
    return downstream


def _load_backbone(
    *,
    downstream: Path,
    checkpoint: Path | None,
    initialization: str,
    seed: int,
) -> tuple[nn.Module, torch.Tensor, str]:
    """Create exactly the official 58-channel encoder, optionally load its weights."""
    montage = load_eegpt_montage()
    if str(downstream) not in sys.path:
        sys.path.insert(0, str(downstream))
    try:
        from Modules.models.EEGPT_mcae import EEGTransformer
    except ImportError as exc:
        raise ContractError(f"cannot import EEGPT's downstream encoder: {exc}") from exc

    torch.manual_seed(seed)
    backbone = EEGTransformer(
        img_size=[58, 1024],
        patch_size=64,
        embed_dim=512,
        embed_num=4,
        depth=8,
        num_heads=8,
        mlp_ratio=4.0,
        drop_rate=0.0,
        attn_drop_rate=0.0,
        drop_path_rate=0.0,
        init_std=0.02,
        qkv_bias=True,
        norm_layer=partial(nn.LayerNorm, eps=1e-6),
    )
    if initialization == "pretrained":
        if checkpoint is None or not checkpoint.is_file():
            raise ContractError("pretrained EEGPT condition requires the pinned checkpoint file")
        try:
            checkpoint_value = torch.load(checkpoint, map_location="cpu", weights_only=False)
        except (OSError, RuntimeError, ValueError) as exc:
            raise ContractError(f"cannot load EEGPT checkpoint: {exc}") from exc
        state_dict = checkpoint_value.get("state_dict") if isinstance(checkpoint_value, dict) else None
        if not isinstance(state_dict, dict):
            raise ContractError("EEGPT checkpoint lacks a state_dict")
        target_state = {key.removeprefix("target_encoder."): value for key, value in state_dict.items() if key.startswith("target_encoder.")}
        if not target_state:
            raise ContractError("EEGPT checkpoint lacks target_encoder weights")
        try:
            backbone.load_state_dict(target_state, strict=True)
        except RuntimeError as exc:
            raise ContractError(f"EEGPT checkpoint does not match the pinned encoder geometry: {exc}") from exc
        checkpoint_sha256 = sha256_file(checkpoint)
    elif initialization == "random":
        checkpoint_sha256 = _module_sha256(backbone)
    else:
        raise ContractError("initialization must be pretrained or random")
    for parameter in backbone.parameters():
        parameter.requires_grad_(False)
    backbone.eval()
    return backbone, backbone.prepare_chan_ids(list(montage.target_channels)), checkpoint_sha256


class EEGPTFoldClassifier(nn.Module):
    """Frozen official encoder with a fold-local Muse adapter and linear head."""

    def __init__(self, backbone: nn.Module, chan_ids: torch.Tensor, class_count: int) -> None:
        super().__init__()
        self.adapter = LearnedMuseToEEGPTAdapter()
        self.backbone = backbone
        for parameter in self.backbone.parameters():
            parameter.requires_grad_(False)
        self.backbone.eval()
        self.register_buffer("chan_ids", chan_ids, persistent=True)
        self.head = nn.Linear(512, class_count)

    def train(self, mode: bool = True) -> "EEGPTFoldClassifier":
        """Train only the fold-local adapter and head, never the backbone mode."""
        super().train(mode)
        self.backbone.eval()
        return self

    def forward(self, windows: torch.Tensor, observed_channels: torch.Tensor) -> torch.Tensor:
        adapted, _ = self.adapter(windows, observed_channels)
        # Frozen parameters still permit gradients from the loss back to the
        # fold-local adapter. ``torch.no_grad`` would silently prevent that.
        encoded = self.backbone(adapted, self.chan_ids)
        pooled = encoded.mean(dim=(1, 2))
        return self.head(pooled)


def _module_sha256(module: nn.Module) -> str:
    parts = []
    for name, value in sorted(module.state_dict().items()):
        parts.append(name.encode("utf-8"))
        parts.append(value.detach().cpu().contiguous().numpy().tobytes())
    return sha256_bytes(b"".join(parts))


def _seed(seed: int) -> None:
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.use_deterministic_algorithms(True, warn_only=True)


def _fit_fold(
    dataset: CanonicalDataset,
    fold: Fold,
    *,
    backbone: nn.Module,
    chan_ids: torch.Tensor,
    class_count: int,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    device: str,
    seed: int,
) -> tuple[np.ndarray, str, dict[str, float | int]]:
    _seed(seed)
    model = EEGPTFoldClassifier(backbone, chan_ids, class_count).to(device)
    trainable = [parameter for parameter in model.parameters() if parameter.requires_grad]
    if any(parameter.requires_grad for parameter in model.backbone.parameters()):
        raise AssertionError("EEGPT backbone must remain frozen")
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


def _worker_manifest(root: Path, seed: int) -> dict[str, Any]:
    accelerator = accelerator_provenance()
    if os.environ.get("KAGGLE_KERNEL_RUN_TYPE"):
        platform_name = "kaggle"
    elif "google.colab" in sys.modules:
        platform_name = "colab"
    elif sys.platform == "darwin":
        platform_name = "macos"
    else:
        platform_name = sys.platform
    return {
        "platform": platform_name,
        "accelerator": str(accelerator["accelerator"] or "cpu"),
        "accelerator_memory": str(accelerator["accelerator_memory_bytes"] or "unavailable"),
        "python_version": sys.version.split()[0],
        "torch_version": str(torch.__version__),
        "cuda_or_mps_version": str(accelerator["cuda_or_mps_version"] or "unavailable"),
        "available_quota": os.environ.get("NC_EEG_AVAILABLE_QUOTA", "unavailable"),
        "git_commit": git_commit(root) or "unavailable",
        "seed": seed,
    }


def _fixed_argument(value: int | float | None, *, configured: int | float, field: str) -> int | float:
    if value is not None and value != configured:
        raise SystemExit(f"--{field.replace('_', '-')} must match the fixed experiment configuration")
    return configured


def run_worker(
    dataset: CanonicalDataset,
    *,
    upstream_root: Path,
    checkpoint: Path | None,
    initialization: str,
    split_unit: str,
    epochs: int,
    batch_size: int,
    learning_rate: float,
    device: str,
    seed: int,
) -> tuple[np.ndarray, dict[str, Any]]:
    montage = load_eegpt_montage()
    downstream = _verify_upstream_checkout(upstream_root, montage.upstream_revision)
    backbone, chan_ids, checkpoint_sha256 = _load_backbone(
        downstream=downstream, checkpoint=checkpoint, initialization=initialization, seed=seed
    )
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
            chan_ids=chan_ids,
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
            "adapter": sha256_file(Path(__file__).with_name("eegpt_adapter.py")),
            "montage": sha256_file(DEFAULT_MONTAGE_PATH),
        }
    )
    return probabilities, {
        "schema_version": WORKER_SCHEMA,
        "representation": {
            "schema_version": "nc-eeg-external-embeddings-v0",
            "dataset_sha256": dataset.artifact_sha256(),
            "model_id": "eegpt",
            "initialization": initialization,
            "model_revision": montage.upstream_revision,
            "checkpoint_sha256": checkpoint_sha256,
            "extractor_version": WORKER_VERSION,
            "extractor_sha256": extractor_sha256,
            "channel_adapter": "four_channel_learned_adapter",
            "missing_channel_mask": "explicit",
            "adapter_training_scope": "fold_train_only",
        },
        "fold_provenance": fold_provenance,
        "runtime_outcomes": summarize_runtime_outcomes(fold_runtime, elapsed_seconds=time.monotonic() - started),
        "deployment": offline_deployment_outcome(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--upstream-root", required=True, type=Path)
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
    budget = configuration["m2_m3"]
    epochs = int(_fixed_argument(args.epochs, configured=int(budget["epochs"]), field="epochs"))
    batch_size = int(_fixed_argument(args.batch_size, configured=int(budget["batch_size"]), field="batch_size"))
    learning_rate = float(_fixed_argument(args.learning_rate, configured=float(budget["learning_rate"]), field="learning_rate"))
    seed = int(_fixed_argument(args.seed, configured=int(budget["seed"]), field="seed"))
    dataset = load_dataset(args.dataset)
    _load_metadata(args.metadata, dataset)
    probabilities, worker_metadata = run_worker(
        dataset,
        upstream_root=args.upstream_root,
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
        "configuration_section": "m2_m3",
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
