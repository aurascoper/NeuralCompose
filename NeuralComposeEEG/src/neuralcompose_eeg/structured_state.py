"""Serialize offline encoder probabilities into a replayable shadow-state contract.

This bridge is deliberately downstream of an offline encoder artifact.  It
stores no waveform values, dialogue content, task labels, or policy actions.
The resulting records are suitable only for deterministic replay while the
encoder program remains ``pipeline_only``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
from typing import Any, Iterable

import numpy as np

from .contracts import ContractError
from .dataset import CanonicalDataset, load_dataset
from .provenance import sha256_json


STATE_SCHEMA = "nc-eeg-encoder-state-v0"
MANIFEST_SCHEMA = "nc-eeg-encoder-state-manifest-v0"
STATE_BRIDGE_VERSION = "nc-eeg-structured-state-bridge-v0"
_REQUIRED_GLOBAL_STATUS = {
    "status": "insufficient_evidence",
    "science_status": "pipeline_only",
    "shadow_only": True,
    "live_control": False,
    "promotion_status": "not_eligible",
}
_ENCODER_PROVENANCE_KEYS = frozenset(
    {
        "model_id",
        "model_revision",
        "initialization",
        "checkpoint_sha256",
        "extractor_sha256",
        "source_kind",
    }
)
_FORBIDDEN_SERIALIZED_TERMS = (
    "dialogue",
    "dialectic",
    "prompt",
    "speech",
    "text",
    "policy",
    "action",
    "eeg_values",
    "waveform",
    "label",
    "target",
)


def _canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _publish_text(path: Path, text: str) -> None:
    """Write via same-directory rename so an interrupted run cannot publish a
    truncated artifact over a previously valid one."""
    partial = path.with_name(f".{path.name}.partial")
    try:
        partial.write_text(text, encoding="utf-8")
        os.replace(partial, path)
    finally:
        partial.unlink(missing_ok=True)


def _sha256_lines(records: Iterable[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for record in records:
        digest.update(_canonical_json(record).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def _entropy(probabilities: np.ndarray) -> float:
    nonzero = probabilities[probabilities > 0]
    return float(-np.sum(nonzero * np.log(nonzero)))


def _validate_encoder_provenance(value: dict[str, Any]) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ContractError("encoder provenance must be an object")
    unexpected = set(value) - _ENCODER_PROVENANCE_KEYS
    if unexpected:
        raise ContractError(f"encoder provenance has unsupported fields: {sorted(unexpected)}")
    required = {"model_id", "model_revision", "source_kind"}
    missing = required - set(value)
    if missing:
        raise ContractError(f"encoder provenance lacks fields: {sorted(missing)}")
    normalized: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(item, str) or not item:
            raise ContractError(f"encoder provenance {key} must be a nonempty string")
        normalized[key] = item
    return normalized


def _validate_probabilities(probabilities: np.ndarray, expected_rows: int, class_count: int) -> np.ndarray:
    result = np.asarray(probabilities, dtype=np.float64)
    if result.ndim != 2 or result.shape != (expected_rows, class_count):
        raise ContractError("probabilities must have [canonical_window, observable_class] shape")
    if not np.all(np.isfinite(result)) or np.any(result < 0) or np.any(result > 1):
        raise ContractError("probabilities must be finite values in [0, 1]")
    if not np.allclose(result.sum(axis=1), 1.0, atol=1e-6):
        raise ContractError("probabilities must sum to one for every canonical window")
    return result


def _require_no_forbidden_serialized_terms(value: Any) -> None:
    serialized = _canonical_json(value).casefold()
    matched = [term for term in _FORBIDDEN_SERIALIZED_TERMS if term in serialized]
    if matched:
        raise ContractError(f"structured state has forbidden fields or values: {matched}")


def build_shadow_state_records(
    dataset: CanonicalDataset,
    probabilities: np.ndarray,
    *,
    encoder_provenance: dict[str, Any],
) -> list[dict[str, Any]]:
    """Create deterministic, read-only states from canonical offline outputs."""
    provenance = _validate_encoder_provenance(encoder_provenance)
    values = _validate_probabilities(probabilities, len(dataset.labels), len(dataset.label_order))
    records: list[dict[str, Any]] = []
    dataset_sha256 = dataset.artifact_sha256()
    for row, probability in enumerate(values):
        top_index = int(np.argmax(probability))
        observable_probabilities = {
            label: float(probability[index])
            for index, label in enumerate(dataset.label_order)
        }
        state = {
            "schema_version": STATE_SCHEMA,
            **_REQUIRED_GLOBAL_STATUS,
            "state_id": hashlib.sha256(
                f"{dataset_sha256}:{dataset.raw_window_hashes[row]}".encode("utf-8")
            ).hexdigest(),
            "source": {
                "dataset_sha256": dataset_sha256,
                "source_manifest_sha256": dataset.source_manifest_sha256,
                "raw_window_sha256": str(dataset.raw_window_hashes[row]),
                "session_id": str(dataset.session_ids[row]),
                "start_sample": int(dataset.start_samples[row]),
            },
            "encoder": provenance,
            "observable_state": {
                "probabilities": observable_probabilities,
                "argmax_observable": dataset.label_order[top_index],
                "confidence": float(probability[top_index]),
                "entropy_nats": _entropy(probability),
            },
        }
        _require_no_forbidden_serialized_terms(state)
        records.append(state)
    return records


def write_shadow_state_artifacts(
    dataset: CanonicalDataset,
    probabilities: np.ndarray,
    *,
    encoder_provenance: dict[str, Any],
    states_output: Path,
    manifest_output: Path,
) -> dict[str, Any]:
    """Persist canonical JSONL records and a hash-bound replay manifest."""
    records = build_shadow_state_records(dataset, probabilities, encoder_provenance=encoder_provenance)
    states_output.parent.mkdir(parents=True, exist_ok=True)
    _publish_text(states_output, "".join(f"{_canonical_json(record)}\n" for record in records))
    manifest = {
        "schema_version": MANIFEST_SCHEMA,
        "state_schema_version": STATE_SCHEMA,
        "bridge_version": STATE_BRIDGE_VERSION,
        **_REQUIRED_GLOBAL_STATUS,
        "record_count": len(records),
        "records_sha256": _sha256_lines(records),
        "dataset_sha256": dataset.artifact_sha256(),
        "source_manifest_sha256": dataset.source_manifest_sha256,
        "encoder": _validate_encoder_provenance(encoder_provenance),
        "input_probability_sha256": sha256_json(np.asarray(probabilities, dtype=np.float64).tolist()),
    }
    _require_no_forbidden_serialized_terms(manifest)
    manifest_output.parent.mkdir(parents=True, exist_ok=True)
    _publish_text(manifest_output, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def load_shadow_state_records(states_path: Path, manifest_path: Path) -> list[dict[str, Any]]:
    """Read records for deterministic replay after validating their complete contract."""
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read state manifest: {exc}") from exc
    if manifest.get("schema_version") != MANIFEST_SCHEMA:
        raise ContractError("state manifest has the wrong schema")
    for key, expected in _REQUIRED_GLOBAL_STATUS.items():
        if manifest.get(key) != expected:
            raise ContractError(f"state manifest {key} violates shadow-only status")
    try:
        records = [json.loads(line) for line in states_path.read_text(encoding="utf-8").splitlines() if line]
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read state records: {exc}") from exc
    if len(records) != manifest.get("record_count"):
        raise ContractError("state record count does not match manifest")
    if _sha256_lines(records) != manifest.get("records_sha256"):
        raise ContractError("state records do not match manifest hash")
    seen_ids: set[str] = set()
    for record in records:
        if record.get("schema_version") != STATE_SCHEMA:
            raise ContractError("state record has the wrong schema")
        for key, expected in _REQUIRED_GLOBAL_STATUS.items():
            if record.get(key) != expected:
                raise ContractError(f"state record {key} violates shadow-only status")
        state_id = record.get("state_id")
        if not isinstance(state_id, str) or len(state_id) != 64 or state_id in seen_ids:
            raise ContractError("state ids must be unique SHA-256 values")
        seen_ids.add(state_id)
        source = record.get("source")
        observable = record.get("observable_state")
        if not isinstance(source, dict) or not isinstance(observable, dict):
            raise ContractError("state record needs source and observable_state objects")
        probabilities = observable.get("probabilities")
        if not isinstance(probabilities, dict) or not probabilities:
            raise ContractError("state record needs observable probabilities")
        values = np.asarray(list(probabilities.values()), dtype=np.float64)
        _validate_probabilities(values.reshape(1, -1), 1, len(values))
        confidence = observable.get("confidence")
        entropy = observable.get("entropy_nats")
        if not isinstance(confidence, (int, float)) or not math.isfinite(float(confidence)):
            raise ContractError("state confidence must be finite")
        if not isinstance(entropy, (int, float)) or not math.isfinite(float(entropy)):
            raise ContractError("state entropy must be finite")
        if observable.get("argmax_observable") not in probabilities:
            raise ContractError("state argmax must be one of its observable probabilities")
        selected_probability = float(probabilities[observable["argmax_observable"]])
        maximum_probability = float(values.max())
        if not math.isclose(selected_probability, maximum_probability, rel_tol=0.0, abs_tol=1e-12):
            raise ContractError("state argmax does not select a maximum observable probability")
        if not math.isclose(float(confidence), maximum_probability, rel_tol=0.0, abs_tol=1e-12):
            raise ContractError("state confidence does not match its maximum observable probability")
        if not math.isclose(float(entropy), _entropy(values), rel_tol=0.0, abs_tol=1e-12):
            raise ContractError("state entropy does not match its observable probabilities")
        _require_no_forbidden_serialized_terms(record)
    return records


def _load_prediction_archive(path: Path, dataset: CanonicalDataset) -> np.ndarray:
    try:
        with np.load(path, allow_pickle=False) as archive:
            hashes = archive["raw_window_hashes"].astype("U64")
            probabilities = archive["probabilities"].astype(np.float64)
    except (OSError, KeyError, ValueError) as exc:
        raise ContractError(f"invalid offline prediction archive: {exc}") from exc
    if len(set(hashes.tolist())) != len(hashes) or set(hashes.tolist()) != set(dataset.raw_window_hashes.tolist()):
        raise ContractError("prediction archive must cover each canonical window exactly once")
    mapped = {window_hash: row for window_hash, row in zip(hashes.tolist(), probabilities, strict=True)}
    return np.vstack([mapped[window_hash] for window_hash in dataset.raw_window_hashes.tolist()])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--probabilities", required=True, type=Path)
    parser.add_argument("--encoder-provenance", required=True, type=Path)
    parser.add_argument("--states-output", required=True, type=Path)
    parser.add_argument("--manifest-output", required=True, type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args(argv)
    dataset = load_dataset(args.dataset)
    try:
        encoder_provenance = json.loads(args.encoder_provenance.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read encoder provenance: {exc}") from exc
    probabilities = _load_prediction_archive(args.probabilities, dataset)
    manifest = write_shadow_state_artifacts(
        dataset,
        probabilities,
        encoder_provenance=encoder_provenance,
        states_output=args.states_output,
        manifest_output=args.manifest_output,
    )
    if args.verify:
        load_shadow_state_records(args.states_output, args.manifest_output)
    print(f"wrote {args.states_output} and {args.manifest_output}; status={manifest['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
