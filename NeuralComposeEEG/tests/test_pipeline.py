"""Regression tests for the leakage-resistant EEG encoder benchmark."""

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import torch

from neuralcompose_eeg.contracts import ContractError
from neuralcompose_eeg.capture_manifest import (
    CAPTURE_INTEGRITY_SCHEMA,
    PROTOCOL_SPEC_PATH,
    compile_capture_manifest,
    validate_capture_integrity,
)
from neuralcompose_eeg.compare_encoder_conditions import assemble_encoder_comparison
from neuralcompose_eeg.bendr_adapter import FrozenBENDRConvEncoder, LearnedMuseToBENDRAdapter, load_bendr_geometry
from neuralcompose_eeg.dataset import build_canonical_dataset, load_dataset, save_dataset
from neuralcompose_eeg.eegpt_adapter import (
    FixedMuseToEEGPTMapping,
    LearnedMuseToEEGPTAdapter,
    ZeroFillNoMaskControl,
    load_eegpt_montage,
)
from neuralcompose_eeg.extract_eegpt_fixed_embeddings import _pooled_embeddings
from neuralcompose_eeg.run_bendr_fold_worker import BENDRFoldClassifier
from neuralcompose_eeg.run_eegpt_fold_worker import EEGPTFoldClassifier
from neuralcompose_eeg.evaluate import DEFAULT_EXPERIMENT_CONFIG_PATH, load_experiment_configuration, run_pilot
from neuralcompose_eeg.evaluate_external_fold_predictions import (
    _hash_window_set,
    evaluate_external_fold_predictions,
    main as evaluate_external_fold_main,
)
from neuralcompose_eeg.features import extract_features
from neuralcompose_eeg.models import fit_predict_m0, fit_predict_m1, grouped_folds, leave_one_session_out, split_manifest_sha256
from neuralcompose_eeg.provenance import sha256_file, sha256_json
from neuralcompose_eeg.representations import load_external_embeddings


def _write_session(path: Path, session_number: int, *, gap: bool = False) -> None:
    sample_rate = 256
    sample_count = 16 * sample_rate
    time = np.arange(sample_count, dtype=np.float64) / sample_rate
    if gap:
        time[1500:] += 0.2
    rows = ["t_seconds,TP9,AF7,AF8,TP10"]
    for index, timestamp in enumerate(time):
        value = 20.0 * np.sin(2 * np.pi * 10.0 * timestamp + session_number)
        if index >= 10 * sample_rate:
            value += 300.0 * np.exp(-0.5 * ((timestamp - 11.0) / 0.04) ** 2)
        channels = [value + channel * 0.2 for channel in range(4)]
        rows.append(",".join([f"{timestamp:.9f}", *[f"{channel:.7f}" for channel in channels]]))
    path.write_text("\n".join(rows) + "\n")


def _manifest(tmp: Path, *, gap_session: int | None = None, malformed: bool = False) -> Path:
    sessions = []
    for session_number in range(3):
        csv_path = tmp / f"session-{session_number}.csv"
        _write_session(csv_path, session_number, gap=session_number == gap_session)
        blocks = [
            {"label": "eyes_open", "start_seconds": 0, "end_seconds": 4, "role": "calibration", "label_provenance": "fixture"},
            {"label": "eyes_closed", "start_seconds": 4, "end_seconds": 10, "role": "task", "label_provenance": "fixture"},
            {"label": "blink_artifact", "start_seconds": 10, "end_seconds": 16, "role": "task", "label_provenance": "fixture"},
        ]
        if malformed and session_number == 0:
            blocks[1]["start_seconds"] = 3
        sessions.append(
            {
                "session_id": f"fixture-{session_number}",
                "participant_id": "fixture-participant",
                "recording_date": f"2026-07-{10 + session_number}",
                "device_id": "fixture-muse",
                "headset_fit_id": f"fixture-fit-{session_number}",
                "eeg_csv": csv_path.name,
                "sample_rate_hz": 256,
                "channel_order": ["TP9", "AF7", "AF8", "TP9"] if malformed and session_number == 1 else ["TP9", "AF7", "AF8", "TP10"],
                "task_blocks": blocks,
            }
        )
    manifest = {
        "schema_version": "nc-eeg-source-manifest-v0",
        "dataset_id": "fixture-dataset",
        "label_order": ["eyes_open", "eyes_closed", "blink_artifact"],
        "sessions": sessions,
    }
    path = tmp / "manifest.json"
    path.write_text(json.dumps(manifest))
    return path


def _preprocessing_path() -> Path:
    return Path(__file__).resolve().parents[1] / "configs" / "muse-four-channel-v0.json"


def _experiment_configuration() -> dict:
    return load_experiment_configuration(DEFAULT_EXPERIMENT_CONFIG_PATH)


def _observable_protocol_spec() -> dict:
    return json.loads(PROTOCOL_SPEC_PATH.read_text())


