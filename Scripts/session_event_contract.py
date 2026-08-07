#!/usr/bin/env python3
"""Contract for `nc-eeg-session-event-v0` — structured references into a recording.

A session event does not carry signal. It carries a *reference*: the SHA-256 of
the `eeg.csv` it points into, plus a sample range. Anyone holding the recording
can re-derive the window and recompute what was observed; anyone without it
learns nothing. That is what makes the artifact model-agnostic — EEGNet, EEGPT,
a future encoder, or a plain spectral routine all consume the same reference.

**These are signal observations, not stage claims.** The Muse montage has no
chin EMG (`SLEEP_CYCLE_DESIGN.md` §291, risk R1), so nothing here may imply REM,
and no sleep stage is inferable from any field. Detection is gated behind the
§21 toolkit gate; intervention efficacy is gated behind the D8 pre-registration
(`Evaluation/reports/decision_registry.md` entry 8). This artifact is upstream of
both and asserts neither — the validator enforces that rather than documenting it.

Standard library only. The checker runs as a direct `python3` step, and the
system interpreter on a clean runner has no numpy.
"""

from __future__ import annotations

import re
from typing import Any

SESSION_EVENT_SCHEMA = "nc-eeg-session-event-v0"
SESSION_MANIFEST_SCHEMA = "nc-eeg-session-manifest-v0"

# The canonical Muse montage and rate, matching
# NeuralComposeEEG/configs/muse-four-channel-v0.json.
CHANNELS: tuple[str, ...] = ("TP9", "AF7", "AF8", "TP10")
SAMPLE_RATE_HZ = 256

EVENT_KINDS: frozenset[str] = frozenset({
    "zero_throughput",          # a gap in the sample clock
    "channel_health_change",    # per-channel RMS / clipping transition
    "band_excursion",           # band power departing an in-session baseline
    "artifact_burst",           # high-amplitude transient run
})

INTERPRETATION = "signal_observation_only"

# Field names that would smuggle an interpretation into an observation record.
# `stage`/`n1`/`rem` are stage claims; `intervention`/`efficacy` are outcome
# claims; `embedding`/`latent` would make the artifact model-specific and defeat
# the reason it stores a reference instead of a vector.
FORBIDDEN_SUBSTRINGS: tuple[str, ...] = (
    "stage", "n1", "rem", "sleep", "intervention", "efficacy",
    "embedding", "latent", "vector",
)
# `stage_claim` / `intervention_claim` are the two deliberate exceptions: they
# exist precisely to be pinned at null.
NULL_CLAIM_FIELDS: tuple[str, ...] = ("stage_claim", "intervention_claim")

