#!/usr/bin/env python3
"""Fail-closed local open-weight review cascade.

This module is deliberately narrow.  It may be used by a *local* operator to
review a quarantined engineering corpus, but it cannot decide science, alter an
experiment, create embeddings, train a model, or control the application.  On
import it reads no source data and contacts no backend.  The command-line entry
point requires an explicit source path and two operator attestations.

Only metadata-only receipts are serializable.  Raw records are held in memory
for one stateless model request and are never passed to aggregation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Protocol
from urllib.parse import urlparse


CHUNK_SCHEMA = "nc-local-review-chunk-v0"
FINDING_SCHEMA = "nc-local-review-finding-v0"
SUMMARY_SCHEMA = "nc-local-review-summary-v0"
RUN_MANIFEST_SCHEMA = "nc-local-review-run-manifest-v0"
CRITIC_SCHEMA = "nc-local-review-critic-v0"
CONFIG_SCHEMA = "nc-local-review-cascade-config-v0"
CASCADE_VERSION = "nc-local-open-weight-review-cascade-v0"
DEFAULT_CONFIGURATION_PATH = Path(__file__).resolve().parents[1] / "configs" / "local-open-weight-review-v0.json"

ALLOWED_FINDING_TYPES = frozenset(
    {
        "malformed_record",
        "duplicate_index",
        "non_monotonic_index",
        "candidate_role_inconsistency",
        "candidate_duplication",
        "selection_inertia",
        "repetitive_synthesis",
        "state_discontinuity",
        "generator_identity_change",
        "possible_context_loss",
        "candidate_selection_mismatch",
        "unclassified",
    }
)
ALLOWED_SEVERITIES = frozenset({"low", "medium", "high"})
REQUIRED_DISPOSITION = {
    "corpus_role": "engineering_replay_only",
    "development_only_permanent": True,
    "eligible_for_encoder_training": False,
    "eligible_for_encoder_evaluation": False,
    "eligible_for_policy_training": False,
    "eligible_for_policy_evaluation": False,
    "eligible_for_science": False,
    "cloud_exposure_allowed": False,
}
_FORBIDDEN_FIELD_TERMS = (
    "eeg",
    "cognitive",
    "emotion",
    "intention",
    "agreement",
    "diagnos",
    "brain",
    "training",
    "scientific",
    "policy_target",
)
_FORBIDDEN_TEXT_PATTERNS = tuple(
    re.compile(pattern, flags=re.IGNORECASE)
    for pattern in (
        r"\beeg\s+(?:label|feature|target)",
        r"\b(?:cognitive|emotional)\s+(?:label|state)",
        r"\b(?:intention|agreement|diagnosis)\b",
        r"\bbrain[ -]dialogue\b",
        r"\bpolicy[ -]training\b",
        r"\bscientific\s+(?:conclusion|claim)\b",
        r"\bmodel[ -]training\s+recommendation\b",
    )
)
_LEAK_TOKEN_PATTERN = re.compile(r"[\w]+", flags=re.UNICODE)
_FINDING_ID_PATTERN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\Z")
_CITATION_ID_PATTERN = re.compile(r"line:([1-9][0-9]*)\Z")
_METADATA_FORBIDDEN_KEYS = frozenset(
    {
        "raw_record",
        "raw_records",
        "record",
        "records",
        "raw_response",
        "response",
        "response_text",
        "response_bytes",
        "prompt",
        "prompt_text",
        "prompt_content",
        "completion",
    }
)

FROZEN_SYSTEM_PROMPT = """You are a local engineering reviewer of a permanently quarantined corpus.

Your only task is to report bounded replay or dialogue-runtime defects from the
provided chunk. Use source-line citations exactly as supplied. Return one JSON
array with the required finding schema. Do not reproduce source text.

