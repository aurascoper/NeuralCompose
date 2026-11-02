"""Canonical, causal four-channel Muse window construction.

This module deliberately rejects convenient-looking legacy data that lacks the
session/block/calibration contract. A model cannot repair ambiguous evidence.
"""

from __future__ import annotations

import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
from scipy import signal

from .contracts import (
    CHANNELS,
    DATASET_SCHEMA,
    STRIDE_SAMPLES,
    TARGET_SAMPLE_RATE_HZ,
    WINDOW_SAMPLES,
    ContractError,
    load_source_manifest,
)
from .provenance import runtime_provenance, sha256_bytes, sha256_file, sha256_json


ARTIFACT_LABELS = frozenset({
    "blink_artifact",
    "jaw_artifact",
    "head_motion_artifact",
    "poor_contact_artifact",
    "head_motion_or_poor_contact_artifact",
})
QUALITY_NAMES = (
    "packet_gap_count",
    "missing_channel_count",
    "maximum_absolute_amplitude",
    "maximum_channel_range",
    "minimum_channel_variance",
)


@dataclass(frozen=True)
class CanonicalDataset:
    windows: np.ndarray
    labels: np.ndarray
    session_ids: np.ndarray
    participant_ids: np.ndarray
    recording_dates: np.ndarray
    device_ids: np.ndarray
    headset_fit_ids: np.ndarray
    raw_window_hashes: np.ndarray
    missing_channel_masks: np.ndarray
    quality: np.ndarray
    start_samples: np.ndarray
    label_order: tuple[str, ...]
    source_manifest_sha256: str
    preprocessing_sha256: str

    def artifact_sha256(self) -> str:
        """Hash values and ordering, not an `.npz` container implementation."""
        digest_parts = [
            self.windows.astype("<f4", copy=False).tobytes(),
            self.labels.astype("<i8", copy=False).tobytes(),
            "\0".join(map(str, self.session_ids.tolist())).encode(),
            "\0".join(map(str, self.participant_ids.tolist())).encode(),
            "\0".join(map(str, self.recording_dates.tolist())).encode(),
            "\0".join(map(str, self.device_ids.tolist())).encode(),
            "\0".join(map(str, self.headset_fit_ids.tolist())).encode(),
            "\0".join(map(str, self.raw_window_hashes.tolist())).encode(),
            self.missing_channel_masks.astype("u1", copy=False).tobytes(),
            self.quality.astype("<f4", copy=False).tobytes(),
            self.start_samples.astype("<i8", copy=False).tobytes(),
            "\0".join(self.label_order).encode(),
            self.source_manifest_sha256.encode(),
            self.preprocessing_sha256.encode(),
        ]
        return sha256_bytes(b"".join(digest_parts))


