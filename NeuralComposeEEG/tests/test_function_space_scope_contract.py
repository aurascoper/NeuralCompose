"""Governance tests for the synthetic-only function-space foundations package."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = REPO_ROOT / "configs" / "function-space-foundations-v0.json"
MEMO_PATH = (
    REPO_ROOT
    / "docs"
    / "research"
    / "function-space-foundations-decision-memo-v0.md"
)
COMPATIBILITY_NOTE = (
    REPO_ROOT / "docs" / "science" / "sobolev-zpd-hypotheses.md"
)
FUNCTION_SPACE_NOTE = (
    REPO_ROOT / "docs" / "science" / "function-space-operator-hypotheses.md"
)
ZPD_NOTE = REPO_ROOT / "docs" / "science" / "zpd-intervention-hypotheses.md"
ENCODER_CONFIG_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "configs" / "experiment-v0.json"
)
SIBLING_CONTRACT_PATH = (
    REPO_ROOT.parent
    / "NeuralComposeScience"
    / "configs"
    / "function-space-foundations-v0.json"
)


class FunctionSpaceScopeContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = json.loads(CONTRACT_PATH.read_text())

    def test_fixed_d0_disposition_is_nonphysical_and_nonpromotable(self) -> None:
        expected = {
            "schema_version": "function-space-foundations-config-v0",
            "report_schema_version": "function-space-foundations-report-v0",
            "experiment_id": "EXP-FUNC-SYN-000",
            "status": "foundational_study_only",
            "data_gate": "D0",
            "decision": "insufficient_evidence",
            "promotion_status": "not_eligible",
            "runtime_change": "none",
            "physical_eeg_used": False,
            "dialogue_logs_used": False,
            "fallback_capture_used": False,
            "scientific_claim_allowed": False,
        }
        for key, value in expected.items():
            self.assertEqual(self.contract[key], value)

    def test_input_policy_has_no_external_or_private_data_path(self) -> None:
        policy = self.contract["input_policy"]
        self.assertEqual(
            policy["source_kind"],
            "embedded_deterministic_synthetic_parameters",
        )
        for key, value in policy.items():
            if key != "source_kind":
                self.assertIs(value, False, key)

        source_files = self.contract["source_files"]
        self.assertTrue(source_files)
        for relative in source_files:
            self.assertFalse(Path(relative).is_absolute())
            self.assertNotIn("..", Path(relative).parts)

    def test_fs0_through_fs5_are_complete_and_pinned(self) -> None:
        studies = self.contract["studies"]
        self.assertEqual(set(studies), {f"FS{index}" for index in range(6)})
        self.assertEqual(
            studies["FS0"]["sample_points"],
            [0.0, 0.25, 0.5, 0.75, 1.0],
        )
        self.assertEqual(
            studies["FS1"]["finite_difference_scheme"],
            "forward",
        )
        self.assertEqual(studies["FS2"]["basis"]["kind"], "fourier")
        self.assertIn(0.0, studies["FS2"]["regularization_grid"])
        self.assertEqual(
            set(studies["FS2"]["sessions"]),
            {"training", "validation", "held_out"},
        )
        self.assertEqual(studies["FS3"]["sequence"], "x^n")
        self.assertEqual(studies["FS4"]["induced_matrix_norm"], "spectral_l2")
        self.assertEqual(
            studies["FS5"]["measure_language"],
            "lebesgue_stieltjes_mixed_measure",
        )

    def test_representation_regularization_remains_in_existing_jepa_scope(
        self,
    ) -> None:
        boundary = self.contract["representation_regularization_boundary"]
        self.assertFalse(boundary["implemented_here"])
        self.assertFalse(boundary["new_trainer_authorized"])
        self.assertEqual(
            boundary["existing_contracts"],
            [
                "EXP-NC-EEG-JEPA-001:J2-J5",
                "jepa-collapse-diagnostics-v0",
            ],
        )

    def test_physical_encoder_contract_is_unchanged_by_function_space_scope(
        self,
    ) -> None:
        encoder = json.loads(ENCODER_CONFIG_PATH.read_text())
        self.assertEqual(encoder["experiment_id"], "EXP-NC-EEG-ENC-001")
        self.assertEqual(encoder["status"], "pipeline_pilot_only")
        self.assertEqual(encoder["promotion_status"], "not_eligible")
        self.assertNotIn("function_space", encoder)
        self.assertNotIn("sobolev", encoder)
        self.assertNotIn("automatic_differentiation", encoder)

    def test_docs_preserve_theory_and_policy_boundaries(self) -> None:
        memo = MEMO_PATH.read_text()
        compatibility = COMPATIBILITY_NOTE.read_text()
        function_space = FUNCTION_SPACE_NOTE.read_text()
        zpd = ZPD_NOTE.read_text()

        self.assertIn("does not stabilize or recover", memo)
        self.assertIn("theorem illustration", memo)
        self.assertIn("$R_0(f;(a,b))$", memo)
        self.assertIn("implementation consequence is inferred", memo)
        self.assertIn("No proposition numbers are asserted", memo)
        self.assertIn("background evidence only", memo)
        self.assertIn("function-space-operator-hypotheses.md", compatibility)
        self.assertIn("zpd-intervention-hypotheses.md", compatibility)
        self.assertIn("No such physical-data study is authorized", function_space)
        self.assertIn("It is not part of `EXP-FUNC-SYN-000`", zpd)

    def test_adjacent_science_contract_is_byte_identical_when_available(
        self,
    ) -> None:
        if not SIBLING_CONTRACT_PATH.exists():
            self.skipTest("independent NeuralComposeScience workspace is absent")
        self.assertEqual(
            CONTRACT_PATH.read_bytes(),
            SIBLING_CONTRACT_PATH.read_bytes(),
        )


if __name__ == "__main__":
    unittest.main()
