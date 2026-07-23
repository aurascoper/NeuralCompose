"""Evaluate a frozen EEGPT/BENDR embedding artifact with grouped linear probes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .dataset import load_dataset
from .evaluate import aggregate_fold_metrics, fold_metrics, _load_metadata
from .models import fit_predict_m0, grouped_folds, split_manifest, split_manifest_sha256
from .provenance import accelerator_provenance, offline_deployment_outcome, package_versions, runtime_provenance, sha256_file
from .representations import load_external_embeddings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--embeddings", required=True, type=Path)
    parser.add_argument("--embedding-metadata", required=True, type=Path)
    parser.add_argument("--split-unit", choices=("session", "recording_date", "participant", "device", "headset_fit"), default="session")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    dataset = load_dataset(args.dataset)
    dataset_metadata = _load_metadata(args.metadata, dataset)
    dataset_archive_sha256 = sha256_file(args.dataset)
    external = load_external_embeddings(
        args.embeddings,
        args.embedding_metadata,
        dataset,
        dataset_archive_sha256=dataset_archive_sha256,
    )
    folds = []
    split_folds = grouped_folds(dataset, args.split_unit)
    canonical_split_manifest = split_manifest(dataset, split_folds)
    for fold in split_folds:
        predictions, probabilities, fit = fit_predict_m0(
            external.values, dataset.labels, fold, class_count=len(dataset.label_order)
        )
        folds.append(
            {
                "held_out_session": fold.held_out_session,
                "held_out_grouping": fold.grouping,
                "train_sessions": sorted(set(dataset.session_ids[fold.train_index].tolist())),
                "test_sessions": sorted(set(dataset.session_ids[fold.test_index].tolist())),
                "metrics": fold_metrics(predictions, probabilities, dataset.labels[fold.test_index], dataset.label_order),
                "fit": fit,
            }
        )
    result = {
        "schema_version": "nc-eeg-external-probe-evaluation-v0",
        "experiment_id": "EXP-NC-EEG-ENC-001",
        "status": "insufficient_evidence",
        "interpretation": (
            "negative_control_only"
            if external.metadata["channel_adapter"].endswith("negative_control")
            else "pipeline_pilot_only"
        ),
        "shadow_only": True,
        "live_control": False,
        "promotion_status": "not_eligible",
        "dataset_sha256": dataset_metadata["dataset_sha256"],
        "experiment_configuration_sha256": external.metadata.get("experiment_configuration_sha256"),
        "external_embedding": external.metadata,
        "embedding_dimension": int(external.values.shape[1]),
        "split": {
            "unit": args.split_unit,
            "method": f"leave_one_{args.split_unit}_out",
            "overlap_leakage_possible": False,
            "manifest": canonical_split_manifest,
            "manifest_sha256": split_manifest_sha256(dataset, split_folds),
        },
        "folds": folds,
        "aggregate": aggregate_fold_metrics(folds),
        "runtime_outcomes": external.metadata.get("runtime_outcomes", {"status": "not_recorded"}),
        "deployment": external.metadata.get("deployment", offline_deployment_outcome()),
        "run_manifest": {
            **runtime_provenance(Path(__file__).resolve().parents[3]),
            **accelerator_provenance(),
            "package_versions": package_versions(),
        },
        "input_sha256": {
            "dataset": dataset_archive_sha256,
            "metadata": sha256_file(args.metadata),
            "embeddings": sha256_file(args.embeddings),
            "embedding_metadata": sha256_file(args.embedding_metadata),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}; status={result['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