Do not infer thoughts, intentions, emotions, agreement, diagnoses, cognitive
state, brain state, or scientific conclusions. Do not propose training, EEG
labels, EEG features, policy targets, or application changes. If the evidence
is ambiguous, use finding_type \"unclassified\". Every finding needs at least
one citation and must cite at least one non-overlap record in this chunk."""


class ReviewContractError(ValueError):
    """A deterministic contract failure that is safe to pass between reviewers."""

    def __init__(self, code: str, message: str | None = None) -> None:
        self.code = code
        super().__init__(message or code)


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_json(value: Any) -> str:
    return sha256_bytes(canonical_json(value).encode("utf-8"))


def _reject_nonfinite_constant(value: str) -> None:
    raise ReviewContractError("nonfinite_number", "JSON must not contain non-finite numeric constants")


def strict_json_loads(value: str) -> Any:
    try:
        return json.loads(value, parse_constant=_reject_nonfinite_constant)
    except ReviewContractError:
        raise
    except json.JSONDecodeError as exc:
        raise ReviewContractError("invalid_json", "response must be one complete JSON value") from exc


def _require_nonempty_string(value: Any, *, code: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReviewContractError(code, "required text is absent")
    return value


def require_quarantine_disposition(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReviewContractError("missing_disposition", "source disposition is required")
    for key, expected in REQUIRED_DISPOSITION.items():
        if value.get(key) != expected:
            raise ReviewContractError("invalid_disposition", f"source disposition violates {key}")
    return dict(value)


@dataclass(frozen=True)
class ReviewRecord:
    source_line: int
    legacy_turn_index: int
    record: dict[str, Any]


@dataclass(frozen=True)
class SourceEnvelope:
    source_sha256: str
    quarantine_report_sha256: str
    disposition: dict[str, Any]
    records: tuple[ReviewRecord, ...]
    source_path: Path | None = None

    def verify_unchanged(self) -> None:
        """Fail the run if an explicit source file changed after envelope creation."""
        if self.source_path is not None and sha256_bytes(self.source_path.read_bytes()) != self.source_sha256:
            raise ReviewContractError("source_changed", "source checksum changed during review")


@dataclass(frozen=True)
class ChunkRecord:
    citation_id: str
    source_line: int
    legacy_turn_index: int
    is_overlap_record: bool
    record: dict[str, Any]


@dataclass(frozen=True)
class ChunkEnvelope:
    chunk_id: str
    source_sha256: str
    records: tuple[ChunkRecord, ...]

    @property
    def allowed_citation_ids(self) -> tuple[str, ...]:
        return tuple(record.citation_id for record in self.records)

    @property
    def new_record_citation_ids(self) -> tuple[str, ...]:
        return tuple(record.citation_id for record in self.records if not record.is_overlap_record)

    def prompt_payload(self, validation_error_codes: Iterable[str] = ()) -> dict[str, Any]:
        """Construct one in-memory request. This value must never be persisted."""
        payload: dict[str, Any] = {
            "schema_version": CHUNK_SCHEMA,
            "chunk_id": self.chunk_id,
            "source_sha256": self.source_sha256,
            "records": [
                {
                    "citation_id": record.citation_id,
                    "source_line": record.source_line,
                    "legacy_turn_index": record.legacy_turn_index,
                    "is_overlap_record": record.is_overlap_record,
                    "record": record.record,
                }
                for record in self.records
            ],
            "allowed_citation_ids": list(self.allowed_citation_ids),
            "new_record_citation_ids": list(self.new_record_citation_ids),
        }
        errors = sorted(set(validation_error_codes))
        if errors:
            payload["previous_validation_error_codes"] = errors
        return payload

    def metadata_receipt(self) -> dict[str, Any]:
        return {
            "schema_version": CHUNK_SCHEMA,
            "chunk_id": self.chunk_id,
            "source_sha256": self.source_sha256,
            "allowed_citation_ids": list(self.allowed_citation_ids),
            "new_record_citation_ids": list(self.new_record_citation_ids),
        }


@dataclass(frozen=True)
class ReviewConfiguration:
    raw: dict[str, Any]
    valid_records_per_chunk: int
    overlap_records: int
    proposer_model: str
    reviewer_models: tuple[str, ...]
    maximum_attempts: int
    temperature: float
    seed: int
    context_limit: int | None
    max_output_tokens: int | None
    critic_enabled: bool
    critic_model: str

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "ReviewConfiguration":
        allowed = {
            "schema_version",
            "configuration_version",
            "validator",
            "proposer",
            "reviewer",
            "critic",
            "human_gate",
            "chunking",
            "generation",
            "retry",
        }
        if set(value) != allowed or value.get("schema_version") != CONFIG_SCHEMA:
            raise ReviewContractError("invalid_configuration", "review configuration schema is invalid")
        validator = value.get("validator")
        proposer = value.get("proposer")
        reviewer = value.get("reviewer")
        critic = value.get("critic")
        human_gate = value.get("human_gate")
        chunking = value.get("chunking")
        generation = value.get("generation")
        retry = value.get("retry")
        for section in (validator, proposer, reviewer, critic, human_gate, chunking, generation, retry):
            if not isinstance(section, dict):
                raise ReviewContractError("invalid_configuration", "review configuration sections must be objects")
        if validator != {"id": "R0", "type": "deterministic"}:
            raise ReviewContractError("invalid_configuration", "R0 must be the deterministic validator")
        proposer_model = _require_nonempty_string(proposer.get("model"), code="invalid_configuration")
        if proposer.get("id") != "R1" or proposer.get("purpose") != "bounded_chunk_findings" or set(proposer) != {"id", "model", "purpose"}:
            raise ReviewContractError("invalid_configuration", "R1 configuration is invalid")
        if reviewer.get("id") != "R2" or reviewer.get("purpose") != "citation_repair_and_aggregation" or set(reviewer) != {"id", "preferred_model", "fallback_model", "purpose"}:
            raise ReviewContractError("invalid_configuration", "R2 configuration is invalid")
        reviewer_values = (reviewer.get("preferred_model"), reviewer.get("fallback_model"))
        reviewer_models = tuple(value for value in reviewer_values if isinstance(value, str) and value)
        if not reviewer_models:
            raise ReviewContractError("invalid_configuration", "R2 needs at least one configured model")
        if set(critic) != {"id", "model", "purpose", "enabled_by_default"} or critic.get("id") != "R3" or critic.get("purpose") != "explicit_independent_adjudication" or critic.get("enabled_by_default") is not False or not isinstance(critic.get("model"), str) or not critic["model"]:
            raise ReviewContractError("invalid_configuration", "R3 must be disabled by default")
        if human_gate.get("id") != "R4" or not isinstance(human_gate.get("required_for"), list):
            raise ReviewContractError("invalid_configuration", "R4 configuration is invalid")
        required_human = {"policy_changes", "experiment_changes", "scientific_claims", "promotion_decisions"}
        if set(human_gate["required_for"]) != required_human:
            raise ReviewContractError("invalid_configuration", "R4 gate coverage is incomplete")
        if set(chunking) != {"valid_records_per_chunk", "overlap_records", "conversation_memory_between_chunks"}:
            raise ReviewContractError("invalid_configuration", "chunking configuration is invalid")
        chunk_size = chunking["valid_records_per_chunk"]
        overlap = chunking["overlap_records"]
        if isinstance(chunk_size, bool) or not isinstance(chunk_size, int) or chunk_size <= 0:
            raise ReviewContractError("invalid_configuration", "chunk size must be a positive integer")
        if isinstance(overlap, bool) or not isinstance(overlap, int) or not 0 <= overlap < chunk_size:
            raise ReviewContractError("invalid_configuration", "chunk overlap is invalid")
        if chunking["conversation_memory_between_chunks"] is not False:
            raise ReviewContractError("invalid_configuration", "cross-chunk conversation memory is prohibited")
        if set(generation) != {"temperature", "seed", "context_limit", "max_output_tokens"}:
            raise ReviewContractError("invalid_configuration", "generation configuration is invalid")
        temperature = generation["temperature"]
        seed = generation["seed"]
        if isinstance(temperature, bool) or not isinstance(temperature, (int, float)) or not math.isfinite(float(temperature)) or float(temperature) != 0.0:
            raise ReviewContractError("invalid_configuration", "temperature must be pinned to 0.0")
        if isinstance(seed, bool) or not isinstance(seed, int):
            raise ReviewContractError("invalid_configuration", "seed must be an integer")
        for key in ("context_limit", "max_output_tokens"):
            item = generation[key]
            if item is not None and (isinstance(item, bool) or not isinstance(item, int) or item <= 0):
                raise ReviewContractError("invalid_configuration", f"{key} must be null or a positive integer")
        if set(retry) != {"maximum_attempts"} or retry["maximum_attempts"] not in {1, 2, 3}:
            raise ReviewContractError("invalid_configuration", "retry count must be between one and three")
        return cls(
            raw=json.loads(canonical_json(dict(value))),
            valid_records_per_chunk=chunk_size,
            overlap_records=overlap,
            proposer_model=proposer_model,
            reviewer_models=reviewer_models,
            maximum_attempts=retry["maximum_attempts"],
            temperature=float(temperature),
            seed=seed,
            context_limit=generation["context_limit"],
            max_output_tokens=generation["max_output_tokens"],
            critic_enabled=False,
            critic_model=critic["model"],
        )

    @property
    def sha256(self) -> str:
        return sha256_json(self.raw)


def default_configuration() -> dict[str, Any]:
    """Load the tracked default configuration without embedding model identities in code."""
    try:
        value = strict_json_loads(DEFAULT_CONFIGURATION_PATH.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ReviewContractError("missing_configuration", "default cascade configuration is unavailable") from exc
    if not isinstance(value, dict):
        raise ReviewContractError("invalid_configuration", "default configuration must be a JSON object")
    return value


def build_chunk_envelopes(source: SourceEnvelope, configuration: ReviewConfiguration) -> list[ChunkEnvelope]:
    source.verify_unchanged()
    records = list(source.records)
    chunks: list[ChunkEnvelope] = []
    start = 0
    ordinal = 1
    while start < len(records):
        selected = records[start : start + configuration.valid_records_per_chunk]
        overlap_count = configuration.overlap_records if ordinal > 1 else 0
        chunk_records = tuple(
            ChunkRecord(
                citation_id=f"line:{record.source_line}",
                source_line=record.source_line,
                legacy_turn_index=record.legacy_turn_index,
                is_overlap_record=position < overlap_count,
                record=record.record,
            )
            for position, record in enumerate(selected)
        )
        chunks.append(
            ChunkEnvelope(
                chunk_id=f"{source.source_sha256[:16]}:chunk:{ordinal:04d}",
                source_sha256=source.source_sha256,
                records=chunk_records,
            )
        )
        if start + configuration.valid_records_per_chunk >= len(records):
            break
        start += configuration.valid_records_per_chunk - configuration.overlap_records
        ordinal += 1
    return chunks


def _iter_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _iter_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _iter_strings(item)


def _private_ngrams(chunk: ChunkEnvelope, width: int = 5) -> set[str]:
    ngrams: set[str] = set()
    for record in chunk.records:
        for text in _iter_strings(record.record):
            tokens = [token.casefold() for token in _LEAK_TOKEN_PATTERN.findall(text)]
            for start in range(0, max(0, len(tokens) - width + 1)):
                candidate = " ".join(tokens[start : start + width])
                if len(candidate) >= 24:
                    ngrams.add(candidate)
    return ngrams


def contains_substantial_private_text(value: str, chunk: ChunkEnvelope) -> bool:
    """Bounded n-gram detector; it is a guardrail, never a proof of privacy."""
    output_tokens = [token.casefold() for token in _LEAK_TOKEN_PATTERN.findall(value)]
    source_ngrams = _private_ngrams(chunk)
    for start in range(0, max(0, len(output_tokens) - 5 + 1)):
        if " ".join(output_tokens[start : start + 5]) in source_ngrams:
            return True
    return False


def _contains_forbidden_text(value: str) -> bool:
    return any(pattern.search(value) is not None for pattern in _FORBIDDEN_TEXT_PATTERNS)


def _reject_unknown_or_forbidden_fields(value: dict[str, Any], expected: set[str]) -> None:
    extra = set(value) - expected
    if not extra:
        return
    if any(any(term in field.casefold() for term in _FORBIDDEN_FIELD_TERMS) for field in extra):
        raise ReviewContractError("forbidden_field", "response contains a prohibited field")
    raise ReviewContractError("unknown_field", "response contains an unsupported field")


def validate_findings_response(response_text: str, chunk: ChunkEnvelope) -> list[dict[str, Any]]:
    """R0 validates a complete model response without repairing it."""
    value = strict_json_loads(response_text)
    if not isinstance(value, list):
        raise ReviewContractError("response_not_array", "response must be a JSON array")
    allowed = set(chunk.allowed_citation_ids)
    new = set(chunk.new_record_citation_ids)
    source_lines = {record.citation_id: record.source_line for record in chunk.records}
    seen_ids: set[str] = set()
    findings: list[dict[str, Any]] = []
    expected_finding = {
        "schema_version",
        "finding_id",
        "finding_type",
        "severity",
        "confidence",
        "evidence",
        "observation",
        "engineering_implication",
        "contains_verbatim_private_text",
    }
    for finding in value:
        if not isinstance(finding, dict):
            raise ReviewContractError("invalid_finding", "finding must be an object")
        _reject_unknown_or_forbidden_fields(finding, expected_finding)
        if set(finding) != expected_finding:
            raise ReviewContractError("missing_finding_field", "finding is missing required fields")
        if finding["schema_version"] != FINDING_SCHEMA:
            raise ReviewContractError("wrong_finding_schema", "finding schema version is invalid")
        finding_id = _require_nonempty_string(finding["finding_id"], code="invalid_finding_id")
        if not _FINDING_ID_PATTERN.fullmatch(finding_id) or finding_id in seen_ids:
            raise ReviewContractError("invalid_finding_id", "finding id is malformed or repeated")
        seen_ids.add(finding_id)
        if finding["finding_type"] not in ALLOWED_FINDING_TYPES:
            raise ReviewContractError("unknown_finding_type", "finding type is not allowed")
        if finding["severity"] not in ALLOWED_SEVERITIES:
            raise ReviewContractError("invalid_severity", "severity is not allowed")
        confidence = finding["confidence"]
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not math.isfinite(float(confidence)):
            raise ReviewContractError("nonfinite_number", "confidence must be finite")
        if not 0.0 <= float(confidence) <= 1.0:
            raise ReviewContractError("confidence_out_of_range", "confidence must be within [0, 1]")
        evidence = finding["evidence"]
        if not isinstance(evidence, list) or not evidence:
            raise ReviewContractError("empty_evidence", "finding evidence must be nonempty")
        citations: list[str] = []
        for item in evidence:
            if not isinstance(item, dict):
                raise ReviewContractError("invalid_evidence", "evidence must be an object")
            _reject_unknown_or_forbidden_fields(item, {"citation_id", "claim"})
            if set(item) != {"citation_id", "claim"}:
                raise ReviewContractError("invalid_evidence", "evidence fields are incomplete")
            citation_id = _require_nonempty_string(item["citation_id"], code="invalid_citation")
            match = _CITATION_ID_PATTERN.fullmatch(citation_id)
            if match is None:
                raise ReviewContractError("invalid_citation", "citation ids must use line:<source-line>")
            if citation_id not in allowed:
                raise ReviewContractError("citation_not_allowed", "citation is not in this chunk")
            if source_lines[citation_id] != int(match.group(1)):
                raise ReviewContractError("citation_line_mismatch", "citation does not match its source line")
            claim = _require_nonempty_string(item["claim"], code="invalid_evidence")
            if _contains_forbidden_text(claim) or contains_substantial_private_text(claim, chunk):
                raise ReviewContractError("private_or_forbidden_evidence", "evidence claim violates the content boundary")
            citations.append(citation_id)
        if not any(citation in new for citation in citations):
            raise ReviewContractError("overlap_only_evidence", "at least one citation must be a new chunk record")
        observation = _require_nonempty_string(finding["observation"], code="invalid_observation")
        implication = _require_nonempty_string(finding["engineering_implication"], code="invalid_implication")
        if finding["contains_verbatim_private_text"] is not False:
            raise ReviewContractError("verbatim_flag", "finding must explicitly deny verbatim private text")
        for text in (observation, implication):
            if _contains_forbidden_text(text):
                raise ReviewContractError("forbidden_semantic_content", "finding has prohibited semantic content")
            if contains_substantial_private_text(text, chunk):
                raise ReviewContractError("private_text_leak", "finding contains substantial source text")
        findings.append(
            {
                "schema_version": FINDING_SCHEMA,
                "finding_id": finding_id,
                "finding_type": finding["finding_type"],
                "severity": finding["severity"],
                "confidence": float(confidence),
                "evidence": [{"citation_id": item["citation_id"], "claim": item["claim"]} for item in evidence],
                "observation": observation,
                "engineering_implication": implication,
                "contains_verbatim_private_text": False,
            }
        )
    return sorted(findings, key=lambda item: item["finding_id"])


@dataclass(frozen=True)
class BackendResponse:
    raw_text: str | None
    model_identity: str
    model_digest: str | None
    runtime_name: str
    runtime_version: str | None
    elapsed_ms: float
    prompt_tokens: int | None
    completion_tokens: int | None
    stop_reason: str | None
    error_status: str | None = None


class LocalReviewBackend(Protocol):
    backend_type: str
    endpoint_class: str
    explicitly_local: bool

    def invoke(self, *, model: str, system_prompt: str, user_payload: dict[str, Any], configuration: ReviewConfiguration) -> BackendResponse:
        """Invoke one stateless local completion without persisting source payload."""


def classify_local_endpoint(endpoint: str) -> str:
    parsed = urlparse(endpoint)
    if parsed.scheme == "unix" and parsed.netloc == "" and parsed.path.startswith("/"):
        return "unix_socket"
    if parsed.scheme not in {"http", "https"} or parsed.username is not None or parsed.password is not None:
        raise ReviewContractError("remote_endpoint", "backend endpoint must be a local loopback or Unix socket")
    if parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ReviewContractError("remote_endpoint", "backend endpoint must be a local loopback or Unix socket")
    return "loopback"


class OllamaLocalBackend:
    """Small Ollama-compatible local HTTP adapter. It intentionally has no cloud mode."""

    backend_type = "ollama"
    explicitly_local = True

    def __init__(self, endpoint: str) -> None:
        self.endpoint_class = classify_local_endpoint(endpoint)
        if self.endpoint_class != "loopback":
            raise ReviewContractError("unsupported_endpoint", "Ollama HTTP requires a loopback HTTP endpoint")
        self.endpoint = endpoint.rstrip("/")

    def _request(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{self.endpoint}{path}",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return strict_json_loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, UnicodeDecodeError) as exc:
            raise ReviewContractError("backend_error", "local backend request failed") from exc

    def invoke(self, *, model: str, system_prompt: str, user_payload: dict[str, Any], configuration: ReviewConfiguration) -> BackendResponse:
        _require_local_model_name(model)
        started = time.monotonic()
        response = self._request(
            "/api/chat",
            {
                "model": model,
                "stream": False,
                "format": "json",
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": canonical_json(user_payload)},
                ],
                "options": {
                    "temperature": configuration.temperature,
                    "seed": configuration.seed,
                    **({"num_ctx": configuration.context_limit} if configuration.context_limit is not None else {}),
                    **({"num_predict": configuration.max_output_tokens} if configuration.max_output_tokens is not None else {}),
                },
            },
        )
        if not isinstance(response, dict):
            raise ReviewContractError("backend_error", "local backend returned a non-object")
        message = response.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        resolved_model = response.get("model") if isinstance(response.get("model"), str) else model
        _require_local_model_name(resolved_model)
        return BackendResponse(
            raw_text=content if isinstance(content, str) else None,
            model_identity=resolved_model,
            model_digest=response.get("digest") if isinstance(response.get("digest"), str) else None,
            runtime_name="ollama",
            runtime_version=None,
            elapsed_ms=(time.monotonic() - started) * 1000,
            prompt_tokens=response.get("prompt_eval_count") if isinstance(response.get("prompt_eval_count"), int) else None,
            completion_tokens=response.get("eval_count") if isinstance(response.get("eval_count"), int) else None,
            stop_reason=response.get("done_reason") if isinstance(response.get("done_reason"), str) else None,
            error_status=None if isinstance(content, str) else "missing_response_content",
        )


class MockLocalBackend:
    """Deterministic test backend. It never opens a socket or writes prompts."""

    backend_type = "mock"
    endpoint_class = "mock"
    explicitly_local = True

    def __init__(self, responses_by_model: Mapping[str, Iterable[BackendResponse | str]]) -> None:
        self._responses = {model: list(responses) for model, responses in responses_by_model.items()}
        self.invocations: list[dict[str, Any]] = []

    def invoke(self, *, model: str, system_prompt: str, user_payload: dict[str, Any], configuration: ReviewConfiguration) -> BackendResponse:
        self.invocations.append(
            {
                "model": model,
                "system_prompt_sha256": sha256_bytes(system_prompt.encode("utf-8")),
                "payload_schema": user_payload.get("schema_version"),
                "previous_validation_error_codes": user_payload.get("previous_validation_error_codes", []),
            }
        )
        values = self._responses.get(model)
        if not values:
            return BackendResponse(None, model, None, "mock", "v0", 0.0, None, None, None, "no_mock_response")
        response = values.pop(0)
        if isinstance(response, BackendResponse):
            return response
        return BackendResponse(response, model, f"mock:{model}", "mock", "v0", 0.0, None, None, "stop", None)


@dataclass(frozen=True)
class OperatorAttestation:
    network_isolation_operator_attested: bool
    prompt_response_logging_confined: bool

    def require_complete(self) -> None:
        if not self.network_isolation_operator_attested:
            raise ReviewContractError("missing_network_attestation", "operator must attest network state; loopback alone is insufficient")
        if not self.prompt_response_logging_confined:
            raise ReviewContractError("unconfined_logging", "operator must attest prompt and response logging confinement")


@dataclass(frozen=True)
class AttemptReceipt:
    attempt: int
    stage: str
    requested_model: str
    resolved_model: str | None
    model_digest: str | None
    runtime_name: str
    runtime_version: str | None
    endpoint_class: str
    elapsed_ms: float
    prompt_tokens: int | None
    completion_tokens: int | None
    stop_reason: str | None
    status: str
    validation_error_codes: tuple[str, ...]

    def as_dict(self) -> dict[str, Any]:
        return {
            "attempt": self.attempt,
            "stage": self.stage,
            "requested_model": self.requested_model,
            "resolved_model": self.resolved_model,
            "model_digest": self.model_digest,
            "runtime_name": self.runtime_name,
            "runtime_version": self.runtime_version,
            "endpoint_class": self.endpoint_class,
            "elapsed_ms": self.elapsed_ms,
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "stop_reason": self.stop_reason,
            "status": self.status,
            "validation_error_codes": list(self.validation_error_codes),
        }


@dataclass(frozen=True)
class ChunkReviewResult:
    chunk: dict[str, Any]
    findings: tuple[dict[str, Any], ...]
    review_status: str
    attempts: tuple[AttemptReceipt, ...]
    rejection_error_codes: tuple[str, ...]

    def persisted(self) -> dict[str, Any]:
        return {
            **self.chunk,
            "findings": list(self.findings),
            "review_status": self.review_status,
            "attempts": [attempt.as_dict() for attempt in self.attempts],
            "rejection_error_codes": list(self.rejection_error_codes),
        }


@dataclass(frozen=True)
class CascadeRun:
    source: SourceEnvelope
    configuration: ReviewConfiguration
    backend: LocalReviewBackend
    chunk_results: tuple[ChunkReviewResult, ...]
    attestation: OperatorAttestation


def _attempt_schedule(configuration: ReviewConfiguration) -> list[tuple[str, str]]:
    schedule = [("R1", configuration.proposer_model)]
    schedule.extend(("R2", model) for model in configuration.reviewer_models)
    return schedule[: configuration.maximum_attempts]


def _require_local_model_name(model: str) -> None:
    """Reject explicit cloud-routing identities without making a vendor assumption."""
    normalized = model.casefold()
    if ":cloud" in normalized or "://" in normalized or normalized.startswith("http:") or normalized.startswith("https:"):
        raise ReviewContractError("remote_model", "configured model identity is not explicitly local")


def run_review_cascade(
    source: SourceEnvelope,
    configuration: ReviewConfiguration,
    backend: LocalReviewBackend,
    attestation: OperatorAttestation,
) -> CascadeRun:
    """Run R0/R1/R2. R3 is intentionally unavailable to automatic retries."""
    if not backend.explicitly_local or backend.endpoint_class not in {"loopback", "unix_socket", "mock"}:
        raise ReviewContractError("backend_not_local", "review backend must be explicitly classified as local")
    attestation.require_complete()
    source.verify_unchanged()
    results: list[ChunkReviewResult] = []
    for chunk in build_chunk_envelopes(source, configuration):
        attempts: list[AttemptReceipt] = []
        prior_errors: list[str] = []
        accepted: list[dict[str, Any]] | None = None
        for ordinal, (stage, model) in enumerate(_attempt_schedule(configuration), start=1):
            _require_local_model_name(model)
            source.verify_unchanged()
            payload = chunk.prompt_payload(prior_errors if ordinal > 1 else ())
            response: BackendResponse | None = None
            try:
                response = backend.invoke(model=model, system_prompt=FROZEN_SYSTEM_PROMPT, user_payload=payload, configuration=configuration)
                source.verify_unchanged()
                if response.error_status is not None or response.raw_text is None:
                    raise ReviewContractError("backend_error", "backend did not return a complete response")
                accepted = validate_findings_response(response.raw_text, chunk)
                attempts.append(
                    AttemptReceipt(
                        ordinal, stage, model, response.model_identity, response.model_digest, response.runtime_name,
                        response.runtime_version, backend.endpoint_class, response.elapsed_ms, response.prompt_tokens,
                        response.completion_tokens, response.stop_reason, "accepted", (),
                    )
                )
                break
            except ReviewContractError as error:
                prior_errors.append(error.code)
                attempts.append(
                    AttemptReceipt(
                        ordinal,
                        stage,
                        model,
                        response.model_identity if response is not None else None,
                        response.model_digest if response is not None else None,
                        response.runtime_name if response is not None else getattr(backend, "backend_type", "unknown"),
                        response.runtime_version if response is not None else None,
                        backend.endpoint_class,
                        response.elapsed_ms if response is not None else 0.0,
                        response.prompt_tokens if response is not None else None,
                        response.completion_tokens if response is not None else None,
                        response.stop_reason if response is not None else None,
                        "rejected",
                        (error.code,),
                    )
                )
        metadata = chunk.metadata_receipt()
        if accepted is None:
            results.append(ChunkReviewResult(metadata, (), "rejected", tuple(attempts), tuple(sorted(set(prior_errors)))))
        else:
            results.append(ChunkReviewResult(metadata, tuple(accepted), "accepted", tuple(attempts), ()))
    source.verify_unchanged()
    return CascadeRun(source, configuration, backend, tuple(results), attestation)


def run_explicit_critic_adjudication(
    *,
    chunk: ChunkEnvelope,
    accepted_finding: dict[str, Any],
    configuration: ReviewConfiguration,
    backend: LocalReviewBackend,
    attestation: OperatorAttestation,
    requested_by_human: bool,
) -> dict[str, Any]:
    """Run R3 only on explicit human request; its output cannot override R0.

    The critic receives the original frozen chunk and an already accepted
    structured finding, never a previous model's raw response.  It returns a
    separate receipt for human review rather than mutating a cascade result.
    """
    if not requested_by_human:
        raise ReviewContractError("critic_requires_human_request", "R3 adjudication requires explicit human request")
    if not backend.explicitly_local or backend.endpoint_class not in {"loopback", "unix_socket", "mock"}:
        raise ReviewContractError("backend_not_local", "critic backend must be explicitly classified as local")
    attestation.require_complete()
    _require_local_model_name(configuration.critic_model)
    validated_input = validate_findings_response(canonical_json([accepted_finding]), chunk)
    if len(validated_input) != 1:
        raise ReviewContractError("invalid_critic_input", "R3 accepts exactly one R0-valid finding")
    payload = chunk.prompt_payload()
    payload["operation"] = "independent_adjudication"
    payload["accepted_finding"] = validated_input[0]
    response = backend.invoke(model=configuration.critic_model, system_prompt=FROZEN_SYSTEM_PROMPT, user_payload=payload, configuration=configuration)
    if response.error_status is not None or response.raw_text is None:
        raise ReviewContractError("backend_error", "R3 did not return a complete response")
    critic_findings = validate_findings_response(response.raw_text, chunk)
    return {
        "schema_version": CRITIC_SCHEMA,
        "status": "advisory_only",
        "critic_id": "R3",
        "requested_by_human": True,
        "input_finding_id": validated_input[0]["finding_id"],
        "critic_findings": critic_findings,
        "backend": {
            "requested_model": configuration.critic_model,
            "resolved_model": response.model_identity,
            "model_digest": response.model_digest,
            "runtime": response.runtime_name,
            "runtime_version": response.runtime_version,
            "endpoint_class": backend.endpoint_class,
        },
        "r0_override_permitted": False,
        "science_influence_allowed": False,
        "promotion_status": "not_eligible",
        "live_control": False,
    }


def _assert_metadata_only(value: Any) -> None:
    if isinstance(value, dict):
        forbidden = set(value) & _METADATA_FORBIDDEN_KEYS
        if forbidden:
            raise ReviewContractError("raw_payload_in_aggregate", "aggregate received prohibited raw payload fields")
        for item in value.values():
            _assert_metadata_only(item)
    elif isinstance(value, list):
        for item in value:
            _assert_metadata_only(item)


def aggregate_review_results(results: Iterable[ChunkReviewResult], *, source_sha256: str, disposition: dict[str, Any]) -> dict[str, Any]:
    """Aggregate accepted structured findings only. Raw chunk records cannot enter."""
    require_quarantine_disposition(disposition)
    persisted = [result.persisted() for result in results]
    _assert_metadata_only(persisted)
    by_type: Counter[str] = Counter()
    source_lines: set[int] = set()
    confidence_bins = {"0.00_to_0.24": 0, "0.25_to_0.49": 0, "0.50_to_0.74": 0, "0.75_to_1.00": 0}
    classifications: dict[int, set[str]] = defaultdict(set)
    model_runs: list[dict[str, Any]] = []
    accepted = 0
    rejected = 0
    for result in persisted:
        if result["review_status"] == "accepted":
            accepted += 1
        else:
            rejected += 1
        for attempt in result["attempts"]:
            model_runs.append({key: attempt[key] for key in attempt if key != "validation_error_codes"})
        for finding in result["findings"]:
            by_type[finding["finding_type"]] += 1
            confidence = finding["confidence"]
            key = "0.00_to_0.24" if confidence < 0.25 else "0.25_to_0.49" if confidence < 0.5 else "0.50_to_0.74" if confidence < 0.75 else "0.75_to_1.00"
            confidence_bins[key] += 1
            for evidence in finding["evidence"]:
                line = int(_CITATION_ID_PATTERN.fullmatch(evidence["citation_id"]).group(1))
                source_lines.add(line)
                classifications[line].add(finding["finding_type"])
    conflicts = [
        {"source_line": line, "finding_types": sorted(types)}
        for line, types in sorted(classifications.items())
        if len(types) > 1
    ]
    return {
        "schema_version": SUMMARY_SCHEMA,
        "source_sha256": source_sha256,
        "model_runs": sorted(model_runs, key=canonical_json),
        "chunk_count": len(persisted),
        "accepted_finding_count": sum(len(result["findings"]) for result in persisted),
        "rejected_response_count": rejected,
        "accepted_chunk_count": accepted,
        "finding_counts_by_type": dict(sorted(by_type.items())),
        "affected_source_lines": sorted(source_lines),
        "confidence_distribution": confidence_bins,
        "conflicting_findings": conflicts,
        "privacy_checks": {
            "raw_records_received_by_aggregator": False,
            "bounded_private_text_detector": "synthetic_ngram_overlap_v0",
            "private_text_detector_is_not_a_proof_of_privacy": True,
            "embeddings_created": False,
            "weights_updated": False,
        },
        "science_influence_allowed": False,
        "disposition": disposition,
    }


def _git_commit(repository_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "not_reported"


def build_run_manifest(run: CascadeRun, *, repository_root: Path) -> dict[str, Any]:
    attempts = [attempt for result in run.chunk_results for attempt in result.attempts]
    first = attempts[0] if attempts else None
    return {
        "schema_version": RUN_MANIFEST_SCHEMA,
        "cascade_version": CASCADE_VERSION,
        "source_sha256": run.source.source_sha256,
        "quarantine_report_sha256": run.source.quarantine_report_sha256,
        "orchestrator_commit": _git_commit(repository_root),
        "orchestrator_sha256": sha256_bytes(Path(__file__).read_bytes()),
        "configuration_sha256": run.configuration.sha256,
        "system_prompt_sha256": sha256_bytes(FROZEN_SYSTEM_PROMPT.encode("utf-8")),
        "backend": {
            "runtime": first.runtime_name if first is not None else getattr(run.backend, "backend_type", "not_reported"),
            "endpoint_class": run.backend.endpoint_class,
            "requested_model": first.requested_model if first is not None else "not_reported",
            "resolved_model": first.resolved_model if first is not None else "not_reported",
            "model_digest": first.model_digest if first is not None else "not_reported",
            "network_isolation_operator_attested": run.attestation.network_isolation_operator_attested,
        },
        "generation": {
            "temperature": run.configuration.temperature,
            "seed": run.configuration.seed,
            "context_limit": run.configuration.context_limit,
            "max_output_tokens": run.configuration.max_output_tokens,
        },
        "privacy": {
            "embeddings_created": False,
            "weights_updated": False,
            "persistent_memory_enabled": False,
            "cloud_exposure_allowed": False,
            "prompt_response_logging_confined_operator_attested": run.attestation.prompt_response_logging_confined,
        },
        "disposition": run.source.disposition,
        "science_status": "pipeline_only",
        "decision": "insufficient_evidence",
        "promotion_status": "not_eligible",
        "live_control": False,
    }


def _approved_artifact_directory(path: Path, repository_root: Path) -> str:
    resolved = path.resolve()
    root = repository_root.resolve()
    try:
        relative = resolved.relative_to(root)
    except ValueError:
        return "outside_repository"
    result = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "-q", "--", str(relative)],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ReviewContractError("unapproved_artifact_directory", "repository-local artifacts must be Git-ignored")
    return "git_ignored"


def write_metadata_only_artifacts(run: CascadeRun, *, artifact_directory: Path, repository_root: Path) -> dict[str, Path]:
    """Persist receipts only after the destination is outside Git or ignored by it."""
    _approved_artifact_directory(artifact_directory, repository_root)
    artifact_directory.mkdir(parents=True, exist_ok=True)
    chunks = [result.persisted() for result in run.chunk_results]
    summary = aggregate_review_results(chunks_to_results(chunks), source_sha256=run.source.source_sha256, disposition=run.source.disposition)
    manifest = build_run_manifest(run, repository_root=repository_root)
    for artifact in (chunks, summary, manifest):
        _assert_metadata_only(artifact)
    paths = {
        "chunks": artifact_directory / "local-review-chunks-v0.jsonl",
        "summary": artifact_directory / "local-review-summary-v0.json",
        "manifest": artifact_directory / "local-review-run-manifest-v0.json",
    }
    paths["chunks"].write_text("".join(canonical_json(chunk) + "\n" for chunk in chunks), encoding="utf-8")
    paths["summary"].write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    paths["manifest"].write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return paths


def chunks_to_results(chunks: Iterable[dict[str, Any]]) -> list[ChunkReviewResult]:
    """Validate persisted receipts before allowing them into aggregation."""
    results: list[ChunkReviewResult] = []
    required = {
        "schema_version",
        "chunk_id",
        "source_sha256",
        "allowed_citation_ids",
        "new_record_citation_ids",
        "findings",
        "review_status",
        "attempts",
        "rejection_error_codes",
    }
    for chunk in chunks:
        if not isinstance(chunk, dict):
            raise ReviewContractError("invalid_receipt", "persisted chunk receipt must be an object")
        _assert_metadata_only(chunk)
        if set(chunk) != required or chunk.get("schema_version") != CHUNK_SCHEMA:
            raise ReviewContractError("invalid_receipt", "persisted chunk receipt has an invalid schema")
        if chunk.get("review_status") not in {"accepted", "rejected"}:
            raise ReviewContractError("invalid_receipt", "persisted chunk review status is invalid")
        if not isinstance(chunk.get("findings"), list) or not isinstance(chunk.get("attempts"), list):
            raise ReviewContractError("invalid_receipt", "persisted chunk receipt is malformed")
        if chunk["review_status"] == "rejected" and chunk["findings"]:
            raise ReviewContractError("invalid_receipt", "rejected chunks cannot contain partial findings")
        allowed_citations = chunk["allowed_citation_ids"]
        new_citations = chunk["new_record_citation_ids"]
        if (
            not isinstance(allowed_citations, list)
            or not isinstance(new_citations, list)
            or not all(isinstance(item, str) and _CITATION_ID_PATTERN.fullmatch(item) for item in allowed_citations)
            or not set(new_citations).issubset(set(allowed_citations))
        ):
            raise ReviewContractError("invalid_receipt", "persisted citation metadata is invalid")
        normalized_findings: list[dict[str, Any]] = []
        finding_keys = {
            "schema_version",
            "finding_id",
            "finding_type",
            "severity",
            "confidence",
            "evidence",
            "observation",
            "engineering_implication",
            "contains_verbatim_private_text",
        }
        for finding in chunk["findings"]:
            if not isinstance(finding, dict):
                raise ReviewContractError("invalid_receipt", "persisted finding must be an object")
            _reject_unknown_or_forbidden_fields(finding, finding_keys)
            if set(finding) != finding_keys or finding.get("schema_version") != FINDING_SCHEMA:
                raise ReviewContractError("invalid_receipt", "persisted finding schema is invalid")
            finding_id = _require_nonempty_string(finding.get("finding_id"), code="invalid_receipt")
            if not _FINDING_ID_PATTERN.fullmatch(finding_id) or finding.get("finding_type") not in ALLOWED_FINDING_TYPES or finding.get("severity") not in ALLOWED_SEVERITIES:
                raise ReviewContractError("invalid_receipt", "persisted finding identity is invalid")
            confidence = finding.get("confidence")
            if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not math.isfinite(float(confidence)) or not 0.0 <= float(confidence) <= 1.0:
                raise ReviewContractError("invalid_receipt", "persisted finding confidence is invalid")
            if finding.get("contains_verbatim_private_text") is not False:
                raise ReviewContractError("invalid_receipt", "persisted finding cannot allow verbatim text")
            evidence = finding.get("evidence")
            if not isinstance(evidence, list) or not evidence:
                raise ReviewContractError("invalid_receipt", "persisted finding evidence is invalid")
            citations: list[str] = []
            normalized_evidence: list[dict[str, str]] = []
            for item in evidence:
                if not isinstance(item, dict) or set(item) != {"citation_id", "claim"}:
                    raise ReviewContractError("invalid_receipt", "persisted evidence is invalid")
                citation = item.get("citation_id")
                claim = item.get("claim")
                if not isinstance(citation, str) or citation not in allowed_citations or not isinstance(claim, str) or not claim.strip() or _contains_forbidden_text(claim):
                    raise ReviewContractError("invalid_receipt", "persisted evidence violates the boundary")
                citations.append(citation)
                normalized_evidence.append({"citation_id": citation, "claim": claim})
            if not set(citations) & set(new_citations):
                raise ReviewContractError("invalid_receipt", "persisted finding has overlap-only evidence")
            observation = _require_nonempty_string(finding.get("observation"), code="invalid_receipt")
            implication = _require_nonempty_string(finding.get("engineering_implication"), code="invalid_receipt")
            if _contains_forbidden_text(observation) or _contains_forbidden_text(implication):
                raise ReviewContractError("invalid_receipt", "persisted finding has prohibited semantic content")
            normalized_findings.append(
                {
                    "schema_version": FINDING_SCHEMA,
                    "finding_id": finding_id,
                    "finding_type": finding["finding_type"],
                    "severity": finding["severity"],
                    "confidence": float(confidence),
                    "evidence": normalized_evidence,
                    "observation": observation,
                    "engineering_implication": implication,
                    "contains_verbatim_private_text": False,
                }
            )
        attempt_keys = {
            "attempt",
            "stage",
            "requested_model",
            "resolved_model",
            "model_digest",
            "runtime_name",
            "runtime_version",
            "endpoint_class",
            "elapsed_ms",
            "prompt_tokens",
            "completion_tokens",
            "stop_reason",
            "status",
            "validation_error_codes",
        }
        for item in chunk["attempts"]:
            if not isinstance(item, dict) or set(item) != attempt_keys:
                raise ReviewContractError("invalid_receipt", "persisted attempt receipt is invalid")
            if item["stage"] not in {"R1", "R2"} or item["status"] not in {"accepted", "rejected"}:
                raise ReviewContractError("invalid_receipt", "persisted attempt status is invalid")
            if isinstance(item["attempt"], bool) or not isinstance(item["attempt"], int) or item["attempt"] < 1:
                raise ReviewContractError("invalid_receipt", "persisted attempt ordinal is invalid")
            if not isinstance(item["requested_model"], str) or not isinstance(item["runtime_name"], str):
                raise ReviewContractError("invalid_receipt", "persisted attempt identity is invalid")
            if item["endpoint_class"] not in {"loopback", "unix_socket", "mock"}:
                raise ReviewContractError("invalid_receipt", "persisted endpoint class is invalid")
            if not isinstance(item["elapsed_ms"], (int, float)) or not math.isfinite(float(item["elapsed_ms"])):
                raise ReviewContractError("invalid_receipt", "persisted elapsed time is invalid")
            if not isinstance(item["validation_error_codes"], list) or not all(isinstance(code, str) for code in item["validation_error_codes"]):
                raise ReviewContractError("invalid_receipt", "persisted validation errors are invalid")
        # Aggregation only needs the metadata representation, so create a small
        # shell rather than reconstructing the raw in-memory chunk.
        results.append(
            ChunkReviewResult(
                {key: chunk[key] for key in ("schema_version", "chunk_id", "source_sha256", "allowed_citation_ids", "new_record_citation_ids")},
                tuple(sorted(normalized_findings, key=lambda item: item["finding_id"])),
                chunk["review_status"],
                tuple(
                    AttemptReceipt(
                        item["attempt"], item["stage"], item["requested_model"], item.get("resolved_model"), item.get("model_digest"),
                        item["runtime_name"], item.get("runtime_version"), item["endpoint_class"], float(item["elapsed_ms"]),
                        item.get("prompt_tokens"), item.get("completion_tokens"), item.get("stop_reason"), item["status"],
                        tuple(item.get("validation_error_codes", [])),
                    )
                    for item in chunk["attempts"]
                ),
                tuple(chunk["rejection_error_codes"]),
            )
        )
    return results


def load_quarantined_source(source_path: Path, quarantine_report_path: Path) -> SourceEnvelope:
    """Load an explicit local source only after validating its existing quarantine report."""
    import quarantine_dialectic_corpus as quarantine  # Local sibling; no data read on import.

    report_bytes = quarantine_report_path.read_bytes()
    report = strict_json_loads(report_bytes.decode("utf-8"))
    if not isinstance(report, dict) or report.get("schema_version") != quarantine.PARSE_REPORT_SCHEMA:
        raise ReviewContractError("invalid_quarantine_report", "quarantine report schema is invalid")
    disposition = require_quarantine_disposition(report.get("disposition"))
    source_bytes = source_path.read_bytes()
    source_sha = sha256_bytes(source_bytes)
    source_metadata = report.get("source")
    if not isinstance(source_metadata, dict) or source_metadata.get("sha256") != source_sha:
        raise ReviewContractError("source_checksum_mismatch", "source does not match quarantine report")
    records: list[ReviewRecord] = []
    for line, raw_line in enumerate(source_bytes.splitlines(), start=1):
        try:
            event = quarantine.load_strict_json_object(raw_line)
            quarantine.validate_turn_schema(event)
        except quarantine.ParseFailure:
            continue
        records.append(ReviewRecord(line, event["index"], event))
    expected = report.get("records", {}).get("valid_record_count") if isinstance(report.get("records"), dict) else None
    if expected != len(records):
        raise ReviewContractError("source_record_count_mismatch", "source no longer matches quarantine report count")
    return SourceEnvelope(source_sha, sha256_bytes(report_bytes), disposition, tuple(records), source_path)


def dry_run_receipt(source: SourceEnvelope, configuration: ReviewConfiguration) -> dict[str, Any]:
    """Build envelopes without invoking a model or serializing raw records."""
    chunks = build_chunk_envelopes(source, configuration)
    return {
        "schema_version": "nc-local-review-dry-run-v0",
        "source_sha256": source.source_sha256,
        "chunk_count": len(chunks),
        "chunk_ids": [chunk.chunk_id for chunk in chunks],
        "all_chunks_have_new_records": all(bool(chunk.new_record_citation_ids) for chunk in chunks),
        "configuration_sha256": configuration.sha256,
        "model_invoked": False,
        "disposition": source.disposition,
        "science_status": "pipeline_only",
        "decision": "insufficient_evidence",
        "promotion_status": "not_eligible",
        "live_control": False,
    }


def _load_configuration(path: Path | None) -> ReviewConfiguration:
    if path is None:
        return ReviewConfiguration.from_mapping(default_configuration())
    value = strict_json_loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ReviewContractError("invalid_configuration", "configuration must be a JSON object")
    return ReviewConfiguration.from_mapping(value)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--quarantine-report", required=True, type=Path)
    parser.add_argument("--configuration", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--backend-url")
    parser.add_argument("--artifact-directory", type=Path)
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--attest-network-isolation", action="store_true")
    parser.add_argument("--attest-prompt-response-logging-confined", action="store_true")
    args = parser.parse_args(argv)
    source = load_quarantined_source(args.source, args.quarantine_report)
    configuration = _load_configuration(args.configuration)
    if args.dry_run:
        print(json.dumps(dry_run_receipt(source, configuration), sort_keys=True))
        return 0
    if not args.backend_url or args.artifact_directory is None:
        parser.error("a non-dry run requires --backend-url and --artifact-directory")
    attestation = OperatorAttestation(args.attest_network_isolation, args.attest_prompt_response_logging_confined)
    run = run_review_cascade(source, configuration, OllamaLocalBackend(args.backend_url), attestation)
    paths = write_metadata_only_artifacts(run, artifact_directory=args.artifact_directory, repository_root=args.repository_root)
    print(json.dumps({key: str(value) for key, value in paths.items()}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