def _read_eeg_csv(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Read exactly `t_seconds,TP9,AF7,AF8,TP10`; never guess a montage."""
    try:
        with path.open(newline="") as handle:
            reader = csv.DictReader(handle)
            required = {"t_seconds", *CHANNELS}
            if not reader.fieldnames or not required.issubset(reader.fieldnames):
                raise ContractError(f"{path}: CSV must include {sorted(required)}")
            rows = list(reader)
    except OSError as exc:
        raise ContractError(f"cannot read {path}: {exc}") from exc
    if len(rows) < WINDOW_SAMPLES:
        raise ContractError(f"{path}: fewer than one four-second window")
    try:
        timestamps = np.asarray([float(row["t_seconds"]) for row in rows], dtype=np.float64)
        values = np.asarray([[float(row[channel]) for channel in CHANNELS] for row in rows], dtype=np.float64)
    except (KeyError, ValueError) as exc:
        raise ContractError(f"{path}: nonnumeric EEG value") from exc
    if not np.all(np.isfinite(timestamps)) or not np.all(np.diff(timestamps) > 0):
        raise ContractError(f"{path}: timestamps must be finite and strictly increasing")
    return timestamps, values


def _timestamp_gaps(timestamps: np.ndarray, *, sample_rate_hz: float) -> tuple[np.ndarray, float]:
    intervals = np.diff(timestamps)
    expected = 1.0 / sample_rate_hz
    median = float(np.median(intervals))
    if abs(median - expected) / expected > 0.05:
        raise ContractError(
            f"source median sample interval implies {1.0 / median:.3f} Hz; pilot requires 256 Hz +/- 5%"
        )
    # A gap index `i` means the discontinuity is between samples i and i + 1.
    return np.flatnonzero(intervals > expected * 1.5), expected


def _causal_fill(values: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Forward-fill missing samples per channel; retain an explicit mask.

    Filling is only necessary to allow a causal filter to operate. The mask is
    carried through to every model, and the quality features expose how much of
    a window was affected.
    """
    observed = np.isfinite(values)
    filled = values.copy()
    for channel in range(filled.shape[1]):
        last = 0.0
        for index in range(filled.shape[0]):
            if observed[index, channel]:
                last = float(filled[index, channel])
            else:
                filled[index, channel] = last
    return filled, observed


def _causal_filter(values: np.ndarray) -> np.ndarray:
    """Use SOS forward filtering only; `sosfiltfilt` is intentionally forbidden."""
    bandpass = signal.butter(4, [1.0, 45.0], btype="bandpass", fs=TARGET_SAMPLE_RATE_HZ, output="sos")
    notch_b, notch_a = signal.iirnotch(60.0, 30.0, fs=TARGET_SAMPLE_RATE_HZ)
    notch = signal.tf2sos(notch_b, notch_a)
    filtered = signal.sosfilt(bandpass, values, axis=0)
    return signal.sosfilt(notch, filtered, axis=0)


def _block_sample_mask(relative_seconds: np.ndarray, blocks: Iterable[dict[str, Any]], role: str) -> np.ndarray:
    mask = np.zeros(relative_seconds.shape[0], dtype=bool)
    for block in blocks:
        if block["role"] != role:
            continue
        mask |= (relative_seconds >= block["start_seconds"]) & (relative_seconds < block["end_seconds"])
    return mask


def _normalize_from_calibration(filtered: np.ndarray, observed: np.ndarray, calibration_mask: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if int(calibration_mask.sum()) < WINDOW_SAMPLES:
        raise ContractError("calibration contains fewer than one complete four-second window")
    means = np.zeros(filtered.shape[1], dtype=np.float64)
    stds = np.zeros(filtered.shape[1], dtype=np.float64)
    for channel in range(filtered.shape[1]):
        valid = calibration_mask & observed[:, channel]
        if int(valid.sum()) < WINDOW_SAMPLES:
            raise ContractError(f"calibration has too few observed samples for {CHANNELS[channel]}")
        means[channel] = float(np.mean(filtered[valid, channel]))
        stds[channel] = float(np.std(filtered[valid, channel]))
    if np.any(stds < 1e-6):
        raise ContractError("calibration standard deviation is degenerate")
    return ((filtered - means) / stds).astype(np.float32), means, stds


def _label_for_window(start_seconds: float, end_seconds: float, blocks: Iterable[dict[str, Any]]) -> str | None:
    for block in blocks:
        if start_seconds >= block["start_seconds"] and end_seconds <= block["end_seconds"]:
            return str(block["label"])
    return None


def _crosses_gap(start: int, end: int, gap_indices: np.ndarray) -> bool:
    return bool(np.any((gap_indices >= start) & (gap_indices < end - 1)))


def _raw_window_hash(session_id: str, start: int, raw_window: np.ndarray) -> str:
    header = f"{session_id}:{start}:{raw_window.shape}".encode("ascii")
    # IEEE NaN is normalized before hashing to make a missing value portable.
    canonical = np.nan_to_num(raw_window.astype("<f4", copy=False), nan=np.float32(9.876543e20))
    return sha256_bytes(header + canonical.tobytes())


def _quality(raw_window: np.ndarray, observed_window: np.ndarray, gap_count: int) -> np.ndarray:
    finite = np.where(observed_window, raw_window, np.nan)
    ranges = np.nanmax(finite, axis=0) - np.nanmin(finite, axis=0)
    variances = np.nanvar(finite, axis=0)
    amplitude = np.nanmax(np.abs(finite))
    return np.asarray(
        [
            float(gap_count),
            float((~observed_window.all(axis=0)).sum()),
            float(amplitude) if math.isfinite(float(amplitude)) else float("inf"),
            float(np.nanmax(ranges)) if np.isfinite(ranges).any() else float("inf"),
            float(np.nanmin(variances)) if np.isfinite(variances).any() else 0.0,
        ],
        dtype=np.float32,
    )


def build_canonical_dataset(source_manifest: Path, preprocessing_config: Path) -> tuple[CanonicalDataset, dict[str, Any]]:
    manifest = load_source_manifest(source_manifest)
    try:
        preprocessing = json.loads(preprocessing_config.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read preprocessing config {preprocessing_config}: {exc}") from exc
    if preprocessing.get("target_sample_rate_hz") != int(TARGET_SAMPLE_RATE_HZ):
        raise ContractError("preprocessing target sample rate must be 256 Hz")
    if preprocessing.get("window_seconds") != 4 or preprocessing.get("stride_seconds") != 1:
        raise ContractError("preprocessing must use four-second windows and one-second stride")
    if preprocessing.get("filter", {}).get("kind") != "causal-sos":
        raise ContractError("only causal SOS filtering is permitted")
    if preprocessing.get("resampling", {}).get("kind") != "identity-at-256-hz-only":
        raise ContractError("pilot must reject non-256 Hz resampling")

    windows: list[np.ndarray] = []
    labels: list[int] = []
    session_ids: list[str] = []
    participant_ids: list[str] = []
    recording_dates: list[str] = []
    device_ids: list[str] = []
    headset_fit_ids: list[str] = []
    hashes: list[str] = []
    missing_masks: list[np.ndarray] = []
    qualities: list[np.ndarray] = []
    starts: list[int] = []
    per_session: list[dict[str, Any]] = []
    label_index = {label: index for index, label in enumerate(manifest["label_order"])}

    for session in manifest["sessions"]:
        source_path = Path(session["_resolved_eeg_csv"])
        timestamps, raw_values = _read_eeg_csv(source_path)
        gaps, _ = _timestamp_gaps(timestamps, sample_rate_hz=float(session["sample_rate_hz"]))
        relative_seconds = timestamps - timestamps[0]
        filled, observed = _causal_fill(raw_values)
        filtered = _causal_filter(filled)
        calibration_mask = _block_sample_mask(relative_seconds, session["task_blocks"], "calibration")
        normalized, means, stds = _normalize_from_calibration(filtered, observed, calibration_mask)

        accepted = 0
        rejected_gap = 0
        rejected_boundary = 0
        for start in range(0, normalized.shape[0] - WINDOW_SAMPLES + 1, STRIDE_SAMPLES):
            end = start + WINDOW_SAMPLES
            if _crosses_gap(start, end, gaps):
                rejected_gap += 1
                continue
            label = _label_for_window(float(relative_seconds[start]), float(relative_seconds[end - 1]), session["task_blocks"])
            if label is None:
                rejected_boundary += 1
                continue
            raw_window = raw_values[start:end]
            observed_window = observed[start:end]
            windows.append(normalized[start:end].T)
            labels.append(label_index[label])
            session_ids.append(session["session_id"])
            participant_ids.append(session["participant_id"])
            recording_dates.append(session["recording_date"])
            device_ids.append(session["device_id"])
            headset_fit_ids.append(session["headset_fit_id"])
            hashes.append(_raw_window_hash(session["session_id"], start, raw_window))
            missing_masks.append(observed_window.all(axis=0).astype(np.uint8))
            qualities.append(_quality(raw_window, observed_window, int(_crosses_gap(start, end, gaps))))
            starts.append(start)
            accepted += 1

        per_session.append(
            {
                "session_id": session["session_id"],
                "participant_id": session["participant_id"],
                "recording_date": session["recording_date"],
                "device_id": session["device_id"],
                "headset_fit_id": session["headset_fit_id"],
                "source_sha256": session["source_sha256"],
                "sample_count": int(raw_values.shape[0]),
                "packet_gap_count": int(len(gaps)),
                "accepted_window_count": accepted,
                "rejected_packet_gap_windows": rejected_gap,
                "rejected_unlabelled_or_boundary_windows": rejected_boundary,
                "calibration_sample_count": int(calibration_mask.sum()),
                "calibration_mean": means.tolist(),
                "calibration_std": stds.tolist(),
            }
        )

    if not windows:
        raise ContractError("no eligible windows after strict source validation")
    dataset = CanonicalDataset(
        windows=np.asarray(windows, dtype=np.float32),
        labels=np.asarray(labels, dtype=np.int64),
        session_ids=np.asarray(session_ids, dtype="U128"),
        participant_ids=np.asarray(participant_ids, dtype="U128"),
        recording_dates=np.asarray(recording_dates, dtype="U32"),
        device_ids=np.asarray(device_ids, dtype="U128"),
        headset_fit_ids=np.asarray(headset_fit_ids, dtype="U128"),
        raw_window_hashes=np.asarray(hashes, dtype="U64"),
        missing_channel_masks=np.asarray(missing_masks, dtype=np.uint8),
        quality=np.asarray(qualities, dtype=np.float32),
        start_samples=np.asarray(starts, dtype=np.int64),
        label_order=tuple(manifest["label_order"]),
        source_manifest_sha256=str(manifest["manifest_sha256"]),
        preprocessing_sha256=sha256_file(preprocessing_config),
    )
    metadata = {
        "schema_version": DATASET_SCHEMA,
        "dataset_id": manifest["dataset_id"],
        "source_manifest_sha256": dataset.source_manifest_sha256,
        "preprocessing_sha256": dataset.preprocessing_sha256,
        "preprocessing_config": preprocessing,
        "window": {
            "channel_order": list(CHANNELS),
            "sample_rate_hz": TARGET_SAMPLE_RATE_HZ,
            "seconds": 4,
            "samples": WINDOW_SAMPLES,
            "stride_seconds": 1,
            "stride_samples": STRIDE_SAMPLES,
        },
        "quality_feature_names": list(QUALITY_NAMES),
        "label_order": list(dataset.label_order),
        "session_count": len(per_session),
        "window_count": int(dataset.labels.shape[0]),
        "sessions": per_session,
        "artifact_labels": sorted(ARTIFACT_LABELS),
        "builder_sha256": sha256_file(Path(__file__)),
        "runtime": runtime_provenance(Path(__file__).resolve().parents[3]),
    }
    metadata["dataset_sha256"] = dataset.artifact_sha256()
    metadata["metadata_sha256"] = sha256_json(metadata)
    return dataset, metadata


def save_dataset(dataset: CanonicalDataset, metadata: dict[str, Any], output_npz: Path, output_metadata: Path) -> None:
    output_npz.parent.mkdir(parents=True, exist_ok=True)
    output_metadata.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        output_npz,
        windows=dataset.windows,
        labels=dataset.labels,
        session_ids=dataset.session_ids,
        participant_ids=dataset.participant_ids,
        recording_dates=dataset.recording_dates,
        device_ids=dataset.device_ids,
        headset_fit_ids=dataset.headset_fit_ids,
        raw_window_hashes=dataset.raw_window_hashes,
        missing_channel_masks=dataset.missing_channel_masks,
        quality=dataset.quality,
        start_samples=dataset.start_samples,
        label_order=np.asarray(dataset.label_order),
        source_manifest_sha256=np.asarray(dataset.source_manifest_sha256),
        preprocessing_sha256=np.asarray(dataset.preprocessing_sha256),
    )
    metadata = dict(metadata)
    metadata["archive_sha256"] = sha256_file(output_npz)
    output_metadata.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


def load_dataset(path: Path) -> CanonicalDataset:
    with np.load(path, allow_pickle=False) as archive:
        dataset = CanonicalDataset(
            windows=archive["windows"].astype(np.float32),
            labels=archive["labels"].astype(np.int64),
            session_ids=archive["session_ids"].astype("U128"),
            participant_ids=archive["participant_ids"].astype("U128"),
            recording_dates=archive["recording_dates"].astype("U32"),
            device_ids=archive["device_ids"].astype("U128"),
            headset_fit_ids=archive["headset_fit_ids"].astype("U128"),
            raw_window_hashes=archive["raw_window_hashes"].astype("U64"),
            missing_channel_masks=archive["missing_channel_masks"].astype(np.uint8),
            quality=archive["quality"].astype(np.float32),
            start_samples=archive["start_samples"].astype(np.int64),
            label_order=tuple(str(value) for value in archive["label_order"].tolist()),
            source_manifest_sha256=str(archive["source_manifest_sha256"].item()),
            preprocessing_sha256=str(archive["preprocessing_sha256"].item()),
        )
    if dataset.windows.ndim != 3 or dataset.windows.shape[1:] != (len(CHANNELS), WINDOW_SAMPLES):
        raise ContractError("dataset does not contain [window, 4, 1024] canonical windows")
    if len(np.unique(dataset.session_ids)) < 2:
        raise ContractError("dataset needs at least two complete sessions")
    if any(
        len(values) != len(dataset.labels)
        for values in (
            dataset.windows,
            dataset.session_ids,
            dataset.participant_ids,
            dataset.recording_dates,
            dataset.device_ids,
            dataset.headset_fit_ids,
            dataset.raw_window_hashes,
            dataset.missing_channel_masks,
            dataset.quality,
            dataset.start_samples,
        )
    ):
        raise ContractError("dataset arrays have inconsistent lengths")
    return dataset
