"""Strict source and representation contracts for EXP-NC-EEG-ENC-001."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

from .provenance import sha256_file, sha256_json


SOURCE_MANIFEST_SCHEMA = "nc-eeg-source-manifest-v0"
DATASET_SCHEMA = "nc-eeg-dataset-v0"
EXTERNAL_EMBEDDING_SCHEMA = "nc-eeg-external-embeddings-v0"
EXTERNAL_FOLD_EVALUATION_SCHEMA = "nc-eeg-external-fold-evaluation-input-v0"
CHANNELS = ("TP9", "AF7", "AF8", "TP10")
TARGET_SAMPLE_RATE_HZ = 256.0
WINDOW_SECONDS = 4.0
WINDOW_SAMPLES = 1024
STRIDE_SECONDS = 1.0
STRIDE_SAMPLES = 256


class ContractError(ValueError):
    """A source or derived artifact does not meet the preregistered contract."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def _finite_number(value: Any, name: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ContractError(f"{name} must be numeric") from exc
    _require(math.isfinite(number), f"{name} must be finite")
    return number


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read JSON artifact {path}: {exc}") from exc
    _require(isinstance(payload, dict), f"{path} must contain a JSON object")
    return payload


def load_source_manifest(path: Path) -> dict[str, Any]:
    """Read and validate the immutable local source-manifest contract.

    The raw files remain external to the generated artifact. Their content
    hashes, rather than waveform values or absolute paths, are retained.
    """
    manifest = load_json(path)
    _require(
        manifest.get("schema_version") == SOURCE_MANIFEST_SCHEMA,
        f"expected schema_version={SOURCE_MANIFEST_SCHEMA}",
    )
    _require(isinstance(manifest.get("dataset_id"), str) and manifest["dataset_id"], "dataset_id is required")
    labels = manifest.get("label_order")
    _require(isinstance(labels, list) and len(labels) >= 2, "label_order must contain at least two labels")
    _require(all(isinstance(label, str) and label for label in labels), "label_order entries must be nonempty strings")
    _require(len(set(labels)) == len(labels), "label_order must not contain duplicates")

    sessions = manifest.get("sessions")
    _require(isinstance(sessions, list) and len(sessions) >= 2, "at least two complete sessions are required")
    seen_sessions: set[str] = set()
    manifest_dir = path.parent
    normalized_sessions: list[dict[str, Any]] = []

    for position, original in enumerate(sessions):
        _require(isinstance(original, dict), f"sessions[{position}] must be an object")
        session = dict(original)
        session_id = session.get("session_id")
        _require(isinstance(session_id, str) and session_id, f"sessions[{position}].session_id is required")
        _require(session_id not in seen_sessions, f"duplicate session_id: {session_id}")
        seen_sessions.add(session_id)
        _require(isinstance(session.get("participant_id"), str) and session["participant_id"], f"{session_id}: participant_id is required")
        _require(isinstance(session.get("recording_date"), str) and session["recording_date"], f"{session_id}: recording_date is required")
        _require(isinstance(session.get("device_id"), str) and session["device_id"], f"{session_id}: device_id is required")
        _require(isinstance(session.get("headset_fit_id"), str) and session["headset_fit_id"], f"{session_id}: headset_fit_id is required")
        _require(tuple(session.get("channel_order", ())) == CHANNELS, f"{session_id}: channel_order must be {list(CHANNELS)}")
        sample_rate = _finite_number(session.get("sample_rate_hz"), f"{session_id}.sample_rate_hz")
        _require(sample_rate == TARGET_SAMPLE_RATE_HZ, f"{session_id}: pilot accepts only 256 Hz sources")

        eeg_csv = session.get("eeg_csv")
        _require(isinstance(eeg_csv, str) and eeg_csv, f"{session_id}: eeg_csv is required")
        resolved_csv = (manifest_dir / eeg_csv).resolve()
        _require(resolved_csv.is_file(), f"{session_id}: missing eeg_csv {resolved_csv}")
        session["_resolved_eeg_csv"] = str(resolved_csv)
        session["source_sha256"] = sha256_file(resolved_csv)

        blocks = session.get("task_blocks")
        _require(isinstance(blocks, list) and blocks, f"{session_id}: task_blocks are required")
        normalized_blocks: list[dict[str, Any]] = []
        previous_end = -math.inf
        calibration_ends: list[float] = []
        task_starts: list[float] = []
        for block_index, original_block in enumerate(blocks):
            _require(isinstance(original_block, dict), f"{session_id}: task_blocks[{block_index}] must be an object")
            block = dict(original_block)
            label = block.get("label")
            _require(label in labels, f"{session_id}: unknown label {label!r}")
            role = block.get("role")
            _require(role in {"calibration", "task"}, f"{session_id}: block role must be calibration or task")
            _require(
                isinstance(block.get("label_provenance"), str) and block["label_provenance"],
                f"{session_id}: every block needs label_provenance",
            )
            start = _finite_number(block.get("start_seconds"), f"{session_id}.block[{block_index}].start_seconds")
            end = _finite_number(block.get("end_seconds"), f"{session_id}.block[{block_index}].end_seconds")
            _require(end > start, f"{session_id}: block end must follow start")
            _require(start >= previous_end, f"{session_id}: task blocks overlap or are unsorted")
            previous_end = end
            block["start_seconds"] = start
            block["end_seconds"] = end
            normalized_blocks.append(block)
            if role == "calibration":
                calibration_ends.append(end)
            else:
                task_starts.append(start)

        _require(calibration_ends, f"{session_id}: at least one calibration block is required")
        _require(task_starts, f"{session_id}: at least one task block is required")
        _require(
            max(calibration_ends) <= min(task_starts),
            f"{session_id}: calibration blocks must finish before task blocks begin",
        )
        session["task_blocks"] = normalized_blocks
        normalized_sessions.append(session)

    manifest["sessions"] = normalized_sessions
    # Location is not evidence. Bind the source manifest to immutable source
    # content while excluding an absolute local path from its identity.
    hashable = {k: v for k, v in manifest.items() if k != "manifest_sha256"}
    hashable["sessions"] = [
        {k: v for k, v in session.items() if k not in {"_resolved_eeg_csv", "eeg_csv"}}
        for session in normalized_sessions
    ]
    manifest["manifest_sha256"] = sha256_json(hashable)
    return manifest


