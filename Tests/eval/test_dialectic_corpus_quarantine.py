"""Regression tests for the private dialogue quarantine artifact builder."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def _load_script():
    path = Path(__file__).resolve().parents[2] / "Scripts" / "quarantine_dialectic_corpus.py"
    spec = importlib.util.spec_from_file_location("quarantine_dialectic_corpus", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CORPUS = _load_script()


def _turn(index: int, *, spoken: str | None = "Private response") -> dict:
    return {
        "index": index,
        "heard": "Private source text",
        "candidates": [
            {"text": "Private candidate", "roleID": "coherence-seeking"},
            {"text": "Private alternative", "roleID": "displacement-seeking"},
        ],
        "tension": 0.4,
        "margin": 0.1,
        "selectionTemperature": 0.2,
        "glossScalar": 0.5,
        "outcome": "synthesized:synthesis",
        "spokenText": spoken,
        "witnessFinding": "Private witness finding",
        "generatorFingerprint": {
            "runtime": "ollama",
            "transport": "http",
            "provider": "ollama",
            "model": "fixture-model",
            "promptProfile": "fixture",
            "interactionStyle": "reflective",
            "promptHash": "a" * 64,
        },
    }


class DialecticCorpusQuarantineTests(unittest.TestCase):
    def test_private_source_yields_metadata_only_derivatives(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "dialectic-turns-2026-07-22.jsonl"
            source.write_bytes(
                b"\n".join(
                    [
                        json.dumps(_turn(4)).encode("utf-8"),
                        b'{"index": 5, "tension": NaN}',
                        b"[]",
                        json.dumps(_turn(4, spoken=None)).encode("utf-8"),
                    ]
                )
                + b"\n"
            )
            original = source.read_bytes()
            report_path = root / "local-manifests" / "parse-report.json"
            events_path = root / "local-manifests" / "events.jsonl"

            report, events = CORPUS.inspect_corpus(
                source,
                report_path,
                events_path,
                candidate_eeg_session_id="candidate-session-001",
            )

            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(report["source"]["sha256"], CORPUS.sha256_bytes(original))
            self.assertEqual(report["source"]["capture_date"], "2026-07-22")
            self.assertEqual(report["records"]["valid_record_count"], 2)
            self.assertEqual(report["records"]["malformed_record_count"], 2)
            self.assertFalse(report["ordering"]["turn_index_strictly_increasing"])
            self.assertEqual(report["ordering"]["duplicate_turn_indexes"], [4])
            self.assertEqual(
                report["ordering"]["timestamp_monotonicity"],
                "not_applicable_not_recorded_in_dialectical_turn_event",
            )
            self.assertEqual(
                report["records"]["malformed_records"],
                [
                    {"source_line": 2, "reason": "non_finite_json_constant:NaN"},
                    {"source_line": 3, "reason": "record_must_be_object"},
                ],
            )
            self.assertEqual(report["crosswalk"]["alignment_status"], "recorded_not_scientifically_enabled")
            self.assertFalse(report["crosswalk"]["used_by_EXP_NC_EEG_ENC_001"])
            self.assertTrue(report["disposition"]["development_only_permanent"])
            self.assertFalse(report["disposition"]["cloud_exposure_allowed"])

            self.assertEqual(len(events), 2)
            self.assertEqual(events[0]["event_id"].split(":")[-1], "1")
            self.assertEqual(events[0]["source_line"], 1)
            self.assertEqual(events[0]["turn_index"], 4)
            self.assertIsNone(events[0]["timestamp_unix"])
            self.assertEqual(events[0]["speaker_role"], "unspecified")
            self.assertNotIn("heard", events[0])
            self.assertNotIn("spokenText", events[0])
            self.assertNotIn("candidates", events[0])

            derived = report_path.read_text() + events_path.read_text()
            self.assertNotIn("Private source text", derived)
            self.assertNotIn("Private candidate", derived)
            self.assertNotIn("Private response", derived)

    def test_schema_rejects_missing_core_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "dialectic-turns-2026-07-22.jsonl"
            incomplete = _turn(0)
            del incomplete["margin"]
            source.write_text(json.dumps(incomplete) + "\n")
            report, events = CORPUS.inspect_corpus(
                source,
                root / "report.json",
                root / "events.jsonl",
            )
            self.assertEqual(events, [])
            self.assertEqual(report["records"]["malformed_records"], [{"source_line": 1, "reason": "schema_invalid:margin"}])


if __name__ == "__main__":
    unittest.main()
