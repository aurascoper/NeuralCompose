#!/usr/bin/env python3
"""Deterministic metadata-only audit for review/EEG noninterference."""

from __future__ import annotations

import json
from typing import Any, Iterable


NONINTERFERENCE_SCHEMA = "nc-local-review-eeg-noninterference-v0"


class NoninterferenceError(ValueError):
    pass


def _serialized(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def _require_absent(value: Any, prohibited_values: Iterable[str], label: str) -> None:
    serialized = _serialized(value)
    if any(item and item in serialized for item in prohibited_values):
        raise NoninterferenceError(label)


def audit_noninterference(
    *,
    dialogue_source_sha256: str,
    dialogue_content_hashes: Iterable[str],
    review_finding_ids: Iterable[str],
    eeg_dataset_artifact: Any,
    eeg_state_artifact: Any,
    eeg_model_input_manifest: Any,
    eeg_experiment_configuration: Any,
    local_review_prompt_metadata: Any,
    eeg_window_hashes: Iterable[str],
    shared_training_buffer: Any = None,
    dialogue_embeddings_created: bool = False,
    dialogue_derived_weight_updates: bool = False,
) -> dict[str, Any]:
    """Prove only absence from supplied metadata artifacts, never data quality."""
    if not isinstance(dialogue_source_sha256, str) or not dialogue_source_sha256:
        raise NoninterferenceError("dialogue source SHA-256 is required")
    content_hashes = tuple(dialogue_content_hashes)
    finding_ids = tuple(review_finding_ids)
    window_hashes = tuple(eeg_window_hashes)
    _require_absent([eeg_dataset_artifact, eeg_state_artifact], [dialogue_source_sha256], "dialogue source SHA present in EEG artifact")
    _require_absent(eeg_model_input_manifest, content_hashes, "dialogue content hash present in EEG model input")
    _require_absent(eeg_experiment_configuration, finding_ids, "review finding present in EEG experiment configuration")
    _require_absent(local_review_prompt_metadata, window_hashes, "EEG window hash present in review prompt metadata")
    if shared_training_buffer is not None:
        raise NoninterferenceError("review and EEG tracks must not share a training buffer")
    if dialogue_embeddings_created:
        raise NoninterferenceError("dialogue embeddings are prohibited")
    if dialogue_derived_weight_updates:
        raise NoninterferenceError("dialogue-derived weight updates are prohibited")
    return {
        "schema_version": NONINTERFERENCE_SCHEMA,
        "status": "pass",
        "checks": {
            "dialogue_source_sha_absent_from_eeg_artifacts": True,
            "dialogue_content_hashes_absent_from_eeg_model_inputs": True,
            "review_findings_absent_from_eeg_configuration": True,
            "eeg_window_hashes_absent_from_review_prompts": True,
            "no_shared_training_buffer": True,
            "no_dialogue_embeddings": True,
            "no_dialogue_derived_weight_updates": True,
        },
        "science_status": "pipeline_only",
        "decision": "insufficient_evidence",
        "promotion_status": "not_eligible",
        "live_control": False,
    }