def validate_external_embedding_metadata(metadata: dict[str, Any], *, dataset_sha256: str) -> None:
    """Require enough evidence to distinguish real transfer from a montage hack."""
    _require(metadata.get("schema_version") == EXTERNAL_EMBEDDING_SCHEMA, "invalid external embedding schema")
    _require(metadata.get("dataset_sha256") == dataset_sha256, "embedding artifact belongs to another dataset")
    _require(metadata.get("model_id") in {"eegpt", "bendr"}, "model_id must be eegpt or bendr")
    _require(metadata.get("initialization") in {"pretrained", "random"}, "initialization must be pretrained or random")
    _require(isinstance(metadata.get("model_revision"), str) and metadata["model_revision"], "model_revision is required")
    checkpoint = metadata.get("checkpoint_sha256")
    _require(isinstance(checkpoint, str) and len(checkpoint) == 64, "checkpoint_sha256 is required")
    _require(isinstance(metadata.get("extractor_version"), str) and metadata["extractor_version"], "extractor_version is required")
    extractor_sha = metadata.get("extractor_sha256")
    _require(isinstance(extractor_sha, str) and len(extractor_sha) == 64, "extractor_sha256 is required")
    input_sha = metadata.get("input_archive_sha256")
    _require(isinstance(input_sha, str) and len(input_sha) == 64, "input_archive_sha256 is required")
    adapter = metadata.get("channel_adapter")
    _require(adapter in {
        "four_channel_learned_adapter",
        "approximate_electrode_mapping_with_mask",
        "zero_filled_no_mask_negative_control",
        "shuffled_electrode_mapping_negative_control",
    }, "explicit channel_adapter is required")
    mask = metadata.get("missing_channel_mask")
    _require(mask in {"explicit", "absent_negative_control"}, "missing_channel_mask provenance is required")
    training_scope = metadata.get("adapter_training_scope")
    _require(
        training_scope in {"fixed_preprocessor", "fold_train_only"},
        "adapter_training_scope must be fixed_preprocessor or fold_train_only",
    )
    if adapter == "zero_filled_no_mask_negative_control":
        _require(mask == "absent_negative_control", "zero-filled control must declare absent mask")
    else:
        _require(mask == "explicit", "transfer conditions must carry an explicit missing-channel mask")
    if adapter == "four_channel_learned_adapter":
        _require(training_scope == "fold_train_only", "a learned adapter must be fit within each training fold")
    else:
        _require(training_scope == "fixed_preprocessor", "fixed adapter conditions must not claim fold training")
    _validate_external_worker_run_manifest(metadata.get("worker_run_manifest"))


def _validate_external_worker_run_manifest(value: Any) -> None:
    """Require worker provenance instead of treating Kaggle/Colab as a black box."""
    _require(isinstance(value, dict), "worker_run_manifest is required")
    for field in (
        "platform",
        "accelerator",
        "accelerator_memory",
        "python_version",
        "torch_version",
        "cuda_or_mps_version",
        "available_quota",
        "git_commit",
    ):
        _require(isinstance(value.get(field), str) and value[field], f"worker_run_manifest.{field} is required")
    _require(isinstance(value.get("seed"), int), "worker_run_manifest.seed is required")
