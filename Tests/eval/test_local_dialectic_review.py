"""Regression tests for bounded local semantic review of quarantined dialogue."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))


def _load(name: str):
    path = SCRIPTS / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


QUARANTINE = _load("quarantine_dialectic_corpus.py")
REVIEW = _load("review_quarantined_dialectics.py")


def _turn(index: int, text: str) -> dict:
    return {
        "index": index,
        "heard": text,
        "candidates": [
            {"text": f"candidate one {text}", "roleID": "coherence-seeking"},
            {"text": f"candidate two {text}", "roleID": "displacement-seeking"},
        ],
        "tension": 0.4,
        "margin": 0.1,
        "selectionTemperature": 0.2,
        "glossScalar": 0.5,
        "outcome": "synthesized:synthesis",
        "spokenText": f"spoken {text}",
    }


class LocalDialecticReviewTests(unittest.TestCase):
    def _quarantined_source(self, root: Path) -> tuple[Path, Path]:
        source = root / "dialectic-turns-2026-07-22.jsonl"
        source.write_text("\n".join(json.dumps(_turn(index, f"private phrase number {index}")) for index in range(18)) + "\n")
        report = root / "parse-report.json"
        QUARANTINE.inspect_corpus(source, report, root / "events.jsonl")
        return source, report

    def test_chunking_is_stateless_with_fixed_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source, report = self._quarantined_source(Path(directory))
            _, records = REVIEW.load_reviewable_records(source, report)
            chunks = REVIEW.chunk_records(records)
            self.assertEqual([len(chunk) for chunk in chunks], [16, 4])
            self.assertEqual([record["source_line"] for record in chunks[0][-2:]], [15, 16])
            self.assertEqual([record["source_line"] for record in chunks[1][:2]], [15, 16])
            context = REVIEW.build_chunk_context("chunk-001", chunks[0])
            self.assertIn("private phrase number 0", context)
            self.assertIn("canonical_source_lines_allowed", context)
            self.assertIn('"1":0', context)
            self.assertNotIn("research", REVIEW.SYSTEM_PROMPT.casefold())

    def test_review_response_is_chunk_bound_and_non_verbatim(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source, report = self._quarantined_source(Path(directory))
            _, records = REVIEW.load_reviewable_records(source, report)
            safe_response = json.dumps([{
                "source_lines": [1, 2],
                "legacy_turn_indices": [0, 1],
                "finding_type": "selection_inertia",
                "severity": "medium",
                "confidence": 0.75,
                "observation": "Adjacent outputs show limited structural variation.",
                "engineering_implication": "Replay should preserve source-line identity for comparison.",
                "contains_verbatim_private_text": False,
            }])
            findings = REVIEW.validate_findings(safe_response, records[:2])
            self.assertEqual(findings[0]["finding_type"], "selection_inertia")
            self.assertFalse(findings[0]["contains_verbatim_private_text"])
            self.assertFalse(findings[0]["citation_normalized_from_legacy_index"])

            prefixed_findings = REVIEW.validate_findings("Review result:\n" + safe_response, records[:2])
            self.assertEqual(prefixed_findings, findings)

            leaking_response = safe_response.replace(
                "Adjacent outputs show limited structural variation.",
                "private phrase number 0",
            )
            with self.assertRaisesRegex(REVIEW.ReviewContractError, "private dialogue"):
                REVIEW.validate_findings(leaking_response, records[:2])

            legacy_citation_response = safe_response.replace('"source_lines": [1, 2]', '"source_lines": [0, 1]')
            normalized = REVIEW.validate_findings(legacy_citation_response, records[:2])
            self.assertEqual(normalized[0]["source_lines"], [1, 2])
            self.assertTrue(normalized[0]["citation_normalized_from_legacy_index"])

    def test_aggregation_never_reopens_raw_dialogue(self) -> None:
        chunks = [
            {
                "schema_version": REVIEW.REVIEW_SCHEMA,
                "chunk_id": "chunk-001",
                "findings": [{"finding_type": "duplicate_index", "source_lines": [3], "confidence": 0.8}],
                "disposition": REVIEW.REVIEW_DISPOSITION,
            },
            {
                "schema_version": REVIEW.REVIEW_SCHEMA,
                "chunk_id": "chunk-002",
                "findings": [
                    {"finding_type": "duplicate_index", "source_lines": [3, 17], "confidence": 0.9},
                    {"finding_type": "state_discontinuity", "source_lines": [3], "confidence": 0.6},
                ],
                "disposition": REVIEW.REVIEW_DISPOSITION,
            },
        ]
        result = REVIEW.aggregate_review_chunks(chunks)
        duplicate = next(category for category in result["categories"] if category["finding_type"] == "duplicate_index")
        self.assertTrue(duplicate["spans_chunk_boundaries"])
        self.assertEqual(duplicate["affected_source_lines"], [3, 17])
        self.assertEqual(result["conflicting_findings"], [{"source_line": 3, "finding_types": ["duplicate_index", "state_discontinuity"]}])
        self.assertEqual(result["disposition"], REVIEW.REVIEW_DISPOSITION)

    def test_aggregation_accepts_a_safe_rejection_receipt(self) -> None:
        result = REVIEW.aggregate_review_chunks([{
            "schema_version": REVIEW.REVIEW_SCHEMA,
            "chunk_id": "chunk-001",
            "review_status": "rejected_response",
            "rejection_reason": "finding 0 cites source lines outside its chunk",
            "findings": [],
            "disposition": REVIEW.REVIEW_DISPOSITION,
        }])
        self.assertEqual(result["finding_count"], 0)
        self.assertEqual(result["categories"], [])

    def test_remote_endpoint_and_cloud_model_are_rejected(self) -> None:
        with self.assertRaisesRegex(REVIEW.ReviewContractError, "only http://127.0.0.1"):
            REVIEW._require_loopback_ollama("https://example.com")
        with self.assertRaisesRegex(REVIEW.ReviewContractError, "qwen2.5"):
            REVIEW.local_model_identity("http://127.0.0.1:11434", "deepseek-v4-flash:cloud")

    def test_private_review_requires_prompt_logging_attestation(self) -> None:
        with self.assertRaisesRegex(REVIEW.ReviewContractError, "prompt_logging_status"):
            REVIEW.run_review(
                Path("unused-source.jsonl"),
                Path("unused-report.json"),
                Path("unused-findings.jsonl"),
                Path("unused-manifest.json"),
                base_url="http://127.0.0.1:11434",
                model="qwen2.5:0.5b",
                context_limit=8192,
                prompt_logging_status="unverified",
            )


if __name__ == "__main__":
    unittest.main()
