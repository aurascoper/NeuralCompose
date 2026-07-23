#!/usr/bin/env python3
"""Run a bounded, local-only semantic engineering review of private dialectics.

This tool accepts only a quarantined dialectic corpus and a loopback Ollama
endpoint. It sends bounded raw chunks to a local Qwen model without retaining
prompts, then persists only validated, metadata-only findings. It never creates
embeddings, changes weights, or produces scientific evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import quarantine_dialectic_corpus as quarantine


REVIEW_SCHEMA = "nc-dialectic-local-review-chunk-v0"
RUN_SCHEMA = "nc-dialectic-local-review-run-v0"
AGGREGATE_SCHEMA = "nc-dialectic-local-review-aggregate-v0"
REVIEWER_VERSION = "local-dialectic-review-v1"
DEFAULT_MODEL = "qwen2.5:0.5b"
DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
CHUNK_SIZE = 16
CHUNK_OVERLAP = 2
REVIEW_SEED = 42
REVIEW_TEMPERATURE = 0.0
DEFAULT_CONTEXT_LIMIT = 8192
MAX_OBSERVATION_LENGTH = 400
MAX_IMPLICATION_LENGTH = 300
FINDING_TYPES = frozenset(
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
        "unclassified",
    }
)
SEVERITIES = frozenset({"low", "medium", "high"})
REVIEW_DISPOSITION = {
    "corpus_role": "engineering_replay_only",
    "review_role": "local_semantic_engineering_review",
    "development_only_permanent": True,
    "eligible_for_science": False,
    "eligible_for_training": False,
    "cloud_exposure_allowed": False,
}
REQUIRED_QUARANTINE_DISPOSITION = {
    "corpus_role": "engineering_replay_only",
    "development_only_permanent": True,
    "eligible_for_encoder_training": False,
    "eligible_for_encoder_evaluation": False,
    "eligible_for_policy_training": False,
    "eligible_for_policy_evaluation": False,
    "cloud_exposure_allowed": False,
}

SYSTEM_PROMPT = """You are reviewing a private, permanently quarantined dialogue corpus for local engineering purposes.

The corpus is development-only. It is ineligible for encoder training, encoder evaluation, policy training, policy evaluation, scientific claims, EEG labeling, or cloud exposure.

Identify structural and conversational-runtime defects that could affect deterministic replay or dialogue-system engineering. You may inspect semantic content only for repeated/collapsed candidates, candidate-role inconsistency, selection inertia, synthesis repetition, apparent context loss, turn-state discontinuity, candidate-diversity versus selection mismatch, or generator behavior changes.

Do not infer thoughts, intention, emotion, agreement, diagnosis, or cognitive state. Do not propose EEG labels or features. Do not infer timestamps or speaker identities. Do not reproduce private dialogue text. Do not recommend training from this corpus.

Return only a JSON array. Each object must contain source_lines, legacy_turn_indices, finding_type, severity, confidence, observation, engineering_implication, and contains_verbatim_private_text. The final field must be false. Use source-line order as canonical; legacy turn indices may repeat or reset. Use unclassified when evidence is ambiguous."""


class ReviewContractError(ValueError):
    """A local review request or model response violates the quarantine contract."""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_json(value: Any) -> str:
    return sha256_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def _require_disposition(value: Any) -> None:
    if not isinstance(value, dict):
        raise ReviewContractError("parse report lacks quarantine disposition")
    for key, expected in REQUIRED_QUARANTINE_DISPOSITION.items():
        if value.get(key) != expected:
            raise ReviewContractError(f"parse report quarantine disposition mismatch: {key}")


def load_reviewable_records(source_path: Path, parse_report_path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Load only source rows that passed the prior strict quarantine parser."""
    report = json.loads(parse_report_path.read_text())
    if report.get("schema_version") != quarantine.PARSE_REPORT_SCHEMA:
        raise ReviewContractError("unexpected parse report schema")
    _require_disposition(report.get("disposition"))

    source_bytes = source_path.read_bytes()
    source = report.get("source")
    if not isinstance(source, dict) or source.get("sha256") != sha256_bytes(source_bytes):
        raise ReviewContractError("raw source checksum does not match quarantine parse report")

    records: list[dict[str, Any]] = []
    for source_line, raw_line in enumerate(source_bytes.splitlines(), start=1):
        try:
            event = quarantine.load_strict_json_object(raw_line)
            quarantine.validate_turn_schema(event)
        except quarantine.ParseFailure:
            continue
        records.append({"source_line": source_line, "legacy_turn_index": event["index"], "raw_event": event})

    expected_count = report.get("records", {}).get("valid_record_count")
    if expected_count != len(records):
        raise ReviewContractError("raw source no longer reconstructs the quarantined valid-record count")
    return report, records


