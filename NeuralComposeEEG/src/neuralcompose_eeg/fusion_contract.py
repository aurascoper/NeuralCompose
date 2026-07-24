"""Deterministic D0 contracts for late EEG representation fusion.

This module consumes only synthetic encoder-output fixtures. It does not read
EEG, train an encoder or fusion head, execute Qwen, or expose a runtime path.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
from pathlib import Path
from typing import Any, Iterable

from .contracts import ContractError


CONFIG_SCHEMA = "nc-eeg-fusion-synthetic-config-v0"
FIXTURE_SCHEMA = "nc-eeg-synthetic-encoder-pair-v0"
ENCODER_OUTPUT_SCHEMA = "nc-eeg-synthetic-encoder-output-v0"
STATE_SCHEMA = "nc-eeg-fused-state-v0"
REPLAY_MANIFEST_SCHEMA = "nc-eeg-fused-state-replay-manifest-v0"
REPORT_SCHEMA = "nc-eeg-fusion-synthetic-report-v0"
QWEN_INPUT_SCHEMA = "nc-eeg-qwen-shadow-input-v0"
QWEN_OUTPUT_SCHEMA = "nc-eeg-qwen-shadow-output-v0"
SYNTHETIC_CHECKPOINT_SCHEMA = "nc-eeg-synthetic-checkpoint-definition-v0"

_FIXED_DISPOSITION = {
    "status": "foundational_study_only",
    "data_gate": "D0",
    "decision": "insufficient_evidence",
    "promotion_status": "not_eligible",
    "runtime_change": "none",
    "source_type": "deterministic_synthetic_fixture",
    "physical_eeg_used": False,
    "scientific_claim_allowed": False,
    "shadow_only": True,
}
_MODEL_IDS = ("eegnet", "eegpt")
_CHANNELS = ("TP9", "AF7", "AF8", "TP10")
_SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9._-]+$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_EXPECTED_QWEN_TASK = "rank_registered_engineering_hypotheses_from_synthetic_fused_state"
_EXPECTED_QWEN_REASON_CODES = (
    "encoder_agreement",
    "encoder_disagreement",
    "high_predictive_entropy",
    "low_signal_quality",
    "missing_encoder",
    "insufficient_evidence",
)
_FORBIDDEN_QWEN_FIELDS = frozenset(
    {
        "agreement",
        "diagnosis",
        "dialogue",
        "eeg_values",
        "emotion",
        "encoder_embedding",
        "encoder_embeddings",
        "free_text",
        "intention",
        "prompt",
        "raw_eeg",
        "speech",
        "thought",
        "waveform",
        "waveforms",
    }
)
_EXPECTED_CONDITIONS = (
    {
        "id": "F0",
        "name": "eegnet_alone",
        "implemented_status": "d0_synthetic_baseline",
        "role": "compact_encoder_baseline",
        "earliest_physical_gate": "D3",
        "trainable_within_fusion_stage": [],
        "permitted_source_type": "deterministic_synthetic_fixture",
        "missing_model_behavior": "require_eegnet",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "synthetic_interface_rehearsal_only_at_D0",
    },
    {
        "id": "F1",
        "name": "eegpt_alone",
        "implemented_status": "d0_synthetic_baseline",
        "role": "pretrained_representation_baseline",
        "earliest_physical_gate": "D3",
        "trainable_within_fusion_stage": ["four_channel_adapter"],
        "permitted_source_type": "deterministic_synthetic_fixture",
        "missing_model_behavior": "require_eegpt",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "synthetic_interface_rehearsal_only_at_D0",
    },
    {
        "id": "F2",
        "name": "fixed_average_of_calibrated_probabilities",
        "implemented_status": "d0_synthetic_baseline",
        "role": "parameter_free_fusion_baseline",
        "earliest_physical_gate": "D3",
        "trainable_within_fusion_stage": [],
        "permitted_source_type": "deterministic_synthetic_fixture",
        "missing_model_behavior": "require_both_or_fail_closed",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "parameter_free_synthetic_fusion_rehearsal_only_at_D0",
    },
    {
        "id": "F3",
        "name": "train_only_regularized_logistic_fusion_head",
        "implemented_status": "specified_not_implemented",
        "role": "first_learned_fusion_condition",
        "earliest_physical_gate": "D3",
        "trainable_within_fusion_stage": ["four_channel_adapter", "fusion_head"],
        "permitted_source_type": "none_at_D0",
        "missing_model_behavior": "require_both_or_fail_closed",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "requires_session_grouped_D3_comparison",
    },
    {
        "id": "F4",
        "name": "small_mlp_fusion_head",
        "implemented_status": "specified_not_implemented",
        "role": "nonlinear_fusion_comparator",
        "earliest_physical_gate": "D3",
        "trainable_within_fusion_stage": ["four_channel_adapter", "fusion_head"],
        "permitted_source_type": "none_at_D0",
        "missing_model_behavior": "require_both_or_fail_closed",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "requires_session_grouped_D3_comparison",
    },
    {
        "id": "F5",
        "name": "uncertainty_gated_mixture_of_experts",
        "implemented_status": "specified_not_implemented",
        "role": "reliability_aware_fusion_comparator",
        "earliest_physical_gate": "D3",
        "trainable_within_fusion_stage": ["four_channel_adapter", "fusion_head"],
        "permitted_source_type": "none_at_D0",
        "missing_model_behavior": "require_both_or_fail_closed",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "requires_session_grouped_D3_comparison",
    },
    {
        "id": "F6",
        "name": "eegpt_to_eegnet_distillation",
        "implemented_status": "specified_not_implemented",
        "role": "post_fusion_deployment_study",
        "earliest_physical_gate": "post_fusion_evidence",
        "trainable_within_fusion_stage": ["eegnet_student"],
        "permitted_source_type": "none_at_D0",
        "missing_model_behavior": "not_executable_at_D0",
        "separate_preregistration_required": True,
        "runtime_use_prohibited": True,
        "scientific_interpretation": "requires_validated_teacher_and_separate_distillation_evidence",
    },
)
_EXPECTED_MISSING_MODEL_POLICY = {
    condition["id"]: condition["missing_model_behavior"] for condition in _EXPECTED_CONDITIONS
}
_STATE_KEYS = {
    "schema_version",
    "experiment_id",
    "state_id",
    "status",
    "data_gate",
    "decision",
    "promotion_status",
    "runtime_change",
    "source_type",
    "synthetic_only",
    "physical_eeg_used",
    "scientific_claim_allowed",
    "shadow_only",
    "live_control",
    "qwen_policy_stage",
    "source",
    "encoder_provenance",
    "fusion",
    "signal_quality",
    "artifact_probabilities",
    "observable_state_probabilities",
    "encoder_disagreement",
    "predictive_entropy",
    "out_of_distribution_score",
    "calibration_scope",
}


def _canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_json(value: Any) -> str:
    return _sha256_bytes(_canonical_json(value).encode("utf-8"))


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _sha256_lines(records: Iterable[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for record in records:
        digest.update(_canonical_json(record).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def _require_exact_keys(value: Any, expected: set[str], name: str) -> dict[str, Any]:
    _require(isinstance(value, dict), f"{name} must be an object")
    actual = set(value)
    _require(
        actual == expected,
        f"{name} fields differ: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}",
    )
    return value


def _finite_number(value: Any, name: str) -> float:
    _require(isinstance(value, (int, float)) and not isinstance(value, bool), f"{name} must be numeric")
    number = float(value)
    _require(math.isfinite(number), f"{name} must be finite")
    return number


def _probability(value: Any, name: str) -> float:
    number = _finite_number(value, name)
    _require(0.0 <= number <= 1.0, f"{name} must be in [0, 1]")
    return number


def _safe_identifier(value: Any, name: str) -> str:
    _require(isinstance(value, str) and bool(_SAFE_IDENTIFIER.fullmatch(value)), f"{name} must be a bounded identifier")
    return value


def _sha256_identifier(value: Any, name: str) -> str:
    _require(isinstance(value, str) and bool(_SHA256.fullmatch(value)), f"{name} must be a SHA-256 digest")
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant: {value}")


def _strict_json_loads(text: str, name: str) -> Any:
    try:
        return json.loads(text, parse_constant=_reject_json_constant)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ContractError(f"{name} is malformed: {exc}") from exc


def _reject_forbidden_qwen_fields(value: Any, name: str = "Qwen payload") -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            _require(isinstance(key, str), f"{name} keys must be strings")
            _require(key.casefold() not in _FORBIDDEN_QWEN_FIELDS, f"{name} contains forbidden field: {key}")
            _reject_forbidden_qwen_fields(nested, f"{name}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            _reject_forbidden_qwen_fields(nested, f"{name}[{index}]")


def _read_json(path: Path, name: str) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(f"cannot read {name}: {exc}") from exc
    value = _strict_json_loads(text, name)
    _require(isinstance(value, dict), f"{name} must contain an object")
    return value


def _resolve_contract_path(contract_path: Path, relative: Any, category: str) -> Path:
    _require(isinstance(relative, str) and relative, f"{category} path is required")
    supplied = Path(relative)
    _require(not supplied.is_absolute(), f"{category} path must be relative")
    package_root = contract_path.resolve().parent.parent
    resolved = (contract_path.parent / supplied).resolve()
    allowed_root = (package_root / category).resolve()
    try:
        resolved.relative_to(allowed_root)
    except ValueError as exc:
        raise ContractError(f"{category} path escapes {allowed_root.name}") from exc
    _require(resolved.is_file(), f"{category} path does not exist")
    return resolved


def _validate_probability_vector(
    value: Any,
    *,
    labels: list[str],
    tolerance: float,
    name: str,
) -> list[float]:
    _require(isinstance(value, list) and len(value) == len(labels), f"{name} must match label_order")
    probabilities = [_probability(item, f"{name}[{index}]") for index, item in enumerate(value)]
    _require(math.isclose(sum(probabilities), 1.0, rel_tol=0.0, abs_tol=tolerance), f"{name} must sum to one")
    return probabilities


def _validate_state_schema(path: Path) -> None:
    schema = _read_json(path, "fused-state schema")
    _require(schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema", "state schema draft changed")
    properties = schema.get("properties")
    _require(isinstance(properties, dict), "state schema properties are required")
    _require(properties.get("schema_version", {}).get("const") == STATE_SCHEMA, "state schema version changed")
    _require(properties.get("experiment_id", {}).get("const") == "EXP-NC-EEG-FUSION-001", "state experiment changed")
    _require(schema.get("additionalProperties") is False, "state schema must reject extra fields")
    _require(set(schema.get("required", ())) == _STATE_KEYS, "state schema required fields changed")


def validate_fusion_contract(contract: dict[str, Any], contract_path: Path) -> dict[str, Any]:
    """Validate the D0 fusion contract and its bounded local references."""
    required = {
        "schema_version",
        "experiment_id",
        "scope",
        "current_gate",
        "fixed_disposition",
        "architecture",
        "encoders",
        "conditions",
        "current_execution",
        "probability_space",
        "metrics",
        "controls",
        "missing_model_policy",
        "state_contract",
        "fixtures",
        "qwen_bridge",
    }
    _require_exact_keys(contract, required, "fusion contract")
    _require(contract["schema_version"] == CONFIG_SCHEMA, "fusion config schema changed")
    _require(contract["experiment_id"] == "EXP-NC-EEG-FUSION-001", "fusion experiment id changed")
    _require(contract["scope"] == "late_representation_fusion", "fusion scope changed")
    _require(contract["current_gate"] == "D0", "fusion contract is not at D0")

    expected_disposition = {
        **_FIXED_DISPOSITION,
        "dialogue_logs_used": False,
        "model_execution": False,
        "weights_updated": False,
    }
    disposition = _require_exact_keys(
        contract["fixed_disposition"],
        set(expected_disposition),
        "fixed disposition",
    )
    for key, expected in expected_disposition.items():
        _require(disposition[key] == expected, f"fixed disposition {key} changed")

    architecture = contract["architecture"]
    _require(isinstance(architecture, dict), "architecture must be an object")
    for field in (
        "direct_weight_fusion",
        "joint_end_to_end_training_now",
        "eegnet_eegpt_tensor_merge",
        "eeg_encoder_qwen_tensor_merge",
        "joint_raw_eeg_language_training",
        "online_weight_updates",
    ):
        _require(architecture.get(field) is False, f"{field} must remain false")
    _require(architecture.get("method") == "late_representation_fusion", "fusion method changed")
    _require(architecture.get("m0_m4_unchanged") is True, "M0-M4 must remain unchanged")

    encoders = contract["encoders"]
    _require(isinstance(encoders, dict) and set(encoders) == set(_MODEL_IDS), "encoder definitions changed")
    _require(encoders["eegnet"].get("backbone_frozen_within_fusion_stage") is True, "EEGNet must be frozen")
    _require(encoders["eegpt"].get("backbone_frozen_within_fusion_stage") is True, "EEGPT must be frozen")
    _require(encoders["eegpt"].get("channel_adapter") == "four_channel_adapter", "EEGPT adapter must be explicit")
    for model_id in _MODEL_IDS:
        dimension = encoders[model_id].get("fixture_embedding_dimension")
        _require(isinstance(dimension, int) and dimension > 0, f"{model_id} fixture dimension is invalid")
        checkpoint = _require_exact_keys(
            encoders[model_id].get("fixture_checkpoint"),
            {"kind", "definition", "sha256"},
            f"{model_id} fixture checkpoint",
        )
        _require(
            checkpoint["kind"] == "deterministic_synthetic_parameter_fixture",
            f"{model_id} checkpoint kind changed",
        )
        definition = _require_exact_keys(
            checkpoint["definition"],
            {
                "schema_version",
                "model_id",
                "model_revision",
                "adapter",
                "embedding_dimension",
                "parameter_fixture",
            },
            f"{model_id} checkpoint definition",
        )
        _require(definition["schema_version"] == SYNTHETIC_CHECKPOINT_SCHEMA, f"{model_id} checkpoint schema changed")
        _require(definition["model_id"] == model_id, f"{model_id} checkpoint identity changed")
        _safe_identifier(definition["model_revision"], f"{model_id} checkpoint revision")
        _safe_identifier(definition["adapter"], f"{model_id} checkpoint adapter")
        _require(definition["embedding_dimension"] == dimension, f"{model_id} checkpoint dimension changed")
        parameters = definition["parameter_fixture"]
        _require(isinstance(parameters, list) and parameters, f"{model_id} checkpoint parameters are required")
        for index, value in enumerate(parameters):
            _finite_number(value, f"{model_id} checkpoint parameter[{index}]")
        checkpoint_sha256 = _sha256_identifier(checkpoint["sha256"], f"{model_id} checkpoint sha256")
        _require(checkpoint_sha256 == _sha256_json(definition), f"{model_id} checkpoint hash does not match definition")
    _require(
        encoders["eegnet"]["fixture_checkpoint"]["sha256"]
        != encoders["eegpt"]["fixture_checkpoint"]["sha256"],
        "synthetic encoder checkpoints must have distinct identities",
    )

    conditions = contract["conditions"]
    _require(conditions == list(_EXPECTED_CONDITIONS), "conditions must exactly match the F0-F6 registry")

    execution = contract["current_execution"]
    _require_exact_keys(
        execution,
        {"synthetic_conditions", "state_emitting_conditions", "allowed", "forbidden"},
        "current execution",
    )
    _require(execution.get("synthetic_conditions") == ["F0", "F1", "F2"], "D0 synthetic conditions changed")
    _require(execution.get("state_emitting_conditions") == ["F2"], "D0 state-emitting condition changed")
    forbidden = set(execution.get("forbidden", ()))
    _require(
        {
            "physical_data_read",
            "encoder_training",
            "fusion_head_training",
            "qwen_model_execution",
            "qwen_weight_update",
            "threshold_selection",
            "runtime_integration",
            "live_control",
        }
        <= forbidden,
        "D0 forbidden operations are incomplete",
    )

    probability_space = contract["probability_space"]
    labels = probability_space.get("label_order")
    artifacts = probability_space.get("artifact_labels")
    observables = probability_space.get("observable_state_labels")
    _require(
        isinstance(labels, list) and len(labels) == 8 and len(set(labels)) == 8,
        "label_order must contain eight labels",
    )
    _require(isinstance(artifacts, list) and isinstance(observables, list), "label partitions are required")
    _require(set(artifacts).isdisjoint(observables), "artifact and observable labels overlap")
    _require(set(artifacts) | set(observables) == set(labels), "label partitions must cover label_order")
    tolerance = _finite_number(probability_space.get("sum_tolerance"), "sum_tolerance")
    _require(0 < tolerance <= 1e-6, "sum_tolerance is out of bounds")

    bins = contract.get("metrics", {}).get("calibration", {}).get("expected_calibration_error_bins")
    _require(isinstance(bins, list) and len(bins) >= 3, "calibration bins are required")
    normalized_bins = [_probability(item, f"calibration bin {index}") for index, item in enumerate(bins)]
    _require(normalized_bins == sorted(set(normalized_bins)), "calibration bins must be unique and sorted")
    _require(normalized_bins[0] == 0.0 and normalized_bins[-1] == 1.0, "calibration bins must span [0, 1]")

    required_controls = {
        "eegnet_alone",
        "eegpt_alone",
        "fixed_probability_average",
        "randomly_initialized_eegpt_same_adapter",
        "shuffled_eegpt_embeddings",
        "shuffled_eegnet_embeddings",
        "matched_dimension_noise_encoder",
        "matched_parameter_count_fusion_head",
        "session_identity_probe",
        "channel_map_shuffle",
        "missing_channel_control",
    }
    _require(set(contract["controls"]) == required_controls, "fusion controls changed")
    _require(
        contract["missing_model_policy"] == _EXPECTED_MISSING_MODEL_POLICY,
        "missing-model policy must exactly match F0-F6",
    )

    state_contract = contract["state_contract"]
    _require(state_contract.get("schema_version") == STATE_SCHEMA, "fused-state version changed")
    _require(state_contract.get("replay_manifest_schema_version") == REPLAY_MANIFEST_SCHEMA, "replay schema changed")
    _require(state_contract.get("report_schema_version") == REPORT_SCHEMA, "report schema changed")
    _require(state_contract.get("embeddings_serialized") is False, "embeddings cannot enter fused state")
    _require(state_contract.get("waveforms_serialized") is False, "waveforms cannot enter fused state")
    _validate_state_schema(_resolve_contract_path(contract_path, state_contract.get("schema_path"), "schemas"))

    fixtures = _require_exact_keys(
        contract["fixtures"],
        {"schema_version", "source_kind", "source_type", "path", "required_count"},
        "fixture registry",
    )
    _require(fixtures.get("schema_version") == FIXTURE_SCHEMA, "fixture schema changed")
    _require(fixtures.get("source_kind") == "synthetic_contract_fixture", "fixtures must remain synthetic")
    _require(
        fixtures.get("source_type") == "deterministic_synthetic_fixture",
        "fixture source type must remain deterministic synthetic",
    )
    _require(
        isinstance(fixtures.get("required_count"), int) and fixtures["required_count"] > 0,
        "fixture count is invalid",
    )
    _resolve_contract_path(contract_path, fixtures.get("path"), "fixtures")

    qwen = _require_exact_keys(
        contract["qwen_bridge"],
        {
            "current_stage",
            "earliest_execution_gate",
            "model_family",
            "backbone_frozen",
            "model_call_allowed",
            "raw_eeg_allowed",
            "encoder_embeddings_allowed",
            "free_text_state_allowed",
            "input_schema_version",
            "output_schema_version",
            "task",
            "legal_actions",
            "reason_codes",
            "shadow_only",
            "live_control",
            "weights_updated",
        },
        "Qwen bridge",
    )
    _reject_forbidden_qwen_fields(qwen, "Qwen bridge")
    for key, expected in {
        "current_stage": "schema_validation_only",
        "earliest_execution_gate": "post_encoder",
        "backbone_frozen": True,
        "model_call_allowed": False,
        "raw_eeg_allowed": False,
        "encoder_embeddings_allowed": False,
        "free_text_state_allowed": False,
        "input_schema_version": QWEN_INPUT_SCHEMA,
        "output_schema_version": QWEN_OUTPUT_SCHEMA,
        "shadow_only": True,
        "live_control": False,
        "weights_updated": False,
    }.items():
        _require(qwen.get(key) == expected, f"Qwen boundary {key} changed")
    _require(qwen.get("task") == _EXPECTED_QWEN_TASK, "unexpected Qwen task")
    _require(qwen.get("legal_actions") == ["abstain", "hold_state", "request_operator_review"], "legal actions changed")
    _require(
        qwen.get("reason_codes") == list(_EXPECTED_QWEN_REASON_CODES),
        "unexpected Qwen reason-code registry",
    )
    return contract


def load_fusion_contract(path: Path) -> dict[str, Any]:
    return validate_fusion_contract(_read_json(path, "fusion contract"), path)


def _validate_encoder_output(
    value: Any,
    *,
    model_id: str,
    contract: dict[str, Any],
    fixture_id: str,
) -> dict[str, Any]:
    expected = {
        "schema_version",
        "model_id",
        "model_revision",
        "backbone_frozen",
        "adapter",
        "checkpoint_kind",
        "checkpoint_sha256",
        "probabilities",
        "embedding",
        "uncertainty",
    }
    encoder = _require_exact_keys(value, expected, f"{fixture_id}.{model_id}")
    _require(encoder["schema_version"] == ENCODER_OUTPUT_SCHEMA, f"{fixture_id}.{model_id} schema changed")
    _require(encoder["model_id"] == model_id, f"{fixture_id}.{model_id} identity changed")
    _safe_identifier(encoder["model_revision"], f"{fixture_id}.{model_id}.model_revision")
    _require(encoder["backbone_frozen"] is True, f"{fixture_id}.{model_id} backbone must be frozen")
    adapter = _safe_identifier(encoder["adapter"], f"{fixture_id}.{model_id}.adapter")
    if model_id == "eegnet":
        _require(adapter == "none", f"{fixture_id}.eegnet must not invent an adapter")
    else:
        _require(adapter == "four_channel_adapter_synthetic_fixture_v0", f"{fixture_id}.eegpt adapter changed")
    checkpoint = contract["encoders"][model_id]["fixture_checkpoint"]
    _require(
        encoder["model_revision"] == checkpoint["definition"]["model_revision"],
        f"{fixture_id}.{model_id} revision does not match checkpoint",
    )
    _require(
        encoder["checkpoint_kind"] == checkpoint["kind"],
        f"{fixture_id}.{model_id} checkpoint kind changed",
    )
    _require(
        _sha256_identifier(
            encoder["checkpoint_sha256"],
            f"{fixture_id}.{model_id}.checkpoint_sha256",
        )
        == checkpoint["sha256"],
        f"{fixture_id}.{model_id} checkpoint identity changed",
    )
    labels = contract["probability_space"]["label_order"]
    tolerance = float(contract["probability_space"]["sum_tolerance"])
    _validate_probability_vector(
        encoder["probabilities"],
        labels=labels,
        tolerance=tolerance,
        name=f"{fixture_id}.{model_id}.probabilities",
    )
    dimension = contract["encoders"][model_id]["fixture_embedding_dimension"]
    embedding = encoder["embedding"]
    _require(
        isinstance(embedding, list) and len(embedding) == dimension,
        f"{fixture_id}.{model_id} embedding dimension changed",
    )
    for index, item in enumerate(embedding):
        _finite_number(item, f"{fixture_id}.{model_id}.embedding[{index}]")
    _probability(encoder["uncertainty"], f"{fixture_id}.{model_id}.uncertainty")
    return encoder


def validate_synthetic_fixture(value: Any, contract: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "schema_version",
        "fixture_id",
        "source_kind",
        "source_type",
        "status",
        "data_gate",
        "decision",
        "promotion_status",
        "runtime_change",
        "physical_eeg_used",
        "scientific_claim_allowed",
        "shadow_only",
        "synthetic_label",
        "signal_quality",
        "encoders",
    }
    fixture = _require_exact_keys(value, expected, "synthetic encoder-pair fixture")
    _require(fixture["schema_version"] == FIXTURE_SCHEMA, "synthetic fixture schema changed")
    fixture_id = _safe_identifier(fixture["fixture_id"], "fixture_id")
    _require(fixture["source_kind"] == "synthetic_contract_fixture", f"{fixture_id} is not synthetic")
    for key, expected_value in _FIXED_DISPOSITION.items():
        _require(fixture.get(key) == expected_value, f"{fixture_id} disposition {key} changed")
    labels = contract["probability_space"]["label_order"]
    _require(fixture["synthetic_label"] in labels, f"{fixture_id} has an unknown synthetic label")

    quality = _require_exact_keys(
        fixture["signal_quality"],
        {"score", "missing_channels"},
        f"{fixture_id}.signal_quality",
    )
    _probability(quality["score"], f"{fixture_id}.signal_quality.score")
    missing = quality["missing_channels"]
    _require(
        isinstance(missing, list) and len(missing) == len(set(missing)),
        f"{fixture_id} missing channels are invalid",
    )
    _require(all(channel in _CHANNELS for channel in missing), f"{fixture_id} names an unknown channel")

    encoders = fixture["encoders"]
    _require(isinstance(encoders, dict), f"{fixture_id}.encoders must be an object")
    _require(set(encoders) <= set(_MODEL_IDS), f"{fixture_id} names an unsupported encoder")
    for model_id, encoder in encoders.items():
        _validate_encoder_output(encoder, model_id=model_id, contract=contract, fixture_id=fixture_id)
    _require(bool(encoders), f"{fixture_id} must include at least one encoder")
    return fixture


def load_synthetic_fixtures(contract: dict[str, Any], contract_path: Path) -> list[dict[str, Any]]:
    fixture_path = _resolve_contract_path(contract_path, contract["fixtures"]["path"], "fixtures")
    try:
        lines = fixture_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ContractError(f"cannot read synthetic fusion fixtures: {exc}") from exc
    rows = [
        _strict_json_loads(line, f"synthetic fusion fixture line {index}")
        for index, line in enumerate(lines, 1)
        if line
    ]
    fixtures = [validate_synthetic_fixture(row, contract) for row in rows]
    fixture_ids = [fixture["fixture_id"] for fixture in fixtures]
    _require(len(fixtures) == contract["fixtures"]["required_count"], "synthetic fixture count changed")
    _require(len(fixture_ids) == len(set(fixture_ids)), "synthetic fixture ids must be unique")
    return fixtures


def condition_probabilities(
    fixture: dict[str, Any],
    condition_id: str,
    contract: dict[str, Any],
) -> list[float]:
    """Return D0 baseline/fixed-fusion probabilities without fitting parameters."""
    _require(
        condition_id in contract["current_execution"]["synthetic_conditions"],
        f"{condition_id} is not executable at D0",
    )
    encoders = fixture.get("encoders")
    _require(isinstance(encoders, dict), "fixture encoders are required")
    if condition_id == "F0":
        _require("eegnet" in encoders, "F0 requires EEGNet")
        return [float(value) for value in encoders["eegnet"]["probabilities"]]
    if condition_id == "F1":
        _require("eegpt" in encoders, "F1 requires EEGPT")
        return [float(value) for value in encoders["eegpt"]["probabilities"]]
    _require(set(_MODEL_IDS) <= set(encoders), "F2 requires both encoders and fails closed")
    eegnet = encoders["eegnet"]["probabilities"]
    eegpt = encoders["eegpt"]["probabilities"]
    return [(float(left) + float(right)) / 2.0 for left, right in zip(eegnet, eegpt, strict=True)]


def encoder_disagreement(fixture: dict[str, Any]) -> float:
    encoders = fixture.get("encoders", {})
    _require(set(_MODEL_IDS) <= set(encoders), "encoder disagreement requires both encoders")
    left = encoders["eegnet"]["probabilities"]
    right = encoders["eegpt"]["probabilities"]
    return 0.5 * sum(abs(float(a) - float(b)) for a, b in zip(left, right, strict=True))


def _normalized_entropy(probabilities: list[float]) -> float:
    nonzero = [value for value in probabilities if value > 0]
    entropy = -sum(value * math.log(value) for value in nonzero)
    return entropy / math.log(len(probabilities))


def _condition_name(contract: dict[str, Any], condition_id: str) -> str:
    for condition in contract["conditions"]:
        if condition["id"] == condition_id:
            return str(condition["name"])
    raise ContractError(f"unknown fusion condition: {condition_id}")


def build_fused_state(
    fixture: dict[str, Any],
    contract: dict[str, Any],
    *,
    condition_id: str = "F2",
) -> dict[str, Any]:
    """Build a bounded fused state; only fixed F2 may emit one at D0."""
    fixture = validate_synthetic_fixture(fixture, contract)
    _require(
        condition_id in contract["current_execution"]["state_emitting_conditions"],
        "only F2 emits a D0 fused state",
    )
    probabilities = condition_probabilities(fixture, condition_id, contract)
    labels = contract["probability_space"]["label_order"]
    mapped = dict(zip(labels, probabilities, strict=True))
    artifacts = contract["probability_space"]["artifact_labels"]
    observables = contract["probability_space"]["observable_state_labels"]
    disagreement = encoder_disagreement(fixture)
    quality = float(fixture["signal_quality"]["score"])
    uncertainties = [float(fixture["encoders"][model]["uncertainty"]) for model in _MODEL_IDS]
    source_sha256 = _sha256_json(fixture)
    state = {
        "schema_version": STATE_SCHEMA,
        "experiment_id": contract["experiment_id"],
        "state_id": _sha256_bytes(
            f"{contract['experiment_id']}:{fixture['fixture_id']}:{condition_id}:{source_sha256}".encode("utf-8")
        ),
        **_FIXED_DISPOSITION,
        "synthetic_only": True,
        "live_control": False,
        "qwen_policy_stage": "schema_validation_only",
        "source": {
            "fixture_id": fixture["fixture_id"],
            "source_record_sha256": source_sha256,
        },
        "encoder_provenance": {
            model_id: {
                "model_id": model_id,
                "model_revision": fixture["encoders"][model_id]["model_revision"],
                "backbone_frozen": True,
                "adapter": fixture["encoders"][model_id]["adapter"],
                "checkpoint_kind": fixture["encoders"][model_id]["checkpoint_kind"],
                "checkpoint_sha256": fixture["encoders"][model_id]["checkpoint_sha256"],
            }
            for model_id in _MODEL_IDS
        },
        "fusion": {
            "condition_id": condition_id,
            "method": _condition_name(contract, condition_id),
            "status": "complete",
            "trainable_parameters": 0,
        },
        "signal_quality": {
            "score": quality,
            "missing_channels": list(fixture["signal_quality"]["missing_channels"]),
        },
        "artifact_probabilities": {label: mapped[label] for label in artifacts},
        "observable_state_probabilities": {label: mapped[label] for label in observables},
        "encoder_disagreement": disagreement,
        "predictive_entropy": _normalized_entropy(probabilities),
        "out_of_distribution_score": max([*uncertainties, disagreement, 1.0 - quality]),
        "calibration_scope": "synthetic_fixture_rehearsal_only",
    }
    validate_fused_state(state, contract, fixture)
    return state


def validate_fused_state(
    state: Any,
    contract: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    state = _require_exact_keys(state, _STATE_KEYS, "fused state")
    for key, expected in {
        "schema_version": STATE_SCHEMA,
        "experiment_id": contract["experiment_id"],
        **_FIXED_DISPOSITION,
        "synthetic_only": True,
        "shadow_only": True,
        "live_control": False,
        "qwen_policy_stage": "schema_validation_only",
        "calibration_scope": "synthetic_fixture_rehearsal_only",
    }.items():
        _require(state.get(key) == expected, f"fused state {key} changed")
    _require(
        isinstance(state["state_id"], str) and bool(re.fullmatch(r"[0-9a-f]{64}", state["state_id"])),
        "state_id is invalid",
    )

    source = _require_exact_keys(state["source"], {"fixture_id", "source_record_sha256"}, "fused state source")
    _require(source["fixture_id"] == fixture["fixture_id"], "fused state points to another fixture")
    _require(source["source_record_sha256"] == _sha256_json(fixture), "fused state source hash changed")
    expected_state_id = _sha256_bytes(
        (
            f"{contract['experiment_id']}:{fixture['fixture_id']}:F2:"
            f"{source['source_record_sha256']}"
        ).encode("utf-8")
    )
    _require(state["state_id"] == expected_state_id, "fused state id does not match its source")

    provenance = _require_exact_keys(state["encoder_provenance"], set(_MODEL_IDS), "encoder provenance")
    for model_id in _MODEL_IDS:
        encoder = _require_exact_keys(
            provenance[model_id],
            {
                "model_id",
                "model_revision",
                "backbone_frozen",
                "adapter",
                "checkpoint_kind",
                "checkpoint_sha256",
            },
            f"encoder provenance {model_id}",
        )
        _require(encoder["model_id"] == model_id, f"{model_id} provenance identity changed")
        _require(
            encoder["model_revision"] == fixture["encoders"][model_id]["model_revision"],
            f"{model_id} revision changed",
        )
        _require(encoder["backbone_frozen"] is True, f"{model_id} backbone is not frozen")
        _require(encoder["adapter"] == fixture["encoders"][model_id]["adapter"], f"{model_id} adapter changed")
        _require(
            encoder["checkpoint_kind"] == fixture["encoders"][model_id]["checkpoint_kind"],
            f"{model_id} checkpoint kind changed",
        )
        _require(
            _sha256_identifier(encoder["checkpoint_sha256"], f"{model_id} checkpoint sha256")
            == fixture["encoders"][model_id]["checkpoint_sha256"],
            f"{model_id} checkpoint identity changed",
        )
    _require(
        provenance["eegnet"]["checkpoint_sha256"] != provenance["eegpt"]["checkpoint_sha256"],
        "encoder checkpoint identities must be distinct",
    )

    fusion = _require_exact_keys(
        state["fusion"],
        {"condition_id", "method", "status", "trainable_parameters"},
        "fusion descriptor",
    )
    _require(fusion == {
        "condition_id": "F2",
        "method": "fixed_average_of_calibrated_probabilities",
        "status": "complete",
        "trainable_parameters": 0,
    }, "D0 fused state must use fixed F2")

    quality = _require_exact_keys(state["signal_quality"], {"score", "missing_channels"}, "signal quality")
    _require(float(quality["score"]) == float(fixture["signal_quality"]["score"]), "signal-quality score changed")
    _require(
        quality["missing_channels"] == fixture["signal_quality"]["missing_channels"],
        "missing-channel state changed",
    )

    artifacts = contract["probability_space"]["artifact_labels"]
    observables = contract["probability_space"]["observable_state_labels"]
    artifact_values = _require_exact_keys(state["artifact_probabilities"], set(artifacts), "artifact probabilities")
    observable_values = _require_exact_keys(
        state["observable_state_probabilities"],
        set(observables),
        "observable-state probabilities",
    )
    combined = {**artifact_values, **observable_values}
    labels = contract["probability_space"]["label_order"]
    probabilities = [_probability(combined[label], f"state probability {label}") for label in labels]
    tolerance = float(contract["probability_space"]["sum_tolerance"])
    _require(
        math.isclose(sum(probabilities), 1.0, rel_tol=0.0, abs_tol=tolerance),
        "fused probabilities must sum to one",
    )
    expected = condition_probabilities(fixture, "F2", contract)
    _require(
        all(
            math.isclose(a, b, rel_tol=0.0, abs_tol=tolerance)
            for a, b in zip(probabilities, expected, strict=True)
        ),
        "fused probabilities changed",
    )

    expected_disagreement = encoder_disagreement(fixture)
    _require(
        math.isclose(
            _probability(state["encoder_disagreement"], "encoder disagreement"),
            expected_disagreement,
            rel_tol=0.0,
            abs_tol=tolerance,
        ),
        "encoder disagreement changed",
    )
    expected_entropy = _normalized_entropy(expected)
    _require(
        math.isclose(
            _probability(state["predictive_entropy"], "predictive entropy"),
            expected_entropy,
            rel_tol=0.0,
            abs_tol=tolerance,
        ),
        "predictive entropy changed",
    )
    expected_ood = max(
        float(fixture["encoders"]["eegnet"]["uncertainty"]),
        float(fixture["encoders"]["eegpt"]["uncertainty"]),
        expected_disagreement,
        1.0 - float(fixture["signal_quality"]["score"]),
    )
    _require(
        math.isclose(
            _probability(state["out_of_distribution_score"], "out-of-distribution score"),
            expected_ood,
            rel_tol=0.0,
            abs_tol=tolerance,
        ),
        "out-of-distribution score changed",
    )

    serialized = _canonical_json(state).casefold()
    for term in ("waveform", "eeg_values", "embedding", "prompt", "dialogue", "speech", "free_text"):
        _require(term not in serialized, f"fused state contains forbidden term: {term}")
    return state


def _validate_state_for_qwen(state: Any, contract: dict[str, Any]) -> dict[str, Any]:
    _reject_forbidden_qwen_fields(state, "Qwen source state")
    state = _require_exact_keys(state, _STATE_KEYS, "Qwen source state")
    for key, expected in {
        "schema_version": STATE_SCHEMA,
        "experiment_id": contract["experiment_id"],
        **_FIXED_DISPOSITION,
        "synthetic_only": True,
        "shadow_only": True,
        "live_control": False,
        "qwen_policy_stage": "schema_validation_only",
        "calibration_scope": "synthetic_fixture_rehearsal_only",
    }.items():
        _require(state.get(key) == expected, f"Qwen source state {key} changed")
    _require(
        isinstance(state["state_id"], str) and bool(re.fullmatch(r"[0-9a-f]{64}", state["state_id"])),
        "Qwen source state id is invalid",
    )
    source = _require_exact_keys(
        state["source"],
        {"fixture_id", "source_record_sha256"},
        "Qwen source identity",
    )
    _safe_identifier(source["fixture_id"], "Qwen source fixture id")
    _sha256_identifier(source["source_record_sha256"], "Qwen source record sha256")
    provenance = _require_exact_keys(
        state["encoder_provenance"],
        set(_MODEL_IDS),
        "Qwen source encoder provenance",
    )
    for model_id in _MODEL_IDS:
        encoder = _require_exact_keys(
            provenance[model_id],
            {
                "model_id",
                "model_revision",
                "backbone_frozen",
                "adapter",
                "checkpoint_kind",
                "checkpoint_sha256",
            },
            f"Qwen source {model_id} provenance",
        )
        _require(encoder["model_id"] == model_id, f"Qwen source {model_id} identity changed")
        _safe_identifier(encoder["model_revision"], f"Qwen source {model_id} revision")
        _require(encoder["backbone_frozen"] is True, f"Qwen source {model_id} must be frozen")
        _safe_identifier(encoder["adapter"], f"Qwen source {model_id} adapter")
        _require(
            encoder["checkpoint_kind"] == "deterministic_synthetic_parameter_fixture",
            f"Qwen source {model_id} checkpoint kind changed",
        )
        _sha256_identifier(encoder["checkpoint_sha256"], f"Qwen source {model_id} checkpoint sha256")
    _require(
        provenance["eegnet"]["checkpoint_sha256"] != provenance["eegpt"]["checkpoint_sha256"],
        "Qwen source checkpoint identities must be distinct",
    )
    fusion = _require_exact_keys(
        state["fusion"],
        {"condition_id", "method", "status", "trainable_parameters"},
        "Qwen source fusion descriptor",
    )
    _require(
        fusion
        == {
            "condition_id": "F2",
            "method": "fixed_average_of_calibrated_probabilities",
            "status": "complete",
            "trainable_parameters": 0,
        },
        "Qwen source state is not the fixed D0 fusion condition",
    )
    quality = _require_exact_keys(
        state["signal_quality"],
        {"score", "missing_channels"},
        "Qwen source signal quality",
    )
    _probability(quality["score"], "Qwen source signal quality score")
    missing = quality["missing_channels"]
    _require(
        isinstance(missing, list)
        and len(missing) == len(set(missing))
        and all(channel in _CHANNELS for channel in missing),
        "Qwen source missing channels are invalid",
    )
    artifacts = contract["probability_space"]["artifact_labels"]
    observables = contract["probability_space"]["observable_state_labels"]
    artifact_values = _require_exact_keys(
        state["artifact_probabilities"],
        set(artifacts),
        "Qwen source artifact probabilities",
    )
    observable_values = _require_exact_keys(
        state["observable_state_probabilities"],
        set(observables),
        "Qwen source observable probabilities",
    )
    combined = {**artifact_values, **observable_values}
    probabilities = [
        _probability(combined[label], f"Qwen source probability {label}")
        for label in contract["probability_space"]["label_order"]
    ]
    _require(
        math.isclose(
            sum(probabilities),
            1.0,
            rel_tol=0.0,
            abs_tol=float(contract["probability_space"]["sum_tolerance"]),
        ),
        "Qwen source probabilities must sum to one",
    )
    for field in ("encoder_disagreement", "predictive_entropy", "out_of_distribution_score"):
        _probability(state[field], f"Qwen source {field}")
    return state


def calibration_metrics(
    fixtures: list[dict[str, Any]],
    condition_id: str,
    contract: dict[str, Any],
) -> dict[str, float | int]:
    labels = contract["probability_space"]["label_order"]
    bins = [float(value) for value in contract["metrics"]["calibration"]["expected_calibration_error_bins"]]
    brier_total = 0.0
    confidence_rows: list[tuple[float, float]] = []
    correct = 0
    for fixture in fixtures:
        probabilities = condition_probabilities(fixture, condition_id, contract)
        target = labels.index(fixture["synthetic_label"])
        brier_total += sum(
            (probability - (1.0 if index == target else 0.0)) ** 2
            for index, probability in enumerate(probabilities)
        )
        predicted = max(range(len(probabilities)), key=probabilities.__getitem__)
        confidence = probabilities[predicted]
        accuracy = 1.0 if predicted == target else 0.0
        confidence_rows.append((confidence, accuracy))
        correct += int(accuracy)

    ece = 0.0
    for index, (lower, upper) in enumerate(zip(bins[:-1], bins[1:], strict=True)):
        if index == len(bins) - 2:
            rows = [(confidence, accuracy) for confidence, accuracy in confidence_rows if lower <= confidence <= upper]
        else:
            rows = [(confidence, accuracy) for confidence, accuracy in confidence_rows if lower <= confidence < upper]
        if not rows:
            continue
        mean_confidence = sum(confidence for confidence, _ in rows) / len(rows)
        mean_accuracy = sum(accuracy for _, accuracy in rows) / len(rows)
        ece += (len(rows) / len(confidence_rows)) * abs(mean_accuracy - mean_confidence)
    return {
        "fixture_count": len(fixtures),
        "multiclass_brier_score": round(brier_total / len(fixtures), 12),
        "expected_calibration_error": round(ece, 12),
        "argmax_accuracy": round(correct / len(fixtures), 12),
    }


def render_qwen_shadow_input(state: dict[str, Any], contract: dict[str, Any]) -> str:
    """Render bounded structured state without invoking or prompting a model."""
    state = _validate_state_for_qwen(state, contract)
    qwen = contract["qwen_bridge"]
    payload = {
        "schema_version": QWEN_INPUT_SCHEMA,
        "experiment_id": contract["experiment_id"],
        "task": qwen["task"],
        "state_id": state["state_id"],
        "structured_state": {
            "signal_quality": state["signal_quality"],
            "artifact_probabilities": state["artifact_probabilities"],
            "observable_state_probabilities": state["observable_state_probabilities"],
            "encoder_disagreement": state["encoder_disagreement"],
            "predictive_entropy": state["predictive_entropy"],
            "out_of_distribution_score": state["out_of_distribution_score"],
        },
        "legal_actions": list(qwen["legal_actions"]),
        "constraints": {
            "shadow_only": True,
            "live_control": False,
            "raw_eeg_present": False,
            "encoder_embeddings_present": False,
            "free_text_state_present": False,
            "model_execution_allowed": False,
            "weights_updated": False,
        },
    }
    rendered = _canonical_json(payload)
    for term in ("waveform", "eeg_values", "\"embedding\"", "dialogue", "speech"):
        _require(term not in rendered.casefold(), f"Qwen input contains forbidden term: {term}")
    return rendered


def _validate_qwen_input_payload(value: Any, contract: dict[str, Any]) -> dict[str, Any]:
    _reject_forbidden_qwen_fields(value, "Qwen shadow input")
    expected_keys = {
        "schema_version",
        "experiment_id",
        "task",
        "state_id",
        "structured_state",
        "legal_actions",
        "constraints",
    }
    payload = _require_exact_keys(value, expected_keys, "Qwen shadow input")
    _require(payload["schema_version"] == QWEN_INPUT_SCHEMA, "Qwen input schema changed")
    _require(payload["experiment_id"] == contract["experiment_id"], "Qwen input experiment changed")
    _require(payload["task"] == contract["qwen_bridge"]["task"], "Qwen input task changed")
    _require(
        isinstance(payload["state_id"], str) and bool(re.fullmatch(r"[0-9a-f]{64}", payload["state_id"])),
        "Qwen input state id is invalid",
    )
    _require(
        payload["legal_actions"] == contract["qwen_bridge"]["legal_actions"],
        "Qwen input legal actions changed",
    )
    expected_constraints = {
        "shadow_only": True,
        "live_control": False,
        "raw_eeg_present": False,
        "encoder_embeddings_present": False,
        "free_text_state_present": False,
        "model_execution_allowed": False,
        "weights_updated": False,
    }
    constraints = _require_exact_keys(
        payload["constraints"],
        set(expected_constraints),
        "Qwen input constraints",
    )
    _require(constraints == expected_constraints, "Qwen input constraints changed")
    structured = _require_exact_keys(
        payload["structured_state"],
        {
            "signal_quality",
            "artifact_probabilities",
            "observable_state_probabilities",
            "encoder_disagreement",
            "predictive_entropy",
            "out_of_distribution_score",
        },
        "Qwen bounded structured state",
    )
    quality = _require_exact_keys(
        structured["signal_quality"],
        {"score", "missing_channels"},
        "Qwen input signal quality",
    )
    _probability(quality["score"], "Qwen input signal quality score")
    missing = quality["missing_channels"]
    _require(
        isinstance(missing, list)
        and len(missing) == len(set(missing))
        and all(channel in _CHANNELS for channel in missing),
        "Qwen input missing channels are invalid",
    )
    artifacts = contract["probability_space"]["artifact_labels"]
    observables = contract["probability_space"]["observable_state_labels"]
    artifact_values = _require_exact_keys(
        structured["artifact_probabilities"],
        set(artifacts),
        "Qwen input artifact probabilities",
    )
    observable_values = _require_exact_keys(
        structured["observable_state_probabilities"],
        set(observables),
        "Qwen input observable probabilities",
    )
    combined = {**artifact_values, **observable_values}
    probabilities = [
        _probability(combined[label], f"Qwen input probability {label}")
        for label in contract["probability_space"]["label_order"]
    ]
    _require(
        math.isclose(
            sum(probabilities),
            1.0,
            rel_tol=0.0,
            abs_tol=float(contract["probability_space"]["sum_tolerance"]),
        ),
        "Qwen input probabilities must sum to one",
    )
    for field in ("encoder_disagreement", "predictive_entropy", "out_of_distribution_score"):
        _probability(structured[field], f"Qwen structured state {field}")
    return payload


def validate_qwen_shadow_output(
    output: str | dict[str, Any],
    rendered_input: str,
    contract: dict[str, Any],
) -> dict[str, Any]:
    """Validate a hypothetical Qwen JSON result without executing Qwen."""
    payload = _strict_json_loads(output, "Qwen shadow output") if isinstance(output, str) else output
    input_payload = _strict_json_loads(rendered_input, "Qwen shadow input")
    _reject_forbidden_qwen_fields(payload, "Qwen shadow output")
    input_payload = _validate_qwen_input_payload(input_payload, contract)
    expected_keys = {
        "schema_version",
        "state_id",
        "action",
        "confidence",
        "abstained",
        "reason_code",
        "shadow_only",
        "live_control",
        "weights_updated",
    }
    payload = _require_exact_keys(payload, expected_keys, "Qwen shadow output")
    _require(payload["schema_version"] == QWEN_OUTPUT_SCHEMA, "Qwen output schema changed")
    _require(payload["state_id"] == input_payload.get("state_id"), "Qwen output references another state")
    legal_actions = contract["qwen_bridge"]["legal_actions"]
    _require(payload["action"] in legal_actions, "Qwen output action is not legal")
    _probability(payload["confidence"], "Qwen output confidence")
    _require(isinstance(payload["abstained"], bool), "Qwen abstained must be boolean")
    _require(payload["abstained"] == (payload["action"] == "abstain"), "Qwen abstention is inconsistent")
    _require(payload["reason_code"] in contract["qwen_bridge"]["reason_codes"], "Qwen reason code is not controlled")
    _require(payload["shadow_only"] is True, "Qwen output must remain shadow-only")
    _require(payload["live_control"] is False, "Qwen output cannot enable live control")
    _require(payload["weights_updated"] is False, "Qwen output cannot claim a weight update")
    return payload


def run_synthetic_fusion_fixture(
    contract_path: Path,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Run the non-training D0 fixture and return replay states plus its report."""
    contract = load_fusion_contract(contract_path)
    fixtures = load_synthetic_fixtures(contract, contract_path)
    states = [build_fused_state(fixture, contract) for fixture in fixtures]
    disagreements = [encoder_disagreement(fixture) for fixture in fixtures]

    missing_model_fixture = copy.deepcopy(fixtures[0])
    del missing_model_fixture["encoders"]["eegpt"]
    missing_model_rejected = False
    try:
        condition_probabilities(missing_model_fixture, "F2", contract)
    except ContractError:
        missing_model_rejected = True

    rendered = render_qwen_shadow_input(states[0], contract)
    qwen_fixture_output = {
        "schema_version": QWEN_OUTPUT_SCHEMA,
        "state_id": states[0]["state_id"],
        "action": "abstain",
        "confidence": 1.0,
        "abstained": True,
        "reason_code": "insufficient_evidence",
        "shadow_only": True,
        "live_control": False,
        "weights_updated": False,
    }
    validate_qwen_shadow_output(qwen_fixture_output, rendered, contract)

    fixture_path = _resolve_contract_path(contract_path, contract["fixtures"]["path"], "fixtures")
    schema_path = _resolve_contract_path(contract_path, contract["state_contract"]["schema_path"], "schemas")
    report = {
        "schema_version": REPORT_SCHEMA,
        "experiment_id": contract["experiment_id"],
        **_FIXED_DISPOSITION,
        "synthetic_only": True,
        "dialogue_logs_used": False,
        "fallback_capture_used": False,
        "encoder_training": False,
        "fusion_head_training": False,
        "qwen_model_executed": False,
        "weights_updated": False,
        "contract_sha256": _sha256_file(contract_path),
        "fixture_sha256": _sha256_file(fixture_path),
        "state_schema_sha256": _sha256_file(schema_path),
        "fixture_count": len(fixtures),
        "state_count": len(states),
        "states_sha256": _sha256_lines(states),
        "conditions": {
            condition_id: calibration_metrics(fixtures, condition_id, contract)
            for condition_id in contract["current_execution"]["synthetic_conditions"]
        },
        "encoder_disagreement": {
            "metric": "total_variation_distance",
            "minimum": round(min(disagreements), 12),
            "mean": round(sum(disagreements) / len(disagreements), 12),
            "maximum": round(max(disagreements), 12),
        },
        "missing_model_behavior": {
            "policy": "require_both_or_fail_closed",
            "negative_fixture_rejected": missing_model_rejected,
        },
        "qwen_bridge": {
            "stage": "schema_validation_only",
            "input_sha256": _sha256_bytes(rendered.encode("utf-8")),
            "output_schema_validated": True,
            "model_executed": False,
            "weights_updated": False,
        },
        "invariants": {
            "direct_weight_fusion_prohibited": contract["architecture"]["direct_weight_fusion"] is False,
            "f2_has_no_trainable_parameters": all(state["fusion"]["trainable_parameters"] == 0 for state in states),
            "missing_model_fails_closed": missing_model_rejected,
            "states_exclude_embeddings": all("embedding" not in _canonical_json(state).casefold() for state in states),
            "states_exclude_waveforms": all("waveform" not in _canonical_json(state).casefold() for state in states),
            "qwen_input_is_structured_only": "\"free_text\"" not in rendered and "\"embedding\"" not in rendered,
            "no_physical_or_private_data": True,
            "no_model_or_runtime_execution": True,
        },
    }
    _require(all(report["invariants"].values()), "synthetic fusion fixture failed an invariant")
    return states, report