def _write_protocol_capture(
    root: Path,
    session_number: int,
    *,
    transport_degraded: bool = False,
    stream_relative: bool = False,
    session_spacing_seconds: float = 86_400.0,
) -> tuple[Path, Path]:
    recording_dir = root / f"capture-{session_number}"
    recording_dir.mkdir()
    base = 1_780_000_000.0 + session_number * session_spacing_seconds
    sample_rate = 256
    specification = _observable_protocol_spec()
    starts: list[float] = []
    ends: list[float] = []
    next_start = base + 1 + float(specification["transition_gap_seconds"])
    for segment in specification["segments"]:
        starts.append(next_start)
        ends.append(next_start + float(segment["duration_seconds"]))
        next_start = ends[-1] + float(specification["transition_gap_seconds"])
    # Four contiguous seconds per block are enough to make one canonical
    # window. The intentionally large gaps exercise packet-loss censoring
    # without turning a fixture into minutes of waveform rows.
    timestamp_chunks = [base + np.arange(sample_rate, dtype=np.float64) / sample_rate]
    timestamp_chunks.extend(start + np.arange(4 * sample_rate, dtype=np.float64) / sample_rate for start in starts)
    timestamp_chunks.append(np.asarray([ends[-1]], dtype=np.float64))
    timestamps = np.concatenate(timestamp_chunks)
    if stream_relative:
        timestamps -= base
    lines = ["t_seconds,TP9,AF7,AF8,TP10"]
    for timestamp in timestamps:
        signal_time = timestamp + base if stream_relative else timestamp
        signal = 20.0 * np.sin(2 * np.pi * 10.0 * (signal_time - base))
        lines.append(",".join([f"{timestamp:.9f}", *[f"{signal + channel:.6f}" for channel in range(4)]]))
    (recording_dir / "eeg.csv").write_text("\n".join(lines) + "\n")
    session_id = f"capture-fixture-{session_number}"
    (recording_dir / "metadata.json").write_text(json.dumps({
        "session_id": session_id,
        "profile": "muses",
        "device_profile": "muse_s_native_ble",
        "sample_rate": 256,
        "transport_degraded": transport_degraded,
        "transport_event_count": 1 if transport_degraded else 0,
        "eeg_timestamp_clock": "stream_relative" if stream_relative else "unix_epoch",
        "first_sample_timestamp": 0.0 if stream_relative else base,
        "first_sample_wallclock_unix": base,
        "timestamp": "2026-07-22T00:00:00Z",
    }))
    protocol_path = root / f"protocol-{session_number}.json"
    protocol_path.write_text(json.dumps({
        "schema_version": "nc-eeg-observable-protocol-v1",
        "protocol_id": "encoder-pilot-v1",
        "protocol_preset": "encoder-pilot-v1",
        "protocol_preset_sha256": sha256_file(PROTOCOL_SPEC_PATH),
        "protocol_cue_clock": "unix_epoch_wall_time",
        "tag_blinks": 5,
        "tag_window_s": 8,
        "transition_gap_seconds": 8,
        "listening_audio_id": "fixture-neutral-audio-v1",
        "listening_audio_sha256": "a" * 64,
        "speaking_script_id": specification["speaking_script"]["id"],
        "speaking_script_sha256": sha256_file(PROTOCOL_SPEC_PATH.parent / specification["speaking_script"]["relative_path"]),
        "dry_run": False,
        "completed": True,
        "segments": [
            {
                "label": segment["label"],
                "cue_unix": start - 8,
                "start_unix": start,
                "end_unix": end,
                "planned_duration_s": segment["duration_seconds"],
                "actual_duration_s": segment["duration_seconds"],
                "completion": "completed",
                "instruction": segment["instruction"],
            }
            for segment, start, end in zip(specification["segments"], starts, ends, strict=True)
        ],
    }))
    return recording_dir, protocol_path


def _capture_index(
    root: Path,
    *,
    transport_degraded: bool = False,
    session_count: int = 2,
    same_recording_date: bool = False,
) -> Path:
    sessions = []
    session_spacing_seconds = 3_600.0 if same_recording_date else 86_400.0
    for session_number in range(session_count):
        recording_dir, protocol_path = _write_protocol_capture(
            root,
            session_number,
            transport_degraded=transport_degraded and session_number == 0,
            session_spacing_seconds=session_spacing_seconds,
        )
        sessions.append({
            "session_id": f"capture-fixture-{session_number}",
            "recording_date": datetime.fromtimestamp(
                1_780_000_000.0 + session_number * session_spacing_seconds,
                timezone.utc,
            ).date().isoformat(),
            "recording_directory": recording_dir.name,
            "protocol_log": protocol_path.name,
            "participant_id": "fixture-participant",
            "device_profile": "muse_s_native_ble",
            "headset_fit_id": f"fixture-fit-{session_number}",
            "protocol_preset": "encoder-pilot-v1",
            "operator_notes": "fixture",
            "eligible_override": False,
        })
    path = root / "capture-index.json"
    path.write_text(json.dumps({
        "schema_version": "nc-eeg-capture-index-v1",
        "dataset_id": "capture-fixture",
        "sessions": sessions,
    }))
    return path


