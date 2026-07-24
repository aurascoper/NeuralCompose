"""Contract tests for function-space provenance in SVD and JEPA scopes."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SVD_REGISTER_PATH = (
    REPO_ROOT / "docs" / "scoping" / "svd-decision-register-v0.json"
)
JEPA_CONTRACT_PATH = (
    REPO_ROOT / "docs" / "scoping" / "jepa-collapse-diagnostics-v0.json"
)
SVD_MEMO_PATH = (
    REPO_ROOT / "docs" / "research" / "svd-four-channel-eeg-decision-memo_v1.md"
)
JEPA_MEMO_PATH = (
    REPO_ROOT / "docs" / "research" / "jepa-four-channel-eeg-decision-memo-v0.md"
)

EXPECTED_REFERENCE = {
    "experiment_id": "EXP-FUNC-SYN-000",
    "status": "foundational_study_only",
    "report_sha256": (
        "5625b616a846c58978ec4b965c2e717509fbc60990b129da36987813c0414b0e"
    ),
    "contract_sha256": (
        "6a08b3a3ff717f98bd40d37bcb35cc4745097e0a72013ec852fd081747c1d1c3"
    ),
    "science_workspace_commit": "8eafaea",
    "synthetic_jepa_isolation_commit": "ba7822b",
    "claim_scope": "mathematical and implementation reference only",
    "physical_thresholds_derived": False,
    "runtime_dependency_authorized": False,
}


class FunctionSpaceTrackProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.svd = json.loads(SVD_REGISTER_PATH.read_text())
        self.jepa = json.loads(JEPA_CONTRACT_PATH.read_text())

    def test_tracks_pin_the_same_foundational_reference(self) -> None:
        self.assertEqual(self.svd["foundational_reference"], EXPECTED_REFERENCE)
        self.assertEqual(self.jepa["foundational_reference"], EXPECTED_REFERENCE)

    def test_reference_does_not_change_track_dispositions(self) -> None:
        self.assertEqual(self.svd["document_status"], "foundational_study_only")
        self.assertEqual(self.svd["current_data_gate"], "D0")
        self.assertEqual(self.svd["promotion_status"], "not_eligible")
        self.assertTrue(
            all(
                not entry["runtime_dependency_authorized"]
                for entry in self.svd["entries"]
            )
        )

        self.assertEqual(self.jepa["status"], "scope_complete")
        self.assertEqual(self.jepa["track"], "Pass_1.5_non_runtime")
        self.assertEqual(self.jepa["data_gate"], "D0")
        self.assertEqual(self.jepa["promotion_status"], "not_eligible")
        self.assertFalse(self.jepa["runtime_dependency_authorized"])
        self.assertFalse(self.jepa["live_inference_authorized"])

    def test_memos_pin_the_allowed_track_specific_interpretations(self) -> None:
        svd_memo = SVD_MEMO_PATH.read_text()
        for phrase in (
            "operator norms and measured perturbation amplification",
            "pseudoinverse instability",
            "retained-rank sensitivity",
            "controlled truncated-SVD versus ridge/Tikhonov comparisons",
            "does not establish physical EEG stability",
        ):
            self.assertIn(phrase, svd_memo)

        jepa_memo = JEPA_MEMO_PATH.read_text()
        for phrase in (
            "empirical-pseudometric vocabulary",
            "singular spectra, effective",
            "No Sobolev term is added to J0-J6",
            "Egorov's theorem is never a threshold",
            "leaving all JEPA losses, gates, thresholds, and runtime",
        ):
            self.assertIn(phrase, jepa_memo)


if __name__ == "__main__":
    unittest.main()
