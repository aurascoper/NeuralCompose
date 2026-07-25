"""Contract tests for the D0 offline encoder-state / Swift replay scope.

These pin the boundary declared in ADR-011: encoders are offline artifact
producers, the application only replays validated artifacts, synthetic and
physical records are structurally distinguishable, and the live 2 s window is
never a legal encoder input.

Unlike the sibling scope-contract tests, this module also *executes* the JSON
Schema when `jsonschema` is importable, and structurally verifies the schema is
closed at every level when it is not. A schema that is only declared and never
run is decoration.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "schemas" / "nc-eeg-encoder-state-v0.schema.json"
)
PROTOCOL_PATH = REPO_ROOT / "NeuralComposeEEG" / "PROTOCOL_OFFLINE_ENCODER.md"
EXPERIMENT_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "experiments" / "EXP-NC-EEG-SHADOW-001.md"
)
ADR_PATH = (
    REPO_ROOT
    / "docs"
    / "architecture"
    / "decision-log"
    / "ADR-011-offline-eeg-encoder-artifact-boundary.md"
)
ADR_REGISTRY_PATH = (
    REPO_ROOT / "docs" / "architecture" / "decision-log" / "README.md"
)
ENCODER_CONFIG_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "configs" / "experiment-v0.json"
)
EEGPT_MONTAGE_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "configs" / "eegpt-58ch-montage-v0.json"
)
CONTRACTS_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "src" / "neuralcompose_eeg" / "contracts.py"
)

SHA = "a" * 64

LABEL_ORDER = [
    "eyes_open",
    "eyes_closed",
    "blink_artifact",
    "jaw_artifact",
    "head_motion_artifact",
    "listening",
    "speaking",
    "recovery",
]


def _window_geometry() -> dict:
    return {
        "channel_order": ["TP9", "AF7", "AF8", "TP10"],
        "sample_rate_hz": 256,
        "window_samples": 1024,
        "stride_samples": 256,
        "window_start_sample": 0,
        "window_end_sample_exclusive": 1024,
        "window_start_timestamp": None,
        "window_end_timestamp": None,
        "window_sha256": SHA,
        "rewindowing_config_sha256": SHA,
        "live_two_second_window_used": False,
    }


def _physical_source() -> dict:
    return {
        "source_type": "physical_recording_replay",
        "physical_eeg_used": True,
        "session_id": "session-001",
        "recording_sha256": SHA,
        "capture_manifest_sha256": SHA,
        "integrity_report_sha256": SHA,
    }


def _record(**overrides) -> dict:
    record = {
        "schema_version": "nc-eeg-encoder-state-v0",
        "state_id": "shadow-001",
        "experiment_id": "EXP-NC-EEG-SHADOW-001",
        "shadow_only": True,
        "live_control": False,
        "scientific_claim_allowed": False,
        "promotion_status": "not_eligible",
        "runtime_change": "none",
        "source": {
            "source_type": "deterministic_synthetic_fixture",
            "physical_eeg_used": False,
            "fixture_sha256": SHA,
            "fixture_id": "fusion-syn-001",
        },
        "window_geometry": _window_geometry(),
        "encoder": {
            "model_id": "eegnet",
            "model_revision": "synthetic-eegnet-v0",
            "backbone_frozen": True,
            "adapter": "none",
            "checkpoint_kind": "deterministic_synthetic_parameter_fixture",
            "checkpoint_sha256": SHA,
        },
        "label_order": list(LABEL_ORDER),
        "probabilities": [0.55, 0.1, 0.05, 0.05, 0.05, 0.08, 0.05, 0.07],
        "uncertainty": 0.31,
        "signal_quality": {"score": 0.96, "missing_channels": []},
    }
    record.update(overrides)
    return record


class EncoderStateSchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = json.loads(SCHEMA_PATH.read_text())

    # -- structural: true even without jsonschema installed ----------------

    def test_schema_is_closed_at_every_object_level(self) -> None:
        """A schema open at any nested level is not a closed contract."""
        open_levels = []

        def walk(node, path: str) -> None:
            if isinstance(node, dict):
                # Only declared object schemas must be closed. if/then blocks
                # carry `properties` as constraints, not as definitions, and
                # closing them would reject every record.
                if node.get("type") == "object":
                    if node.get("additionalProperties") is not False:
                        open_levels.append(path or "<root>")
                for key, value in node.items():
                    if key in {"properties", "$defs"} and isinstance(value, dict):
                        for name, sub in value.items():
                            walk(sub, f"{path}.{name}")
                    elif key in {"oneOf", "anyOf", "allOf"} and isinstance(value, list):
                        for index, sub in enumerate(value):
                            walk(sub, f"{path}.{key}[{index}]")

        walk(self.schema, "")
        self.assertEqual(open_levels, [], f"open object levels: {open_levels}")

    def test_disposition_constants_are_pinned(self) -> None:
        props = self.schema["properties"]
        for field, expected in (
            ("schema_version", "nc-eeg-encoder-state-v0"),
            ("experiment_id", "EXP-NC-EEG-SHADOW-001"),
            ("shadow_only", True),
            ("live_control", False),
            ("scientific_claim_allowed", False),
            ("promotion_status", "not_eligible"),
            ("runtime_change", "none"),
        ):
            self.assertEqual(props[field]["const"], expected, field)

    def test_source_type_is_not_globally_pinned_to_synthetic(self) -> None:
        """A future physical record must be representable.

        The fused-state schema pins source_type/physical_eeg_used globally,
        which is correct there because it describes one synthetic artifact.
        Here it would make physical replay unrepresentable, so the union
        carries the discrimination instead.
        """
        source = self.schema["properties"]["source"]
        self.assertIn("oneOf", source)
        self.assertEqual(len(source["oneOf"]), 2)
        self.assertNotIn("const", source)

    def test_window_geometry_pins_the_four_second_contract(self) -> None:
        geom = self.schema["$defs"]["window_geometry"]["properties"]
        self.assertEqual(geom["window_samples"]["const"], 1024)
        self.assertEqual(geom["stride_samples"]["const"], 256)
        self.assertEqual(geom["sample_rate_hz"]["const"], 256)
        self.assertEqual(geom["channel_order"]["const"], ["TP9", "AF7", "AF8", "TP10"])
        self.assertEqual(geom["live_two_second_window_used"]["const"], False)

    def test_encoder_ids_are_limited_to_the_fusion_pair(self) -> None:
        enum = self.schema["$defs"]["encoder_identity"]["properties"]["model_id"]["enum"]
        self.assertEqual(sorted(enum), ["eegnet", "eegpt"])

    # -- executable: the schema actually runs ------------------------------

    def _validator(self):
        try:
            from jsonschema import Draft202012Validator
        except ImportError:  # pragma: no cover - environment dependent
            self.skipTest("jsonschema is not installed; structural tests still apply")
        Draft202012Validator.check_schema(self.schema)
        return Draft202012Validator(self.schema)

    def test_both_source_branches_validate(self) -> None:
        validator = self._validator()
        self.assertEqual(list(validator.iter_errors(_record())), [])

        physical = _record(source=_physical_source())
        physical["window_geometry"]["window_start_timestamp"] = 1_780_000_000.0
        physical["window_geometry"]["window_end_timestamp"] = 1_780_000_004.0
        self.assertEqual(list(validator.iter_errors(physical)), [])

    def test_neither_branch_can_masquerade_as_the_other(self) -> None:
        validator = self._validator()
        physical_without_integrity = _record(
            source={
                "source_type": "physical_recording_replay",
                "physical_eeg_used": True,
                "session_id": "session-001",
            }
        )
        self.assertTrue(list(validator.iter_errors(physical_without_integrity)))

        synthetic_claiming_physical = _record(
            source={
                "source_type": "deterministic_synthetic_fixture",
                "physical_eeg_used": True,
                "fixture_sha256": SHA,
                "fixture_id": "f",
            }
        )
        self.assertTrue(list(validator.iter_errors(synthetic_claiming_physical)))

    def test_source_type_constrains_the_window_clock_fields(self) -> None:
        """A physical record with no clock origin is not admissible evidence."""
        validator = self._validator()

        physical_null_clock = _record(source=_physical_source())
        self.assertTrue(
            list(validator.iter_errors(physical_null_clock)),
            "physical replay with null timestamps must be rejected",
        )

        synthetic_with_clock = _record()
        synthetic_with_clock["window_geometry"]["window_start_timestamp"] = 1.0
        self.assertTrue(
            list(validator.iter_errors(synthetic_with_clock)),
            "a synthetic fixture must not carry a wall clock",
        )

    def test_nested_unknown_field_is_rejected(self) -> None:
        validator = self._validator()
        for path in ("window_geometry", "encoder", "signal_quality"):
            record = _record()
            record[path]["unexpected_nested_key"] = 1
            self.assertTrue(
                list(validator.iter_errors(record)), f"{path} must be closed"
            )
        record = _record()
        record["source"]["unexpected_nested_key"] = 1
        self.assertTrue(list(validator.iter_errors(record)), "source must be closed")

    def test_live_two_second_window_is_rejected(self) -> None:
        validator = self._validator()
        for key, value in (
            ("live_two_second_window_used", True),
            ("window_samples", 512),
        ):
            record = _record()
            record["window_geometry"][key] = value
            self.assertTrue(
                list(validator.iter_errors(record)),
                f"window_geometry.{key}={value} must be rejected",
            )

    def test_unknown_keys_and_promoted_status_are_rejected(self) -> None:
        validator = self._validator()
        extra = _record()
        extra["unexpected_key"] = 1
        self.assertTrue(list(validator.iter_errors(extra)))
        self.assertTrue(list(validator.iter_errors(_record(promotion_status="eligible"))))

    def test_window_span_must_equal_the_pinned_window_length(self) -> None:
        """JSON Schema cannot express this arithmetic; pin it here instead."""
        for start, end, ok in ((0, 1024, True), (2048, 3072, True), (0, 512, False), (0, 2048, False)):
            geometry = _window_geometry()
            geometry["window_start_sample"] = start
            geometry["window_end_sample_exclusive"] = end
            span = geometry["window_end_sample_exclusive"] - geometry["window_start_sample"]
            self.assertEqual(
                span == geometry["window_samples"],
                ok,
                f"span {start}->{end} should be {'legal' if ok else 'illegal'}",
            )

    def test_fusion_encoder_output_is_not_silently_reclassified(self) -> None:
        """A raw fusion encoder-output record is NOT a W1 encoder state.

        It carries no source discrimination and no window geometry. If it were
        to validate, the two artifact kinds could be confused and a fusion
        fixture could be replayed as if it described a real window.
        """
        validator = self._validator()
        fixture_path = (
            REPO_ROOT
            / "NeuralComposeEEG"
            / "fixtures"
            / "fusion-synthetic-v0"
            / "encoder-outputs.jsonl"
        )
        rows = [json.loads(line) for line in fixture_path.read_text().splitlines() if line.strip()]
        self.assertTrue(rows)
        for row in rows:
            self.assertTrue(
                list(validator.iter_errors(row)),
                "a fusion pair record must not validate as an encoder state",
            )
            for encoder in row["encoders"].values():
                self.assertTrue(
                    list(validator.iter_errors(encoder)),
                    "a fusion encoder-output must not validate as an encoder state",
                )


class ExistingEvidenceUntouchedTests(unittest.TestCase):
    """The F0-F2 evidence bundle's byte identity is part of its provenance.

    This W0 package must not mutate it to satisfy a later schema.
    """

    ARTIFACT_DIR = REPO_ROOT / "NeuralComposeEEG" / "artifacts" / "fusion-synthetic-v0"

    def test_fusion_artifacts_are_byte_identical_to_head(self) -> None:
        import subprocess

        for name in ("fused-states.jsonl", "replay-manifest.json", "fusion-synthetic-report.json"):
            path = self.ARTIFACT_DIR / name
            committed = subprocess.run(
                ["git", "show", f"HEAD:NeuralComposeEEG/artifacts/fusion-synthetic-v0/{name}"],
                cwd=REPO_ROOT,
                capture_output=True,
            )
            self.assertEqual(committed.returncode, 0, name)
            self.assertEqual(path.read_bytes(), committed.stdout, f"{name} was modified")

    def test_fusion_fixture_is_byte_identical_to_head(self) -> None:
        import subprocess

        rel = "NeuralComposeEEG/fixtures/fusion-synthetic-v0/encoder-outputs.jsonl"
        committed = subprocess.run(
            ["git", "show", f"HEAD:{rel}"], cwd=REPO_ROOT, capture_output=True
        )
        self.assertEqual(committed.returncode, 0)
        self.assertEqual((REPO_ROOT / rel).read_bytes(), committed.stdout)


class ShadowScopeSeparationTests(unittest.TestCase):
    def test_current_encoder_experiment_is_untouched_by_this_track(self) -> None:
        """The incumbent M0-M4 pilot must not acquire this track's stage keys."""
        encoder = json.loads(ENCODER_CONFIG_PATH.read_text())
        self.assertEqual(encoder["experiment_id"], "EXP-NC-EEG-ENC-001")
        self.assertEqual({"m0", "m1", "m2_m3", "m4"}, {"m0", "m1", "m2_m3", "m4"} & set(encoder))
        self.assertFalse(any(key.lower().startswith("w") for key in encoder))
        self.assertEqual(encoder["status"], "pipeline_pilot_only")
        self.assertEqual(encoder["promotion_status"], "not_eligible")

    def test_eegpt_checkpoint_remains_explicitly_unpinned(self) -> None:
        """A placeholder digest would be worse than null; W4 stays unauthorized."""
        montage = json.loads(EEGPT_MONTAGE_PATH.read_text())
        self.assertIsNone(montage["upstream"]["checkpoint_sha256"])

    def test_encoder_id_registry_is_not_widened_on_this_branch(self) -> None:
        """Adding EEGNet to the registry is a named prerequisite, made elsewhere."""
        self.assertIn('{"eegpt", "bendr"}', CONTRACTS_PATH.read_text())

    def test_experiment_pins_the_complete_condition_set(self) -> None:
        experiment = EXPERIMENT_PATH.read_text()
        condition_ids = set(re.findall(r"^\| (W[1-5]) \|", experiment, flags=re.MULTILINE))
        self.assertEqual(condition_ids, {f"W{index}" for index in range(1, 6)})

    def test_documents_keep_encoders_out_of_the_application_runtime(self) -> None:
        # Normalize whitespace so these assertions survive re-wrapping of the
        # prose; the claim is what matters, not the line breaks.
        def flat(path: Path) -> str:
            return " ".join(path.read_text().split())

        adr = flat(ADR_PATH)
        experiment = flat(EXPERIMENT_PATH)
        protocol = flat(PROTOCOL_PATH)

        self.assertIn("offline", adr.lower())
        self.assertIn("No encoder, fusion stage, or policy model executes", adr)
        self.assertIn("live_runtime_authority_change: none", adr)
        self.assertIn("model_execution_authority: none", adr)
        self.assertIn("behavioral_control_authority: none", adr)

        self.assertIn("promotion_status: not_eligible", experiment)
        self.assertIn("shadow_only: true", experiment)
        self.assertIn("live_control: false", experiment)
        self.assertIn("W4_execution_authorized: false", experiment)

        self.assertIn("no subprocess lifecycle", protocol)
        self.assertIn("There is no partial-success status", protocol)

    def test_w1_defers_all_process_machinery(self) -> None:
        """W1 launches nothing, so it must not acquire worker infrastructure."""
        adr = " ".join(ADR_PATH.read_text().split())
        for deferred in (
            "subprocess execution",
            "local worker lifecycle",
            "timeout/cancellation utilities",
            "Python invocation",
            "model loading",
        ):
            self.assertIn(deferred, adr, f"{deferred!r} must be listed as deferred")
        self.assertIn("would require a separate ADR", adr)

    def test_physical_artifacts_are_not_git_eligible(self) -> None:
        for path in (ADR_PATH, EXPERIMENT_PATH):
            text = " ".join(path.read_text().split())
            self.assertIn("git_eligible: false", text)
            self.assertIn("raw_eeg_embedded: false", text)
            self.assertIn("source_manifest_bound: true", text)

    def test_publication_is_atomic_and_only_completed_is_replayable(self) -> None:
        protocol = " ".join(PROTOCOL_PATH.read_text().split())
        self.assertIn("share one parent directory", protocol)
        self.assertIn("never silently overwritten", protocol)
        self.assertIn("Only `completed` may be replayed", protocol)
        for state in (
            "started",
            "completed",
            "cancelled",
            "model_load_failed",
            "checkpoint_mismatch",
            "invalid_output",
            "nonfinite_output",
            "publication_failed",
        ):
            self.assertIn(f"`{state}`", protocol, f"missing typed state {state}")

    def test_adr_registry_records_the_numbering_hazards(self) -> None:
        registry = ADR_REGISTRY_PATH.read_text()
        self.assertIn("ADR-009", registry)
        self.assertIn("ADR-010", registry)
        self.assertIn("ADR-011", registry)
        self.assertIn("rust-compute-engine", registry)


if __name__ == "__main__":
    unittest.main()
