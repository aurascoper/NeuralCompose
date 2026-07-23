"""Contract tests for the D0 JEPA research scope."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DIAGNOSTICS_PATH = (
    REPO_ROOT / "docs" / "scoping" / "jepa-collapse-diagnostics-v0.json"
)
ENCODER_CONFIG_PATH = (
    REPO_ROOT / "NeuralComposeEEG" / "configs" / "experiment-v0.json"
)
EXPERIMENT_PATH = (
    REPO_ROOT
    / "NeuralComposeEEG"
    / "experiments"
    / "EXP-NC-EEG-JEPA-001.md"
)
MEMO_PATH = (
    REPO_ROOT
    / "docs"
    / "research"
    / "jepa-four-channel-eeg-decision-memo-v0.md"
)


class JEPAScopeContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = json.loads(DIAGNOSTICS_PATH.read_text())

    def test_scope_is_d0_non_runtime_and_non_promotable(self) -> None:
        self.assertEqual(
            self.contract["schema_version"],
            "nc-eeg-jepa-collapse-diagnostics-v0",
        )
        self.assertEqual(self.contract["experiment_id"], "EXP-NC-EEG-JEPA-001")
        self.assertEqual(self.contract["status"], "scope_complete")
        self.assertEqual(self.contract["track"], "Pass_1.5_non_runtime")
        self.assertEqual(self.contract["data_gate"], "D0")
        self.assertEqual(
            self.contract["decision"],
            "foundational_study_only",
        )
        self.assertEqual(self.contract["promotion_status"], "not_eligible")
        self.assertFalse(self.contract["live_control"])
        self.assertFalse(self.contract["runtime_dependency_authorized"])
        self.assertFalse(self.contract["live_inference_authorized"])
        self.assertFalse(self.contract["laya_download_or_training_authorized"])

    def test_execution_gates_and_j6_block_are_pinned(self) -> None:
        gates = self.contract["execution_gates"]
        self.assertEqual(
            set(gates),
            {"D0", "D1", "D2", "D3", "post_encoder"},
        )
        self.assertIn("no_jepa_training", gates["D1"])
        self.assertIn("no_confirmation_or_promotion", gates["D2"])
        self.assertIn("fold_local_pretraining", gates["D3"])
        self.assertIn("action_conditioned", gates["post_encoder"])

        j6 = self.contract["j6_gate"]
        self.assertEqual(j6["status"], "blocked")
        self.assertEqual(
            set(j6["requires"]),
            {
                "reproducible_pinned_implementation",
                "pinned_checkpoint",
                "compatible_channel_mapping",
                "matched_compute_controls",
                "license_review",
            },
        )

    def test_all_required_collapse_diagnostics_are_registered(self) -> None:
        required = {
            "per_dimension_variance",
            "covariance_off_diagonal_magnitude",
            "singular_value_spectrum",
            "entropy_effective_rank",
            "energy_rank",
            "condition_number",
            "mean_pairwise_distance",
            "nearest_neighbor_session_identity",
            "constant_output_check",
            "feature_utilization",
            "predictor_loss",
            "regularization_loss",
            "linear_probe_performance",
        }
        registered = {
            diagnostic["id"]
            for diagnostic in self.contract["diagnostics"]
            if diagnostic["required"]
        }
        self.assertEqual(registered, required)
        self.assertEqual(
            self.contract["measurement_frequency"]["trainable_conditions"],
            "every_epoch_on_training_and_inner_validation_groups",
        )
        self.assertEqual(
            self.contract["measurement_frequency"]["outer_held_out_group"],
            "once_after_complete_condition_freeze",
        )

    def test_negative_controls_and_train_only_threshold_policy_are_pinned(
        self,
    ) -> None:
        expected_controls = {
            "temporal_target_permutation",
            "different_session_target",
            "channel_coordinate_shuffle",
            "channel_order_shuffle",
            "mask_location_shuffle",
            "no_regularization",
            "constant_embedding",
            "random_encoder",
            "matched_reconstruction",
        }
        self.assertEqual(
            set(self.contract["required_negative_controls"]),
            expected_controls,
        )
        self.assertFalse(
            self.contract["threshold_policy"]["held_out_threshold_fitting_allowed"]
        )
        self.assertFalse(
            self.contract["threshold_policy"]["outer_group_selects_epoch_or_condition"]
        )
        self.assertIn(
            "predictor-output-only",
            self.contract["regularization_application_rule"],
        )
        self.assertFalse(
            self.contract["interpretation_rules"]["geometry_alone_supports_model"]
        )
        self.assertFalse(
            self.contract["interpretation_rules"][
                "reconstruction_error_proves_noncollapse"
            ]
        )

    def test_current_encoder_experiment_remains_the_m0_to_m4_pilot(self) -> None:
        encoder = json.loads(ENCODER_CONFIG_PATH.read_text())
        self.assertEqual(encoder["experiment_id"], "EXP-NC-EEG-ENC-001")
        self.assertEqual(
            {"m0", "m1", "m2_m3", "m4"},
            {"m0", "m1", "m2_m3", "m4"} & set(encoder),
        )
        self.assertFalse(any(key.startswith("j") for key in encoder))
        self.assertEqual(encoder["status"], "pipeline_pilot_only")
        self.assertEqual(encoder["promotion_status"], "not_eligible")

    def test_scope_documents_keep_jepa_separate_from_the_runtime(self) -> None:
        experiment = EXPERIMENT_PATH.read_text()
        memo = MEMO_PATH.read_text()
        self.assertIn("This experiment is separate from", experiment)
        self.assertIn("Runtime dependency:** prohibited", experiment)
        self.assertIn("implement_live_JEPA: false", memo)
        self.assertIn("modify_EXP_NC_EEG_ENC_001: false", memo)
        self.assertIn("download_or_train_Laya_now: false", memo)
        self.assertIn("status: scope_complete", memo)
        self.assertIn("track: Pass_1.5_non_runtime", memo)
        self.assertIn('"retrieved_date": "2026-07-23"', memo)
        self.assertEqual(memo.count('"claim_scope": "background evidence only"'), 2)

    def test_experiment_pins_the_complete_condition_and_outcome_sets(self) -> None:
        experiment = EXPERIMENT_PATH.read_text()
        condition_ids = set(
            re.findall(r"^\| (J[0-6]) \|", experiment, flags=re.MULTILINE)
        )
        self.assertEqual(condition_ids, {f"J{index}" for index in range(7)})

        for outcome in (
            "balanced accuracy",
            "macro F1",
            "Brier score",
            "expected calibration error",
            "artifact sensitivity and specificity",
            "cross-session degradation",
            "data-efficiency curves",
            "channel dropout",
            "EMG-like noise",
            "movement artifacts",
        ):
            self.assertIn(outcome, experiment)


if __name__ == "__main__":
    unittest.main()
