from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from neuralcompose_eeg.contracts import ContractError, load_source_manifest
from neuralcompose_eeg.fusion_contract import (
    QWEN_OUTPUT_SCHEMA,
    REPORT_SCHEMA,
    STATE_SCHEMA,
    build_fused_state,
    calibration_metrics,
    condition_probabilities,
    load_fused_state_replay,
    load_fusion_contract,
    load_synthetic_fixtures,
    render_qwen_shadow_input,
    run_synthetic_fusion_fixture,
    validate_fusion_contract,
    validate_fused_state,
    validate_qwen_shadow_output,
    validate_synthetic_fixture,
    write_synthetic_fusion_artifacts,
)


EEG_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = EEG_ROOT / "configs" / "fusion-synthetic-v0.json"
STATE_SCHEMA_PATH = EEG_ROOT / "schemas" / "nc-eeg-fused-state-v0.schema.json"
ARTIFACT_ROOT = EEG_ROOT / "artifacts" / "fusion-synthetic-v0"


class FusionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = load_fusion_contract(CONTRACT_PATH)
        cls.fixtures = load_synthetic_fixtures(cls.contract, CONTRACT_PATH)

    def test_contract_pins_late_fusion_and_preserves_encoder_program(self) -> None:
        architecture = self.contract["architecture"]
        self.assertEqual(architecture["method"], "late_representation_fusion")
        self.assertTrue(architecture["m0_m4_unchanged"])
        for key in (
            "direct_weight_fusion",
            "joint_end_to_end_training_now",
            "eegnet_eegpt_tensor_merge",
            "eeg_encoder_qwen_tensor_merge",
            "joint_raw_eeg_language_training",
            "online_weight_updates",
        ):
            self.assertFalse(architecture[key])
        self.assertEqual(
            [condition["id"] for condition in self.contract["conditions"]],
            ["F0", "F1", "F2", "F3", "F4", "F5", "F6"],
        )
        self.assertEqual(self.contract["current_execution"]["state_emitting_conditions"], ["F2"])
        self.assertEqual(
            next(item for item in self.contract["conditions"] if item["id"] == "F3")["earliest_physical_gate"],
            "D3",
        )
        self.assertEqual(
            next(item for item in self.contract["conditions"] if item["id"] == "F6")["earliest_physical_gate"],
            "post_fusion_evidence",
        )

    def test_contract_pins_controls_and_current_prohibitions(self) -> None:
        self.assertEqual(
            set(self.contract["controls"]),
            {
                "eegnet_alone",
                "eegpt_alone",
                "fixed_probability_average",
                "randomly_initialized_eegpt_same_adapter",
                "shuffled_eegpt_embeddings",
                "shuffled_eegnet_embeddings",
                "matched_dimension_noise_encoder",
                "matched_parameter_count_fusion_head",
                "session_identity_probe",
                "channel_map_shuffle",
                "missing_channel_control",
            },
        )
        forbidden = set(self.contract["current_execution"]["forbidden"])
        self.assertTrue(
            {
                "physical_data_read",
                "encoder_training",
                "fusion_head_training",
                "qwen_model_execution",
                "qwen_weight_update",
                "threshold_selection",
                "runtime_integration",
                "live_control",
            }.issubset(forbidden)
        )

    def test_fixtures_are_bounded_synthetic_encoder_outputs(self) -> None:
        self.assertEqual(len(self.fixtures), 6)
        for fixture in self.fixtures:
            self.assertEqual(fixture["source_kind"], "synthetic_contract_fixture")
            self.assertEqual(fixture["source_type"], "deterministic_synthetic_fixture")
            self.assertFalse(fixture["physical_eeg_used"])
            self.assertFalse(fixture["scientific_claim_allowed"])
            self.assertTrue(fixture["shadow_only"])
            self.assertEqual(set(fixture["encoders"]), {"eegnet", "eegpt"})
            self.assertTrue(fixture["encoders"]["eegnet"]["backbone_frozen"])
            self.assertTrue(fixture["encoders"]["eegpt"]["backbone_frozen"])
            self.assertEqual(fixture["encoders"]["eegpt"]["adapter"], "four_channel_adapter_synthetic_fixture_v0")
            for encoder in fixture["encoders"].values():
                self.assertAlmostEqual(sum(encoder["probabilities"]), 1.0, places=12)
                self.assertEqual(encoder["checkpoint_kind"], "deterministic_synthetic_parameter_fixture")
                self.assertRegex(encoder["checkpoint_sha256"], r"^[0-9a-f]{64}$")
            self.assertNotEqual(
                fixture["encoders"]["eegnet"]["checkpoint_sha256"],
                fixture["encoders"]["eegpt"]["checkpoint_sha256"],
            )

    def test_f2_emits_the_only_d0_fused_state(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        self.assertEqual(state["schema_version"], STATE_SCHEMA)
        self.assertEqual(state["fusion"]["condition_id"], "F2")
        self.assertEqual(state["fusion"]["trainable_parameters"], 0)
        self.assertEqual(state["status"], "foundational_study_only")
        self.assertEqual(state["decision"], "insufficient_evidence")
        self.assertEqual(state["promotion_status"], "not_eligible")
        self.assertEqual(state["source_type"], "deterministic_synthetic_fixture")
        self.assertFalse(state["physical_eeg_used"])
        self.assertFalse(state["scientific_claim_allowed"])
        self.assertTrue(state["shadow_only"])
        self.assertFalse(state["live_control"])
        self.assertAlmostEqual(state["observable_state_probabilities"]["eyes_open"], 0.5, places=12)
        self.assertAlmostEqual(state["encoder_disagreement"], 0.12, places=12)
        with self.assertRaisesRegex(ContractError, "only F2"):
            build_fused_state(self.fixtures[0], self.contract, condition_id="F0")
        with self.assertRaisesRegex(ContractError, "only F2"):
            build_fused_state(self.fixtures[0], self.contract, condition_id="F3")

    def test_fused_state_rejects_arbitrary_embeddings_or_fields(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        state["encoder_embedding"] = [0.1, 0.2]
        with self.assertRaisesRegex(ContractError, "fields differ"):
            validate_fused_state(state, self.contract, self.fixtures[0])

    def test_missing_model_behavior_is_explicit_and_fail_closed_for_fusion(self) -> None:
        without_eegpt = copy.deepcopy(self.fixtures[0])
        del without_eegpt["encoders"]["eegpt"]
        self.assertEqual(
            condition_probabilities(without_eegpt, "F0", self.contract),
            self.fixtures[0]["encoders"]["eegnet"]["probabilities"],
        )
        with self.assertRaisesRegex(ContractError, "F1 requires EEGPT"):
            condition_probabilities(without_eegpt, "F1", self.contract)
        with self.assertRaisesRegex(ContractError, "F2 requires both"):
            condition_probabilities(without_eegpt, "F2", self.contract)

    def test_no_learned_condition_is_executable_at_d0(self) -> None:
        for condition_id in ("F3", "F4", "F5", "F6"):
            with self.assertRaisesRegex(ContractError, "not executable at D0"):
                condition_probabilities(self.fixtures[0], condition_id, self.contract)

    def test_calibration_metrics_are_deterministic_fixture_checks(self) -> None:
        expected = {
            "F0": (0.1918, 0.398333333333),
            "F1": (0.259133333333, 0.466666666667),
            "F2": (0.2235, 0.4325),
        }
        for condition_id, (brier, ece) in expected.items():
            metrics = calibration_metrics(self.fixtures, condition_id, self.contract)
            self.assertEqual(metrics["fixture_count"], 6)
            self.assertEqual(metrics["multiclass_brier_score"], brier)
            self.assertEqual(metrics["expected_calibration_error"], ece)
            self.assertEqual(metrics["argmax_accuracy"], 1.0)

    def test_qwen_rendering_is_structured_only_and_does_not_execute_a_model(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        rendered = render_qwen_shadow_input(state, self.contract)
        payload = json.loads(rendered)
        self.assertEqual(payload["constraints"], {
            "encoder_embeddings_present": False,
            "free_text_state_present": False,
            "live_control": False,
            "model_execution_allowed": False,
            "raw_eeg_present": False,
            "shadow_only": True,
            "weights_updated": False,
        })
        serialized = rendered.casefold()
        self.assertNotIn("\"embedding\"", serialized)
        self.assertNotIn("waveform", serialized)
        self.assertNotIn("dialogue", serialized)
        self.assertNotIn("speech", serialized)

        malformed_state = copy.deepcopy(state)
        malformed_state["signal_quality"]["score"] = "unbounded content"
        with self.assertRaisesRegex(ContractError, "must be numeric"):
            render_qwen_shadow_input(malformed_state, self.contract)

        output = {
            "schema_version": QWEN_OUTPUT_SCHEMA,
            "state_id": state["state_id"],
            "action": "abstain",
            "confidence": 0.8,
            "abstained": True,
            "reason_code": "encoder_disagreement",
            "shadow_only": True,
            "live_control": False,
            "weights_updated": False,
        }
        self.assertEqual(validate_qwen_shadow_output(output, rendered, self.contract), output)

    def test_qwen_output_rejects_free_text_illegal_actions_and_control(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        rendered = render_qwen_shadow_input(state, self.contract)
        valid = {
            "schema_version": QWEN_OUTPUT_SCHEMA,
            "state_id": state["state_id"],
            "action": "abstain",
            "confidence": 1.0,
            "abstained": True,
            "reason_code": "insufficient_evidence",
            "shadow_only": True,
            "live_control": False,
            "weights_updated": False,
        }
        with_free_text = {**valid, "rationale": "unbounded prose"}
        with self.assertRaisesRegex(ContractError, "extra=.*rationale"):
            validate_qwen_shadow_output(with_free_text, rendered, self.contract)
        illegal = {**valid, "action": "speak", "abstained": False}
        with self.assertRaisesRegex(ContractError, "not legal"):
            validate_qwen_shadow_output(illegal, rendered, self.contract)
        live = {**valid, "live_control": True}
        with self.assertRaisesRegex(ContractError, "live control"):
            validate_qwen_shadow_output(live, rendered, self.contract)
        forged_input = json.loads(rendered)
        forged_input["constraints"]["model_execution_allowed"] = True
        with self.assertRaisesRegex(ContractError, "constraints changed"):
            validate_qwen_shadow_output(valid, json.dumps(forged_input), self.contract)

    def test_qwen_input_rejects_recursive_prohibited_and_unknown_fields(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        rendered = render_qwen_shadow_input(state, self.contract)
        valid_output = {
            "schema_version": QWEN_OUTPUT_SCHEMA,
            "state_id": state["state_id"],
            "action": "abstain",
            "confidence": 1.0,
            "abstained": True,
            "reason_code": "insufficient_evidence",
            "shadow_only": True,
            "live_control": False,
            "weights_updated": False,
        }
        attacks = (
            ("raw_eeg", ("structured_state", "signal_quality")),
            ("thought", ("structured_state", "observable_state_probabilities")),
            ("intention", ("structured_state", "signal_quality")),
            ("emotion", ("structured_state",)),
            ("diagnosis", ("constraints",)),
        )
        for field, path in attacks:
            with self.subTest(field=field, path=path):
                payload = json.loads(rendered)
                target = payload
                for component in path:
                    target = target[component]
                target[field] = {"nested": [1, 2, 3]}
                with self.assertRaisesRegex(ContractError, f"forbidden field: {field}"):
                    validate_qwen_shadow_output(valid_output, json.dumps(payload), self.contract)

        unknown = json.loads(rendered)
        unknown["structured_state"]["signal_quality"]["unregistered_nested_object"] = {}
        with self.assertRaisesRegex(ContractError, "extra=.*unregistered_nested_object"):
            validate_qwen_shadow_output(valid_output, json.dumps(unknown), self.contract)

    def test_qwen_input_rejects_nonfinite_and_invalid_probabilities(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        rendered = render_qwen_shadow_input(state, self.contract)
        valid_output = {
            "schema_version": QWEN_OUTPUT_SCHEMA,
            "state_id": state["state_id"],
            "action": "abstain",
            "confidence": 1.0,
            "abstained": True,
            "reason_code": "insufficient_evidence",
            "shadow_only": True,
            "live_control": False,
            "weights_updated": False,
        }
        for nonfinite in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(nonfinite=nonfinite):
                payload = json.loads(rendered)
                payload["structured_state"]["observable_state_probabilities"]["eyes_open"] = nonfinite
                with self.assertRaisesRegex(ContractError, "non-finite JSON constant"):
                    validate_qwen_shadow_output(valid_output, json.dumps(payload), self.contract)

        for invalid in ("0.5", True, -0.1, 1.1):
            with self.subTest(invalid=invalid):
                payload = json.loads(rendered)
                payload["structured_state"]["observable_state_probabilities"]["eyes_open"] = invalid
                with self.assertRaises(ContractError):
                    validate_qwen_shadow_output(valid_output, json.dumps(payload), self.contract)

        nonnormalized = json.loads(rendered)
        nonnormalized["structured_state"]["observable_state_probabilities"]["eyes_open"] = 0.4
        with self.assertRaisesRegex(ContractError, "must sum to one"):
            validate_qwen_shadow_output(valid_output, json.dumps(nonnormalized), self.contract)

    def test_qwen_task_and_reason_code_registry_are_immutable(self) -> None:
        mutated = copy.deepcopy(self.contract)
        mutated["qwen_bridge"]["task"] = "infer_thought_intention_emotion_and_diagnosis"
        with self.assertRaisesRegex(ContractError, "unexpected Qwen task"):
            validate_fusion_contract(mutated, CONTRACT_PATH)

        for reason_codes in (
            ["encoder_agreement"],
            [*self.contract["qwen_bridge"]["reason_codes"], "thought_detected"],
            list(reversed(self.contract["qwen_bridge"]["reason_codes"])),
        ):
            with self.subTest(reason_codes=reason_codes):
                mutated = copy.deepcopy(self.contract)
                mutated["qwen_bridge"]["reason_codes"] = reason_codes
                with self.assertRaisesRegex(ContractError, "reason-code registry"):
                    validate_fusion_contract(mutated, CONTRACT_PATH)

    def test_synthetic_disposition_is_required_everywhere(self) -> None:
        for field, invalid in (
            ("source_type", "physical_capture"),
            ("scientific_claim_allowed", True),
            ("shadow_only", False),
        ):
            with self.subTest(field=field):
                mutated_contract = copy.deepcopy(self.contract)
                mutated_contract["fixed_disposition"][field] = invalid
                with self.assertRaisesRegex(ContractError, f"fixed disposition {field} changed"):
                    validate_fusion_contract(mutated_contract, CONTRACT_PATH)

                mutated_fixture = copy.deepcopy(self.fixtures[0])
                mutated_fixture[field] = invalid
                with self.assertRaisesRegex(ContractError, f"disposition {field} changed"):
                    validate_synthetic_fixture(mutated_fixture, self.contract)

                mutated_state = build_fused_state(self.fixtures[0], self.contract)
                mutated_state[field] = invalid
                with self.assertRaisesRegex(ContractError, f"fused state {field} changed"):
                    validate_fused_state(mutated_state, self.contract, self.fixtures[0])

    def test_checkpoint_provenance_rejects_missing_malformed_and_swapped_identities(self) -> None:
        missing = copy.deepcopy(self.fixtures[0])
        del missing["encoders"]["eegnet"]["checkpoint_sha256"]
        with self.assertRaisesRegex(ContractError, "missing=.*checkpoint_sha256"):
            validate_synthetic_fixture(missing, self.contract)

        malformed = copy.deepcopy(self.fixtures[0])
        malformed["encoders"]["eegpt"]["checkpoint_sha256"] = "not-a-sha256"
        with self.assertRaisesRegex(ContractError, "must be a SHA-256 digest"):
            validate_synthetic_fixture(malformed, self.contract)

        swapped = build_fused_state(self.fixtures[0], self.contract)
        swapped["encoder_provenance"]["eegnet"]["model_id"] = "eegpt"
        swapped["encoder_provenance"]["eegpt"]["model_id"] = "eegnet"
        with self.assertRaisesRegex(ContractError, "eegnet provenance identity changed"):
            validate_fused_state(swapped, self.contract, self.fixtures[0])

        duplicate_hash = copy.deepcopy(self.contract)
        duplicate_hash["encoders"]["eegpt"]["fixture_checkpoint"]["sha256"] = (
            duplicate_hash["encoders"]["eegnet"]["fixture_checkpoint"]["sha256"]
        )
        with self.assertRaises(ContractError):
            validate_fusion_contract(duplicate_hash, CONTRACT_PATH)

    def test_every_condition_gate_and_missing_model_policy_is_pinned(self) -> None:
        attacks = (
            ("F3 gate", lambda contract: contract["conditions"][3].update({"earliest_physical_gate": "D0"})),
            ("F4 gate", lambda contract: contract["conditions"][4].update({"earliest_physical_gate": "D0"})),
            (
                "F5 policy",
                lambda contract: contract["conditions"][5].update({"missing_model_behavior": "use_eegnet_only"}),
            ),
            (
                "F6 gate",
                lambda contract: contract["conditions"][6].update({"earliest_physical_gate": "D3"}),
            ),
        )
        for name, mutate in attacks:
            with self.subTest(name=name):
                contract = copy.deepcopy(self.contract)
                mutate(contract)
                with self.assertRaisesRegex(ContractError, "F0-F6 registry"):
                    validate_fusion_contract(contract, CONTRACT_PATH)

        policy = copy.deepcopy(self.contract)
        policy["missing_model_policy"]["F5"] = "use_eegnet_only"
        with self.assertRaisesRegex(ContractError, "missing-model policy"):
            validate_fusion_contract(policy, CONTRACT_PATH)

    def test_replay_round_trip_is_byte_stable_and_hash_bound(self) -> None:
        with tempfile.TemporaryDirectory() as first_directory, tempfile.TemporaryDirectory() as second_directory:
            first = Path(first_directory)
            second = Path(second_directory)
            first_manifest = write_synthetic_fusion_artifacts(
                CONTRACT_PATH,
                states_output=first / "states.jsonl",
                manifest_output=first / "manifest.json",
                report_output=first / "report.json",
            )
            second_manifest = write_synthetic_fusion_artifacts(
                CONTRACT_PATH,
                states_output=second / "states.jsonl",
                manifest_output=second / "manifest.json",
                report_output=second / "report.json",
            )
            self.assertEqual(first_manifest, second_manifest)
            for name in ("states.jsonl", "manifest.json", "report.json"):
                self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
            replay = load_fused_state_replay(
                CONTRACT_PATH,
                states_path=first / "states.jsonl",
                manifest_path=first / "manifest.json",
            )
            self.assertEqual(len(replay), 6)

            rows = (first / "states.jsonl").read_text(encoding="utf-8").splitlines()
            tampered = json.loads(rows[0])
            tampered["encoder_disagreement"] = 0.0
            rows[0] = json.dumps(tampered, sort_keys=True, separators=(",", ":"))
            (first / "states.jsonl").write_text("\n".join(rows) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "record hash"):
                load_fused_state_replay(
                    CONTRACT_PATH,
                    states_path=first / "states.jsonl",
                    manifest_path=first / "manifest.json",
                )

    def test_replay_rejects_disposition_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_synthetic_fusion_artifacts(
                CONTRACT_PATH,
                states_output=root / "states.jsonl",
                manifest_output=root / "manifest.json",
                report_output=root / "report.json",
            )
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            for field, invalid in (
                ("source_type", "physical_capture"),
                ("scientific_claim_allowed", True),
                ("shadow_only", False),
            ):
                with self.subTest(field=field):
                    mutated = copy.deepcopy(manifest)
                    mutated[field] = invalid
                    (root / "mutated-manifest.json").write_text(
                        json.dumps(mutated, sort_keys=True),
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(ContractError, f"manifest {field} changed"):
                        load_fused_state_replay(
                            CONTRACT_PATH,
                            states_path=root / "states.jsonl",
                            manifest_path=root / "mutated-manifest.json",
                        )

    def test_synthetic_fused_state_cannot_satisfy_physical_source_manifest(self) -> None:
        state = build_fused_state(self.fixtures[0], self.contract)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic-state.json"
            path.write_text(json.dumps(state), encoding="utf-8")
            with self.assertRaisesRegex(ContractError, "nc-eeg-source-manifest-v0"):
                load_source_manifest(path)

    def test_committed_artifacts_match_clean_regeneration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            regenerated = Path(directory)
            write_synthetic_fusion_artifacts(
                CONTRACT_PATH,
                states_output=regenerated / "fused-states.jsonl",
                manifest_output=regenerated / "replay-manifest.json",
                report_output=regenerated / "fusion-synthetic-report.json",
            )
            for name in (
                "fused-states.jsonl",
                "replay-manifest.json",
                "fusion-synthetic-report.json",
            ):
                self.assertEqual(
                    (regenerated / name).read_bytes(),
                    (ARTIFACT_ROOT / name).read_bytes(),
                    name,
                )

    def test_report_cannot_be_read_as_physical_or_policy_evidence(self) -> None:
        states, report = run_synthetic_fusion_fixture(CONTRACT_PATH)
        self.assertEqual(len(states), 6)
        self.assertEqual(report["schema_version"], REPORT_SCHEMA)
        self.assertEqual(report["status"], "foundational_study_only")
        self.assertEqual(report["data_gate"], "D0")
        self.assertEqual(report["decision"], "insufficient_evidence")
        self.assertEqual(report["promotion_status"], "not_eligible")
        self.assertEqual(report["runtime_change"], "none")
        self.assertEqual(report["source_type"], "deterministic_synthetic_fixture")
        self.assertFalse(report["physical_eeg_used"])
        self.assertFalse(report["scientific_claim_allowed"])
        self.assertTrue(report["shadow_only"])
        self.assertFalse(report["dialogue_logs_used"])
        self.assertFalse(report["fallback_capture_used"])
        self.assertFalse(report["encoder_training"])
        self.assertFalse(report["fusion_head_training"])
        self.assertFalse(report["qwen_model_executed"])
        self.assertFalse(report["weights_updated"])
        self.assertTrue(all(report["invariants"].values()))

    def test_json_schema_is_closed_and_matches_manual_contract(self) -> None:
        schema = json.loads(STATE_SCHEMA_PATH.read_text(encoding="utf-8"))
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["properties"]["schema_version"]["const"], STATE_SCHEMA)
        self.assertEqual(schema["properties"]["fusion"]["properties"]["condition_id"]["const"], "F2")
        self.assertFalse(schema["properties"]["live_control"]["const"])
        self.assertFalse(schema["properties"]["physical_eeg_used"]["const"])
        self.assertFalse(schema["properties"]["scientific_claim_allowed"]["const"])
        self.assertEqual(schema["properties"]["source_type"]["const"], "deterministic_synthetic_fixture")
        self.assertEqual(
            schema["$defs"]["eegnet_encoder"]["properties"]["model_id"]["const"],
            "eegnet",
        )
        self.assertEqual(
            schema["$defs"]["eegpt_encoder"]["properties"]["model_id"]["const"],
            "eegpt",
        )


if __name__ == "__main__":
    unittest.main()
