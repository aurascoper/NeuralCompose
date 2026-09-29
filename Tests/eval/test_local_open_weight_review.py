"""Synthetic contract tests for the fail-closed local open-weight review cascade."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "Scripts"
EEG_SOURCE = ROOT / "NeuralComposeEEG" / "src"
sys.path[:0] = [str(SCRIPTS), str(EEG_SOURCE), str(ROOT)]


def _load(filename: str):
    path = SCRIPTS / filename
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


CASCADE = _load("local_open_weight_review.py")
NONINTERFERENCE = _load("local_review_noninterference.py")
REGISTER = _load("research_decision_register.py")


def _disposition() -> dict:
    return {
        "corpus_role": "engineering_replay_only",
        "development_only_permanent": True,
        "eligible_for_encoder_training": False,
        "eligible_for_encoder_evaluation": False,
        "eligible_for_policy_training": False,
        "eligible_for_policy_evaluation": False,
        "eligible_for_science": False,
        "cloud_exposure_allowed": False,
    }


def _record(index: int) -> dict:
    return {
        "index": index,
        "payload": {
            "heard": f"fixture confidential dialogue material alpha {index} stable",
            "candidate": f"fixture candidate material beta {index} stable",
        },
    }


def _source(count: int = 18, *, source_path: Path | None = None) -> object:
    records = tuple(
        CASCADE.ReviewRecord(41 + position, [7, 7, 4][position % 3], _record(position))
        for position in range(count)
    )
    source_bytes = ("fixture-source-" + str(count)).encode("utf-8")
    return CASCADE.SourceEnvelope(
        CASCADE.sha256_bytes(source_bytes),
        CASCADE.sha256_bytes(b"fixture-quarantine-report"),
        _disposition(),
        records,
        source_path,
    )


def _configuration(*, maximum_attempts: int = 3) -> object:
    value = json.loads(json.dumps(CASCADE.default_configuration()))
    value["retry"]["maximum_attempts"] = maximum_attempts
    return CASCADE.ReviewConfiguration.from_mapping(value)


def _finding(chunk: object, *, citation_id: str | None = None, finding_id: str = "finding-1") -> dict:
    citation = citation_id or chunk.new_record_citation_ids[0]
    return {
        "schema_version": CASCADE.FINDING_SCHEMA,
        "finding_id": finding_id,
        "finding_type": "selection_inertia",
        "severity": "medium",
        "confidence": 0.75,
        "evidence": [{"citation_id": citation, "claim": "A bounded structural pattern is visible."}],
        "observation": "Adjacent records exhibit limited structural variation.",
        "engineering_implication": "Replay should preserve source-line identity.",
        "contains_verbatim_private_text": False,
    }


def _attestation() -> object:
    return CASCADE.OperatorAttestation(True, True)


class LocalOpenWeightReviewTests(unittest.TestCase):
    def test_valid_chunk_construction_overlap_duplicate_and_nonmonotonic_indices(self) -> None:
        chunks = CASCADE.build_chunk_envelopes(_source(), _configuration())
        self.assertEqual([len(chunk.records) for chunk in chunks], [16, 4])
        self.assertEqual(chunks[0].chunk_id.split(":")[-1], "0001")
        self.assertEqual([record.citation_id for record in chunks[0].records[-2:]], ["line:55", "line:56"])
        self.assertEqual([record.citation_id for record in chunks[1].records[:2]], ["line:55", "line:56"])
        self.assertTrue(all(record.is_overlap_record for record in chunks[1].records[:2]))
        self.assertTrue(all(not record.is_overlap_record for record in chunks[1].records[2:]))
        self.assertEqual([record.legacy_turn_index for record in chunks[0].records[:3]], [7, 7, 4])
        self.assertEqual(CASCADE.FROZEN_SYSTEM_PROMPT, CASCADE.FROZEN_SYSTEM_PROMPT)

    def test_finding_validator_accepts_complete_causal_response(self) -> None:
        chunk = CASCADE.build_chunk_envelopes(_source(2), _configuration())[0]
        findings = CASCADE.validate_findings_response(json.dumps([_finding(chunk)]), chunk)
        self.assertEqual(findings[0]["finding_type"], "selection_inertia")
        self.assertEqual(findings[0]["evidence"][0]["citation_id"], "line:41")

    def test_validator_rejects_invented_and_mismatched_citations(self) -> None:
        chunk = CASCADE.build_chunk_envelopes(_source(2), _configuration())[0]
        invented = _finding(chunk, citation_id="line:999")
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "citation"):
            CASCADE.validate_findings_response(json.dumps([invented]), chunk)
        malformed_chunk = CASCADE.ChunkEnvelope(
            chunk.chunk_id,
            chunk.source_sha256,
            (CASCADE.ChunkRecord("line:41", 42, 7, False, _record(0)),),
        )
        mismatch = _finding(malformed_chunk)
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "citation"):
            CASCADE.validate_findings_response(json.dumps([mismatch]), malformed_chunk)

    def test_validator_rejects_overlap_only_evidence(self) -> None:
        chunk = CASCADE.build_chunk_envelopes(_source(), _configuration())[1]
        finding = _finding(chunk, citation_id=chunk.records[0].citation_id)
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "new chunk"):
            CASCADE.validate_findings_response(json.dumps([finding]), chunk)

    def test_validator_rejects_invalid_json_nonfinite_and_unknown_type(self) -> None:
        chunk = CASCADE.build_chunk_envelopes(_source(2), _configuration())[0]
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "complete JSON"):
            CASCADE.validate_findings_response("not-json", chunk)
        nonfinite = json.dumps([_finding(chunk)]).replace("0.75", "NaN")
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "non-finite"):
            CASCADE.validate_findings_response(nonfinite, chunk)
        infinity = json.dumps([_finding(chunk)]).replace("0.75", "Infinity")
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "non-finite"):
            CASCADE.validate_findings_response(infinity, chunk)
        unknown = _finding(chunk)
        unknown["finding_type"] = "unsupported"
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "not allowed"):
            CASCADE.validate_findings_response(json.dumps([unknown]), chunk)

    def test_validator_rejects_out_of_range_empty_forbidden_and_private_leakage(self) -> None:
        chunk = CASCADE.build_chunk_envelopes(_source(2), _configuration())[0]
        out_of_range = _finding(chunk)
        out_of_range["confidence"] = 1.1
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "within"):
            CASCADE.validate_findings_response(json.dumps([out_of_range]), chunk)
        empty_evidence = _finding(chunk)
        empty_evidence["evidence"] = []
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "nonempty"):
            CASCADE.validate_findings_response(json.dumps([empty_evidence]), chunk)
        forbidden = _finding(chunk)
        forbidden["eeg_label"] = "not permitted"
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "prohibited"):
            CASCADE.validate_findings_response(json.dumps([forbidden]), chunk)
        leaking = _finding(chunk)
        leaking["observation"] = "fixture confidential dialogue material alpha 0 stable"
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "source text"):
            CASCADE.validate_findings_response(json.dumps([leaking]), chunk)

    def test_loopback_acceptance_and_remote_rejection(self) -> None:
        for endpoint in ("http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434", "unix:///tmp/local-review.sock"):
            self.assertIn(CASCADE.classify_local_endpoint(endpoint), {"loopback", "unix_socket"})
        for endpoint in ("https://example.com", "http://192.168.1.10:11434", "http://localhost.evil:11434"):
            with self.assertRaises(CASCADE.ReviewContractError):
                CASCADE.classify_local_endpoint(endpoint)

    def test_missing_disposition_and_source_checksum_change_fail_closed(self) -> None:
        incomplete = _disposition()
        incomplete.pop("eligible_for_science")
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "disposition"):
            CASCADE.require_quarantine_disposition(incomplete)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.jsonl"
            original = b"synthetic-source"
            path.write_bytes(original)
            source = _source(1, source_path=path)
            source = CASCADE.SourceEnvelope(CASCADE.sha256_bytes(original), source.quarantine_report_sha256, source.disposition, source.records, path)
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(CASCADE.ReviewContractError, "changed"):
                CASCADE.build_chunk_envelopes(source, _configuration())

    def test_quarantine_report_checksum_mismatch_is_rejected(self) -> None:
        import quarantine_dialectic_corpus as quarantine

        turn = {
            "index": 1,
            "heard": "synthetic fixture only",
            "candidates": [
                {"text": "synthetic coherence", "roleID": "coherence-seeking"},
                {"text": "synthetic displacement", "roleID": "displacement-seeking"},
            ],
            "tension": 0.4,
            "margin": 0.1,
            "selectionTemperature": 0.2,
            "glossScalar": 0.5,
            "outcome": "synthesized:fixture",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "fixture.jsonl"
            report = root / "report.json"
            source.write_text(json.dumps(turn) + "\n")
            quarantine.inspect_corpus(source, report, root / "events.jsonl")
            source.write_text(json.dumps({**turn, "index": 2}) + "\n")
            with self.assertRaisesRegex(CASCADE.ReviewContractError, "does not match"):
                CASCADE.load_quarantined_source(source, report)

    def test_source_mutation_during_attempt_aborts_the_entire_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.jsonl"
            original = b"fixture-source-2"
            path.write_bytes(original)
            initial = _source(2, source_path=path)
            source = CASCADE.SourceEnvelope(CASCADE.sha256_bytes(original), initial.quarantine_report_sha256, initial.disposition, initial.records, path)
            chunk = CASCADE.build_chunk_envelopes(source, _configuration())[0]

            class MutatingBackend(CASCADE.MockLocalBackend):
                def invoke(self, **kwargs):
                    path.write_bytes(b"source-mutated-during-attempt")
                    return super().invoke(**kwargs)

            backend = MutatingBackend({"qwen3:0.6b": [json.dumps([_finding(chunk)])]})
            with self.assertRaisesRegex(CASCADE.ReviewContractError, "changed"):
                CASCADE.run_review_cascade(source, _configuration(), backend, _attestation())

    def test_retry_r1_failure_then_valid_r2_without_raw_response_handoff(self) -> None:
        source = _source(2)
        configuration = _configuration()
        chunk = CASCADE.build_chunk_envelopes(source, configuration)[0]
        invalid = json.dumps([_finding(chunk, citation_id="line:999")])
        valid = json.dumps([_finding(chunk)])
        backend = CASCADE.MockLocalBackend({"qwen3:0.6b": [invalid], "qwen3:4b": [valid]})
        run = CASCADE.run_review_cascade(source, configuration, backend, _attestation())
        result = run.chunk_results[0]
        self.assertEqual(result.review_status, "accepted")
        self.assertEqual([attempt.stage for attempt in result.attempts], ["R1", "R2"])
        self.assertEqual(backend.invocations[1]["previous_validation_error_codes"], ["citation_not_allowed"])
        self.assertEqual(backend.invocations[0]["system_prompt_sha256"], backend.invocations[1]["system_prompt_sha256"])

    def test_bounded_retry_count_and_all_attempts_rejected(self) -> None:
        source = _source(2)
        configuration = _configuration(maximum_attempts=2)
        backend = CASCADE.MockLocalBackend({"qwen3:0.6b": ["not-json"], "qwen3:4b": ["not-json"]})
        run = CASCADE.run_review_cascade(source, configuration, backend, _attestation())
        result = run.chunk_results[0]
        self.assertEqual(result.review_status, "rejected")
        self.assertEqual(len(result.attempts), 2)
        self.assertEqual(len(backend.invocations), 2)
        self.assertEqual(result.rejection_error_codes, ("invalid_json",))

    def test_local_attestations_and_explicit_r3_adjudication_boundary(self) -> None:
        source = _source(2)
        configuration = _configuration()
        chunk = CASCADE.build_chunk_envelopes(source, configuration)[0]
        valid = _finding(chunk)
        backend = CASCADE.MockLocalBackend({"gemma-family-local": [json.dumps([_finding(chunk, finding_id="critic-1")])]})
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "attest"):
            CASCADE.run_review_cascade(
                source,
                configuration,
                CASCADE.MockLocalBackend({"qwen3:0.6b": [json.dumps([valid])]}),
                CASCADE.OperatorAttestation(False, True),
            )
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "human request"):
            CASCADE.run_explicit_critic_adjudication(
                chunk=chunk,
                accepted_finding=valid,
                configuration=configuration,
                backend=backend,
                attestation=_attestation(),
                requested_by_human=False,
            )
        receipt = CASCADE.run_explicit_critic_adjudication(
            chunk=chunk,
            accepted_finding=valid,
            configuration=configuration,
            backend=backend,
            attestation=_attestation(),
            requested_by_human=True,
        )
        self.assertEqual(receipt["status"], "advisory_only")
        self.assertFalse(receipt["r0_override_permitted"])

    def test_aggregator_is_metadata_only_and_deterministic(self) -> None:
        source = _source(2)
        configuration = _configuration()
        chunk = CASCADE.build_chunk_envelopes(source, configuration)[0]
        backend = CASCADE.MockLocalBackend({"qwen3:0.6b": [json.dumps([_finding(chunk)])]})
        run = CASCADE.run_review_cascade(source, configuration, backend, _attestation())
        first = CASCADE.aggregate_review_results(run.chunk_results, source_sha256=source.source_sha256, disposition=source.disposition)
        second = CASCADE.aggregate_review_results(run.chunk_results, source_sha256=source.source_sha256, disposition=source.disposition)
        self.assertEqual(first, second)
        self.assertEqual(first["affected_source_lines"], [41])
        bad = run.chunk_results[0].persisted()
        bad["raw_record"] = _record(0)
        with self.assertRaisesRegex(CASCADE.ReviewContractError, "raw payload"):
            CASCADE.chunks_to_results([bad])

    def test_metadata_artifacts_never_persist_synthetic_source_content(self) -> None:
        source = _source(2)
        configuration = _configuration()
        chunk = CASCADE.build_chunk_envelopes(source, configuration)[0]
        backend = CASCADE.MockLocalBackend({"qwen3:0.6b": [json.dumps([_finding(chunk)])]})
        run = CASCADE.run_review_cascade(source, configuration, backend, _attestation())
        with tempfile.TemporaryDirectory() as directory:
            paths = CASCADE.write_metadata_only_artifacts(run, artifact_directory=Path(directory), repository_root=ROOT)
            serialized = "".join(path.read_text() for path in paths.values())
            self.assertNotIn("fixture confidential dialogue material", serialized)
            self.assertIn("pipeline_only", serialized)

    def test_cross_track_noninterference(self) -> None:
        report = NONINTERFERENCE.audit_noninterference(
            dialogue_source_sha256="a" * 64,
            dialogue_content_hashes=["b" * 64],
            review_finding_ids=["finding-1"],
            eeg_dataset_artifact={"dataset": "synthetic"},
            eeg_state_artifact={"state": "shadow_only"},
            eeg_model_input_manifest={"input": "canonical"},
            eeg_experiment_configuration={"experiment": "EXP-NC-EEG-ENC-001"},
            local_review_prompt_metadata={"schema": "chunk"},
            eeg_window_hashes=["c" * 64],
        )
        self.assertEqual(report["status"], "pass")
        with self.assertRaisesRegex(NONINTERFERENCE.NoninterferenceError, "source SHA"):
            NONINTERFERENCE.audit_noninterference(
                dialogue_source_sha256="a" * 64,
                dialogue_content_hashes=[],
                review_finding_ids=[],
                eeg_dataset_artifact={"source": "a" * 64},
                eeg_state_artifact={},
                eeg_model_input_manifest={},
                eeg_experiment_configuration={},
                local_review_prompt_metadata={},
                eeg_window_hashes=[],
            )

    def test_synthetic_structured_state_replay_remains_shadow_only(self) -> None:
        from neuralcompose_eeg.dataset import build_canonical_dataset
        from neuralcompose_eeg.structured_state import load_shadow_state_records, write_shadow_state_artifacts
        from NeuralComposeEEG.tests.test_pipeline import _manifest, _preprocessing_path

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset, _ = build_canonical_dataset(_manifest(root), _preprocessing_path())
            probabilities = np.zeros((len(dataset.labels), len(dataset.label_order)), dtype=np.float64)
            probabilities[:, 0] = 1.0
            # Publish under a subdirectory: _manifest(root) already wrote the
            # *source* manifest to root/manifest.json, and the shadow bridge
            # refuses to overwrite an existing artifact that differs.
            states = root / "shadow" / "states.jsonl"
            manifest = root / "shadow" / "manifest.json"
            written = write_shadow_state_artifacts(
                dataset,
                probabilities,
                encoder_provenance={"model_id": "fixture", "model_revision": "v0", "source_kind": "synthetic_contract_fixture"},
                states_output=states,
                manifest_output=manifest,
            )
            replay = load_shadow_state_records(states, manifest)
            self.assertEqual(written["status"], "insufficient_evidence")
            self.assertTrue(all(item["shadow_only"] for item in replay))
            self.assertFalse(any(item["live_control"] for item in replay))

    def test_decision_register_is_governance_only(self) -> None:
        entry = {
            "schema_version": REGISTER.DECISION_REGISTER_SCHEMA,
            "topic": "forward model foundations",
            "pass": 2,
            "owner": "science",
            "registered_question": "Does a specified forward model change a stated decision?",
            "decision_it_can_change": "Whether to register a separate forward-model experiment.",
            "required_data_gate": "D1",
            "falsification_criterion": "The model fails its preregistered error criterion.",
            "implementation_status": "deferred",
            "runtime_dependency_authorized": False,
        }
        self.assertEqual(REGISTER.validate_decision_register_entry(entry), entry)
        entry["runtime_dependency_authorized"] = True
        with self.assertRaisesRegex(REGISTER.DecisionRegisterError, "never authorize"):
            REGISTER.validate_decision_register_entry(entry)


if __name__ == "__main__":
    unittest.main()
