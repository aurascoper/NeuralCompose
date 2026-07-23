#!/usr/bin/env python3
"""Create local-only, metadata-only engineering artifacts from dialectic JSONL.

The source is private dialogue. This tool never rewrites it, never emits text
or embeddings, and labels every derived artifact as permanently ineligible for
encoder or policy science. It is for bounded local replay and parser work only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections import Counter
from pathlib import Path
from typing import Any


PARSER_VERSION = "dialectic-corpus-quarantine-v1"
PARSE_REPORT_SCHEMA = "nc-dialectic-parse-report-v0"
EVENT_STREAM_SCHEMA = "nc-dialectic-engineering-event-v0"
CAPTURE_DATE_PATTERN = re.compile(r"^dialectic-turns-(\d{4}-\d{2}-\d{2})\.jsonl$")
CONTENT_FIELDS = ("heard", "candidates", "spokenText", "witnessFinding")
FINGERPRINT_FIELDS = (
    "runtime",
    "transport",
    "provider",
    "model",
    "promptProfile",
    "interactionStyle",
    "promptHash",
)

DISPOSITION = {
    "corpus_role": "engineering_replay_only",
    "development_only_permanent": True,
    "eligible_for_encoder_training": False,
    "eligible_for_encoder_evaluation": False,
    "eligible_for_policy_training": False,
    "eligible_for_policy_evaluation": False,
    "contains_private_dialogue": True,
    "cloud_exposure_allowed": False,
}


class ParseFailure(ValueError):
    """A deterministic, reportable rejection reason for one JSONL line."""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _reject_nonfinite_json_constant(value: str) -> None:
    raise ParseFailure(f"non_finite_json_constant:{value}")


def load_strict_json_object(raw_line: bytes) -> dict[str, Any]:
    """Decode one JSONL row without accepting NaN/Infinity or non-objects."""
    try:
        text = raw_line.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ParseFailure("invalid_utf8") from error
    if not text.strip():
        raise ParseFailure("blank_line")
    try:
        value = json.loads(text, parse_constant=_reject_nonfinite_json_constant)
    except ParseFailure:
        raise
    except json.JSONDecodeError as error:
        raise ParseFailure("invalid_json") from error
    if not isinstance(value, dict):
        raise ParseFailure("record_must_be_object")
    return value


def _require(event: dict[str, Any], field: str, expected: type[Any]) -> None:
    value = event.get(field)
    if isinstance(value, bool) and expected is int:
        raise ParseFailure(f"schema_invalid:{field}")
    if not isinstance(value, expected):
        raise ParseFailure(f"schema_invalid:{field}")


def validate_turn_schema(event: dict[str, Any]) -> None:
    """Check only the stable core required for engineering replay."""
    _require(event, "index", int)
    _require(event, "heard", str)
    _require(event, "candidates", list)
    _require(event, "outcome", str)
    for field in ("tension", "margin", "selectionTemperature", "glossScalar"):
        value = event.get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
            raise ParseFailure(f"schema_invalid:{field}")
    for position, candidate in enumerate(event["candidates"]):
        if not isinstance(candidate, dict):
            raise ParseFailure(f"schema_invalid:candidates[{position}]")
        _require(candidate, "text", str)
        _require(candidate, "roleID", str)


def content_projection(event: dict[str, Any]) -> dict[str, Any]:
    """Collect the private fields whose digest represents this turn's content."""
    return {field: event.get(field) for field in CONTENT_FIELDS}


