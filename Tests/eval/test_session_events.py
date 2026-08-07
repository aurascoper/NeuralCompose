"""Tests for the session-event reference artifact (nc-eeg-session-event-v0).

Three properties matter, and each has its own group below.

  * **Contract** — an event may reference signal and report measurements, but may
    never carry a stage claim, an efficacy claim, or an embedding. The validator
    enforces the boundary rather than the documentation describing it.
  * **Determinism** — the same recording yields byte-identical output, and a
    one-sample edit changes the recording digest so every reference into it is
    invalidated rather than silently re-pointed.
  * **Replay** — given only `recording_sha256` and a sample range, the window is
    re-derivable and `observed` recomputes to equality. This is the property
    that makes the artifact model-agnostic; without it the reference is just a
    number and the log is unfalsifiable.

Standard library only, and the fixtures are synthesised here rather than read
from `Recordings/`: no `eeg.csv` is committed (only the golden report), so a
test depending on one would skip vacuously on a clean checkout.

pytest-style + __main__ runner, matching the rest of Tests/eval.
"""
import copy
import csv
import hashlib
import json
import math
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "Scripts"))

import extract_session_events as extractor  # noqa: E402
from session_event_contract import (  # noqa: E402
    CHANNELS, ContractError, REQUIRED_DISPOSITIONS, SAMPLE_RATE_HZ,
    SESSION_EVENT_SCHEMA, validate_session_event, validate_session_event_file,
    validate_session_manifest,
)

WINDOW = extractor.PARAMS["window_samples"]


# ── fixtures ────────────────────────────────────────────────────────────────

