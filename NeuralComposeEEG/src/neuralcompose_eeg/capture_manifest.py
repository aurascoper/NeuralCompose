"""Compile a complete observable-protocol capture into a local source manifest.

The app continues to own recording. This offline tool joins the app's immutable
recording metadata with the separately logged protocol cues, then refuses a
session that cannot prove the expected timing, montage, or transport state.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from collections.abc import Callable
from typing import Any

from .contracts import CHANNELS, ContractError
from .provenance import sha256_file, sha256_json


CAPTURE_INDEX_SCHEMA = "nc-eeg-capture-index-v1"
OBSERVABLE_PROTOCOL_SCHEMA = "nc-eeg-observable-protocol-v1"
OBSERVABLE_PROTOCOL_ID = "encoder-pilot-v1"
PROTOCOL_SPEC_PATH = Path(__file__).resolve().parents[2] / "configs" / "observable-protocol-v1.json"
OBSERVABLE_CUE_SEQUENCE = (
    "eyes_open",
    "eyes_closed",
    "blink_artifact",
    "jaw_artifact",
)
MOTION_CUES = frozenset({"head_motion_artifact", "poor_contact_artifact", "head_motion_or_poor_contact_artifact"})
FOLLOWING_CUES = ("listening", "speaking", "recovery")
EXPECTED_DEVICE_PROFILE = "muse_s_native_ble"


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{path} must contain a JSON object")
    return value


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def _protocol_spec() -> dict[str, Any]:
    specification = _load_json(PROTOCOL_SPEC_PATH)
    if specification.get("schema_version") != "nc-eeg-observable-protocol-spec-v1":
        raise ContractError("observable protocol specification has the wrong schema")
    if specification.get("protocol_id") != OBSERVABLE_PROTOCOL_ID:
        raise ContractError("observable protocol specification has the wrong protocol id")
    if not isinstance(specification.get("segments"), list) or not specification["segments"]:
        raise ContractError("observable protocol specification needs segments")
    if not isinstance(specification.get("transition_gap_seconds"), (int, float)):
        raise ContractError("observable protocol specification needs a transition gap")
    return specification


def _recording_bounds(path: Path) -> tuple[float, float, tuple[str, ...]]:
    try:
        with path.open(newline="") as handle:
            reader = csv.DictReader(handle)
            fields = tuple(reader.fieldnames or ())
            if fields != ("t_seconds", *CHANNELS):
                raise ContractError(f"{path}: expected t_seconds plus {list(CHANNELS)}")
            first: float | None = None
            last: float | None = None
            for row in reader:
                timestamp = float(row["t_seconds"])
                if not math.isfinite(timestamp):
                    raise ContractError(f"{path}: EEG timestamps must be finite")
                for channel in CHANNELS:
                    if not math.isfinite(float(row[channel])):
                        raise ContractError(f"{path}: missing or non-finite {channel} sample")
                if first is None:
                    first = timestamp
                if last is not None and timestamp <= last:
                    raise ContractError(f"{path}: EEG timestamps must be strictly increasing")
                last = timestamp
    except (OSError, ValueError) as exc:
        raise ContractError(f"cannot read EEG timestamps from {path}: {exc}") from exc
    if first is None or last is None or last <= first:
        raise ContractError(f"{path}: recording has no usable timestamp span")
    return first, last, fields


def _protocol_blocks(
    protocol: dict[str, Any],
    *,
    recording_start: float,
    recording_end: float,
    protocol_to_sample_time: Callable[[float], float],
    protocol_sha256: str,
) -> list[dict[str, Any]]:
    specification = _protocol_spec()
    if protocol.get("dry_run") is True:
        raise ContractError("protocol log was a dry run")
    if protocol.get("schema_version") != OBSERVABLE_PROTOCOL_SCHEMA:
        raise ContractError(f"protocol must use schema_version={OBSERVABLE_PROTOCOL_SCHEMA}")
    if protocol.get("protocol_id") != OBSERVABLE_PROTOCOL_ID:
        raise ContractError(f"protocol must declare protocol_id={OBSERVABLE_PROTOCOL_ID}")
    if protocol.get("protocol_preset") != OBSERVABLE_PROTOCOL_ID:
        raise ContractError(f"protocol must declare protocol_preset={OBSERVABLE_PROTOCOL_ID}")
    if protocol.get("protocol_preset_sha256") != sha256_file(PROTOCOL_SPEC_PATH):
        raise ContractError("protocol does not use the pinned observable-preset revision")
    if protocol.get("protocol_cue_clock") != specification.get("protocol_cue_clock"):
        raise ContractError("protocol cue clock must be Unix wall time")
    if protocol.get("tag_blinks") != specification.get("tag_blinks"):
        raise ContractError("protocol tag-blink count differs from the pinned preset")
    if not math.isclose(float(protocol.get("tag_window_s", -1)), float(specification["transition_gap_seconds"])):
        raise ContractError("protocol transition gap differs from the pinned preset")
    if protocol.get("transition_gap_seconds") != specification["transition_gap_seconds"]:
        raise ContractError("protocol did not record the pinned transition gap")
    speaking = specification.get("speaking_script")
    if not isinstance(speaking, dict):
        raise ContractError("observable protocol specification lacks its speaking script")
    speaking_path = PROTOCOL_SPEC_PATH.parent / str(speaking.get("relative_path", ""))
    if protocol.get("speaking_script_id") != speaking.get("id") or protocol.get("speaking_script_sha256") != sha256_file(speaking_path):
        raise ContractError("protocol speaking script does not match the pinned revision")
    if not isinstance(protocol.get("listening_audio_id"), str) or not protocol["listening_audio_id"]:
        raise ContractError("protocol lacks a listening audio identifier")
    if not _is_sha256(protocol.get("listening_audio_sha256")):
        raise ContractError("protocol lacks a valid listening audio checksum")
    if protocol.get("completed") is not True:
        raise ContractError("protocol did not complete every observable block")
    segments = protocol.get("segments")
    if not isinstance(segments, list) or not segments:
        raise ContractError("protocol log has no segments")
    labels: list[str] = []
    starts: list[float] = []
    ends: list[float] = []
    expected_segments = specification["segments"]
    if len(segments) != len(expected_segments):
        raise ContractError("protocol has a different block count from the pinned preset")
    for index, (segment, expected) in enumerate(zip(segments, expected_segments, strict=True)):
        if not isinstance(segment, dict) or not isinstance(segment.get("label"), str):
            raise ContractError(f"protocol segment {index} is malformed")
        try:
            cue = float(segment["cue_unix"])
            start = float(segment["start_unix"])
            end = float(segment["end_unix"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ContractError(f"protocol segment {index} lacks explicit Unix cue/start/end timestamps") from exc
        if segment.get("completion") != "completed":
            raise ContractError(f"protocol segment {index} was not completed")
        if segment.get("label") != expected.get("label"):
            raise ContractError(f"protocol segment {index} label differs from the pinned preset")
        if segment.get("planned_duration_s") != expected.get("duration_seconds"):
            raise ContractError(f"protocol segment {index} duration differs from the pinned preset")
        if segment.get("instruction") != expected.get("instruction"):
            raise ContractError(f"protocol segment {index} instruction differs from the pinned preset")
        if not all(math.isfinite(value) for value in (cue, start, end)) or cue > start:
            raise ContractError(f"protocol segment {index} has invalid Unix clock values")
        if end <= start:
            raise ContractError(f"protocol segment {index} has a nonpositive duration")
        try:
            actual_duration = float(segment["actual_duration_s"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ContractError(f"protocol segment {index} lacks actual_duration_s") from exc
        tolerance = float(specification.get("duration_tolerance_seconds", 0))
        if not math.isclose(actual_duration, end - start, rel_tol=0.0, abs_tol=0.001):
            raise ContractError(f"protocol segment {index} actual duration does not match its timestamps")
        if abs(actual_duration - float(expected["duration_seconds"])) > tolerance:
            raise ContractError(f"protocol segment {index} actual duration exceeds the pinned tolerance")
        labels.append(segment["label"])
        starts.append(protocol_to_sample_time(start))
        ends.append(protocol_to_sample_time(end))
    if tuple(labels[: len(OBSERVABLE_CUE_SEQUENCE)]) != OBSERVABLE_CUE_SEQUENCE:
        raise ContractError(f"protocol must begin with {list(OBSERVABLE_CUE_SEQUENCE)}")
    motion_index = len(OBSERVABLE_CUE_SEQUENCE)
    if len(labels) != motion_index + 1 + len(FOLLOWING_CUES) or labels[motion_index] not in MOTION_CUES:
        raise ContractError("protocol needs exactly one head-motion or poor-contact artifact block")
    if tuple(labels[motion_index + 1 :]) != FOLLOWING_CUES:
        raise ContractError(f"protocol must end with {list(FOLLOWING_CUES)}")
    if any(next_start <= start for start, next_start in zip(starts, starts[1:])):
        raise ContractError("protocol start times must be strictly increasing")
    if any(end > next_start for end, next_start in zip(ends, starts[1:])):
        raise ContractError("protocol blocks overlap")
    minimum_gap = float(specification["transition_gap_seconds"])
    if any(next_start - end < minimum_gap - 0.001 for end, next_start in zip(ends, starts[1:])):
        raise ContractError("protocol blocks do not retain the pinned unlabeled transition gap")
    if starts[0] < recording_start or ends[-1] > recording_end:
        raise ContractError("protocol does not fit inside the EEG recording bounds")

    blocks: list[dict[str, Any]] = []
    for index, (label, start, end) in enumerate(zip(labels, starts, ends, strict=True)):
        if end - start < 4.0:
            raise ContractError(f"protocol block {label} is shorter than one canonical window")
        blocks.append(
            {
                "label": label,
                "start_seconds": start - recording_start,
                "end_seconds": end - recording_start,
                "role": "calibration" if index == 0 else "task",
                "label_provenance": f"protocol-log-sha256:{protocol_sha256}",
            }
        )
    return blocks


def _protocol_clock_mapper(metadata: dict[str, Any], recording_start: float) -> Callable[[float], float]:
    """Map Unix protocol cues into the exact coordinate stored in `eeg.csv`."""
    clock = metadata.get("eeg_timestamp_clock")
    try:
        first_sample = float(metadata["first_sample_timestamp"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ContractError("recorder metadata requires first_sample_timestamp") from exc
    try:
        first_wall_clock = float(metadata["first_sample_wallclock_unix"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ContractError("recorder metadata requires a first-sample wall-clock anchor") from exc
    if not math.isfinite(first_sample) or not math.isfinite(first_wall_clock):
        raise ContractError("recorder first-sample clock provenance must be finite")
    if not math.isclose(first_sample, recording_start, rel_tol=0.0, abs_tol=1e-6):
        raise ContractError("recorder first-sample timestamp does not match eeg.csv")
    if clock == "unix_epoch":
        return lambda unix_seconds: unix_seconds
    if clock == "stream_relative":
        stream_zero_wall_clock = first_wall_clock - first_sample
        return lambda unix_seconds: unix_seconds - stream_zero_wall_clock
    raise ContractError("recorder metadata must declare eeg_timestamp_clock as unix_epoch or stream_relative")


def _recording_start_unix(metadata: dict[str, Any], recording_start: float) -> float:
    clock = metadata.get("eeg_timestamp_clock")
    if clock == "unix_epoch":
        return recording_start
    if clock == "stream_relative":
        try:
            first_sample = float(metadata["first_sample_timestamp"])
            first_wall_clock = float(metadata["first_sample_wallclock_unix"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ContractError("stream-relative EEG requires a first-sample wall-clock anchor") from exc
        return first_wall_clock + (recording_start - first_sample)
    raise ContractError("recorder metadata must declare eeg_timestamp_clock as unix_epoch or stream_relative")


def compile_capture_manifest(index_path: Path, output_path: Path) -> dict[str, Any]:
    """Create an ignored source manifest from reviewed local capture paths."""
    index = _load_json(index_path)
    if index.get("schema_version") != CAPTURE_INDEX_SCHEMA:
        raise ContractError(f"expected schema_version={CAPTURE_INDEX_SCHEMA}")
    if not isinstance(index.get("dataset_id"), str) or not index["dataset_id"]:
        raise ContractError("capture index requires dataset_id")
    sessions = index.get("sessions")
    if not isinstance(sessions, list) or len(sessions) < 2:
        raise ContractError("capture index needs at least two sessions")
    session_ids: set[str] = set()
    compiled_sessions: list[dict[str, Any]] = []
    excluded_sessions: list[dict[str, str]] = []
    output_parent = output_path.parent.resolve()
    for position, entry in enumerate(sessions):
        if not isinstance(entry, dict):
            raise ContractError(f"sessions[{position}] must be an object")
        for field in (
            "session_id", "recording_date", "recording_directory", "protocol_log", "participant_id",
            "device_profile", "headset_fit_id", "protocol_preset",
        ):
            if not isinstance(entry.get(field), str) or not entry[field]:
                raise ContractError(f"sessions[{position}] requires {field}")
        if not isinstance(entry.get("operator_notes"), str):
            raise ContractError(f"sessions[{position}] requires string operator_notes")
        if entry.get("protocol_preset") != OBSERVABLE_PROTOCOL_ID:
            raise ContractError(f"sessions[{position}] must declare protocol_preset={OBSERVABLE_PROTOCOL_ID}")
        if entry.get("device_profile") != EXPECTED_DEVICE_PROFILE:
            raise ContractError(f"sessions[{position}] must declare device_profile={EXPECTED_DEVICE_PROFILE}")
        if not isinstance(entry.get("eligible_override"), bool):
            raise ContractError(f"sessions[{position}] requires boolean eligible_override")
        if entry["eligible_override"]:
            excluded_sessions.append({"session_id": entry["session_id"], "reason": "operator_forced_exclusion"})
            continue
        recording_dir = (index_path.parent / entry["recording_directory"]).resolve()
        protocol_path = (index_path.parent / entry["protocol_log"]).resolve()
        eeg_path = recording_dir / "eeg.csv"
        metadata_path = recording_dir / "metadata.json"
        if not eeg_path.is_file() or not metadata_path.is_file() or not protocol_path.is_file():
            raise ContractError(f"sessions[{position}] must contain eeg.csv, metadata.json, and a protocol log")
        metadata = _load_json(metadata_path)
        session_id = metadata.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            raise ContractError(f"{recording_dir}: recorder metadata lacks session_id")
        if session_id != entry["session_id"]:
            raise ContractError(f"{recording_dir}: capture index session_id does not match recorder metadata")
        if session_id in session_ids:
            raise ContractError(f"duplicate recorder session_id {session_id}")
        session_ids.add(session_id)
        try:
            sample_rate = float(metadata["sample_rate"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ContractError(f"{session_id}: recorder metadata lacks a known sample rate") from exc
        if metadata.get("profile") != "muses" or metadata.get("device_profile") != EXPECTED_DEVICE_PROFILE or sample_rate != 256.0:
            raise ContractError(f"{session_id}: only a 256 Hz live Muse recording is eligible")
        if metadata.get("transport_degraded") is not False or metadata.get("transport_event_count") != 0:
            raise ContractError(f"{session_id}: transport-stalled, reconnected, or fallback recordings are not eligible")
        recording_start, recording_end, _ = _recording_bounds(eeg_path)
        mapper = _protocol_clock_mapper(metadata, recording_start)
        recording_start_unix = _recording_start_unix(metadata, recording_start)
        recording_date = datetime.fromtimestamp(recording_start_unix, timezone.utc).date().isoformat()
        if entry["recording_date"] != recording_date:
            raise ContractError(f"{session_id}: capture index recording_date does not match recorder clock")
        protocol_sha = sha256_file(protocol_path)
        protocol = _load_json(protocol_path)
        blocks = _protocol_blocks(
            protocol,
            recording_start=recording_start,
            recording_end=recording_end,
            protocol_to_sample_time=mapper,
            protocol_sha256=protocol_sha,
        )
        compiled_sessions.append(
            {
                "session_id": session_id,
                "participant_id": entry["participant_id"],
                "recording_date": recording_date,
                # The operator-facing v1 index intentionally records only the
                # reviewed hardware profile. The source-manifest grouping key
                # is derived from that immutable recorder fact, not operator
                # recollection of a device identifier.
                "device_id": metadata["device_profile"],
                "headset_fit_id": entry["headset_fit_id"],
                "eeg_csv": os.path.relpath(eeg_path, output_parent),
                "sample_rate_hz": 256,
                "channel_order": list(CHANNELS),
                "task_blocks": blocks,
                "capture_provenance": {
                    "recording_metadata_sha256": sha256_file(metadata_path),
                    "protocol_log_sha256": protocol_sha,
                    "recording_start_sample_timestamp": recording_start,
                    "recording_end_sample_timestamp": recording_end,
                    "recording_start_unix": recording_start_unix,
                    "recording_end_unix": recording_start_unix + (recording_end - recording_start),
                    "eeg_timestamp_clock": metadata["eeg_timestamp_clock"],
                    "device_profile": metadata["device_profile"],
                    "protocol_schema_version": OBSERVABLE_PROTOCOL_SCHEMA,
                    "protocol_id": OBSERVABLE_PROTOCOL_ID,
                    "protocol_preset_sha256": protocol["protocol_preset_sha256"],
                    "listening_audio_id": protocol["listening_audio_id"],
                    "listening_audio_sha256": protocol["listening_audio_sha256"],
                    "speaking_script_id": protocol["speaking_script_id"],
                    "speaking_script_sha256": protocol["speaking_script_sha256"],
                },
            }
        )
    if len(compiled_sessions) < 2:
        raise ContractError("capture index needs at least two non-excluded eligible sessions")
    stimulus_identity = {
        key: compiled_sessions[0]["capture_provenance"][key]
        for key in (
            "protocol_preset_sha256", "listening_audio_id", "listening_audio_sha256",
            "speaking_script_id", "speaking_script_sha256",
        )
    }
    for session in compiled_sessions[1:]:
        if any(session["capture_provenance"][key] != value for key, value in stimulus_identity.items()):
            raise ContractError("eligible sessions do not share the pinned protocol and stimulus identity")
    label_order = list(dict.fromkeys(block["label"] for session in compiled_sessions for block in session["task_blocks"]))
    capture_identity = {
        "dataset_id": index["dataset_id"],
        "sessions": [
            {
                "session_id": session["session_id"],
                "participant_id": session["participant_id"],
                "recording_date": session["recording_date"],
                "device_id": session["device_id"],
                "headset_fit_id": session["headset_fit_id"],
                "capture_provenance": session["capture_provenance"],
            }
            for session in compiled_sessions
        ],
    }
    manifest = {
        "schema_version": "nc-eeg-source-manifest-v0",
        "dataset_id": index["dataset_id"],
        "label_order": label_order,
        "sessions": compiled_sessions,
        "capture_index_sha256": sha256_json(capture_identity),
        "excluded_capture_index_entries": excluded_sessions,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-index", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    manifest = compile_capture_manifest(args.capture_index, args.output)
    print(f"wrote {args.output} ({len(manifest['sessions'])} complete live-Muse sessions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
