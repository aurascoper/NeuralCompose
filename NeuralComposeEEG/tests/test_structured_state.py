from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from neuralcompose_eeg.contracts import ContractError
from neuralcompose_eeg.dataset import build_canonical_dataset
from neuralcompose_eeg.structured_state import (
    MANIFEST_SCHEMA,
    STATE_SCHEMA,
    _sha256_lines,
    build_shadow_state_records,
    load_shadow_state_records,
    write_shadow_state_artifacts,
)

from .test_pipeline import _manifest, _preprocessing_path


class StructuredStateTests(unittest.TestCase):
    def _dataset_and_probabilities(self, root: Path):
        dataset, _ = build_canonical_dataset(_manifest(root), _preprocessing_path())
        values = np.zeros((len(dataset.labels), len(dataset.label_order)), dtype=np.float64)
        values[:, 0] = 0.7
        values[:, 1] = 0.2
        values[:, 2] = 0.1
        return dataset, values

    @staticmethod
    def _encoder_provenance() -> dict[str, str]:
        return {
            "model_id": "fixture-shadow-encoder",
            "model_revision": "fixture-v0",
            "source_kind": "synthetic_contract_fixture",
        }

    def test_round_trip_is_deterministic_and_shadow_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            first = write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            first_state_bytes = states.read_bytes()
            first_manifest_bytes = manifest.read_bytes()
            second = write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            replay = load_shadow_state_records(states, manifest)
            self.assertEqual(first, second)
            self.assertEqual(first_state_bytes, states.read_bytes())
            self.assertEqual(first_manifest_bytes, manifest.read_bytes())
            self.assertEqual(first["schema_version"], MANIFEST_SCHEMA)
            self.assertEqual(first["status"], "insufficient_evidence")
            self.assertEqual(first["science_status"], "pipeline_only")
            self.assertFalse(first["live_control"])
            self.assertEqual(len(replay), len(dataset.labels))
            self.assertTrue(all(record["schema_version"] == STATE_SCHEMA for record in replay))
            serialized = states.read_text().casefold()
            for forbidden in ("dialogue", "dialectic", "prompt", "speech", "policy", "action", "waveform", "target"):
                self.assertNotIn(forbidden, serialized)

    def test_replay_rejects_tampered_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            rows = states.read_text().splitlines()
            row = json.loads(rows[0])
            row["observable_state"]["confidence"] = 0.01
            rows[0] = json.dumps(row, sort_keys=True, separators=(",", ":"))
            states.write_text("\n".join(rows) + "\n")
            with self.assertRaisesRegex(ContractError, "manifest hash"):
                load_shadow_state_records(states, manifest)

    def test_replay_rejects_self_inconsistent_confidence_even_with_rehashed_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            records = [json.loads(line) for line in states.read_text().splitlines()]
            records[0]["observable_state"]["confidence"] = 0.1
            states.write_text("".join(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n" for record in records))
            manifest_value = json.loads(manifest.read_text())
            manifest_value["records_sha256"] = _sha256_lines(records)
            manifest.write_text(json.dumps(manifest_value, sort_keys=True) + "\n")
            with self.assertRaisesRegex(ContractError, "confidence does not match"):
                load_shadow_state_records(states, manifest)

    def test_prohibits_dialogue_or_policy_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            with self.assertRaisesRegex(ContractError, "unsupported fields"):
                build_shadow_state_records(
                    dataset,
                    probabilities,
                    encoder_provenance={**self._encoder_provenance(), "dialogue_source": "forbidden"},
                )

    def test_rejects_invalid_probability_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            probabilities[0, 0] = 0.6
            with self.assertRaisesRegex(ContractError, "sum to one"):
                build_shadow_state_records(
                    dataset,
                    probabilities,
                    encoder_provenance=self._encoder_provenance(),
                )

    def test_rejects_probability_shape_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            for malformed in (probabilities[:, :-1], probabilities[0]):
                with self.assertRaisesRegex(ContractError, "shape"):
                    build_shadow_state_records(
                        dataset,
                        malformed,
                        encoder_provenance=self._encoder_provenance(),
                    )

    def test_rejects_nonfinite_probabilities(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for bad in (np.nan, np.inf):
                dataset, probabilities = self._dataset_and_probabilities(root)
                probabilities[0, 0] = bad
                with self.assertRaisesRegex(ContractError, r"finite values in \[0, 1\]"):
                    build_shadow_state_records(
                        dataset,
                        probabilities,
                        encoder_provenance=self._encoder_provenance(),
                    )

    def test_records_dataset_and_encoder_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            records = build_shadow_state_records(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
            )
            for record in records:
                self.assertEqual(record["encoder"], self._encoder_provenance())
                self.assertEqual(record["source"]["dataset_sha256"], dataset.artifact_sha256())
                self.assertEqual(record["source"]["source_manifest_sha256"], dataset.source_manifest_sha256)
                self.assertEqual(len(record["source"]["raw_window_sha256"]), 64)
            self.assertEqual(len({record["state_id"] for record in records}), len(records))

    def _rehash(self, states: Path, manifest: Path, records: list[dict]) -> None:
        """Republish tampered records with a manifest hash that matches them, so
        the reader cannot fall back on the hash check to reject the content."""
        states.write_text(
            "".join(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n" for record in records)
        )
        manifest_value = json.loads(manifest.read_text())
        manifest_value["records_sha256"] = _sha256_lines(records)
        manifest.write_text(json.dumps(manifest_value, sort_keys=True) + "\n")

    def _published(self, root: Path) -> tuple[Path, Path, list[dict]]:
        dataset, probabilities = self._dataset_and_probabilities(root)
        states = root / "shadow" / "states.jsonl"
        manifest = root / "shadow" / "manifest.json"
        write_shadow_state_artifacts(
            dataset,
            probabilities,
            encoder_provenance=self._encoder_provenance(),
            states_output=states,
            manifest_output=manifest,
        )
        return states, manifest, [json.loads(line) for line in states.read_text().splitlines()]

    def test_replay_rejects_manifest_granting_live_control_or_promotion(self) -> None:
        for key, granted in (("live_control", True), ("promotion_status", "eligible")):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                states, manifest, _ = self._published(root)
                manifest_value = json.loads(manifest.read_text())
                manifest_value[key] = granted
                manifest.write_text(json.dumps(manifest_value, sort_keys=True) + "\n")
                with self.assertRaisesRegex(ContractError, f"{key} violates shadow-only status"):
                    load_shadow_state_records(states, manifest)

    def test_replay_rejects_record_granting_live_control(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            states, manifest, records = self._published(root)
            records[0]["live_control"] = True
            self._rehash(states, manifest, records)
            with self.assertRaisesRegex(ContractError, "live_control violates shadow-only status"):
                load_shadow_state_records(states, manifest)

    def test_replay_rejects_argmax_that_is_not_the_maximum(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            states, manifest, records = self._published(root)
            observable = records[0]["observable_state"]
            lowest = min(observable["probabilities"], key=observable["probabilities"].get)
            observable["argmax_observable"] = lowest
            observable["confidence"] = observable["probabilities"][lowest]
            self._rehash(states, manifest, records)
            with self.assertRaisesRegex(ContractError, "argmax does not select a maximum"):
                load_shadow_state_records(states, manifest)

    def test_publication_leaves_no_partial_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            published = root / "published"
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=published / "states.jsonl",
                manifest_output=published / "manifest.json",
            )
            self.assertEqual(
                sorted(path.name for path in published.iterdir()),
                ["manifest.json", "states.jsonl"],
            )

    def test_rejected_republication_preserves_the_previous_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            previous = states.read_bytes()
            probabilities[0, 0] = np.nan
            with self.assertRaises(ContractError):
                write_shadow_state_artifacts(
                    dataset,
                    probabilities,
                    encoder_provenance=self._encoder_provenance(),
                    states_output=states,
                    manifest_output=manifest,
                )
            self.assertEqual(states.read_bytes(), previous)
            self.assertEqual([path.name for path in states.parent.iterdir() if ".partial" in path.name], [])
            load_shadow_state_records(states, manifest)

    # ── record/manifest provenance agreement ─────────────────────────────
    #
    # records_sha256 only proves the records are the ones the manifest was
    # written for. Each case below rehashes the manifest so that check passes,
    # leaving the agreement checks as the only thing standing between a
    # mismatched artifact and a successful replay.

    def test_replay_rejects_record_encoder_mismatch_with_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            states, manifest, records = self._published(root)
            records[0]["encoder"] = {**self._encoder_provenance(), "model_id": "substituted-encoder"}
            self._rehash(states, manifest, records)
            with self.assertRaisesRegex(ContractError, "encoder does not match the manifest"):
                load_shadow_state_records(states, manifest)

    def test_replay_rejects_record_source_mismatch_with_manifest(self) -> None:
        for field in ("dataset_sha256", "source_manifest_sha256"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                states, manifest, records = self._published(root)
                records[0]["source"][field] = "0" * 64
                self._rehash(states, manifest, records)
                with self.assertRaisesRegex(ContractError, f"{field} does not match the manifest"):
                    load_shadow_state_records(states, manifest)

    def test_replay_rejects_invalid_or_unrecomputed_state_id(self) -> None:
        cases = {
            "not_hexadecimal": ("z" * 64, "state_id must be a lowercase SHA-256"),
            "wrong_length": ("abc123", "state_id must be a lowercase SHA-256"),
            "valid_hex_but_not_derived": ("a" * 64, "not derived from its dataset and raw window"),
        }
        for name, (state_id, expected) in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                states, manifest, records = self._published(root)
                records[0]["state_id"] = state_id
                self._rehash(states, manifest, records)
                with self.assertRaisesRegex(ContractError, expected):
                    load_shadow_state_records(states, manifest)

    def test_replay_rejects_raw_window_that_is_not_a_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            states, manifest, records = self._published(root)
            records[0]["source"]["raw_window_sha256"] = "not-a-digest"
            self._rehash(states, manifest, records)
            with self.assertRaisesRegex(ContractError, "raw_window_sha256 must be a lowercase SHA-256"):
                load_shadow_state_records(states, manifest)

    # ── the pair is the unit of publication ──────────────────────────────

    def test_differing_republication_is_refused_and_preserves_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            published = (states.read_bytes(), manifest.read_bytes())
            # A different but entirely valid run over the same output paths.
            probabilities[:, 0], probabilities[:, 2] = 0.1, 0.7
            with self.assertRaisesRegex(ContractError, "refusing to overwrite"):
                write_shadow_state_artifacts(
                    dataset,
                    probabilities,
                    encoder_provenance=self._encoder_provenance(),
                    states_output=states,
                    manifest_output=manifest,
                )
            self.assertEqual((states.read_bytes(), manifest.read_bytes()), published)
            self.assertEqual([path.name for path in states.parent.iterdir() if ".partial" in path.name], [])
            load_shadow_state_records(states, manifest)

    def test_matching_states_only_publication_can_complete_manifest(self) -> None:
        """An interrupted first publication — records committed, manifest never
        written — is completable, because the records on disk match exactly."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            committed = states.read_bytes()
            manifest.unlink()
            write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance=self._encoder_provenance(),
                states_output=states,
                manifest_output=manifest,
            )
            self.assertEqual(states.read_bytes(), committed)
            self.assertEqual(len(load_shadow_state_records(states, manifest)), len(dataset.labels))

    def test_states_and_manifest_outputs_must_be_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, probabilities = self._dataset_and_probabilities(root)
            shared = root / "artifact.json"
            with self.assertRaisesRegex(ContractError, "must be distinct paths"):
                write_shadow_state_artifacts(
                    dataset,
                    probabilities,
                    encoder_provenance=self._encoder_provenance(),
                    states_output=shared,
                    manifest_output=shared,
                )
            self.assertFalse(shared.exists())


if __name__ == "__main__":
    unittest.main()