def content_metadata(event: dict[str, Any]) -> tuple[str, int]:
    encoded = json.dumps(
        content_projection(event),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return sha256_bytes(encoded), len(encoded)


def fingerprint_identity(event: dict[str, Any]) -> dict[str, str] | None:
    fingerprint = event.get("generatorFingerprint")
    if not isinstance(fingerprint, dict):
        return None
    return {
        field: str(fingerprint[field])
        for field in FINGERPRINT_FIELDS
        if isinstance(fingerprint.get(field), str) and fingerprint[field]
    }


def capture_date_from_filename(path: Path) -> str | None:
    match = CAPTURE_DATE_PATTERN.fullmatch(path.name)
    return match.group(1) if match else None


def _identity_key(identity: dict[str, str] | None) -> str:
    return json.dumps(identity or {"status": "not_recorded"}, sort_keys=True, separators=(",", ":"))


def inspect_corpus(
    source_path: Path,
    parse_report_path: Path,
    events_path: Path,
    *,
    candidate_eeg_session_id: str | None = None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Read a private JSONL file once and write metadata-only local derivatives."""
    source_bytes = source_path.read_bytes()
    source_sha256 = sha256_bytes(source_bytes)
    malformed: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []
    identity_counts: Counter[str] = Counter()
    turn_indexes: list[tuple[int, int]] = []
    total_lines = 0

    for source_line, raw_line in enumerate(source_bytes.splitlines(), start=1):
        total_lines += 1
        try:
            event = load_strict_json_object(raw_line)
            validate_turn_schema(event)
        except ParseFailure as error:
            malformed.append({"source_line": source_line, "reason": str(error)})
            continue

        content_sha256, content_length = content_metadata(event)
        identity = fingerprint_identity(event)
        identity_counts[_identity_key(identity)] += 1
        turn_indexes.append((source_line, event["index"]))
        events.append(
            {
                "schema_version": EVENT_STREAM_SCHEMA,
                "event_id": f"{source_sha256[:16]}:line:{source_line}",
                "source_line": source_line,
                "turn_index": event["index"],
                "timestamp_unix": None,
                "timestamp_status": "not_recorded_in_dialectical_turn_event",
                "speaker_role": "unspecified",
                "event_type": "dialogue_turn",
                "outcome": event["outcome"],
                "candidate_count": len(event["candidates"]),
                "generator_identity": identity,
                "content_sha256": content_sha256,
                "content_length_bytes": content_length,
                "parse_valid": True,
                "disposition": DISPOSITION,
            }
        )

    identities = [
        {"identity": json.loads(identity), "record_count": count}
        for identity, count in sorted(identity_counts.items())
    ]
    index_counts = Counter(index for _, index in turn_indexes)
    non_monotonic_transitions = [
        {
            "previous_source_line": previous_line,
            "previous_turn_index": previous_index,
            "source_line": source_line,
            "turn_index": index,
        }
        for (previous_line, previous_index), (source_line, index) in zip(turn_indexes, turn_indexes[1:])
        if index <= previous_index
    ]
    report = {
        "schema_version": PARSE_REPORT_SCHEMA,
        "parser_version": PARSER_VERSION,
        "source": {
            "file_name": source_path.name,
            "sha256": source_sha256,
            "size_bytes": len(source_bytes),
            "total_line_count": total_lines,
            "capture_date": capture_date_from_filename(source_path),
            "capture_date_provenance": "file_name" if capture_date_from_filename(source_path) else "not_recorded",
            "raw_file_mutated_by_tool": False,
        },
        "records": {
            "valid_record_count": len(events),
            "malformed_record_count": len(malformed),
            "malformed_records": malformed,
        },
        "backend_identities": identities,
        "ordering": {
            "source_line_order": "preserved",
            "turn_index_strictly_increasing": not non_monotonic_transitions,
            "duplicate_turn_indexes": sorted(index for index, count in index_counts.items() if count > 1),
            "non_monotonic_turn_index_transitions": non_monotonic_transitions,
            "timestamp_monotonicity": "not_applicable_not_recorded_in_dialectical_turn_event",
        },
        "fully_live_status": "not_recorded_in_dialectical_turn_event",
        "crosswalk": {
            "candidate_eeg_session_id": candidate_eeg_session_id,
            "alignment_status": "recorded_not_scientifically_enabled" if candidate_eeg_session_id else "not_recorded",
            "used_by_EXP_NC_EEG_ENC_001": False,
        },
        "disposition": DISPOSITION,
    }

    parse_report_path.parent.mkdir(parents=True, exist_ok=True)
    events_path.parent.mkdir(parents=True, exist_ok=True)
    parse_report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    events_path.write_text("".join(json.dumps(event, sort_keys=True) + "\n" for event in events))
    if sha256_bytes(source_path.read_bytes()) != source_sha256:
        raise RuntimeError("source file changed while producing quarantine artifacts")
    return report, events


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="private local dialectic-turns JSONL")
    parser.add_argument("--parse-report", required=True, type=Path, help="local metadata-only JSON report")
    parser.add_argument("--events-output", required=True, type=Path, help="local metadata-only JSONL stream")
    parser.add_argument("--candidate-eeg-session-id", help="recorded-only, never scientifically enabled crosswalk")
    args = parser.parse_args(argv)

    report, _ = inspect_corpus(
        args.input,
        args.parse_report,
        args.events_output,
        candidate_eeg_session_id=args.candidate_eeg_session_id,
    )
    print(
        f"wrote {args.parse_report} and {args.events_output} "
        f"({report['records']['valid_record_count']} valid, "
        f"{report['records']['malformed_record_count']} malformed; engineering replay only)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