def _write_recording(directory: Path, *, samples: int = 12000,
                     gap_at: int | None = None, clip_channel: int | None = None,
                     clip_from: int | None = None) -> Path:
    """A deterministic synthetic recording. No randomness, no clock."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "eeg.csv"
    period = 1.0 / SAMPLE_RATE_HZ
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["t_seconds", *CHANNELS])
        t = 1_000_000.0
        for i in range(samples):
            if gap_at is not None and i == gap_at:
                t += period * 40          # a visible hole in the sample clock
            row = []
            for ch in range(len(CHANNELS)):
                # 10 Hz carrier, per-channel phase offset, ~20 µV amplitude.
                value = 20.0 * math.sin(2 * math.pi * 10.0 * i / SAMPLE_RATE_HZ + ch)
                if (clip_channel == ch and clip_from is not None and i >= clip_from):
                    value = 900.0 if (i % 2 == 0) else -900.0
                row.append(round(value, 6))
            writer.writerow([f"{t:.9f}", *row])
            t += period
    return path


def _valid_event() -> dict:
    return {
        "schema_version": SESSION_EVENT_SCHEMA,
        "event_id": "a" * 32,
        "kind": "channel_health_change",
        "source": {
            "recording_sha256": "b" * 64,
            "start_sample": 0,
            "sample_count": WINDOW,
            "channel_order": list(CHANNELS),
            "sample_rate_hz": SAMPLE_RATE_HZ,
        },
        "observed": {"channel": "TP9", "rms_microvolts": 21.5},
        "baseline_ref": {"start_sample": 0, "sample_count": WINDOW},
        "interpretation": "signal_observation_only",
        "stage_claim": None,
        "intervention_claim": None,
    }


def _rejects(record: dict, fragment: str) -> None:
    try:
        validate_session_event(record)
    except ContractError as exc:
        assert fragment in str(exc), f"expected {fragment!r} in: {exc}"
        return
    raise AssertionError(f"expected rejection mentioning {fragment!r}")


# ── contract ────────────────────────────────────────────────────────────────

def test_valid_event_is_accepted():
    validate_session_event(_valid_event())


def test_rejects_a_stage_claim():
    """The whole point. Detection is gated behind the §21 toolkit gate; an
    observation record may not pre-empt it."""
    e = _valid_event(); e["stage_claim"] = "N1"
    _rejects(e, "stage_claim must be null")


def test_rejects_an_intervention_claim():
    """Efficacy is gated behind the D8 pre-registration."""
    e = _valid_event(); e["intervention_claim"] = "cue_delivered"
    _rejects(e, "intervention_claim must be null")


def test_rejects_a_smuggled_stage_field_at_any_depth():
    e = _valid_event(); e["observed"]["sleep_stage_hint"] = "n2"
    _rejects(e, "never what it might mean")
    e = _valid_event(); e["source"]["rem_probability"] = 0.4
    _rejects(e, "never what it might mean")


def test_rejects_an_embedding():
    """A reference exists so the artifact survives a change of encoder. Storing
    a vector would bind it to one."""
    e = _valid_event(); e["observed"] = {"latent_vector": 1.0}
    _rejects(e, "never what it might mean")


def test_rejects_non_scalar_observed_value():
    """`observed` carries measurements, not signal."""
    e = _valid_event(); e["observed"]["samples"] = [1.0, 2.0, 3.0]
    _rejects(e, "must be a scalar")


def test_rejects_a_bad_recording_digest():
    for bad in ("", "not-a-digest", "B" * 64, "b" * 63):
        e = _valid_event(); e["source"]["recording_sha256"] = bad
        _rejects(e, "SHA-256 hex digest")


def test_rejects_a_range_past_the_end_of_the_recording():
    e = _valid_event()
    e["source"]["start_sample"] = 900
    e["source"]["sample_count"] = 200
    try:
        validate_session_event(e, recording_sample_count=1000)
    except ContractError as exc:
        assert "exceeds the recording" in str(exc)
        return
    raise AssertionError("a reference past the end must be rejected")


def test_rejects_a_foreign_montage():
    e = _valid_event(); e["source"]["channel_order"] = ["Fz", "Cz", "Pz", "Oz"]
    _rejects(e, "channel_order must be exactly")
    e = _valid_event(); e["source"]["sample_rate_hz"] = 128
    _rejects(e, "sample_rate_hz must be")


def test_rejects_a_reinterpreted_record():
    e = _valid_event(); e["interpretation"] = "sleep_onset_detected"
    _rejects(e, "interpretation must be")


def test_rejects_unknown_kind():
    e = _valid_event(); e["kind"] = "sleep_onset"
    _rejects(e, "kind must be one of")


def test_log_rejects_duplicate_ids_and_mixed_recordings():
    a, b = _valid_event(), _valid_event()
    try:
        validate_session_event_file([a, b])
    except ContractError as exc:
        assert "unique" in str(exc)
    else:
        raise AssertionError("duplicate event_id must be rejected")

    c = copy.deepcopy(_valid_event())
    c["event_id"] = "c" * 32
    c["source"]["recording_sha256"] = "d" * 64
    try:
        validate_session_event_file([_valid_event(), c])
    except ContractError as exc:
        assert "one log describes one recording" in str(exc)
        return
    raise AssertionError("a log spanning two recordings must be rejected")


# ── determinism ─────────────────────────────────────────────────────────────

def test_extraction_is_byte_identical_across_runs():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d, clip_channel=1, clip_from=9000, gap_at=5000)
        first = extractor.extract(d)
        second = extractor.extract(d)
        dump = lambda evs: "\n".join(
            json.dumps(e, sort_keys=True, separators=(",", ":")) for e in evs)
        assert dump(first) == dump(second)
        assert first, "the fixture should produce events"


def test_editing_one_sample_invalidates_every_reference():
    """The digest is the anchor: change the recording and the old references no
    longer resolve, rather than silently pointing at different signal."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        path = _write_recording(d, clip_channel=1, clip_from=9000)
        before = extractor.extract(d)
        digest_before = before[0]["source"]["recording_sha256"]

        rows = path.read_text().splitlines()
        head, first_row = rows[0], rows[1].split(",")
        first_row[1] = f"{float(first_row[1]) + 1.0:.6f}"
        rows[1] = ",".join(first_row)
        path.write_text("\n".join(rows) + "\n")

        after = extractor.extract(d)
        assert after[0]["source"]["recording_sha256"] != digest_before