_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ContractError(ValueError):
    """A session-event record that must not be written or consumed."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def _walk_keys(value: Any, path: str = "") -> list[str]:
    """Every key path in a nested record, so a forbidden name cannot hide."""
    found: list[str] = []
    if isinstance(value, dict):
        for key, sub in value.items():
            here = f"{path}.{key}" if path else str(key)
            found.append(here)
            found.extend(_walk_keys(sub, here))
    elif isinstance(value, list):
        for index, sub in enumerate(value):
            found.extend(_walk_keys(sub, f"{path}[{index}]"))
    return found


def validate_session_event(
    record: dict[str, Any],
    *,
    recording_sample_count: int | None = None,
) -> None:
    """Validate one event. Pass `recording_sample_count` to bound the range.

    Without it the range is checked for internal consistency only; a reference
    past the end of a recording is caught when the recording is available.
    """
    _require(isinstance(record, dict), "event must be a JSON object")
    _require(record.get("schema_version") == SESSION_EVENT_SCHEMA,
             f"schema_version must be {SESSION_EVENT_SCHEMA}")

    event_id = record.get("event_id")
    _require(isinstance(event_id, str) and event_id != "", "event_id must be a non-empty string")

    kind = record.get("kind")
    _require(kind in EVENT_KINDS,
             f"kind must be one of {sorted(EVENT_KINDS)}; got {kind!r}")

    _require(record.get("interpretation") == INTERPRETATION,
             f"interpretation must be {INTERPRETATION!r} — this artifact makes no "
             "stage or efficacy claim")

    for field in NULL_CLAIM_FIELDS:
        _require(field in record, f"{field} must be present and null")
        _require(record[field] is None,
                 f"{field} must be null; a session event may not assert one")

    # No forbidden name anywhere in the record, at any depth. The two
    # `*_claim` fields above are the sanctioned exceptions.
    for key_path in _walk_keys(record):
        leaf = key_path.split(".")[-1].split("[")[0].lower()
        if leaf in NULL_CLAIM_FIELDS:
            continue
        for banned in FORBIDDEN_SUBSTRINGS:
            _require(banned not in leaf,
                     f"field {key_path!r} contains {banned!r}: a session event records "
                     "what was measured, never what it might mean")

    source = record.get("source")
    _require(isinstance(source, dict), "source must be an object")

    digest = source.get("recording_sha256")
    _require(isinstance(digest, str) and _SHA256.match(digest) is not None,
             "source.recording_sha256 must be a lowercase SHA-256 hex digest")

    start = source.get("start_sample")
    count = source.get("sample_count")
    _require(isinstance(start, int) and not isinstance(start, bool) and start >= 0,
             "source.start_sample must be a non-negative integer")
    _require(isinstance(count, int) and not isinstance(count, bool) and count > 0,
             "source.sample_count must be a positive integer")

    if recording_sample_count is not None:
        _require(start + count <= recording_sample_count,
                 f"reference [{start}, {start + count}) exceeds the recording's "
                 f"{recording_sample_count} samples")

    _require(list(source.get("channel_order") or []) == list(CHANNELS),
             f"source.channel_order must be exactly {list(CHANNELS)}")
    _require(source.get("sample_rate_hz") == SAMPLE_RATE_HZ,
             f"source.sample_rate_hz must be {SAMPLE_RATE_HZ}")

    observed = record.get("observed")
    _require(isinstance(observed, dict) and observed != {},
             "observed must be a non-empty object")
    for key, value in observed.items():
        _require(isinstance(value, (int, float, str, bool)) or value is None,
                 f"observed.{key} must be a scalar — an event carries measurements, "
                 "not signal")

    baseline = record.get("baseline_ref")
    if baseline is not None:
        _require(isinstance(baseline, dict), "baseline_ref must be an object or null")
        b_start, b_count = baseline.get("start_sample"), baseline.get("sample_count")
        _require(isinstance(b_start, int) and b_start >= 0,
                 "baseline_ref.start_sample must be a non-negative integer")
        _require(isinstance(b_count, int) and b_count > 0,
                 "baseline_ref.sample_count must be a positive integer")


def validate_session_event_file(
    records: list[dict[str, Any]],
    *,
    recording_sample_count: int | None = None,
) -> None:
    """Validate a whole event log, including cross-record invariants."""
    for index, record in enumerate(records):
        try:
            validate_session_event(record, recording_sample_count=recording_sample_count)
        except ContractError as exc:
            raise ContractError(f"event {index}: {exc}") from exc

    digests = {r["source"]["recording_sha256"] for r in records}
    _require(len(digests) <= 1,
             f"an event log references {len(digests)} recordings; one log describes one recording")

    ids = [r["event_id"] for r in records]
    _require(len(ids) == len(set(ids)), "event_id values must be unique within a log")


# ── session manifest ────────────────────────────────────────────────────────

DETECTOR_STATUSES: frozenset[str] = frozenset({"eligible", "suppressed"})
SUPPRESSED_REASONS: frozenset[str] = frozenset({"channel_saturated", "channel_silent"})

# Dispositions that must be present and must be exactly these values. They are
# all negative on purpose: this artifact indexes a recording, and an index is
# not a dataset, not a label set, and not evidence.
REQUIRED_DISPOSITIONS: dict[str, Any] = {
    "contains_signal": False,
    "science_status": "pipeline_only",
    "label_status": "heuristic_observation",
    "live_control": False,
    "promotion_status": "not_eligible",
    "clean_session_gate_credited": False,
}


def validate_session_manifest(manifest: dict[str, Any]) -> None:
    """Validate the session manifest.

    The manifest exists so an *absent* event is interpretable. A channel whose
    baseline is already saturated cannot produce an `artifact_burst`, and on a
    real recording one did not — silence there means the detector was never
    eligible, not that the channel was clean. Encoding that distinction is the
    manifest's entire job, so a manifest that omits a channel is rejected.
    """
    _require(isinstance(manifest, dict), "manifest must be a JSON object")
    _require(manifest.get("schema_version") == SESSION_MANIFEST_SCHEMA,
             f"schema_version must be {SESSION_MANIFEST_SCHEMA}")

    digest = manifest.get("recording_sha256")
    _require(isinstance(digest, str) and _SHA256.match(digest) is not None,
             "recording_sha256 must be a lowercase SHA-256 hex digest")

    total = manifest.get("recording_sample_count")
    _require(isinstance(total, int) and not isinstance(total, bool) and total >= 0,
             "recording_sample_count must be a non-negative integer")

    _require(manifest.get("sample_interval_convention", "").startswith("half_open"),
             "sample_interval_convention must declare the half-open convention")

    channels = manifest.get("channels")
    _require(isinstance(channels, dict), "channels must be an object")
    for name in CHANNELS:
        _require(name in channels,
                 f"channels is missing {name}: every channel must state detector "
                 "eligibility, or an absent event is ambiguous")
        entry = channels[name]
        _require(isinstance(entry, dict), f"channels.{name} must be an object")
        status = entry.get("detector_status")
        _require(status in DETECTOR_STATUSES,
                 f"channels.{name}.detector_status must be one of {sorted(DETECTOR_STATUSES)}")
        reason = entry.get("suppressed_reason")
        if status == "suppressed":
            _require(reason in SUPPRESSED_REASONS,
                     f"channels.{name} is suppressed and must name a reason from "
                     f"{sorted(SUPPRESSED_REASONS)}")
        else:
            _require(reason is None,
                     f"channels.{name} is eligible; suppressed_reason must be null")

    for key, expected in REQUIRED_DISPOSITIONS.items():
        _require(key in manifest, f"manifest must state {key}")
        _require(manifest[key] == expected,
                 f"{key} must be {expected!r} — this artifact indexes a recording; "
                 "it is not a dataset, a label set, or evidence")
