"""Session-grouped pilot evaluation for M0 and M1.

The result is intentionally not a promotion gate. Its job is to prove or
falsify the data/evaluation pipeline before any pretrained encoder claim.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.metrics import balanced_accuracy_score, f1_score, roc_auc_score

from .contracts import ContractError, DATASET_SCHEMA
from .dataset import ARTIFACT_LABELS, CanonicalDataset, load_dataset
from .features import extract_features, feature_names
from .models import fit_predict_m0, fit_predict_m1, grouped_folds, split_manifest, split_manifest_sha256
from .provenance import (
    accelerator_provenance,
    offline_deployment_outcome,
    package_versions,
    runtime_provenance,
    sha256_file,
    sha256_json,
    summarize_runtime_outcomes,
)


DEFAULT_EXPERIMENT_CONFIG_PATH = Path(__file__).resolve().parents[2] / "configs" / "experiment-v0.json"


def expected_calibration_error(probabilities: np.ndarray, labels: np.ndarray, bins: int = 10) -> float:
    confidence = probabilities.max(axis=1)
    correct = probabilities.argmax(axis=1) == labels
    total = len(labels)
    if not total:
        return float("nan")
    ece = 0.0
    for lower in np.linspace(0.0, 1.0, bins, endpoint=False):
        upper = lower + 1.0 / bins
        membership = (confidence >= lower) & ((confidence < upper) if upper < 1.0 else (confidence <= upper))
        if membership.any():
            ece += abs(float(correct[membership].mean()) - float(confidence[membership].mean())) * (membership.sum() / total)
    return float(ece)


def multiclass_brier(probabilities: np.ndarray, labels: np.ndarray, class_count: int) -> float:
    target = np.eye(class_count, dtype=np.float64)[labels]
    return float(np.mean(np.sum((probabilities - target) ** 2, axis=1)))


def artifact_metrics(predictions: np.ndarray, labels: np.ndarray, label_order: tuple[str, ...]) -> dict[str, float | None]:
    artifact_indices = {index for index, label in enumerate(label_order) if label in ARTIFACT_LABELS}
    if not artifact_indices:
        return {"sensitivity": None, "specificity": None}
    actual = np.asarray([label in artifact_indices for label in labels], dtype=bool)
    predicted = np.asarray([label in artifact_indices for label in predictions], dtype=bool)
    positives, negatives = int(actual.sum()), int((~actual).sum())
    return {
        "sensitivity": float((predicted & actual).sum() / positives) if positives else None,
        "specificity": float(((~predicted) & (~actual)).sum() / negatives) if negatives else None,
    }


def fold_metrics(predictions: np.ndarray, probabilities: np.ndarray, labels: np.ndarray, label_order: tuple[str, ...]) -> dict[str, Any]:
    metrics: dict[str, Any] = {
        "macro_f1": float(f1_score(labels, predictions, labels=np.arange(len(label_order)), average="macro", zero_division=0)),
        "balanced_accuracy": float(balanced_accuracy_score(labels, predictions)),
        "brier_score": multiclass_brier(probabilities, labels, len(label_order)),
        "expected_calibration_error": expected_calibration_error(probabilities, labels),
        "artifact": artifact_metrics(predictions, labels, label_order),
    }
    test_classes = np.unique(labels)
    if len(test_classes) > 1:
        try:
            metrics["auroc_ovr_macro"] = float(roc_auc_score(labels, probabilities, labels=np.arange(len(label_order)), multi_class="ovr", average="macro"))
        except ValueError:
            metrics["auroc_ovr_macro"] = None
    else:
        metrics["auroc_ovr_macro"] = None
    return metrics


def _mean_or_none(values: list[float | None]) -> float | None:
    numeric = [value for value in values if value is not None and np.isfinite(value)]
    return float(np.mean(numeric)) if numeric else None


def aggregate_fold_metrics(folds: list[dict[str, Any]]) -> dict[str, Any]:
    metric_names = ("macro_f1", "balanced_accuracy", "auroc_ovr_macro", "brier_score", "expected_calibration_error")
    result = {name: _mean_or_none([fold["metrics"][name] for fold in folds]) for name in metric_names}
    result["artifact_sensitivity"] = _mean_or_none([fold["metrics"]["artifact"]["sensitivity"] for fold in folds])
    result["artifact_specificity"] = _mean_or_none([fold["metrics"]["artifact"]["specificity"] for fold in folds])
    balanced = [fold["metrics"]["balanced_accuracy"] for fold in folds]
    result["cross_session_performance_degradation"] = float(max(balanced) - min(balanced)) if balanced else None
    return result


def _load_metadata(path: Path, dataset: CanonicalDataset) -> dict[str, Any]:
    try:
        metadata = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read dataset metadata: {exc}") from exc
    if metadata.get("schema_version") != DATASET_SCHEMA:
        raise ContractError("dataset metadata has the wrong schema")
    if metadata.get("dataset_sha256") != dataset.artifact_sha256():
        raise ContractError("dataset content does not match its metadata hash")
    if metadata.get("label_order") != list(dataset.label_order):
        raise ContractError("dataset label order does not match metadata")
    return metadata


def run_pilot(
    dataset: CanonicalDataset,
    metadata: dict[str, Any],
    *,
    models: tuple[str, ...] = ("m0", "m1"),
    m0_regularization_c: float = 1.0,
    m1_epochs: int = 20,
    m1_batch_size: int = 32,
    m1_learning_rate: float = 1e-3,
    seed: int = 42,
    device: str = "auto",
    experiment_configuration: dict[str, Any] | None = None,
    split_unit: str = "session",
) -> dict[str, Any]:
    allowed = {"m0", "m1"}
    unexpected = set(models) - allowed
    if unexpected:
        raise ValueError(f"only locally implemented pilot models are available: {sorted(unexpected)}")
    folds = grouped_folds(dataset, split_unit)
    canonical_split_manifest = split_manifest(dataset, folds)
    if len(np.unique(dataset.labels)) < 2:
        raise ContractError("target is degenerate: fewer than two observed labels")
    features = extract_features(dataset.windows, dataset.quality, dataset.missing_channel_masks)
    results: dict[str, Any] = {}
    for model_name in models:
        fold_results: list[dict[str, Any]] = []
        started = time.monotonic()
        for fold_index, fold in enumerate(folds):
            if model_name == "m0":
                predictions, probabilities, details = fit_predict_m0(
                    features,
                    dataset.labels,
                    fold,
                    class_count=len(dataset.label_order),
                    regularization_c=m0_regularization_c,
                )
            else:
                predictions, probabilities, details = fit_predict_m1(
                    dataset,
                    fold,
                    class_count=len(dataset.label_order),
                    seed=seed + fold_index,
                    epochs=m1_epochs,
                    batch_size=m1_batch_size,
                    learning_rate=m1_learning_rate,
                    device=device,
                )
            fold_results.append(
                {
                    "held_out_session": fold.held_out_session,
                    "held_out_grouping": fold.grouping,
                    "train_sessions": sorted(set(dataset.session_ids[fold.train_index].tolist())),
                    "test_sessions": sorted(set(dataset.session_ids[fold.test_index].tolist())),
                    "train_window_count": int(len(fold.train_index)),
                    "test_window_count": int(len(fold.test_index)),
                    "metrics": fold_metrics(predictions, probabilities, dataset.labels[fold.test_index], dataset.label_order),
                    "fit": details,
                }
            )
        results[model_name] = {
            "folds": fold_results,
            "aggregate": aggregate_fold_metrics(fold_results),
            "runtime_outcomes": summarize_runtime_outcomes(
                [fold["fit"] for fold in fold_results], elapsed_seconds=time.monotonic() - started
            ),
        }
    return {
        "schema_version": "nc-eeg-evaluation-v0",
        "experiment_id": "EXP-NC-EEG-ENC-001",
        "hypothesis_id": "H-NC-EEG-ENC-001",
        "status": "insufficient_evidence",
        "interpretation": "pipeline_pilot_only",
        "shadow_only": True,
        "live_control": False,
        "promotion_status": "not_eligible",
        "dataset_sha256": metadata["dataset_sha256"],
        "source_manifest_sha256": dataset.source_manifest_sha256,
        "preprocessing_sha256": dataset.preprocessing_sha256,
        "split": {
            "unit": split_unit,
            "method": f"leave_one_{split_unit}_out",
            "session_count": len(folds),
            "overlap_leakage_possible": False,
            "manifest": canonical_split_manifest,
            "manifest_sha256": split_manifest_sha256(dataset, folds),
        },
        "target": {
            "label_order": list(dataset.label_order),
            "window_count": int(len(dataset.labels)),
            "class_counts": {label: int((dataset.labels == index).sum()) for index, label in enumerate(dataset.label_order)},
            "nondegenerate": bool(len(np.unique(dataset.labels)) >= 2),
        },
        "m0_feature_contract": {
            "feature_names": feature_names(),
            "features_precomputed_without_labels": True,
            "normalization": "StandardScaler fit only inside each training fold",
        },
        "models": results,
        "run_manifest": {
            **runtime_provenance(Path(__file__).resolve().parents[3]),
            **accelerator_provenance(),
            "package_versions": package_versions(),
            "requested_device": device,
            "seed": seed,
            "experiment_configuration": experiment_configuration,
            "experiment_configuration_sha256": sha256_json(experiment_configuration) if experiment_configuration else None,
        },
        "deployment": offline_deployment_outcome(),
    }


def load_experiment_configuration(path: Path) -> dict[str, Any]:
    try:
        configuration = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read experiment config {path}: {exc}") from exc
    if configuration.get("schema_version") != "nc-eeg-experiment-config-v0":
        raise ContractError("experiment configuration has the wrong schema")
    required_sections = ("m0", "m1", "m2_m3", "m4", "fixed_controls")
    if any(not isinstance(configuration.get(section), dict) for section in required_sections):
        raise ContractError(f"experiment configuration needs sections: {', '.join(required_sections)}")
    for section in ("m1", "m2_m3", "m4"):
        budget = configuration[section]
        for field in ("epochs", "batch_size", "learning_rate", "seed"):
            if not isinstance(budget.get(field), (int, float)):
                raise ContractError(f"experiment configuration {section}.{field} must be numeric")
        if int(budget["epochs"]) < 1 or int(budget["batch_size"]) < 1 or float(budget["learning_rate"]) <= 0:
            raise ContractError(f"experiment configuration {section} has an invalid optimization budget")
    for field in ("batch_size", "seed"):
        if not isinstance(configuration["fixed_controls"].get(field), (int, float)):
            raise ContractError(f"experiment configuration fixed_controls.{field} must be numeric")
    return configuration


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--models", default="m0,m1", help="Comma-separated subset of m0,m1")
    parser.add_argument("--experiment-config", type=Path, default=DEFAULT_EXPERIMENT_CONFIG_PATH)
    parser.add_argument("--m1-epochs", type=int)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--split-unit", choices=("session", "recording_date", "participant", "device", "headset_fit"), default="session")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    dataset = load_dataset(args.dataset)
    metadata = _load_metadata(args.metadata, dataset)
    configuration = load_experiment_configuration(args.experiment_config)
    m0_configuration = configuration["m0"]
    m1_configuration = configuration["m1"]
    if args.m1_epochs is not None and args.m1_epochs != int(m1_configuration["epochs"]):
        raise SystemExit("--m1-epochs must match the fixed experiment configuration")
    result = run_pilot(
        dataset,
        metadata,
        models=tuple(value.strip().lower() for value in args.models.split(",") if value.strip()),
        m0_regularization_c=float(m0_configuration["regularization_c"]),
        m1_epochs=int(m1_configuration["epochs"]),
        m1_batch_size=int(m1_configuration["batch_size"]),
        m1_learning_rate=float(m1_configuration["learning_rate"]),
        seed=int(m1_configuration["seed"]),
        device=args.device,
        experiment_configuration=configuration,
        split_unit=args.split_unit,
    )
    result["dataset_archive_sha256"] = sha256_file(args.dataset)
    result["dataset_metadata_sha256"] = sha256_file(args.metadata)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}; status={result['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