def write_synthetic_fusion_artifacts(
    contract_path: Path,
    *,
    states_output: Path,
    manifest_output: Path,
    report_output: Path,
) -> dict[str, Any]:
    states, report = run_synthetic_fusion_fixture(contract_path)
    states_bytes = "".join(f"{_canonical_json(state)}\n" for state in states).encode("utf-8")
    report_bytes = (json.dumps(report, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")
    manifest = {
        "schema_version": REPLAY_MANIFEST_SCHEMA,
        "state_schema_version": STATE_SCHEMA,
        "experiment_id": report["experiment_id"],
        **_FIXED_DISPOSITION,
        "synthetic_only": True,
        "live_control": False,
        "record_count": len(states),
        "records_sha256": _sha256_bytes(states_bytes),
        "report_sha256": _sha256_bytes(report_bytes),
        "contract_sha256": _sha256_file(contract_path),
    }
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")
    for path in (states_output, manifest_output, report_output):
        path.parent.mkdir(parents=True, exist_ok=True)
    states_output.write_bytes(states_bytes)
    report_output.write_bytes(report_bytes)
    manifest_output.write_bytes(manifest_bytes)
    return manifest


def load_fused_state_replay(
    contract_path: Path,
    *,
    states_path: Path,
    manifest_path: Path,
) -> list[dict[str, Any]]:
    contract = load_fusion_contract(contract_path)
    fixtures = load_synthetic_fixtures(contract, contract_path)
    fixture_map = {fixture["fixture_id"]: fixture for fixture in fixtures}
    manifest = _read_json(manifest_path, "fused-state replay manifest")
    expected_manifest_keys = {
        "schema_version",
        "state_schema_version",
        "experiment_id",
        *set(_FIXED_DISPOSITION),
        "synthetic_only",
        "live_control",
        "record_count",
        "records_sha256",
        "report_sha256",
        "contract_sha256",
    }
    manifest = _require_exact_keys(manifest, expected_manifest_keys, "fused-state replay manifest")
    for key, expected in {
        "schema_version": REPLAY_MANIFEST_SCHEMA,
        "state_schema_version": STATE_SCHEMA,
        "experiment_id": contract["experiment_id"],
        **_FIXED_DISPOSITION,
        "synthetic_only": True,
        "shadow_only": True,
        "live_control": False,
        "contract_sha256": _sha256_file(contract_path),
    }.items():
        _require(manifest.get(key) == expected, f"replay manifest {key} changed")
    try:
        states_bytes = states_path.read_bytes()
        lines = states_bytes.decode("utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise ContractError(f"cannot read fused-state replay: {exc}") from exc
    records = [
        _strict_json_loads(line, f"fused-state replay line {index}")
        for index, line in enumerate(lines, 1)
        if line
    ]
    _require(manifest.get("record_count") == len(records), "replay record count changed")
    _require(manifest.get("records_sha256") == _sha256_bytes(states_bytes), "replay record hash changed")
    seen_ids: set[str] = set()
    for record in records:
        fixture_id = record.get("source", {}).get("fixture_id") if isinstance(record, dict) else None
        _require(fixture_id in fixture_map, "replay state references an unknown fixture")
        validate_fused_state(record, contract, fixture_map[fixture_id])
        _require(record["state_id"] not in seen_ids, "replay state ids must be unique")
        seen_ids.add(record["state_id"])
    return records


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--states-output", required=True, type=Path)
    parser.add_argument("--manifest-output", required=True, type=Path)
    parser.add_argument("--report-output", required=True, type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args(argv)
    manifest = write_synthetic_fusion_artifacts(
        args.contract,
        states_output=args.states_output,
        manifest_output=args.manifest_output,
        report_output=args.report_output,
    )
    if args.verify:
        records = load_fused_state_replay(
            args.contract,
            states_path=args.states_output,
            manifest_path=args.manifest_output,
        )
        _require(len(records) == manifest["record_count"], "verification count changed")
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