def test_params_digest_travels_with_every_event():
    """Two logs are comparable only if the rules that produced them match."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d, clip_channel=1, clip_from=9000)
        events = extractor.extract(d)
        expected = extractor.params_digest()
        assert all(e["params_sha256"] == expected for e in events)


# ── replay ──────────────────────────────────────────────────────────────────

def test_observed_recomputes_from_the_reference_alone():
    """The load-bearing property: hold the recording, follow the reference,
    recompute the measurement, get the same number."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d, clip_channel=1, clip_from=9000)
        events = extractor.extract(d)
        health = [e for e in events if e["kind"] == "channel_health_change"]
        assert health, "the clipped channel should raise a health event"

        _, channels = extractor.read_eeg(d / "eeg.csv")
        for event in health[:5]:
            src = event["source"]
            index = list(CHANNELS).index(event["observed"]["channel"])
            window = channels[index][src["start_sample"]:
                                     src["start_sample"] + src["sample_count"]]
            assert round(extractor.rms(window), 6) == event["observed"]["rms_microvolts"]


def test_digest_in_the_event_matches_the_file_it_references():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        path = _write_recording(d, clip_channel=1, clip_from=9000)
        events = extractor.extract(d)
        on_disk = hashlib.sha256(path.read_bytes()).hexdigest()
        assert all(e["source"]["recording_sha256"] == on_disk for e in events)


def test_extractor_output_passes_its_own_contract():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d, clip_channel=1, clip_from=9000, gap_at=5000)
        events = extractor.extract(d)
        total = sum(1 for _ in (d / "eeg.csv").read_text().splitlines()) - 1
        validate_session_event_file(events, recording_sample_count=total)


def test_a_clean_recording_yields_no_health_or_burst_events():
    """A quiet fixture must stay quiet — otherwise the triggers are noise."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d)
        kinds = {e["kind"] for e in extractor.extract(d)}
        assert "channel_health_change" not in kinds
        assert "artifact_burst" not in kinds


def test_a_clock_gap_is_reported_as_zero_throughput():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d, gap_at=5000)
        gaps = [e for e in extractor.extract(d) if e["kind"] == "zero_throughput"]
        assert len(gaps) == 1
        assert gaps[0]["observed"]["missing_samples_estimate"] > 0


# ── detector eligibility ────────────────────────────────────────────────────

def test_a_saturated_channel_is_reported_suppressed_not_clean():
    """The blocker. A saturated channel cannot exceed 6x its own rail, so it
    produces no artifact_burst — which must not read as "clean". Silence and
    ineligibility are different observations."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d, clip_channel=1, clip_from=0)   # AF7 saturated throughout
        events, manifest = extractor.extract_with_manifest(d)

        af7 = manifest["channels"]["AF7"]
        assert af7["detector_status"] == "suppressed"
        assert af7["suppressed_reason"] == "channel_saturated"
        assert not [e for e in events
                    if e["kind"] == "artifact_burst" and e["observed"]["channel"] == "AF7"]

        for other in ("TP9", "AF8", "TP10"):
            assert manifest["channels"][other]["detector_status"] == "eligible"
            assert manifest["channels"][other]["suppressed_reason"] is None


