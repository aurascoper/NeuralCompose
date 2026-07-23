"""Verify fold-scoped EEGPT/BENDR predictions against canonical EEG splits.

Precomputed vectors are valid only for a fixed preprocessing path. A learned
four-channel adapter changes the backbone input, so it must be fit inside every
training fold. CUDA workers therefore return held-out probabilities and an
attested fold manifest; this local verifier checks that no held-out window was
available to the adapter or linear head.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import numpy as np

from .contracts import ContractError, EXTERNAL_FOLD_EVALUATION_SCHEMA, validate_external_embedding_metadata
from .dataset import CanonicalDataset, load_dataset
from .evaluate import DEFAULT_EXPERIMENT_CONFIG_PATH, _load_metadata, aggregate_fold_metrics, fold_metrics, load_experiment_configuration
from .models import Fold, grouped_folds, split_manifest, split_manifest_sha256
from .provenance import (
    accelerator_provenance,
    offline_deployment_outcome,
    package_versions,
    runtime_provenance,
    sha256_file,
    sha256_json,
    sha256_string_set,
)


def _hash_window_set(hashes: np.ndarray) -> str:
    return sha256_string_set(hashes.tolist())


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read external fold metadata: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError("external fold metadata must be a JSON object")
    return value


def _validate_metadata(
    metadata: dict[str, Any],
    dataset: CanonicalDataset,
    archive_sha256: str,
    experiment_configuration: dict[str, Any],
) -> dict[str, Any]:
    if metadata.get("schema_version") != EXTERNAL_FOLD_EVALUATION_SCHEMA:
        raise ContractError("external fold metadata has the wrong schema")
    representation = metadata.get("representation")
    if not isinstance(representation, dict):
        raise ContractError("external fold metadata requires representation provenance")
    representation = dict(representation)
    representation["schema_version"] = "nc-eeg-external-embeddings-v0"
    validate_external_embedding_metadata(representation, dataset_sha256=dataset.artifact_sha256())
    if representation["adapter_training_scope"] != "fold_train_only":
        raise ContractError("fold-scoped evaluation is reserved for a fold-trained adapter")
    if representation["input_archive_sha256"] != archive_sha256:
        raise ContractError("external fold predictions were generated from a different dataset archive")
    section = "m2_m3" if representation["model_id"] == "eegpt" else "m4" if representation["model_id"] == "bendr" else None
    if section is None:
        raise ContractError("fold-trained external predictions must be from EEGPT or BENDR")
    if metadata.get("experiment_configuration_sha256") != sha256_json(experiment_configuration):
        raise ContractError("external fold predictions do not attest to this fixed experiment configuration")
    training = metadata.get("training")
    if not isinstance(training, dict) or training.get("configuration_section") != section:
        raise ContractError("external fold predictions lack their fixed-compute configuration section")
    budget = experiment_configuration[section]
    for field in ("epochs", "batch_size", "learning_rate", "seed"):
        if training.get(field) != budget[field]:
            raise ContractError(f"external fold predictions do not match fixed {section}.{field}")
    return representation


def _load_probabilities(path: Path, dataset: CanonicalDataset) -> np.ndarray:
    try:
        with np.load(path, allow_pickle=False) as archive:
            hashes = archive["raw_window_hashes"].astype("U64")
            probabilities = archive["probabilities"].astype(np.float64)
    except (OSError, KeyError, ValueError) as exc:
        raise ContractError(f"invalid external fold prediction archive: {exc}") from exc
    if probabilities.ndim != 2 or probabilities.shape != (len(hashes), len(dataset.label_order)):
        raise ContractError("probabilities must have [canonical_window, class] shape")
    if len(set(hashes.tolist())) != len(hashes):
        raise ContractError("external fold prediction archive has duplicate window hashes")
    expected = dataset.raw_window_hashes.tolist()
    if set(hashes.tolist()) != set(expected):
        raise ContractError("external fold prediction archive must cover exactly canonical windows")
    if not np.all(np.isfinite(probabilities)) or np.any(probabilities < 0) or np.any(probabilities > 1):
        raise ContractError("probabilities must be finite values in [0, 1]")
    if not np.allclose(probabilities.sum(axis=1), 1.0, atol=1e-5):
        raise ContractError("probabilities must sum to one for every canonical window")
    mapping = {window_hash: row for window_hash, row in zip(hashes.tolist(), probabilities, strict=True)}
    return np.vstack([mapping[window_hash] for window_hash in expected])


def _validate_fold_provenance(metadata: dict[str, Any], dataset: CanonicalDataset, folds: list[Fold]) -> None:
    records = metadata.get("fold_provenance")
    if not isinstance(records, list) or len(records) != len(folds):
        raise ContractError("external fold metadata needs exactly one provenance record per canonical fold")
    by_group: dict[str, dict[str, Any]] = {}
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("held_out_group_id"), str):
            raise ContractError("external fold provenance record lacks held_out_group_id")
        group_id = record["held_out_group_id"]
        if group_id in by_group:
            raise ContractError("external fold provenance has duplicate held-out groups")
        by_group[group_id] = record
    for fold in folds:
        record = by_group.get(fold.held_out_session)
        if record is None:
            raise ContractError("external fold provenance does not match canonical held-out groups")
        expected_train = _hash_window_set(dataset.raw_window_hashes[fold.train_index])
        expected_test = _hash_window_set(dataset.raw_window_hashes[fold.test_index])
        if record.get("train_raw_window_hashes_sha256") != expected_train:
            raise ContractError(f"{fold.held_out_session}: adapter provenance has wrong training windows")
        if record.get("test_raw_window_hashes_sha256") != expected_test:
            raise ContractError(f"{fold.held_out_session}: adapter provenance has wrong held-out windows")
        if record.get("backbone_frozen") is not True:
            raise ContractError(f"{fold.held_out_session}: frozen-backbone condition reports a trainable backbone")
        modules = record.get("trainable_modules")
        if not isinstance(modules, list) or set(modules) != {"four_channel_adapter", "linear_head"}:
            raise ContractError(f"{fold.held_out_session}: only adapter and linear head may be trainable")
        checkpoint_sha = record.get("adapter_checkpoint_sha256")
        if not isinstance(checkpoint_sha, str) or len(checkpoint_sha) != 64:
            raise ContractError(f"{fold.held_out_session}: adapter checkpoint hash is required")


def _runtime_outcomes(metadata: dict[str, Any]) -> dict[str, Any]:
    value = metadata.get("runtime_outcomes")
    if isinstance(value, dict):
        return value
    return {
        "status": "not_recorded",
        "reason": "Legacy or manually assembled fold predictions omitted worker runtime measurements.",
    }


def evaluate_external_fold_predictions(
    dataset: CanonicalDataset,
    metadata: dict[str, Any],
    probabilities: np.ndarray,
    *,
    split_unit: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    folds = grouped_folds(dataset, split_unit)
    _validate_fold_provenance(metadata, dataset, folds)
    results: list[dict[str, Any]] = []
    for fold in folds:
        test_probabilities = probabilities[fold.test_index]
        predictions = test_probabilities.argmax(axis=1).astype(np.int64)
        results.append(
            {
                "held_out_session": fold.held_out_session,
                "held_out_grouping": fold.grouping,
                "train_sessions": sorted(set(dataset.session_ids[fold.train_index].tolist())),
                "test_sessions": sorted(set(dataset.session_ids[fold.test_index].tolist())),
                "train_window_count": int(len(fold.train_index)),
                "test_window_count": int(len(fold.test_index)),
                "metrics": fold_metrics(predictions, test_probabilities, dataset.labels[fold.test_index], dataset.label_order),
            }
        )
    return results, {"manifest": split_manifest(dataset, folds), "manifest_sha256": split_manifest_sha256(dataset, folds)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--prediction-metadata", required=True, type=Path)
    parser.add_argument("--experiment-config", type=Path, default=DEFAULT_EXPERIMENT_CONFIG_PATH)
    parser.add_argument("--split-unit", choices=("session", "recording_date", "participant", "device", "headset_fit"), default="session")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    dataset = load_dataset(args.dataset)
    dataset_metadata = _load_metadata(args.metadata, dataset)
    dataset_archive_sha256 = sha256_file(args.dataset)
    prediction_metadata = _load_json(args.prediction_metadata)
    experiment_configuration = load_experiment_configuration(args.experiment_config)
    representation = _validate_metadata(prediction_metadata, dataset, dataset_archive_sha256, experiment_configuration)
    probabilities = _load_probabilities(args.predictions, dataset)
    folds, split = evaluate_external_fold_predictions(dataset, prediction_metadata, probabilities, split_unit=args.split_unit)
    result = {
        "schema_version": "nc-eeg-external-fold-evaluation-v0",
        "experiment_id": "EXP-NC-EEG-ENC-001",
        "status": "insufficient_evidence",
        "interpretation": "pipeline_pilot_only",
        "shadow_only": True,
        "live_control": False,
        "promotion_status": "not_eligible",
        "dataset_sha256": dataset_metadata["dataset_sha256"],
        "experiment_configuration_sha256": sha256_json(experiment_configuration),
        "external_embedding": representation,
        "split": {
            "unit": args.split_unit,
            "method": f"leave_one_{args.split_unit}_out",
            "overlap_leakage_possible": False,
            **split,
        },
        "folds": folds,
        "aggregate": aggregate_fold_metrics(folds),
        "runtime_outcomes": _runtime_outcomes(prediction_metadata),
        "deployment": prediction_metadata.get("deployment", offline_deployment_outcome()),
        "run_manifest": {
            **runtime_provenance(Path(__file__).resolve().parents[3]),
            **accelerator_provenance(),
            "package_versions": package_versions(),
        },
        "input_sha256": {
            "dataset": dataset_archive_sha256,
            "metadata": sha256_file(args.metadata),
            "predictions": sha256_file(args.predictions),
            "prediction_metadata": sha256_file(args.prediction_metadata),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}; status={result['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
