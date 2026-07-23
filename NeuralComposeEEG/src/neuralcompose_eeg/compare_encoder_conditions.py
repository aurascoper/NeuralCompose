"""Assemble compatible EXP-NC-EEG-ENC-001 condition reports.

This is deliberately an evidence ledger, not a model selector. It makes the
comparison prerequisites machine-checkable while retaining the pilot's fixed
``insufficient_evidence`` outcome.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from .contracts import ContractError
from .provenance import runtime_provenance, sha256_file


COMPARISON_SCHEMA = "nc-eeg-encoder-comparison-v0"
HIGHER_IS_BETTER = ("macro_f1", "balanced_accuracy", "auroc_ovr_macro", "artifact_sensitivity", "artifact_specificity")
LOWER_IS_BETTER = ("brier_score", "expected_calibration_error", "cross_session_performance_degradation")


def _read_result(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read evaluation artifact {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"evaluation artifact {path} must contain a JSON object")
    return value


def _require_common(result: dict[str, Any], reference: dict[str, Any]) -> None:
    if result.get("experiment_id") != "EXP-NC-EEG-ENC-001":
        raise ContractError("all condition reports must belong to EXP-NC-EEG-ENC-001")
    if result.get("dataset_sha256") != reference["dataset_sha256"]:
        raise ContractError("condition reports reference different canonical datasets")
    if result.get("experiment_configuration_sha256") != reference["experiment_configuration_sha256"]:
        raise ContractError("condition reports do not attest to the same fixed experiment configuration")
    split = result.get("split")
    if not isinstance(split, dict) or split.get("manifest_sha256") != reference["split_manifest_sha256"]:
        raise ContractError("condition reports did not use the same grouped split manifest")
    if split.get("overlap_leakage_possible") is not False:
        raise ContractError("a condition report does not rule out overlap leakage")


def _metric_deltas(candidate: dict[str, Any], comparator: dict[str, Any]) -> dict[str, float | None]:
    values: dict[str, float | None] = {}
    for name in (*HIGHER_IS_BETTER, *LOWER_IS_BETTER):
        candidate_value = candidate.get(name)
        comparator_value = comparator.get(name)
        if candidate_value is None or comparator_value is None:
            values[name] = None
            continue
        raw = float(candidate_value) - float(comparator_value)
        values[name] = raw if name in HIGHER_IS_BETTER else -raw
    return values


def _condition_id(metadata: dict[str, Any]) -> str:
    model = metadata["model_id"]
    initialization = metadata["initialization"]
    adapter = metadata["channel_adapter"]
    if adapter.endswith("negative_control"):
        return f"control:{model}:{initialization}:{adapter}"
    if model == "eegpt" and initialization == "random":
        return f"m2:eegpt-random:{adapter}"
    if model == "eegpt" and initialization == "pretrained":
        return f"m3:eegpt-frozen:{adapter}"
    if model == "bendr" and initialization == "pretrained":
        return f"m4:bendr-frozen:{adapter}"
    return f"control:{model}:{initialization}:{adapter}"


def _external_condition(report: dict[str, Any], source_sha256: str, reference: dict[str, Any]) -> dict[str, Any]:
    if report.get("schema_version") not in {
        "nc-eeg-external-probe-evaluation-v0",
        "nc-eeg-external-fold-evaluation-v0",
    }:
        raise ContractError("external condition has the wrong evaluation schema")
    _require_common(report, reference)
    metadata = report.get("external_embedding")
    aggregate = report.get("aggregate")
    if not isinstance(metadata, dict) or not isinstance(aggregate, dict):
        raise ContractError("external condition lacks embedding provenance or aggregate metrics")
    for field in ("model_id", "initialization", "channel_adapter", "missing_channel_mask", "checkpoint_sha256"):
        if not isinstance(metadata.get(field), str) or not metadata[field]:
            raise ContractError(f"external condition lacks {field}")
    return {
        "id": _condition_id(metadata),
        "source_sha256": source_sha256,
        "metrics": aggregate,
        "runtime_outcomes": report.get("runtime_outcomes", {"status": "not_recorded"}),
        "deployment": report.get("deployment", {"status": "not_recorded"}),
        "provenance": {
            "model_id": metadata["model_id"],
            "initialization": metadata["initialization"],
            "channel_adapter": metadata["channel_adapter"],
            "missing_channel_mask": metadata["missing_channel_mask"],
            "checkpoint_sha256": metadata["checkpoint_sha256"],
            "model_revision": metadata.get("model_revision"),
            "extractor_sha256": metadata.get("extractor_sha256"),
        },
    }


def _matched_random(pretrained: dict[str, Any], conditions: list[dict[str, Any]]) -> bool:
    target = pretrained["provenance"]
    return any(
        condition["provenance"].get("model_id") == target["model_id"]
        and condition["provenance"].get("initialization") == "random"
        and condition["provenance"].get("channel_adapter") == target["channel_adapter"]
        and condition["provenance"].get("missing_channel_mask") == target["missing_channel_mask"]
        for condition in conditions
    )


def _required_controls(conditions: list[dict[str, Any]]) -> dict[str, bool]:
    adapters = {condition["provenance"].get("channel_adapter") for condition in conditions if "provenance" in condition}
    return {
        "shuffled_electrode_mapping": "shuffled_electrode_mapping_negative_control" in adapters,
        "zero_filled_no_mask": "zero_filled_no_mask_negative_control" in adapters,
    }


def assemble_encoder_comparison(
    local_evaluation: dict[str, Any],
    external_evaluations: list[tuple[str, dict[str, Any]]],
    *,
    source_hashes: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Validate common evidence and emit an explicitly non-promotable ledger."""
    if local_evaluation.get("schema_version") != "nc-eeg-evaluation-v0":
        raise ContractError("local evaluation has the wrong schema")
    split = local_evaluation.get("split")
    if not isinstance(split, dict) or not isinstance(split.get("manifest_sha256"), str):
        raise ContractError("local evaluation lacks a grouped split manifest")
    if local_evaluation.get("experiment_id") != "EXP-NC-EEG-ENC-001":
        raise ContractError("local evaluation is not an encoder-benchmark artifact")
    models = local_evaluation.get("models")
    if not isinstance(models, dict):
        raise ContractError("local evaluation lacks model results")
    reference = {
        "dataset_sha256": local_evaluation.get("dataset_sha256"),
        "split_manifest_sha256": split["manifest_sha256"],
        "experiment_configuration_sha256": local_evaluation.get("run_manifest", {}).get("experiment_configuration_sha256"),
    }
    if not isinstance(reference["dataset_sha256"], str) or not reference["dataset_sha256"]:
        raise ContractError("local evaluation lacks dataset identity")
    if not isinstance(reference["experiment_configuration_sha256"], str) or not reference["experiment_configuration_sha256"]:
        raise ContractError("local evaluation lacks fixed experiment configuration provenance")

    conditions: list[dict[str, Any]] = []
    for model_id, expected in (("m0", "M0"), ("m1", "M1")):
        model = models.get(model_id)
        if isinstance(model, dict) and isinstance(model.get("aggregate"), dict):
            conditions.append(
                {
                    "id": model_id,
                    "source_sha256": None,
                    "metrics": model["aggregate"],
                    "runtime_outcomes": model.get("runtime_outcomes", {"status": "not_recorded"}),
                    "deployment": local_evaluation.get("deployment", {"status": "not_recorded"}),
                    "provenance": {"model": expected},
                }
            )

    hashes = source_hashes or {}
    for source_id, report in external_evaluations:
        conditions.append(_external_condition(report, hashes.get(source_id, "unknown"), reference))

    condition_ids = [condition["id"] for condition in conditions]
    if len(set(condition_ids)) != len(condition_ids):
        raise ContractError("multiple reports claim the same condition identity; compare one prespecified condition at a time")
    by_id = {condition["id"]: condition for condition in conditions}
    m0 = by_id.get("m0")
    m1 = by_id.get("m1")
    pretrained = [condition for condition in conditions if condition["id"].startswith(("m3:", "m4:"))]
    controls = _required_controls(conditions)
    readiness: list[dict[str, Any]] = []
    for condition in pretrained:
        comparisons: dict[str, dict[str, float | None]] = {}
        if m0 is not None:
            comparisons["m0"] = _metric_deltas(condition["metrics"], m0["metrics"])
        if m1 is not None:
            comparisons["m1"] = _metric_deltas(condition["metrics"], m1["metrics"])
        matched_random = _matched_random(condition, conditions)
        readiness.append(
            {
                "condition_id": condition["id"],
                "matched_random_initialization": matched_random,
                "mapping_controls_present": controls,
                "comparisons_positive_when_metric_is_higher": comparisons,
                "eligible_for_transfer_claim": False,
                "reason": (
                    "No pilot comparison can establish encoder transfer. Confirmation still requires a protocol-complete, "
                    "multi-session corpus and preregistered statistical review."
                ),
            }
        )

    required = {"m0", "m1"}
    missing_core_conditions = sorted(required - set(condition_ids))
    return {
        "schema_version": COMPARISON_SCHEMA,
        "experiment_id": "EXP-NC-EEG-ENC-001",
        "status": "insufficient_evidence",
        "interpretation": "pipeline_and_control_readiness_only",
        "shadow_only": True,
        "live_control": False,
        "promotion_status": "not_eligible",
        "dataset_sha256": reference["dataset_sha256"],
        "experiment_configuration_sha256": reference["experiment_configuration_sha256"],
        "split_manifest_sha256": reference["split_manifest_sha256"],
        "conditions": conditions,
        "required_core_conditions_missing": missing_core_conditions,
        "pretrained_condition_readiness": readiness,
        "evidence_limit": (
            "This ledger verifies compatibility and control presence. It does not establish generalized EEG understanding, "
            "select a deployment model, or authorize ARC/Qwen work."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-evaluation", required=True, type=Path)
    parser.add_argument("--external-evaluation", action="append", default=[], type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    local = _read_result(args.local_evaluation)
    external = [(str(path), _read_result(path)) for path in args.external_evaluation]
    source_hashes = {str(args.local_evaluation): sha256_file(args.local_evaluation)}
    source_hashes.update({str(path): sha256_file(path) for path in args.external_evaluation})
    result = assemble_encoder_comparison(local, external, source_hashes=source_hashes)
    result["input_sha256"] = source_hashes
    result["run_manifest"] = runtime_provenance(Path(__file__).resolve().parents[3])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}; status={result['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