def chunk_records(records: list[dict[str, Any]], *, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[list[dict[str, Any]]]:
    if chunk_size <= 0 or overlap < 0 or overlap >= chunk_size:
        raise ReviewContractError("chunk size must be positive and overlap must be smaller than it")
    chunks: list[list[dict[str, Any]]] = []
    start = 0
    while start < len(records):
        chunk = records[start : start + chunk_size]
        if not chunk:
            break
        chunks.append(chunk)
        if start + chunk_size >= len(records):
            break
        start += chunk_size - overlap
    return chunks


def _sanitize_identity(event: dict[str, Any]) -> dict[str, str] | None:
    return quarantine.fingerprint_identity(event)


def build_chunk_context(chunk_id: str, records: list[dict[str, Any]]) -> str:
    """Build the only raw-content prompt payload used by one stateless request."""
    return json.dumps(
        {
            "disposition": REVIEW_DISPOSITION,
            "chunk_id": chunk_id,
            "records": [
                {
                    "source_line": record["source_line"],
                    "legacy_turn_index": record["legacy_turn_index"],
                    "generator_fingerprint": _sanitize_identity(record["raw_event"]),
                    "raw_record": record["raw_event"],
                }
                for record in records
            ],
        },
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _require_loopback_ollama(base_url: str) -> str:
    parsed = urlparse(base_url)
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
        or parsed.port != 11434
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
    ):
        raise ReviewContractError("local review permits only http://127.0.0.1:11434 or localhost equivalent")
    return f"http://{parsed.netloc}"


def _request_json(url: str, *, method: str = "GET", payload: dict[str, Any] | None = None) -> dict[str, Any]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            value = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise ReviewContractError(f"local Ollama request failed: {error}") from error
    if not isinstance(value, dict):
        raise ReviewContractError("local Ollama response must be a JSON object")
    return value


def local_model_identity(base_url: str, model: str) -> dict[str, Any]:
    if not model.startswith("qwen2.5:"):
        raise ReviewContractError("only a local qwen2.5 model is allowed for this review")
    tags = _request_json(f"{base_url}/api/tags")
    models = tags.get("models")
    if not isinstance(models, list):
        raise ReviewContractError("local Ollama tags response lacks models")
    for candidate in models:
        if isinstance(candidate, dict) and candidate.get("name") == model:
            if candidate.get("remote_model") or candidate.get("remote_host"):
                raise ReviewContractError("remote Ollama models are prohibited for corpus review")
            digest = candidate.get("digest")
            if not isinstance(digest, str) or not digest:
                raise ReviewContractError("local Ollama model lacks a digest")
            return {
                "name": model,
                "digest": digest,
                "details": candidate.get("details") if isinstance(candidate.get("details"), dict) else {},
            }
    raise ReviewContractError(f"local Ollama model is unavailable: {model}")


def _json_array_from_model_content(content: str) -> list[Any]:
    stripped = content.strip()
    if stripped.startswith("```"):
        match = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, flags=re.DOTALL | re.IGNORECASE)
        if match is not None:
            stripped = match.group(1)
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError as error:
        raise ReviewContractError("local review response was not a JSON array") from error
    if not isinstance(value, list):
        raise ReviewContractError("local review response must be a JSON array")
    return value