def test_manifest_covers_every_channel():
    """A missing channel would make its silence ambiguous again."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d)
        _, manifest = extractor.extract_with_manifest(d)
        validate_session_manifest(manifest)
        assert set(manifest["channels"]) == set(CHANNELS)

        broken = copy.deepcopy(manifest)
        del broken["channels"]["AF7"]
        try:
            validate_session_manifest(broken)
        except ContractError as exc:
            assert "detector eligibility" in str(exc)
            return
        raise AssertionError("a manifest missing a channel must be rejected")


def test_manifest_dispositions_are_pinned_negative():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d)
        _, manifest = extractor.extract_with_manifest(d)
        for key, expected in REQUIRED_DISPOSITIONS.items():
            assert manifest[key] == expected, key
        for key in REQUIRED_DISPOSITIONS:
            flipped = copy.deepcopy(manifest)
            flipped[key] = True if manifest[key] is False else "promoted"
            try:
                validate_session_manifest(flipped)
            except ContractError:
                continue
            raise AssertionError(f"{key} must be pinned")


def test_manifest_declares_the_half_open_convention():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        _write_recording(d)
        _, manifest = extractor.extract_with_manifest(d)
        assert manifest["sample_interval_convention"].startswith("half_open")


# ── content addressing ──────────────────────────────────────────────────────

def test_same_bytes_at_a_different_path_give_identical_references():
    """Content-addressed means content-addressed: the location is not part of
    the identity."""
    with tempfile.TemporaryDirectory() as tmp:
        a, b = Path(tmp) / "one", Path(tmp) / "two" / "nested"
        _write_recording(a, clip_channel=1, clip_from=9000)
        b.mkdir(parents=True)
        (b / "eeg.csv").write_bytes((a / "eeg.csv").read_bytes())
        dump = lambda evs: "\n".join(
            json.dumps(e, sort_keys=True, separators=(",", ":")) for e in evs)
        assert dump(extractor.extract(a)) == dump(extractor.extract(b))


def test_params_digest_is_order_independent():
    """Canonical serialisation — otherwise the digest depends on dict order and
    two identical parameter sets could disagree."""
    original = extractor.PARAMS
    first = extractor.params_digest()
    try:
        extractor.PARAMS = dict(reversed(list(original.items())))
        assert extractor.params_digest() == first
    finally:
        extractor.PARAMS = original


# ── fail closed on malformed input ──────────────────────────────────────────

def _expect_exit(directory: Path, fragment: str) -> None:
    try:
        extractor.extract(directory)
    except SystemExit as exc:
        assert fragment in str(exc), f"expected {fragment!r} in: {exc}"
        return
    raise AssertionError(f"expected a failure mentioning {fragment!r}")


def test_non_finite_sample_fails_closed():
    """A NaN would otherwise propagate into a baseline median and move every
    threshold derived from it."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        path = _write_recording(d, samples=2000)
        rows = path.read_text().splitlines()
        cells = rows[500].split(","); cells[2] = "nan"
        rows[500] = ",".join(cells)
        path.write_text("\n".join(rows) + "\n")
        _expect_exit(d, "non-finite")


def test_unparseable_row_fails_closed():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        path = _write_recording(d, samples=2000)
        rows = path.read_text().splitlines()
        cells = rows[500].split(","); cells[1] = "n/a"
        rows[500] = ",".join(cells)
        path.write_text("\n".join(rows) + "\n")
        _expect_exit(d, "unparseable row")


def test_sample_rate_disagreement_fails_closed():
    """A 128 Hz file indexed under the 256 Hz contract points every event at the
    wrong seconds."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        path = _write_recording(d, samples=2000)
        rows = path.read_text().splitlines()
        out = [rows[0]]
        t = 1_000_000.0
        for row in rows[1:]:
            cells = row.split(",")
            out.append(",".join([f"{t:.9f}", *cells[1:]]))
            t += 1.0 / 128.0
        path.write_text("\n".join(out) + "\n")
        _expect_exit(d, "disagrees with the")


def test_missing_channel_column_fails_closed():
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "rec"
        path = _write_recording(d, samples=1200)
        rows = path.read_text().splitlines()
        rows[0] = "t_seconds,TP9,AF7,AF8"
        path.write_text("\n".join(rows) + "\n")
        _expect_exit(d, "missing channel column")


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok   {name}")
            except Exception as exc:  # noqa: BLE001 - a test runner reports, not raises
                failures += 1
                print(f"  FAIL {name}: {type(exc).__name__}: {exc}")
    total = sum(1 for n, f in globals().items() if n.startswith("test_") and callable(f))
    print(f"\n{total - failures}/{total} passed")
    raise SystemExit(1 if failures else 0)
