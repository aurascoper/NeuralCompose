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
            states = root / "states.jsonl"
            manifest = root / "manifest.json"
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
            states = root / "states.jsonl"
            manifest = root / "manifest.json"
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
            states = root / "states.jsonl"
            manifest = root / "manifest.json"
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


if __name__ == "__main__":
    unittest.main()
