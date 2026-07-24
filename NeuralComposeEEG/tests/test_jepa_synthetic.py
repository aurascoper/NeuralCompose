"""Tests for the quarantined synthetic JEPA execution rehearsal."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from neuralcompose_eeg.contracts import ContractError, load_source_manifest
from neuralcompose_eeg.jepa_synthetic import (
    CONDITIONS,
    EXPERIMENT_ID,
    MODE_CONTROLS,
    MODE_EXPERIMENT_ID,
    MODES,
    SOURCE_SCHEMA,
    _mask_for_indices,
    build_model,
    fit_normalization,
    generate_base_sessions,
    generate_mode_sessions,
    grouped_folds,
    load_contracts,
    make_pairs,
    mode_grouped_fold,
    normalize_pairs,
    raw_generator_diagnostics,
    run_rehearsal,
    sigreg_loss,
    train_condition,
    vicreg_terms,
)
from neuralcompose_eeg.provenance import sha256_file


REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / "NeuralComposeEEG" / "configs" / "jepa-synthetic-v0.json"
GENERATORS_PATH = REPO_ROOT / "docs" / "scoping" / "jepa-synthetic-generators-v0.json"


class JEPASyntheticContractTests(unittest.TestCase):
    def test_contract_is_separate_nonphysical_and_nonpromotable(self) -> None:
        config, generators = load_contracts(CONFIG_PATH, GENERATORS_PATH)
        self.assertEqual(config["experiment_id"], EXPERIMENT_ID)
        self.assertEqual(config["mode_experiment_id"], MODE_EXPERIMENT_ID)
        self.assertEqual(config["source"]["schema_version"], SOURCE_SCHEMA)
        self.assertFalse(config["source"]["physical_capture_eligible"])
        self.assertFalse(config["source"]["fallback_capture_allowed"])
        self.assertFalse(generators["fallback_acquisition_stream"]["accepted"])
        self.assertEqual(tuple(config["training"]["conditions"]), CONDITIONS)
        self.assertEqual(tuple(config["mode_extension"]["controls"]), MODE_CONTROLS)
        self.assertEqual(tuple(config["mode_extension"]["modes"]), MODES)
        self.assertEqual(config["artifact"]["decision"], "pipeline_evidence_only")
        self.assertEqual(config["artifact"]["promotion_status"], "not_eligible")
        self.assertEqual(config["artifact"]["runtime_change"], "none")
        self.assertFalse(config["artifact"]["physical_eeg_used"])
        self.assertFalse(config["artifact"]["scientific_transfer_claim_allowed"])
        expected = {
            entry["id"]: entry["expected_invariants"]
            for entry in generators["generators"]
        }
        self.assertEqual(expected["S0"]["correct_to_permuted_ratio_max"], 0.98)
        self.assertEqual(expected["S1"]["correct_to_permuted_ratio_min"], 0.95)
        self.assertEqual(expected["S5"]["state_probe_accuracy_min"], 0.55)
        self.assertEqual(expected["S6"]["T2_effective_rank_max"], 2.0)
        self.assertEqual(
            expected["S6"]["anti_collapse_effective_rank_gain_min"],
            0.25,
        )

    def test_fallback_admission_cannot_be_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = json.loads(CONFIG_PATH.read_text())
            config["source"]["fallback_capture_allowed"] = True
            config_path = root / "config.json"
            config_path.write_text(json.dumps(config))
            with self.assertRaisesRegex(ContractError, "fallback acquisition"):
                load_contracts(config_path, GENERATORS_PATH)

    def test_synthetic_schema_is_rejected_by_physical_source_loader(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic-source.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": SOURCE_SCHEMA,
                        "experiment_id": EXPERIMENT_ID,
                        "source_type": "deterministic_synthetic_fixture",
                        "sessions": [],
                    }
                )
            )
            with self.assertRaisesRegex(ContractError, "nc-eeg-source-manifest-v0"):
                load_source_manifest(path)


class JEPASyntheticGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config, _ = load_contracts(CONFIG_PATH, GENERATORS_PATH)
        cls.sessions = generate_base_sessions(cls.config)

    def test_generators_are_byte_deterministic(self) -> None:
        second = generate_base_sessions(self.config)
        for generator_id in self.sessions:
            for first_session, second_session in zip(
                self.sessions[generator_id],
                second[generator_id],
                strict=True,
            ):
                np.testing.assert_array_equal(first_session.windows, second_session.windows)
                np.testing.assert_array_equal(
                    first_session.state_labels,
                    second_session.state_labels,
                )

    def test_known_raw_structures_are_present(self) -> None:
        diagnostics = {
            generator_id: raw_generator_diagnostics(sessions, self.config)
            for generator_id, sessions in self.sessions.items()
        }
        self.assertGreaterEqual(diagnostics["S0"]["entropy_effective_rank"], 1.5)
        self.assertLessEqual(diagnostics["S0"]["entropy_effective_rank"], 2.6)
        self.assertGreaterEqual(diagnostics["S1"]["entropy_effective_rank"], 3.2)
        self.assertGreaterEqual(diagnostics["S2"]["first_singular_energy"], 0.55)
        self.assertGreaterEqual(
            diagnostics["S3"]["nearest_neighbor_session_identity"],
            0.75,
        )
        self.assertLessEqual(
            diagnostics["S4"]["maximum_session_channel_matrix_rank"],
            3,
        )
        self.assertEqual(
            len(diagnostics["S4"]["missing_channel_provenance"]),
            self.config["data"]["sessions_per_generator"],
        )

    def test_nonfinite_fixture_is_rejected(self) -> None:
        session = self.sessions["S0"][0]
        broken = session.windows.copy()
        broken[0, 0, 0] = np.nan
        with self.assertRaisesRegex(ContractError, "nonfinite"):
            type(session)(
                session_id=session.session_id,
                generator_id=session.generator_id,
                windows=broken,
                state_labels=session.state_labels,
                mode=session.mode,
                nuisance=session.nuisance,
            ).validate(
                channels=self.config["data"]["channel_count"],
                window_samples=self.config["data"]["window_samples"],
            )

    def test_mode_regimes_cross_the_same_nuisance_grid(self) -> None:
        sessions = generate_mode_sessions(self.config)
        self.assertEqual({session.mode for session in sessions}, set(MODES))
        self.assertEqual(len(sessions), 4 * len(MODES))
        for mode in MODES:
            mode_sessions = [session for session in sessions if session.mode == mode]
            self.assertEqual(
                {session.nuisance["mixing_family"] for session in mode_sessions},
                {0, 1, 2, 3},
            )
            self.assertEqual(
                {session.nuisance["latent_rank"] for session in mode_sessions},
                {2, 3},
            )


class JEPASyntheticLeakageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config, _ = load_contracts(CONFIG_PATH, GENERATORS_PATH)
        cls.sessions = generate_base_sessions(cls.config)["S0"]
        cls.pairs = make_pairs(cls.sessions)

    def test_grouped_folds_have_no_shared_sessions(self) -> None:
        folds = grouped_folds(self.pairs.session_ids.tolist(), self.config)
        self.assertEqual(len(folds), self.config["split"]["outer_fold_count"])
        for fold in folds:
            train = set(fold.train_sessions)
            validation = set(fold.validation_sessions)
            test = set(fold.test_sessions)
            self.assertFalse(train & validation)
            self.assertFalse(train & test)
            self.assertFalse(validation & test)
            for session_id in set(self.pairs.session_ids.tolist()):
                pair_indices = np.flatnonzero(self.pairs.session_ids == session_id)
                self.assertGreater(len(pair_indices), 1)
                self.assertIn(
                    session_id,
                    train | validation | test,
                )

    def test_normalization_uses_training_values_only(self) -> None:
        fold = grouped_folds(self.pairs.session_ids.tolist(), self.config)[0]
        train = self.pairs.subset(set(fold.train_sessions))
        test = self.pairs.subset(set(fold.test_sessions))
        mean, std = fit_normalization(train)
        changed = copy.deepcopy(test)
        changed.context[:] = 1e6
        changed.target[:] = -1e6
        unchanged_mean, unchanged_std = fit_normalization(train)
        np.testing.assert_array_equal(mean, unchanged_mean)
        np.testing.assert_array_equal(std, unchanged_std)
        normalized = normalize_pairs(changed, mean, std)
        self.assertGreater(float(np.abs(normalized.context).mean()), 1000.0)

    def test_mask_is_deterministic_and_does_not_read_target(self) -> None:
        indices = np.arange(12)
        first = _mask_for_indices(
            indices,
            window_samples=64,
            fraction=0.25,
            seed=42,
        )
        second = _mask_for_indices(
            indices,
            window_samples=64,
            fraction=0.25,
            seed=42,
        )
        shifted = _mask_for_indices(
            indices,
            window_samples=64,
            fraction=0.25,
            seed=42,
            offset=1,
        )
        np.testing.assert_array_equal(first, second)
        self.assertFalse(np.array_equal(first, shifted))
        self.assertTrue(np.all(first.sum(axis=2) == 16))

    def test_mode_split_uses_complete_sessions(self) -> None:
        sessions = generate_mode_sessions(self.config)
        fold = mode_grouped_fold(sessions)
        self.assertFalse(set(fold.train_sessions) & set(fold.test_sessions))
        self.assertEqual(len(fold.test_sessions), len(MODES))
        test_modes = {
            session.mode
            for session in sessions
            if session.session_id in set(fold.test_sessions)
        }
        self.assertEqual(test_modes, set(MODES))


class JEPASyntheticObjectiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config, _ = load_contracts(CONFIG_PATH, GENERATORS_PATH)
        sessions = generate_base_sessions(cls.config)["S5"]
        pairs = make_pairs(sessions)
        fold = grouped_folds(pairs.session_ids.tolist(), cls.config)[0]
        train_raw = pairs.subset(set(fold.train_sessions))
        mean, std = fit_normalization(train_raw)
        cls.train = normalize_pairs(train_raw, mean, std)

    def test_all_conditions_have_identical_parameter_count(self) -> None:
        counts = []
        for condition in CONDITIONS:
            model, report = train_condition(
                condition,
                self.train,
                self.config,
                seed=42,
            )
            self.assertIsNotNone(model)
            counts.append(report["parameter_count"])
        self.assertEqual(len(set(counts)), 1)

    def test_target_encoder_is_stop_gradient(self) -> None:
        model = build_model(self.config)
        batch = torch.from_numpy(self.train.context[:8])
        target = model.target(batch)
        self.assertFalse(target.requires_grad)
        self.assertTrue(
            all(not parameter.requires_grad for parameter in model.target_encoder.parameters())
        )
        self.assertTrue(
            all(not parameter.requires_grad for parameter in model.target_projector.parameters())
        )

    def test_sigreg_and_vicreg_attach_to_projector_not_predictor(self) -> None:
        model = build_model(self.config)
        batch = torch.from_numpy(self.train.context[:16])
        _, projector = model.encode(batch)
        sigreg_loss(projector).backward(retain_graph=True)
        self.assertTrue(
            any(
                parameter.grad is not None and torch.any(parameter.grad != 0)
                for parameter in model.projector.parameters()
            )
        )
        self.assertTrue(all(parameter.grad is None for parameter in model.predictor.parameters()))

        model.zero_grad(set_to_none=True)
        _, projector = model.encode(batch)
        variance, covariance = vicreg_terms(projector)
        (variance + covariance).backward()
        self.assertTrue(
            any(
                parameter.grad is not None and torch.any(parameter.grad != 0)
                for parameter in model.projector.parameters()
            )
        )
        self.assertTrue(all(parameter.grad is None for parameter in model.predictor.parameters()))

    def test_bounded_reconstruction_never_exceeds_registered_fraction(self) -> None:
        _, report = train_condition("T5", self.train, self.config, seed=42)
        losses = report["last_losses"]
        self.assertLessEqual(
            losses["bounded_reconstruction"],
            0.25 * max(losses["prediction"], 1e-6) + 1e-7,
        )


class JEPASyntheticArtifactTests(unittest.TestCase):
    def _micro_contracts(self, root: Path) -> tuple[Path, Path]:
        config = json.loads(CONFIG_PATH.read_text())
        config["data"]["generator_ids"] = ["S0"]
        config["data"]["windows_per_session"] = 8
        config["data"]["sessions_per_generator"] = 4
        config["split"]["outer_test_sessions"] = 1
        config["split"]["inner_validation_sessions"] = 1
        config["split"]["outer_fold_count"] = 1
        config["training"]["steps"] = 2
        config["training"]["batch_size"] = 8
        config["mode_extension"]["enabled"] = False
        generators = json.loads(GENERATORS_PATH.read_text())
        generators["generators"] = [
            generator for generator in generators["generators"] if generator["id"] == "S0"
        ]
        config_path = root / "config.json"
        generators_path = root / "generators.json"
        config_path.write_text(json.dumps(config, sort_keys=True))
        generators_path.write_text(json.dumps(generators, sort_keys=True))
        return config_path, generators_path

    def test_end_to_end_artifacts_are_deterministic_and_nonphysical(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path, generators_path = self._micro_contracts(root)
            first = run_rehearsal(
                config_path,
                generators_path,
                root / "first",
                include_mode=False,
            )
            second = run_rehearsal(
                config_path,
                generators_path,
                root / "second",
                include_mode=False,
            )
            first_report = json.loads(first["base_report"].read_text())
            second_report = json.loads(second["base_report"].read_text())
            self.assertEqual(
                first_report["report_identity_sha256"],
                second_report["report_identity_sha256"],
            )
            self.assertEqual(first_report["experiment_id"], EXPERIMENT_ID)
            self.assertFalse(first_report["physical_eeg_used"])
            self.assertFalse(first_report["scientific_transfer_claim_allowed"])
            self.assertFalse(first_report["fallback_capture_used"])
            self.assertEqual(first_report["decision"], "pipeline_evidence_only")
            self.assertEqual(first_report["promotion_status"], "not_eligible")
            self.assertEqual(first_report["runtime_change"], "none")
            self.assertTrue(
                all(
                    result["passed"]
                    for result in first_report["diagnostic_self_tests"].values()
                )
            )
            generator = first_report["base_rehearsal"]["generators"]["S0"]
            self.assertTrue(
                all(result["passed"] for result in generator["matched_execution"])
            )
            source = json.loads(first["source_manifest"].read_text())
            self.assertEqual(source["schema_version"], SOURCE_SCHEMA)
            self.assertTrue(
                all(
                    session["session_id"].startswith("synthetic:")
                    and not session["physical_capture_eligible"]
                    for session in source["sessions"]
                )
            )
            self.assertEqual(
                sha256_file(first["source_manifest"]),
                first_report["source_manifest_sha256"],
            )

if __name__ == "__main__":
    unittest.main()
