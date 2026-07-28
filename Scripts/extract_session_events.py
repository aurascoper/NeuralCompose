#!/usr/bin/env python3
"""Extract structured session events from a recording, offline and deterministically.

    python3 Scripts/extract_session_events.py <recording-dir> [--out events.jsonl]
    python3 Scripts/extract_session_events.py <recording-dir> --stdout

Reads `<recording-dir>/eeg.csv` and emits one `nc-eeg-session-event-v0` record per
observation. **No signal is copied.** Each event carries the SHA-256 of the
`eeg.csv` it points into plus a sample range, so the window is re-derivable by
anyone holding the recording and meaningless to anyone who is not.

Determinism is a contract, not an aspiration: the same file yields byte-identical
output. Nothing consults the clock, the filesystem order, or a random seed, and
every threshold is pinned in `PARAMS` and echoed into each record so a later
reader can tell which rules produced it.

**Observations only.** No stage is inferred, no intervention is implied. See
`Scripts/session_event_contract.py` for the boundary the validator enforces.

Standard library only — the system interpreter on a clean runner has no numpy.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any, Iterator

sys.path.insert(0, str(Path(__file__).resolve().parent))
from session_event_contract import (  # noqa: E402
    CHANNELS, EVENT_KINDS, INTERPRETATION, SAMPLE_RATE_HZ,
    SESSION_EVENT_SCHEMA, SESSION_MANIFEST_SCHEMA,
    validate_session_event_file, validate_session_manifest,
)

# Pinned analysis parameters. Changing any of these changes the events, so the
# set is hashed into every record's `params_sha256`: two logs are comparable
# only if that digest matches.
PARAMS: dict[str, Any] = {
    "window_samples": 1024,          # 4 s at 256 Hz — the canonical window
    "stride_samples": 256,           # 1 s hop
    "baseline_windows": 30,          # first 30 windows form the in-session baseline
    "gap_factor": 1.5,               # sample-clock gap > 1.5 × nominal ⇒ throughput event
    "clip_microvolts": 800.0,        # |x| at or above this counts as clipped
    "clip_fraction_trigger": 0.10,   # ≥10 % clipped samples in a window
    "rms_ratio_trigger": 3.0,        # per-channel RMS ≥ 3 × its baseline median
    "band_ratio_trigger": 2.5,       # band power ≥ 2.5 × its baseline median
    "burst_sigma": 6.0,              # |x| ≥ 6 × baseline RMS ⇒ burst sample
    "burst_min_samples": 8,          # ≥8 such samples in a window ⇒ artifact_burst
    "bands": {"theta": [4.0, 8.0], "alpha": [8.0, 13.0], "beta": [13.0, 30.0]},
}


def params_digest() -> str:
    return hashlib.sha256(
        json.dumps(PARAMS, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_eeg(path: Path) -> tuple[list[float], list[list[float]]]:
    """Return (timestamps, per-channel sample lists) in canonical channel order."""
    times: list[float] = []
    channels: list[list[float]] = [[] for _ in CHANNELS]
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        missing = [c for c in CHANNELS if c not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit(f"{path} is missing channel column(s): {missing}")
        for line_no, row in enumerate(reader, start=2):
            # Fail closed. A row with a missing cell, a non-numeric value, or a
            # NaN/inf would otherwise propagate into a baseline median and
            # silently move every threshold derived from it.
            try:
                t = float(row["t_seconds"])
                values = [float(row[name]) for name in CHANNELS]
            except (TypeError, ValueError) as exc:
                raise SystemExit(f"{path}:{line_no}: unparseable row ({exc})") from exc
            if not math.isfinite(t) or any(not math.isfinite(v) for v in values):
                raise SystemExit(f"{path}:{line_no}: non-finite value")
            if len(row) < len(CHANNELS) + 1:
                raise SystemExit(f"{path}:{line_no}: expected {len(CHANNELS)} channels")
            times.append(t)
            for index, value in enumerate(values):
                channels[index].append(value)
    if len(times) >= 2:
        # The recording must agree with the montage contract it will be
        # referenced under; a 128 Hz file indexed as 256 Hz points at the wrong
        # seconds for every event in the log.
        span = times[-1] - times[0]
        if span > 0:
            observed_rate = (len(times) - 1) / span
            if abs(observed_rate - SAMPLE_RATE_HZ) / SAMPLE_RATE_HZ > 0.05:
                raise SystemExit(
                    f"{path}: sample rate ~{observed_rate:.1f} Hz disagrees with the "
                    f"{SAMPLE_RATE_HZ} Hz contract by more than 5%")
    return times, channels


def goertzel_power(samples: list[float], low_hz: float, high_hz: float) -> float:
    """Summed power in [low, high) via Goertzel over the integer bins.

    Goertzel rather than a full transform because this is stdlib-only: it costs
    O(n) per bin and the bands here need a few dozen bins, where a hand-rolled
    DFT would be O(n²) per window and far too slow to run over a night.

    Demeaned *and* Hann-windowed before transforming. Both matter for the same
    reason the burst detector is per-channel: a DC offset or a rectangular
    window's spectral leakage lets a large-amplitude channel bleed energy across
    every bin, which would reintroduce the electrode-baseline problem in the
    frequency domain. The Hann coherent-gain factor is divided back out so the
    power stays comparable to an unwindowed estimate.
    """
    n = len(samples)
    if n == 0:
        return 0.0
    mean = sum(samples) / n
    window = [0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1)) for i in range(n)]
    centred = [(s - mean) * w for s, w in zip(samples, window)]
    coherent_gain = sum(window) / n          # 0.5 for Hann
    resolution = SAMPLE_RATE_HZ / n
    first = max(1, int(math.ceil(low_hz / resolution)))
    last = int(math.floor((high_hz - 1e-9) / resolution))
    total = 0.0
    for k in range(first, last + 1):
        omega = 2.0 * math.pi * k / n
        coeff = 2.0 * math.cos(omega)
        s1 = s2 = 0.0
        for value in centred:
            s0 = value + coeff * s1 - s2
            s2, s1 = s1, s0
        total += s1 * s1 + s2 * s2 - coeff * s1 * s2
    return total / (n * n * coherent_gain * coherent_gain)


def rms(samples: list[float]) -> float:
    if not samples:
        return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples))


def median(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def windows(total: int) -> Iterator[tuple[int, int]]:
    size, stride = PARAMS["window_samples"], PARAMS["stride_samples"]
    start = 0
    while start + size <= total:
        yield start, size
        start += stride


def make_event(
    kind: str, digest: str, start: int, count: int,
    observed: dict[str, Any], baseline: tuple[int, int] | None,
) -> dict[str, Any]:
    # The id is derived from content, so re-running produces the same ids and a
    # diff shows only real changes.
    # Everything that changes the meaning of the record, and nothing that does
    # not: schema, recording, kind, range, parameters, and the observation
    # itself. Deliberately no filesystem path — the same bytes under a different
    # name must produce the same reference, or the artifact is not
    # content-addressed.
    seed = ":".join((
        SESSION_EVENT_SCHEMA, digest, kind, str(start), str(count),
        params_digest(), json.dumps(observed, sort_keys=True, separators=(",", ":")),
    ))
    return {
        "schema_version": SESSION_EVENT_SCHEMA,
        "event_id": hashlib.sha256(seed.encode("utf-8")).hexdigest()[:32],
        "kind": kind,
        "source": {
            "recording_sha256": digest,
            "start_sample": start,
            "sample_count": count,
            "channel_order": list(CHANNELS),
            "sample_rate_hz": SAMPLE_RATE_HZ,
        },
        "observed": observed,
        "baseline_ref": (
            None if baseline is None
            else {"start_sample": baseline[0], "sample_count": baseline[1]}
        ),
        "params_sha256": params_digest(),
        "interpretation": INTERPRETATION,
        "stage_claim": None,
        "intervention_claim": None,
    }


def extract(recording_dir: Path) -> list[dict[str, Any]]:
    """Events only. Use `extract_with_manifest` when eligibility matters."""
    eeg_path = recording_dir / "eeg.csv"
    if not eeg_path.is_file():
        raise SystemExit(f"no eeg.csv in {recording_dir}")
    digest = file_sha256(eeg_path)
    times, channels = read_eeg(eeg_path)
    total = len(times)
    events: list[dict[str, Any]] = []

    # 1 · throughput gaps in the sample clock. This is the watchdog's own
    # condition (HealthSnapshot's `eeg-zero-throughput`) recorded as a
    # referenceable span rather than only raised as a live flag.
    nominal = 1.0 / SAMPLE_RATE_HZ
    for index in range(1, total):
        delta = times[index] - times[index - 1]
        if delta > nominal * PARAMS["gap_factor"]:
            events.append(make_event(
                "zero_throughput", digest, index - 1, 2,
                {"gap_seconds": round(delta, 6),
                 "expected_seconds": round(nominal, 6),
                 "missing_samples_estimate": int(round(delta / nominal)) - 1},
                None))

    if total < PARAMS["window_samples"]:
        return events

    window_list = list(windows(total))
    baseline_count = min(PARAMS["baseline_windows"], len(window_list))
    baseline_span = (window_list[0][0],
                     window_list[baseline_count - 1][0] + PARAMS["window_samples"]
                     - window_list[0][0])

    # Per-channel and per-band baselines: the median over the opening windows of
    # this same session. In-session by construction — a cross-session baseline
    # would silently import another night's headset fit.
    per_channel_rms: list[list[float]] = [[] for _ in CHANNELS]
    per_band: dict[str, list[float]] = {b: [] for b in PARAMS["bands"]}
    for start, size in window_list[:baseline_count]:
        for ch_index, samples in enumerate(channels):
            per_channel_rms[ch_index].append(rms(samples[start:start + size]))
        merged = [sum(c[start + i] for c in channels) / len(channels) for i in range(size)]
        for band, (low, high) in PARAMS["bands"].items():
            per_band[band].append(goertzel_power(merged, low, high))

    rms_baseline = [median(v) for v in per_channel_rms]
    band_baseline = {b: median(v) for b, v in per_band.items()}

    # Detector eligibility, per channel.
    #
    # The burst detector compares a channel against its *own* baseline. When
    # that baseline is itself pathological — a saturated electrode — the
    # comparison is vacuous: nothing can exceed 6x a rail. On a real recording
    # this produced zero artifact_burst records for a visibly broken AF7, and
    # an absent record is ambiguous. It could mean clean, or no transient, or
    # a detector that was never eligible to fire. Those must not be the same
    # observation, so eligibility is stated rather than inferred from silence.
    eligibility: dict[str, dict[str, Any]] = {}
    for ch_index, name in enumerate(CHANNELS):
        base = rms_baseline[ch_index]
        baseline_samples = channels[ch_index][baseline_span[0]:
                                              baseline_span[0] + baseline_span[1]]
        clipped = sum(1 for s in baseline_samples if abs(s) >= PARAMS["clip_microvolts"])
        clipped_fraction = clipped / len(baseline_samples) if baseline_samples else 0.0
        if base <= 0:
            status, reason = "suppressed", "channel_silent"
        elif base >= PARAMS["clip_microvolts"] or clipped_fraction >= PARAMS["clip_fraction_trigger"]:
            status, reason = "suppressed", "channel_saturated"
        else:
            status, reason = "eligible", None
        eligibility[name] = {
            "detector_status": status,
            "suppressed_reason": reason,
            "baseline_rms_microvolts": round(base, 6),
            "baseline_clipped_fraction": round(clipped_fraction, 6),
        }

    for start, size in window_list:
        window_channels = [c[start:start + size] for c in channels]

        # 2 · per-channel health: clipping fraction, or RMS far above baseline.
        for ch_index, name in enumerate(CHANNELS):
            samples = window_channels[ch_index]
            clipped = sum(1 for s in samples if abs(s) >= PARAMS["clip_microvolts"])
            fraction = clipped / len(samples)
            channel_rms = rms(samples)
            base = rms_baseline[ch_index]
            ratio = (channel_rms / base) if base > 0 else 0.0
            if fraction >= PARAMS["clip_fraction_trigger"] or ratio >= PARAMS["rms_ratio_trigger"]:
                events.append(make_event(
                    "channel_health_change", digest, start, size,
                    {"channel": name,
                     "clipped_fraction": round(fraction, 6),
                     "rms_microvolts": round(channel_rms, 6),
                     "baseline_rms_microvolts": round(base, 6),
                     "rms_ratio": round(ratio, 6)},
                    baseline_span))

        # 3 · band excursion against the in-session baseline.
        merged = [sum(c[i] for c in window_channels) / len(window_channels)
                  for i in range(size)]
        for band, (low, high) in PARAMS["bands"].items():
            power = goertzel_power(merged, low, high)
            base = band_baseline[band]
            ratio = (power / base) if base > 0 else 0.0
            if ratio >= PARAMS["band_ratio_trigger"]:
                events.append(make_event(
                    "band_excursion", digest, start, size,
                    {"band": band, "low_hz": low, "high_hz": high,
                     "power": round(power, 9),
                     "baseline_power": round(base, 9),
                     "power_ratio": round(ratio, 6)},
                    baseline_span))

        # 4 · artifact burst: samples far above *that channel's own* baseline.
        #
        # Deliberately per-channel. A cross-channel envelope makes one bad
        # electrode trip the burst detector on every window — on the first run
        # against a real recording, a saturated AF7 (~900 µV against ~20 µV
        # elsewhere) produced an artifact_burst almost every second, restating
        # a fault `channel_health_change` already reports. A burst is a
        # departure from a channel's own norm, so the norm has to be its own.
        for ch_index, name in enumerate(CHANNELS):
            if eligibility[name]["detector_status"] != "eligible":
                continue          # recorded in the manifest, not inferable from silence
            base = rms_baseline[ch_index]
            threshold = PARAMS["burst_sigma"] * base
            hits = sum(1 for s in window_channels[ch_index] if abs(s) >= threshold)
            if hits >= PARAMS["burst_min_samples"]:
                events.append(make_event(
                    "artifact_burst", digest, start, size,
                    {"channel": name,
                     "samples_over_threshold": hits,
                     "threshold_microvolts": round(threshold, 6),
                     "baseline_rms_microvolts": round(base, 6)},
                    baseline_span))

    # Stable order: by position, then kind, then id. Independent of dict order.
    events.sort(key=lambda e: (e["source"]["start_sample"], e["kind"], e["event_id"]))
    _LAST_MANIFEST.clear()
    _LAST_MANIFEST.update(build_manifest(digest, total, eligibility, events))
    return events


# Populated by `extract`; read by `extract_with_manifest`. A module-level box
# rather than a changed return type, so existing callers keep working.
_LAST_MANIFEST: dict[str, Any] = {}


def build_manifest(
    digest: str, total: int, eligibility: dict[str, dict[str, Any]],
    events: list[dict[str, Any]],
) -> dict[str, Any]:
    """The session-level record that makes an *absent* event interpretable.

    Every disposition here is deliberately negative. This artifact indexes a
    recording; it is not a dataset, not a label set, and not evidence. It
    credits nothing toward the §21 five-clean-session gate, because whether a
    session was clean is a judgement about the recording, not about whether an
    extractor ran over it.
    """
    counts: dict[str, int] = {}
    for event in events:
        counts[event["kind"]] = counts.get(event["kind"], 0) + 1
    return {
        "schema_version": SESSION_MANIFEST_SCHEMA,
        "recording_sha256": digest,
        "recording_sample_count": total,
        "params_sha256": params_digest(),
        "sample_interval_convention": "half_open_[start_sample,_start_sample+sample_count)",
        "channels": {name: eligibility[name] for name in CHANNELS},
        "event_counts": {kind: counts.get(kind, 0) for kind in sorted(EVENT_KINDS)},
        "contains_signal": False,
        "science_status": "pipeline_only",
        "label_status": "heuristic_observation",
        "live_control": False,
        "promotion_status": "not_eligible",
        "clean_session_gate_credited": False,
    }


def extract_with_manifest(
    recording_dir: Path,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    events = extract(recording_dir)
    return events, dict(_LAST_MANIFEST)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path, help="a Recordings/<session> directory")
    parser.add_argument("--out", type=Path, default=None,
                        help="output JSONL (default: <recording>/session-events.jsonl)")
    parser.add_argument("--stdout", action="store_true", help="write to stdout instead")
    args = parser.parse_args(argv)

    events, manifest = extract_with_manifest(args.recording)
    validate_session_event_file(events)
    validate_session_manifest(manifest)

    lines = "".join(
        json.dumps(e, sort_keys=True, separators=(",", ":")) + "\n" for e in events)
    if args.stdout:
        sys.stdout.write(lines)
    else:
        destination = args.out or (args.recording / "session-events.jsonl")
        destination.write_text(lines, encoding="utf-8")
        manifest_path = destination.with_name("session-events-manifest.json")
        manifest_path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"{manifest_path}")
        for name in CHANNELS:
            entry = manifest["channels"][name]
            note = f" ({entry['suppressed_reason']})" if entry["suppressed_reason"] else ""
            print(f"  {name:5s} burst detector: {entry['detector_status']}{note}")
        kinds: dict[str, int] = {}
        for event in events:
            kinds[event["kind"]] = kinds.get(event["kind"], 0) + 1
        print(f"{destination}: {len(events)} events")
        for kind in sorted(kinds):
            print(f"  {kind:24s} {kinds[kind]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