class DatasetContractTests(unittest.TestCase):
    def test_rejects_malformed_source_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ContractError):
                build_canonical_dataset(_manifest(Path(directory), malformed=True), _preprocessing_path())

    def test_gap_crossing_windows_are_censored_and_hashes_are_reproducible(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = _manifest(Path(directory), gap_session=1)
            first, first_metadata = build_canonical_dataset(manifest, _preprocessing_path())
            second, second_metadata = build_canonical_dataset(manifest, _preprocessing_path())
            self.assertEqual(first.artifact_sha256(), second.artifact_sha256())
            self.assertGreater(first_metadata["sessions"][1]["packet_gap_count"], 0)
            self.assertGreater(first_metadata["sessions"][1]["rejected_packet_gap_windows"], 0)
            self.assertEqual(first_metadata["dataset_sha256"], second_metadata["dataset_sha256"])
            self.assertEqual(first.windows.shape[1:], (4, 1024))

    def test_dataset_archive_round_trip_excludes_source_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, metadata = build_canonical_dataset(_manifest(root), _preprocessing_path())
            archive, metadata_path = root / "dataset.npz", root / "dataset.json"
            save_dataset(dataset, metadata, archive, metadata_path)
            loaded = load_dataset(archive)
            self.assertEqual(loaded.artifact_sha256(), dataset.artifact_sha256())
            persisted = json.loads(metadata_path.read_text())
            self.assertNotIn("eeg_csv", json.dumps(persisted))
            self.assertEqual(persisted["dataset_sha256"], dataset.artifact_sha256())

    def test_future_task_values_cannot_change_calibration_windows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _manifest(root)
            baseline, _ = build_canonical_dataset(manifest, _preprocessing_path())
            csv_path = root / "session-0.csv"
            lines = csv_path.read_text().splitlines()
            modified = [lines[0]]
            for line in lines[1:]:
                values = line.split(",")
                if float(values[0]) >= 4.0:
                    values[1:] = [str(float(value) * 1000.0) for value in values[1:]]
                modified.append(",".join(values))
            csv_path.write_text("\n".join(modified) + "\n")
            changed, _ = build_canonical_dataset(manifest, _preprocessing_path())
            original_window = baseline.windows[np.flatnonzero(baseline.session_ids == "fixture-0")[0]]
            changed_window = changed.windows[np.flatnonzero(changed.session_ids == "fixture-0")[0]]
            np.testing.assert_allclose(original_window, changed_window, rtol=0, atol=1e-6)


class CaptureManifestTests(unittest.TestCase):
    def test_one_clean_capture_has_integrity_without_experiment_eligibility(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root, session_count=1)
            report = validate_capture_integrity(
                index_path,
                root / "capture-integrity.json",
            )
            self.assertEqual(report["schema_version"], CAPTURE_INTEGRITY_SCHEMA)
            self.assertTrue(report["integrity_valid"])
            self.assertEqual(report["integrity_session_count"], 1)
            self.assertFalse(report["experiment_eligible"])
            self.assertEqual(report["experiment_eligibility_reason"], "insufficient_session_count")
            with self.assertRaisesRegex(ContractError, "at least two non-excluded eligible sessions"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

    def test_benchmark_manifest_requires_two_distinct_recording_dates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root, same_recording_date=True)
            report = validate_capture_integrity(index_path, root / "capture-integrity.json")
            self.assertTrue(report["integrity_valid"])
            self.assertFalse(report["experiment_eligible"])
            self.assertEqual(report["experiment_eligibility_reason"], "insufficient_recording_date_count")
            with self.assertRaisesRegex(ContractError, "at least two recording dates"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

    def test_compiles_complete_protocol_into_canonical_source_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "source-manifest.json"
            manifest = compile_capture_manifest(_capture_index(root), output)
            self.assertEqual(manifest["schema_version"], "nc-eeg-source-manifest-v0")
            self.assertEqual(len(manifest["sessions"]), 2)
            self.assertEqual(manifest["sessions"][0]["task_blocks"][0]["role"], "calibration")
            self.assertEqual(manifest["sessions"][0]["task_blocks"][0]["label"], "eyes_open")
            dataset, _ = build_canonical_dataset(output, _preprocessing_path())
            self.assertGreater(len(dataset.labels), 0)

    def test_rejects_transport_degraded_capture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ContractError):
                compile_capture_manifest(_capture_index(root, transport_degraded=True), root / "source-manifest.json")

    def test_transport_event_count_alone_rejects_capture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root)
            index = json.loads(index_path.read_text())
            for entry in index["sessions"]:
                metadata_path = root / entry["recording_directory"] / "metadata.json"
                metadata = json.loads(metadata_path.read_text())
                metadata["transport_event_count"] = 1
                metadata_path.write_text(json.dumps(metadata))
            index_path.write_text(json.dumps(index))
            with self.assertRaisesRegex(ContractError, "transport-stalled"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

    def test_eligible_override_can_only_exclude(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root, session_count=3)
            index = json.loads(index_path.read_text())
            index["sessions"][0]["eligible_override"] = True
            index["sessions"][0]["operator_notes"] = "Exclude this clean engineering capture."
            index_path.write_text(json.dumps(index))
            manifest = compile_capture_manifest(index_path, root / "source-manifest.json")
            self.assertEqual(len(manifest["sessions"]), 2)
            self.assertEqual(
                manifest["excluded_capture_index_entries"],
                [{"session_id": "capture-fixture-0", "reason": "operator_forced_exclusion"}],
            )

    def test_rejects_mismatched_stimulus_and_wrong_fixed_duration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root)
            index = json.loads(index_path.read_text())
            second_protocol_path = root / index["sessions"][1]["protocol_log"]
            second_protocol = json.loads(second_protocol_path.read_text())
            second_protocol["listening_audio_sha256"] = "b" * 64
            second_protocol_path.write_text(json.dumps(second_protocol))
            with self.assertRaisesRegex(ContractError, "stimulus identity"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

            first_protocol_path = root / index["sessions"][0]["protocol_log"]
            first_protocol = json.loads(first_protocol_path.read_text())
            first_protocol["segments"][0]["actual_duration_s"] = 59
            first_protocol_path.write_text(json.dumps(first_protocol))
            with self.assertRaisesRegex(ContractError, "actual duration"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

    def test_rejects_incomplete_or_overlapping_observable_protocol(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root)
            index = json.loads(index_path.read_text())
            protocol_path = root / index["sessions"][0]["protocol_log"]
            protocol = json.loads(protocol_path.read_text())
            protocol["completed"] = False
            protocol_path.write_text(json.dumps(protocol))
            with self.assertRaisesRegex(ContractError, "did not complete"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

            protocol["completed"] = True
            overlapping = protocol["segments"][1]
            overlapping["start_unix"] = protocol["segments"][0]["end_unix"] - 1
            overlapping["cue_unix"] = overlapping["start_unix"] - 8
            overlapping["end_unix"] = overlapping["start_unix"] + overlapping["planned_duration_s"]
            overlapping["actual_duration_s"] = overlapping["planned_duration_s"]
            protocol_path.write_text(json.dumps(protocol))
            with self.assertRaisesRegex(ContractError, "overlap"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

    def test_compiles_stream_relative_recording_from_first_sample_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = []
            for index in range(2):
                recording_dir, protocol_path = _write_protocol_capture(root, index, stream_relative=True)
                sessions.append({
                    "session_id": f"capture-fixture-{index}",
                    "recording_date": datetime.fromtimestamp(1_780_000_000.0 + index * 86_400.0, timezone.utc).date().isoformat(),
                    "recording_directory": recording_dir.name,
                    "protocol_log": protocol_path.name,
                    "participant_id": "fixture-participant",
                    "device_profile": "muse_s_native_ble",
                    "headset_fit_id": f"fixture-fit-{index}",
                    "protocol_preset": "encoder-pilot-v1",
                    "operator_notes": "fixture",
                    "eligible_override": False,
                })
            index_path = root / "capture-index.json"
            index_path.write_text(json.dumps({
                "schema_version": "nc-eeg-capture-index-v1", "dataset_id": "relative-clock-fixture", "sessions": sessions,
            }))
            manifest = compile_capture_manifest(index_path, root / "source-manifest.json")
            self.assertEqual(manifest["sessions"][0]["task_blocks"][0]["start_seconds"], 9.0)

    def test_rejects_stream_relative_capture_without_wall_clock_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root)
            index = json.loads(index_path.read_text())
            for entry in index["sessions"]:
                metadata_path = root / entry["recording_directory"] / "metadata.json"
                metadata = json.loads(metadata_path.read_text())
                metadata["eeg_timestamp_clock"] = "stream_relative"
                metadata.pop("first_sample_wallclock_unix")
                metadata_path.write_text(json.dumps(metadata))
            index_path.write_text(json.dumps(index))

            with self.assertRaisesRegex(ContractError, "first-sample wall-clock anchor"):
                compile_capture_manifest(index_path, root / "source-manifest.json")

    def test_rejects_capture_with_unknown_timestamp_clock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index_path = _capture_index(root)
            index = json.loads(index_path.read_text())
            for entry in index["sessions"]:
                metadata_path = root / entry["recording_directory"] / "metadata.json"
                metadata = json.loads(metadata_path.read_text())
                metadata["eeg_timestamp_clock"] = "unavailable"
                metadata_path.write_text(json.dumps(metadata))
            index_path.write_text(json.dumps(index))

            with self.assertRaisesRegex(ContractError, "must declare eeg_timestamp_clock"):
                compile_capture_manifest(index_path, root / "source-manifest.json")


class SplitAndModelTests(unittest.TestCase):
    def _dataset(self):
        self.temporary = tempfile.TemporaryDirectory()
        return build_canonical_dataset(_manifest(Path(self.temporary.name)), _preprocessing_path())

    def tearDown(self) -> None:
        if hasattr(self, "temporary"):
            self.temporary.cleanup()

    def test_complete_sessions_are_never_shared_across_folds(self) -> None:
        dataset, _ = self._dataset()
        folds = leave_one_session_out(dataset)
        self.assertEqual(len(folds), 3)
        for fold in folds:
            train = set(dataset.session_ids[fold.train_index].tolist())
            test = set(dataset.session_ids[fold.test_index].tolist())
            self.assertFalse(train & test)
            self.assertEqual(test, {fold.held_out_session})

    def test_confirmation_groupings_remain_whole_session_splits(self) -> None:
        dataset, _ = self._dataset()
        for grouping in ("recording_date", "headset_fit"):
            for fold in grouped_folds(dataset, grouping):
                train = set(dataset.session_ids[fold.train_index].tolist())
                test = set(dataset.session_ids[fold.test_index].tolist())
                self.assertFalse(train & test)
                self.assertEqual(fold.grouping, grouping)

    def test_m0_standardizer_is_fit_only_from_training_rows(self) -> None:
        dataset, _ = self._dataset()
        features = extract_features(dataset.windows, dataset.quality, dataset.missing_channel_masks)
        fold = leave_one_session_out(dataset)[0]
        _, _, first = fit_predict_m0(features, dataset.labels, fold, class_count=len(dataset.label_order))
        changed = features.copy()
        changed[fold.test_index] += 1_000_000.0
        _, _, second = fit_predict_m0(changed, dataset.labels, fold, class_count=len(dataset.label_order))
        self.assertEqual(first["train_only_standardizer_sha256"], second["train_only_standardizer_sha256"])

    def test_pilot_is_never_promotable(self) -> None:
        dataset, metadata = self._dataset()
        result = run_pilot(dataset, metadata, models=("m0",))
        self.assertEqual(result["status"], "insufficient_evidence")
        self.assertEqual(result["promotion_status"], "not_eligible")
        self.assertFalse(result["split"]["overlap_leakage_possible"])
        self.assertIsInstance(result["split"]["manifest_sha256"], str)
        self.assertEqual(result["split"]["manifest"]["grouping"], "session")
        self.assertEqual(set(result["models"]["m0"]["folds"][0]["train_sessions"]) & set(result["models"]["m0"]["folds"][0]["test_sessions"]), set())
        self.assertIsNotNone(result["models"]["m0"]["runtime_outcomes"]["mean_training_seconds"])

    def test_eegnet_training_smoke_uses_mask_contract(self) -> None:
        dataset, _ = self._dataset()
        predictions, probabilities, fit = fit_predict_m1(
            dataset,
            leave_one_session_out(dataset)[0],
            class_count=len(dataset.label_order),
            epochs=1,
            batch_size=8,
            device="cpu",
        )
        self.assertEqual(predictions.shape, (probabilities.shape[0],))
        self.assertEqual(probabilities.shape[1], len(dataset.label_order))
        self.assertEqual(fit["missing_channel_mask"], "explicit-mask-concatenated-at-classifier")


class ExternalRepresentationTests(unittest.TestCase):
    @staticmethod
    def _embedding_metadata(dataset, *, adapter: str, scope: str) -> dict:
        return {
            "schema_version": "nc-eeg-external-embeddings-v0",
            "dataset_sha256": dataset.artifact_sha256(),
            "model_id": "eegpt",
            "initialization": "pretrained",
            "model_revision": "fixture",
            "checkpoint_sha256": "0" * 64,
            "extractor_version": "fixture-extractor",
            "extractor_sha256": "1" * 64,
            "input_archive_sha256": "2" * 64,
            "channel_adapter": adapter,
            "missing_channel_mask": "absent_negative_control" if adapter == "zero_filled_no_mask_negative_control" else "explicit",
            "adapter_training_scope": scope,
            "worker_run_manifest": {
                "platform": "fixture",
                "accelerator": "cpu",
                "accelerator_memory": "unavailable",
                "python_version": "fixture",
                "torch_version": "fixture",
                "cuda_or_mps_version": "unavailable",
                "available_quota": "unavailable",
                "git_commit": "fixture",
                "seed": 42,
            },
        }

    def test_fixed_embedding_probe_accepts_only_nonlearned_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, _ = build_canonical_dataset(_manifest(root), _preprocessing_path())
            archive = root / "embeddings.npz"
            np.savez_compressed(
                archive,
                raw_window_hashes=dataset.raw_window_hashes,
                embeddings=np.ones((len(dataset.labels), 3), dtype=np.float32),
            )
            metadata_path = root / "embedding.json"
            metadata_path.write_text(json.dumps(self._embedding_metadata(
                dataset, adapter="approximate_electrode_mapping_with_mask", scope="fixed_preprocessor"
            )))
            external = load_external_embeddings(archive, metadata_path, dataset)
            self.assertEqual(external.values.shape, (len(dataset.labels), 3))

            metadata_path.write_text(json.dumps(self._embedding_metadata(
                dataset, adapter="four_channel_learned_adapter", scope="fold_train_only"
            )))
            with self.assertRaisesRegex(ContractError, "precomputed embeddings cannot prove"):
                load_external_embeddings(archive, metadata_path, dataset)

    def test_requires_explicit_mask_for_transfer_embeddings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, _ = build_canonical_dataset(_manifest(root), _preprocessing_path())
            archive = root / "embeddings.npz"
            np.savez_compressed(
                archive,
                raw_window_hashes=dataset.raw_window_hashes,
                embeddings=np.ones((len(dataset.labels), 3), dtype=np.float32),
            )
            metadata = {
                "schema_version": "nc-eeg-external-embeddings-v0",
                "dataset_sha256": dataset.artifact_sha256(),
                "model_id": "eegpt",
                "initialization": "pretrained",
                "model_revision": "fixture",
                "checkpoint_sha256": "0" * 64,
                "extractor_version": "fixture-extractor",
                "extractor_sha256": "1" * 64,
                "input_archive_sha256": "2" * 64,
                "channel_adapter": "four_channel_learned_adapter",
                "missing_channel_mask": "absent_negative_control",
            }
            metadata_path = root / "embedding.json"
            metadata_path.write_text(json.dumps(metadata))
            with self.assertRaises(ContractError):
                load_external_embeddings(archive, metadata_path, dataset)

    def test_requires_exactly_the_canonical_window_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, _ = build_canonical_dataset(_manifest(root), _preprocessing_path())
            archive = root / "embeddings.npz"
            np.savez_compressed(
                archive,
                raw_window_hashes=dataset.raw_window_hashes[:-1],
                embeddings=np.ones((len(dataset.labels) - 1, 3), dtype=np.float32),
            )
            metadata = {
                "schema_version": "nc-eeg-external-embeddings-v0",
                "dataset_sha256": dataset.artifact_sha256(),
                "model_id": "bendr",
                "initialization": "random",
                "model_revision": "fixture",
                "checkpoint_sha256": "0" * 64,
                "extractor_version": "fixture-extractor",
                "extractor_sha256": "1" * 64,
                "input_archive_sha256": "2" * 64,
                "channel_adapter": "four_channel_learned_adapter",
                "missing_channel_mask": "explicit",
            }
            metadata_path = root / "embedding.json"
            metadata_path.write_text(json.dumps(metadata))
            with self.assertRaises(ContractError):
                load_external_embeddings(archive, metadata_path, dataset)

    def test_rejects_embeddings_extracted_from_another_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, _ = build_canonical_dataset(_manifest(root), _preprocessing_path())
            archive = root / "embeddings.npz"
            np.savez_compressed(
                archive,
                raw_window_hashes=dataset.raw_window_hashes,
                embeddings=np.ones((len(dataset.labels), 3), dtype=np.float32),
            )
            metadata = {
                "schema_version": "nc-eeg-external-embeddings-v0",
                "dataset_sha256": dataset.artifact_sha256(),
                "model_id": "eegpt",
                "initialization": "pretrained",
                "model_revision": "fixture",
                "checkpoint_sha256": "0" * 64,
                "extractor_version": "fixture-extractor",
                "extractor_sha256": "1" * 64,
                "input_archive_sha256": "2" * 64,
                "channel_adapter": "four_channel_learned_adapter",
                "missing_channel_mask": "explicit",
            }
            metadata_path = root / "embedding.json"
            metadata_path.write_text(json.dumps(metadata))
            with self.assertRaises(ContractError):
                load_external_embeddings(
                    archive,
                    metadata_path,
                    dataset,
                    dataset_archive_sha256="3" * 64,
                )


class EEGPTMontageAdapterTests(unittest.TestCase):
    def test_pinned_mapping_preserves_shape_and_exposes_missing_targets(self) -> None:
        torch.manual_seed(7)
        montage = load_eegpt_montage()
        self.assertEqual(len(montage.target_channels), 58)
        self.assertEqual(
            tuple(montage.target_channels[index] for index in montage.target_indices),
            ("TP7", "AF3", "AF4", "TP8"),
        )
        windows = torch.stack(
            [torch.full((1024,), float(channel + 1)) for channel in range(4)],
            dim=0,
        ).unsqueeze(0).repeat(2, 1, 1)
        observed = torch.tensor([[1, 1, 1, 1], [1, 1, 0, 1]], dtype=torch.float32)

        fixed = FixedMuseToEEGPTMapping(montage)
        fixed_values, fixed_mask = fixed(windows, observed)
        self.assertEqual(tuple(fixed_values.shape), (2, 58, 1024))
        self.assertEqual(tuple(fixed_mask.shape), (2, 58))
        self.assertEqual(int(fixed_mask[0].sum()), 4)
        self.assertEqual(int(fixed_mask[1].sum()), 3)
        self.assertTrue(torch.all(fixed_values[0, montage.target_indices[0]] == 1.0))
        self.assertTrue(torch.all(fixed_values[1, montage.target_indices[2]] == 0.0))

        learned = LearnedMuseToEEGPTAdapter(montage)
        learned_values, learned_mask = learned(windows, observed)
        self.assertTrue(torch.equal(learned_mask, fixed_mask))
        self.assertTrue(torch.any(learned_values[1, learned_mask[1] == 0] != 0.0))

        shuffled = FixedMuseToEEGPTMapping(montage, source_order=(3, 2, 1, 0))
        shuffled_values, _ = shuffled(windows, observed)
        self.assertFalse(torch.equal(shuffled_values, fixed_values))

        zero_fill = ZeroFillNoMaskControl(montage)
        self.assertTrue(torch.equal(zero_fill(windows), fixed(windows, torch.ones_like(observed))[0]))


class EEGPTFoldWorkerTests(unittest.TestCase):
    def test_adapter_receives_gradients_while_backbone_remains_frozen_and_evaluating(self) -> None:
        class ToyEEGPTBackbone(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.scale = torch.nn.Parameter(torch.tensor(1.0))

            def forward(self, values: torch.Tensor, chan_ids: torch.Tensor) -> torch.Tensor:
                del chan_ids
                patches = values.reshape(values.shape[0], 58, 16, 64).mean(dim=(1, 3))
                return (patches[:, :, None, None] * self.scale).expand(-1, -1, 4, 512)

        backbone = ToyEEGPTBackbone()
        model = EEGPTFoldClassifier(backbone, torch.arange(58).unsqueeze(0), class_count=3)
        model.train()
        self.assertFalse(backbone.training)
        self.assertFalse(any(parameter.requires_grad for parameter in backbone.parameters()))

        logits = model(torch.randn(2, 4, 1024), torch.ones(2, 4))
        torch.nn.functional.cross_entropy(logits, torch.tensor([0, 1])).backward()

        self.assertIsNotNone(model.adapter.projection.weight.grad)
        self.assertIsNotNone(model.head.weight.grad)
        self.assertIsNone(backbone.scale.grad)


class EEGPTFixedEmbeddingTests(unittest.TestCase):
    def test_fixed_conditions_preserve_or_deliberately_omit_missing_mask_features(self) -> None:
        class ToyEEGPTBackbone(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.last_values: torch.Tensor | None = None

            def forward(self, values: torch.Tensor, chan_ids: torch.Tensor) -> torch.Tensor:
                del chan_ids
                self.last_values = values.detach().cpu()
                patches = values.reshape(values.shape[0], 58, 16, 64).mean(dim=(1, 3))
                return patches[:, :, None, None].expand(-1, -1, 4, 512)

        with tempfile.TemporaryDirectory() as directory:
            dataset, _ = build_canonical_dataset(_manifest(Path(directory)), _preprocessing_path())
            dataset.missing_channel_masks[0, 2] = 0
            montage = load_eegpt_montage()
            backbone = ToyEEGPTBackbone()
            canonical = _pooled_embeddings(
                dataset,
                backbone=backbone,
                chan_ids=torch.arange(58).unsqueeze(0),
                condition="canonical",
                batch_size=len(dataset.labels),
                device="cpu",
            )
            self.assertEqual(canonical.shape, (len(dataset.labels), 512 + 58))
            self.assertEqual(canonical[0, 512 + montage.target_indices[2]], 0.0)

            zero_fill = _pooled_embeddings(
                dataset,
                backbone=backbone,
                chan_ids=torch.arange(58).unsqueeze(0),
                condition="zero_fill",
                batch_size=len(dataset.labels),
                device="cpu",
            )
            self.assertEqual(zero_fill.shape, (len(dataset.labels), 512))
            self.assertIsNotNone(backbone.last_values)
            self.assertTrue(torch.all(backbone.last_values[0, montage.target_indices[2]] == 0.0))


class BENDRAdapterTests(unittest.TestCase):
    def test_pinned_bendr_adapter_exposes_the_20_channel_geometry_and_missing_targets(self) -> None:
        geometry = load_bendr_geometry()
        adapter = LearnedMuseToBENDRAdapter(geometry)
        values, target_mask = adapter(
            torch.randn(2, 4, 1024),
            torch.tensor([[1, 1, 1, 1], [1, 1, 0, 1]], dtype=torch.float32),
        )
        self.assertEqual(tuple(values.shape), (2, 20, 1024))
        self.assertEqual(tuple(target_mask.shape), (2, 20))
        self.assertEqual(int(target_mask[0].sum()), 4)
        self.assertEqual(int(target_mask[1].sum()), 3)
        self.assertTrue(torch.any(values[1, target_mask[1] == 0] != 0.0))
        self.assertEqual(
            tuple(geometry.target_channels[index] for index in geometry.target_indices),
            ("T5", "F7", "F8", "T6"),
        )

    def test_bendr_checkpoint_loader_rejects_an_unpinned_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "encoder.pt"
            checkpoint.write_bytes(b"not the pinned BENDR release artifact")
            with self.assertRaisesRegex(ContractError, "hash does not match"):
                FrozenBENDRConvEncoder().load_pinned_checkpoint(checkpoint)

    def test_bendr_adapter_receives_gradients_with_a_frozen_backbone(self) -> None:
        class ToyBENDRBackbone(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.scale = torch.nn.Parameter(torch.tensor(1.0))

            def forward(self, values: torch.Tensor) -> torch.Tensor:
                return values.mean(dim=1, keepdim=True).repeat(1, 512, 1) * self.scale

        backbone = ToyBENDRBackbone()
        model = BENDRFoldClassifier(backbone, class_count=3)
        model.train()
        self.assertFalse(backbone.training)
        self.assertFalse(any(parameter.requires_grad for parameter in backbone.parameters()))
        logits = model(torch.randn(2, 4, 1024), torch.ones(2, 4))
        torch.nn.functional.cross_entropy(logits, torch.tensor([0, 1])).backward()
        self.assertIsNotNone(model.adapter.projection.weight.grad)
        self.assertIsNotNone(model.head.weight.grad)
        self.assertIsNone(backbone.scale.grad)


class ExternalFoldEvaluationTests(unittest.TestCase):
    def _dataset(self):
        self.temporary = tempfile.TemporaryDirectory()
        return build_canonical_dataset(_manifest(Path(self.temporary.name)), _preprocessing_path())

    def tearDown(self) -> None:
        if hasattr(self, "temporary"):
            self.temporary.cleanup()

    @staticmethod
    def _fold_metadata(dataset) -> dict:
        return {
            "fold_provenance": [
                {
                    "held_out_group_id": fold.held_out_session,
                    "train_raw_window_hashes_sha256": _hash_window_set(dataset.raw_window_hashes[fold.train_index]),
                    "test_raw_window_hashes_sha256": _hash_window_set(dataset.raw_window_hashes[fold.test_index]),
                    "backbone_frozen": True,
                    "trainable_modules": ["four_channel_adapter", "linear_head"],
                    "adapter_checkpoint_sha256": "a" * 64,
                }
                for fold in leave_one_session_out(dataset)
            ]
        }

    def test_fold_scoped_predictions_require_canonical_train_and_test_windows(self) -> None:
        dataset, _ = self._dataset()
        probabilities = np.eye(len(dataset.label_order), dtype=np.float64)[dataset.labels]
        metadata = self._fold_metadata(dataset)
        folds, split = evaluate_external_fold_predictions(
            dataset, metadata, probabilities, split_unit="session"
        )
        self.assertEqual(len(folds), 3)
        self.assertEqual(split["manifest_sha256"], split_manifest_sha256(dataset, leave_one_session_out(dataset)))

        metadata["fold_provenance"][0]["train_raw_window_hashes_sha256"] = "0" * 64
        with self.assertRaisesRegex(ContractError, "wrong training windows"):
            evaluate_external_fold_predictions(dataset, metadata, probabilities, split_unit="session")

    def test_fold_scoped_cli_reorders_prediction_rows_by_raw_window_hash(self) -> None:
        dataset, dataset_metadata = self._dataset()
        root = Path(self.temporary.name)
        archive, metadata_path = root / "canonical.npz", root / "canonical.json"
        save_dataset(dataset, dataset_metadata, archive, metadata_path)
        reverse = np.arange(len(dataset.labels) - 1, -1, -1)
        probabilities = np.eye(len(dataset.label_order), dtype=np.float64)[dataset.labels][reverse]
        prediction_path = root / "predictions.npz"
        np.savez_compressed(
            prediction_path,
            raw_window_hashes=dataset.raw_window_hashes[reverse],
            probabilities=probabilities,
        )
        representation = {
            "dataset_sha256": dataset.artifact_sha256(),
            "model_id": "eegpt",
            "initialization": "pretrained",
            "model_revision": "fixture",
            "checkpoint_sha256": "c" * 64,
            "extractor_version": "fixture-extractor",
            "extractor_sha256": "d" * 64,
            "input_archive_sha256": sha256_file(archive),
            "channel_adapter": "four_channel_learned_adapter",
            "missing_channel_mask": "explicit",
            "adapter_training_scope": "fold_train_only",
            "worker_run_manifest": {
                "platform": "fixture",
                "accelerator": "cpu",
                "accelerator_memory": "unavailable",
                "python_version": "fixture",
                "torch_version": "fixture",
                "cuda_or_mps_version": "unavailable",
                "available_quota": "unavailable",
                "git_commit": "fixture",
                "seed": 42,
            },
        }
        prediction_metadata = {
            "schema_version": "nc-eeg-external-fold-evaluation-input-v0",
            "representation": representation,
            "experiment_configuration_sha256": sha256_json(_experiment_configuration()),
            "training": {
                "configuration_section": "m2_m3",
                "epochs": 10,
                "batch_size": 16,
                "learning_rate": 0.001,
                "seed": 42,
            },
            "runtime_outcomes": {
                "elapsed_seconds": 1.25,
                "peak_process_memory_bytes": 1024,
                "mean_training_seconds": 0.5,
                "mean_per_window_inference_ms": 0.25,
                "mean_checkpoint_size_bytes": 2048.0,
                "energy_impact_proxy": None,
            },
            "deployment": {"coreml_conversion": {"attempted": False, "success": None}},
            **self._fold_metadata(dataset),
        }
        prediction_metadata_path = root / "predictions.json"
        prediction_metadata_path.write_text(json.dumps(prediction_metadata))
        output = root / "evaluation.json"
        self.assertEqual(
            evaluate_external_fold_main(
                [
                    "--dataset", str(archive), "--metadata", str(metadata_path),
                    "--predictions", str(prediction_path), "--prediction-metadata", str(prediction_metadata_path),
                    "--output", str(output),
                ]
            ),
            0,
        )
        evaluated = json.loads(output.read_text())
        self.assertEqual(evaluated["status"], "insufficient_evidence")
        self.assertEqual(evaluated["aggregate"]["balanced_accuracy"], 1.0)
        self.assertEqual(evaluated["runtime_outcomes"]["mean_per_window_inference_ms"], 0.25)
        self.assertFalse(evaluated["deployment"]["coreml_conversion"]["attempted"])

        prediction_metadata["training"]["epochs"] = 11
        prediction_metadata_path.write_text(json.dumps(prediction_metadata))
        with self.assertRaisesRegex(ContractError, "fixed m2_m3.epochs"):
            evaluate_external_fold_main(
                [
                    "--dataset", str(archive), "--metadata", str(metadata_path),
                    "--predictions", str(prediction_path), "--prediction-metadata", str(prediction_metadata_path),
                    "--output", str(output),
                ]
            )

    @staticmethod
    def _local_report() -> dict:
        aggregate = {
            "macro_f1": 0.4,
            "balanced_accuracy": 0.4,
            "auroc_ovr_macro": 0.5,
            "brier_score": 0.8,
            "expected_calibration_error": 0.2,
            "artifact_sensitivity": 0.5,
            "artifact_specificity": 0.6,
            "cross_session_performance_degradation": 0.2,
        }
        return {
            "schema_version": "nc-eeg-evaluation-v0",
            "experiment_id": "EXP-NC-EEG-ENC-001",
            "dataset_sha256": "d" * 64,
            "split": {"manifest_sha256": "s" * 64, "overlap_leakage_possible": False},
            "models": {
                "m0": {"aggregate": aggregate, "runtime_outcomes": {"elapsed_seconds": 1.0}},
                "m1": {"aggregate": aggregate, "runtime_outcomes": {"elapsed_seconds": 2.0}},
            },
            "run_manifest": {"experiment_configuration_sha256": sha256_json(_experiment_configuration())},
            "deployment": {"coreml_conversion": {"attempted": False, "success": None}},
        }

    @staticmethod
    def _external_report(*, model_id: str, initialization: str, adapter: str) -> dict:
        return {
            "schema_version": "nc-eeg-external-fold-evaluation-v0",
            "experiment_id": "EXP-NC-EEG-ENC-001",
            "dataset_sha256": "d" * 64,
            "experiment_configuration_sha256": sha256_json(_experiment_configuration()),
            "split": {"manifest_sha256": "s" * 64, "overlap_leakage_possible": False},
            "external_embedding": {
                "model_id": model_id,
                "initialization": initialization,
                "channel_adapter": adapter,
                "missing_channel_mask": "absent_negative_control" if adapter == "zero_filled_no_mask_negative_control" else "explicit",
                "checkpoint_sha256": "e" * 64,
                "model_revision": "fixture",
                "extractor_sha256": "f" * 64,
            },
            "aggregate": {"macro_f1": 0.6, "balanced_accuracy": 0.6, "auroc_ovr_macro": 0.7, "brier_score": 0.6, "expected_calibration_error": 0.1, "artifact_sensitivity": 0.6, "artifact_specificity": 0.7, "cross_session_performance_degradation": 0.1},
            "runtime_outcomes": {"elapsed_seconds": 3.0},
            "deployment": {"coreml_conversion": {"attempted": False, "success": None}},
        }

    def test_encoder_comparison_requires_common_dataset_and_reports_controls_without_promotion(self) -> None:
        reports = [
            ("m2", self._external_report(model_id="eegpt", initialization="random", adapter="four_channel_learned_adapter")),
            ("m3", self._external_report(model_id="eegpt", initialization="pretrained", adapter="four_channel_learned_adapter")),
            ("bendr-random", self._external_report(model_id="bendr", initialization="random", adapter="four_channel_learned_adapter")),
            ("bendr-frozen", self._external_report(model_id="bendr", initialization="pretrained", adapter="four_channel_learned_adapter")),
            ("shuffle", self._external_report(model_id="eegpt", initialization="pretrained", adapter="shuffled_electrode_mapping_negative_control")),
            ("zero", self._external_report(model_id="eegpt", initialization="pretrained", adapter="zero_filled_no_mask_negative_control")),
        ]
        result = assemble_encoder_comparison(self._local_report(), reports)
        self.assertEqual(result["status"], "insufficient_evidence")
        self.assertEqual(result["promotion_status"], "not_eligible")
        readiness = result["pretrained_condition_readiness"]
        self.assertEqual(len(readiness), 2)
        self.assertTrue(all(item["matched_random_initialization"] for item in readiness))
        self.assertTrue(all(item["mapping_controls_present"]["shuffled_electrode_mapping"] for item in readiness))
        self.assertTrue(all(item["mapping_controls_present"]["zero_filled_no_mask"] for item in readiness))
        self.assertEqual(result["conditions"][0]["runtime_outcomes"]["elapsed_seconds"], 1.0)

        reports[1][1]["dataset_sha256"] = "x" * 64
        with self.assertRaisesRegex(ContractError, "different canonical datasets"):
            assemble_encoder_comparison(self._local_report(), reports)


if __name__ == "__main__":
    unittest.main()
