"""Extract fixed EEGPT representations for A2/A4 control conditions.

M2/M3 use the fold-local learned adapter worker. This companion executable
handles only deterministic montage paths, so it can emit one canonical
embedding table for the local grouped linear-probe evaluator. It never trains
or claims a four-channel adapter.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch

from .contracts import ContractError
from .dataset import CanonicalDataset, load_dataset
from .eegpt_adapter import DEFAULT_MONTAGE_PATH, FixedMuseToEEGPTMapping, ZeroFillNoMaskControl, load_eegpt_montage
from .evaluate import DEFAULT_EXPERIMENT_CONFIG_PATH, _load_metadata, load_experiment_configuration
from .models import resolve_torch_device
from .provenance import offline_deployment_outcome, sha256_file, sha256_json, summarize_runtime_outcomes
from .run_eegpt_fold_worker import WORKER_VERSION, _fixed_argument, _load_backbone, _verify_upstream_checkout, _worker_manifest


EXTRACTOR_VERSION = "nc-eegpt-fixed-embedding-extractor-v0"
MAPPING_SOURCE_ORDERS = {
    "canonical": (0, 1, 2, 3),
    "shuffled": (3, 2, 1, 0),
}


def _condition_metadata(condition: str) -> tuple[str, str, str]:
    if condition == "canonical":
        return "approximate_electrode_mapping_with_mask", "explicit", "fixed_preprocessor"
    if condition == "shuffled":
        return "shuffled_electrode_mapping_negative_control", "explicit", "fixed_preprocessor"
    if condition == "zero_fill":
        return "zero_filled_no_mask_negative_control", "absent_negative_control", "fixed_preprocessor"
    raise ContractError(f"unknown fixed EEGPT condition: {condition}")


def _pooled_embeddings(
    dataset: CanonicalDataset,
    *,
    backbone: torch.nn.Module,
    chan_ids: torch.Tensor,
    condition: str,
    batch_size: int,
    device: str,
) -> np.ndarray:
    montage = load_eegpt_montage()
    if condition == "zero_fill":
        adapter: torch.nn.Module = ZeroFillNoMaskControl(montage)
    else:
        adapter = FixedMuseToEEGPTMapping(montage, source_order=MAPPING_SOURCE_ORDERS[condition])
    adapter = adapter.to(device).eval()
    backbone = backbone.to(device).eval()
    rows: list[np.ndarray] = []
    for offset in range(0, len(dataset.labels), batch_size):
        windows = torch.from_numpy(dataset.windows[offset : offset + batch_size]).float().to(device)
        observed = torch.from_numpy(dataset.missing_channel_masks[offset : offset + batch_size]).float().to(device)
        with torch.no_grad():
            if condition == "zero_fill":
                values = adapter(windows, observed)
                mask_features = None
            else:
                values, target_mask = adapter(windows, observed)
                # A2 and its shuffled sensitivity retain the deterministic
                # missing-electrode mask as an explicit probe input.
                mask_features = target_mask
            encoded = backbone(values, chan_ids)
            pooled = encoded.mean(dim=(1, 2))
            if mask_features is not None:
                pooled = torch.cat((pooled, mask_features), dim=1)
        rows.append(pooled.cpu().numpy().astype(np.float32))
    return np.vstack(rows)


def extract_embeddings(
    dataset: CanonicalDataset,
    *,
    upstream_root: Path,
    checkpoint: Path | None,
    initialization: str,
    condition: str,
    batch_size: int,
    device: str,
    seed: int,
) -> tuple[np.ndarray, dict[str, Any]]:
    montage = load_eegpt_montage()
    downstream = _verify_upstream_checkout(upstream_root, montage.upstream_revision)
    backbone, chan_ids, checkpoint_sha256 = _load_backbone(
        downstream=downstream,
        checkpoint=checkpoint,
        initialization=initialization,
        seed=seed,
    )
    resolved_device = resolve_torch_device(device)
    inference_started = time.perf_counter()
    embeddings = _pooled_embeddings(
        dataset,
        backbone=backbone,
        chan_ids=chan_ids.to(resolved_device),
        condition=condition,
        batch_size=batch_size,
        device=resolved_device,
    )
    inference_seconds = time.perf_counter() - inference_started
    channel_adapter, missing_channel_mask, scope = _condition_metadata(condition)
    extractor_sha256 = sha256_json(
        {
            "extractor": sha256_file(Path(__file__)),
            "fold_worker": sha256_file(Path(__file__).with_name("run_eegpt_fold_worker.py")),
            "adapter": sha256_file(Path(__file__).with_name("eegpt_adapter.py")),
            "montage": sha256_file(DEFAULT_MONTAGE_PATH),
        }
    )
    return embeddings, {
        "schema_version": "nc-eeg-external-embeddings-v0",
        "dataset_sha256": dataset.artifact_sha256(),
        "model_id": "eegpt",
        "initialization": initialization,
        "model_revision": montage.upstream_revision,
        "checkpoint_sha256": checkpoint_sha256,
        "extractor_version": EXTRACTOR_VERSION,
        "extractor_sha256": extractor_sha256,
        "channel_adapter": channel_adapter,
        "missing_channel_mask": missing_channel_mask,
        "adapter_training_scope": scope,
        "fixed_representation": {
            "pooling": "mean_time_and_summary_tokens",
            "embedding_dimension": int(embeddings.shape[1]),
            "mask_features_appended": condition != "zero_fill",
            "condition": condition,
            "random_backbone_seed": seed if initialization == "random" else None,
            "worker_reference": WORKER_VERSION,
        },
        "runtime_outcomes": summarize_runtime_outcomes(
            [
                {
                    "training_seconds": None,
                    "inference_seconds": inference_seconds,
                    "per_window_inference_ms": inference_seconds * 1000.0 / max(len(dataset.labels), 1),
                    "checkpoint_size_bytes": int(sum(parameter.numel() * parameter.element_size() for parameter in backbone.parameters())),
                }
            ],
            elapsed_seconds=inference_seconds,
        ),
        "deployment": offline_deployment_outcome(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--upstream-root", required=True, type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--initialization", choices=("pretrained", "random"), required=True)
    parser.add_argument("--condition", choices=("canonical", "shuffled", "zero_fill"), required=True)
    parser.add_argument("--experiment-config", type=Path, default=DEFAULT_EXPERIMENT_CONFIG_PATH)
    parser.add_argument("--batch-size", type=int)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--seed", type=int)
    parser.add_argument("--embeddings-output", required=True, type=Path)
    parser.add_argument("--metadata-output", required=True, type=Path)
    args = parser.parse_args(argv)
    if args.initialization == "random" and args.checkpoint is not None:
        raise SystemExit("random initialization must not receive a pretrained checkpoint")
    if args.initialization == "pretrained" and args.checkpoint is None:
        raise SystemExit("pretrained initialization requires --checkpoint")
    configuration = load_experiment_configuration(args.experiment_config)
    budget = configuration["fixed_controls"]
    batch_size = int(_fixed_argument(args.batch_size, configured=int(budget["batch_size"]), field="batch_size"))
    seed = int(_fixed_argument(args.seed, configured=int(budget["seed"]), field="seed"))

    dataset = load_dataset(args.dataset)
    _load_metadata(args.metadata, dataset)
    embeddings, provenance = extract_embeddings(
        dataset,
        upstream_root=args.upstream_root,
        checkpoint=args.checkpoint,
        initialization=args.initialization,
        condition=args.condition,
        batch_size=batch_size,
        device=args.device,
        seed=seed,
    )
    root = Path(__file__).resolve().parents[3]
    provenance["input_archive_sha256"] = sha256_file(args.dataset)
    provenance["worker_run_manifest"] = _worker_manifest(root, seed)
    provenance["input_sha256"] = {"dataset": sha256_file(args.dataset), "metadata": sha256_file(args.metadata)}
    provenance["experiment_configuration_sha256"] = sha256_json(configuration)
    provenance["training"] = {
        "configuration_section": "fixed_controls",
        "batch_size": batch_size,
        "seed": seed,
        "requested_device": args.device,
    }
    args.embeddings_output.parent.mkdir(parents=True, exist_ok=True)
    args.metadata_output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.embeddings_output, raw_window_hashes=dataset.raw_window_hashes, embeddings=embeddings)
    args.metadata_output.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.embeddings_output} and {args.metadata_output}; local grouped probe remains required")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