def _private_text_fragments(records: list[dict[str, Any]]) -> list[str]:
    fragments: list[str] = []

    def add_fragment(value: str) -> None:
        normalized = " ".join(value.split())
        if len(normalized) >= 16:
            fragments.append(normalized)
        words = normalized.split()
        for start in range(max(0, len(words) - 3)):
            phrase = " ".join(words[start : start + 4])
            if len(phrase) >= 16:
                fragments.append(phrase)

    for record in records:
        content = quarantine.content_projection(record["raw_event"])
        for field, value in content.items():
            if isinstance(value, str) and len(value.strip()) >= 16:
                add_fragment(value)
            if field == "candidates" and isinstance(value, list):
                for candidate in value:
                    if isinstance(candidate, dict):
                        text = candidate.get("text")
                        if isinstance(text, str) and len(text.strip()) >= 16:
                            add_fragment(text)
    return fragments


def _contains_private_text(value: str, fragments: list[str]) -> bool:
    normalized = " ".join(value.casefold().split())
    return any(" ".join(fragment.casefold().split()) in normalized for fragment in fragments)


def validate_findings(response_content: str, records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Accept only bounded, chunk-local, non-verbatim engineering findings."""
    value = _json_array_from_model_content(response_content)
    allowed_lines = {record["source_line"] for record in records}
    line_to_index = {record["source_line"]: record["legacy_turn_index"] for record in records}
    private_fragments = _private_text_fragments(records)
    findings: list[dict[str, Any]] = []
    for position, finding in enumerate(value):
        if not isinstance(finding, dict):
            raise ReviewContractError(f"finding {position} must be an object")
        source_lines = finding.get("source_lines")
        legacy_indexes = finding.get("legacy_turn_indices")
        if (
            not isinstance(source_lines, list)
            or not source_lines
            or any(isinstance(line, bool) or not isinstance(line, int) or line not in allowed_lines for line in source_lines)
        ):
            raise ReviewContractError(f"finding {position} cites source lines outside its chunk")
        if len(set(source_lines)) != len(source_lines):
            raise ReviewContractError(f"finding {position} repeats a source line")
        if (
            not isinstance(legacy_indexes, list)
            or not legacy_indexes
            or any(isinstance(index, bool) or not isinstance(index, int) for index in legacy_indexes)
        ):
            raise ReviewContractError(f"finding {position} has invalid legacy turn indexes")
        expected_indexes = {line_to_index[line] for line in source_lines}
        if not set(legacy_indexes).issubset(expected_indexes):
            raise ReviewContractError(f"finding {position} cites a legacy index outside its source lines")
        finding_type = finding.get("finding_type")
        severity = finding.get("severity")
        confidence = finding.get("confidence")
        observation = finding.get("observation")
        implication = finding.get("engineering_implication")
        if finding_type not in FINDING_TYPES or severity not in SEVERITIES:
            raise ReviewContractError(f"finding {position} uses an unsupported category")
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0.0 <= float(confidence) <= 1.0:
            raise ReviewContractError(f"finding {position} has invalid confidence")
        if not isinstance(observation, str) or not observation or len(observation) > MAX_OBSERVATION_LENGTH:
            raise ReviewContractError(f"finding {position} has invalid observation")
        if not isinstance(implication, str) or not implication or len(implication) > MAX_IMPLICATION_LENGTH:
            raise ReviewContractError(f"finding {position} has invalid engineering implication")
        if finding.get("contains_verbatim_private_text") is not False:
            raise ReviewContractError(f"finding {position} must deny verbatim private text")
        if _contains_private_text(observation, private_fragments) or _contains_private_text(implication, private_fragments):
            raise ReviewContractError(f"finding {position} contains private dialogue text")
        findings.append(
            {
                "source_lines": sorted(source_lines),
                "legacy_turn_indices": sorted(set(legacy_indexes)),
                "finding_type": finding_type,
                "severity": severity,
                "confidence": float(confidence),
                "observation": observation,
                "engineering_implication": implication,
                "contains_verbatim_private_text": False,
            }
        )
    return findings


def review_chunk(base_url: str, model: str, context_limit: int, chunk_id: str, records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    response = _request_json(
        f"{base_url}/api/chat",
        method="POST",
        payload={
            "model": model,
            "stream": False,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": build_chunk_context(chunk_id, records)},
            ],
            "options": {"temperature": REVIEW_TEMPERATURE, "seed": REVIEW_SEED, "num_ctx": context_limit},
        },
    )
    message = response.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        raise ReviewContractError("local Ollama chat response lacks message content")
    return validate_findings(message["content"], records)


def aggregate_review_chunks(chunks: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate structured Pass-A findings without reopening the raw corpus."""
    category_lines: dict[str, set[int]] = defaultdict(set)
    category_chunks: dict[str, set[str]] = defaultdict(set)
    line_types: dict[int, set[str]] = defaultdict(set)
    confidences: list[float] = []
    finding_count = 0
    for chunk in chunks:
        chunk_id = str(chunk["chunk_id"])
        for finding in chunk["findings"]:
            finding_count += 1
            finding_type = str(finding["finding_type"])
            source_lines = [int(line) for line in finding["source_lines"]]
            category_lines[finding_type].update(source_lines)
            category_chunks[finding_type].add(chunk_id)
            for source_line in source_lines:
                line_types[source_line].add(finding_type)
            confidences.append(float(finding["confidence"]))
    confidence_distribution = {
        "0.00_to_0.24": sum(confidence < 0.25 for confidence in confidences),
        "0.25_to_0.49": sum(0.25 <= confidence < 0.5 for confidence in confidences),
        "0.50_to_0.74": sum(0.5 <= confidence < 0.75 for confidence in confidences),
        "0.75_to_1.00": sum(confidence >= 0.75 for confidence in confidences),
    }
    categories = [
        {
            "finding_type": finding_type,
            "finding_count": sum(
                1 for chunk in chunks for finding in chunk["findings"] if finding["finding_type"] == finding_type
            ),
            "affected_source_lines": sorted(category_lines[finding_type]),
            "chunk_ids": sorted(category_chunks[finding_type]),
            "spans_chunk_boundaries": len(category_chunks[finding_type]) > 1,
        }
        for finding_type in sorted(category_lines)
    ]
    conflicts = [
        {"source_line": source_line, "finding_types": sorted(finding_types)}
        for source_line, finding_types in sorted(line_types.items())
        if len(finding_types) > 1
    ]
    return {
        "schema_version": AGGREGATE_SCHEMA,
        "reviewer_version": REVIEWER_VERSION,
        "input_chunk_count": len(chunks),
        "finding_count": finding_count,
        "categories": categories,
        "conflicting_findings": conflicts,
        "confidence_distribution": confidence_distribution,
        "disposition": REVIEW_DISPOSITION,
    }


def _load_review_chunks(path: Path) -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        try:
            chunk = json.loads(line)
        except json.JSONDecodeError as error:
            raise ReviewContractError(f"review findings line {line_number} is invalid JSON") from error
        if not isinstance(chunk, dict) or chunk.get("schema_version") != REVIEW_SCHEMA:
            raise ReviewContractError(f"review findings line {line_number} has the wrong schema")
        if chunk.get("disposition") != REVIEW_DISPOSITION:
            raise ReviewContractError(f"review findings line {line_number} has the wrong disposition")
        if not isinstance(chunk.get("chunk_id"), str) or not isinstance(chunk.get("findings"), list):
            raise ReviewContractError(f"review findings line {line_number} is malformed")
        chunks.append(chunk)
    return chunks


def run_review(
    source_path: Path,
    parse_report_path: Path,
    findings_path: Path,
    run_manifest_path: Path,
    *,
    base_url: str,
    model: str,
    context_limit: int,
    prompt_logging_status: str,
) -> dict[str, Any]:
    if prompt_logging_status != "verified_disabled":
        raise ReviewContractError("private review requires prompt_logging_status=verified_disabled")
    report, records = load_reviewable_records(source_path, parse_report_path)
    chunks = chunk_records(records)
    model_identity = local_model_identity(base_url, model)
    review_chunks: list[dict[str, Any]] = []
    for ordinal, records_chunk in enumerate(chunks, start=1):
        chunk_id = f"chunk-{ordinal:03d}"
        findings = review_chunk(base_url, model, context_limit, chunk_id, records_chunk)
        review_chunks.append(
            {
                "schema_version": REVIEW_SCHEMA,
                "chunk_id": chunk_id,
                "source_lines": [record["source_line"] for record in records_chunk],
                "legacy_turn_indices": [record["legacy_turn_index"] for record in records_chunk],
                "findings": findings,
                "disposition": REVIEW_DISPOSITION,
            }
        )
    run_manifest = {
        "schema_version": RUN_SCHEMA,
        "reviewer_version": REVIEWER_VERSION,
        "review_model": model_identity["name"],
        "model_digest": model_identity["digest"],
        "model_details": model_identity["details"],
        "runtime": "ollama_local_loopback",
        "network_enabled": False,
        "temperature": REVIEW_TEMPERATURE,
        "seed": REVIEW_SEED,
        "context_limit": context_limit,
        "chunk_size_valid_records": CHUNK_SIZE,
        "chunk_overlap_records": CHUNK_OVERLAP,
        "conversation_memory_between_chunks": False,
        "embeddings_created": False,
        "weights_updated": False,
        "source_sha256": report["source"]["sha256"],
        "science_influence_allowed": False,
        "prompt_logging_status": "verified_disabled",
        "disposition": REVIEW_DISPOSITION,
        "review_chunk_count": len(review_chunks),
        "review_findings_sha256": sha256_json(review_chunks),
    }
    findings_path.parent.mkdir(parents=True, exist_ok=True)
    run_manifest_path.parent.mkdir(parents=True, exist_ok=True)
    findings_path.write_text("".join(json.dumps(chunk, sort_keys=True) + "\n" for chunk in review_chunks))
    run_manifest_path.write_text(json.dumps(run_manifest, indent=2, sort_keys=True) + "\n")
    return run_manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)

    review = subcommands.add_parser("review", help="perform stateless local Qwen chunk review")
    review.add_argument("--input", required=True, type=Path, help="private local dialectic JSONL")
    review.add_argument("--parse-report", required=True, type=Path)
    review.add_argument("--findings-output", required=True, type=Path)
    review.add_argument("--run-manifest-output", required=True, type=Path)
    review.add_argument("--model", default=DEFAULT_MODEL)
    review.add_argument("--ollama-url", default=DEFAULT_OLLAMA_URL)
    review.add_argument("--context-limit", default=DEFAULT_CONTEXT_LIMIT, type=int)
    review.add_argument(
        "--prompt-logging-status",
        choices=("verified_disabled",),
        required=True,
        help="operator attestation required before private text is sent to local Ollama",
    )

    aggregate = subcommands.add_parser("aggregate", help="aggregate structured Pass-A findings without raw dialogue")
    aggregate.add_argument("--findings-input", required=True, type=Path)
    aggregate.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    if args.command == "aggregate":
        result = aggregate_review_chunks(_load_review_chunks(args.findings_input))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(f"wrote {args.output} ({result['finding_count']} metadata-only findings)")
        return 0

    if args.context_limit <= 0:
        raise SystemExit("--context-limit must be positive")
    base_url = _require_loopback_ollama(args.ollama_url)
    manifest = run_review(
        args.input,
        args.parse_report,
        args.findings_output,
        args.run_manifest_output,
        base_url=base_url,
        model=args.model,
        context_limit=args.context_limit,
        prompt_logging_status=args.prompt_logging_status,
    )
    print(f"wrote {args.findings_output} and {args.run_manifest_output} ({manifest['review_chunk_count']} local-only chunks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
