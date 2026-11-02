"""Adversarial Stress Test Suite for NeuralCompose Master Event Contract.

Challenger 1: Schema and Type Adversarial Challenger.
Empirically stress-tests:
1. Header Conflation Attacks (Turn L14, Turn L16)
2. Betti Number Float and Non-Integer Attacks
3. Continuous Observable Boolean and Non-Float64 Attacks
4. Cyclic Feedback Attacks on Tarjan Solver DAG (Turn L21)
5. Non-Recursive Guard Bypass Attacks (Turn L112, Turn L20)
6. Defect Axis Tripping Attacks (Boundary, Control, Source, Coordination)
7. Typographic Hygiene and Forbidden Dash Injection Verification

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from Scripts.contracts.alara_closed_loop_controller import (
    ALARAClosedLoopController,
    ALARAControllerError,
    ALARAControllerState,
)
from Scripts.contracts.logic_gates_evaluator import (
    GateEvaluationResult,
    LogicGatesEvaluator,
    TransitionEvaluationResult,
)
from Scripts.contracts.master_event_contract import (
    AnastomosisTopology,
    BettiNumbers,
    BiofilmSessionEnvelope,
    CategoryTypeViolation,
    CircadianState,
    CriticalityMetrics,
    DefectAxes,
    MasterEvent,
    MasterEventContractError,
    MomentumAutomataEnvelope,
    MultiPoolReactorEnvelope,
    NeuralComposeFixtureEnvelope,
    SchemaValidationError,
    VALID_M7_STAGE_HEADERS,
    assert_float64,
    assert_int64,
    assert_stage_header,
    validate_biofilm_session_envelope,
    validate_master_event,
    validate_momentum_automata_envelope,
    validate_multipool_reactor_envelope,
    validate_neuralcompose_fixture_envelope,
)
from Scripts.contracts.tarjan_bridge_verifier import (
    TarjanBridgeVerifier,
    TarjanVerificationError,
    compute_betti_numbers,
    find_cut_vertices_and_bridges,
    tarjan_scc,
    verify_nilpotent_adjacency,
)


class TestHeaderConflationAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging container header vs numeric conflation."""

    def test_header_conflation_float_7_1_raises_category_violation(self) -> None:
        """Injecting float 7.1 as stage header must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation) as ctx:
            assert_stage_header(7.1)
        self.assertIn("Category-Level Schema Violation", str(ctx.exception))

    def test_header_conflation_int_7_raises_category_violation(self) -> None:
        """Injecting int 7 as stage header must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation) as ctx:
            assert_stage_header(7)
        self.assertIn("Category-Level Schema Violation", str(ctx.exception))

    def test_header_conflation_float_7_8_raises_category_violation(self) -> None:
        """Injecting float 7.8 as stage header must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation) as ctx:
            assert_stage_header(7.8)
        self.assertIn("Category-Level Schema Violation", str(ctx.exception))

    def test_header_conflation_string_numeric_7_1_raises_category_violation(self) -> None:
        """Injecting numeric string '7.1' without 'M' prefix must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation) as ctx:
            assert_stage_header("7.1")
        self.assertIn("must be one of", str(ctx.exception))

    def test_header_conflation_invalid_m_prefix_raises_category_violation(self) -> None:
        """Injecting invalid stage headers 'M7.9' or 'M8.1' must raise CategoryTypeViolation."""
        for bad_header in ("M7.9", "M8.1", "M7.0", "M7"):
            with self.assertRaises(CategoryTypeViolation):
                assert_stage_header(bad_header)

    def test_header_conflation_bool_raises_category_violation(self) -> None:
        """Injecting boolean True or False as stage header must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            assert_stage_header(True)
        with self.assertRaises(CategoryTypeViolation):
            assert_stage_header(False)

    def test_header_conflation_none_raises_category_violation(self) -> None:
        """Injecting None as stage header must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            assert_stage_header(None)

    def test_header_conflation_in_multipool_reactor_envelope(self) -> None:
        """MultiPoolReactorEnvelope must reject float 7.3 header at instantiation."""
        with self.assertRaises(CategoryTypeViolation):
            MultiPoolReactorEnvelope(
                sequence_id="seq_s3_adv",
                container_header=7.3,  # type: ignore[arg-type]
                n_pool=8,
                chamber_ids=[f"chamber_{i}" for i in range(1, 9)],
                sucrose_concentrations_mol_m3=[55.0] * 8,
                temperatures_kelvin=[298.15] * 8,
                phreeqc_activity_avg_ph=7.0,
                phreeqc_charge_imbalance_pct=0.2,
                radiolytic_h2o2_scavenged_uM=[15.0] * 8,
                nutmeg_quarantine_status=":Accepted",
            )

    def test_header_conflation_in_biofilm_session_envelope(self) -> None:
        """BiofilmSessionEnvelope must reject float 7.1 header at instantiation."""
        with self.assertRaises(CategoryTypeViolation):
            BiofilmSessionEnvelope(
                sequence_id="seq_s4_adv",
                container_header=7.1,  # type: ignore[arg-type]
                circadian_state=CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=0.0),
                cytoplasmic_streaming_velocity_um_s=25.0,
                hex1_woronin_plugging_active=False,
                anastomosis_topology=AnastomosisTopology(beta_0=1, beta_1=3),
                biomass_density_kg_m3=[0.5] * 8,
                tip_density_m3=[1000.0] * 8,
                eps_streamer_fraction=[0.2] * 8,
            )

    def test_header_conflation_in_dict_validator_multipool(self) -> None:
        """validate_multipool_reactor_envelope dict validator must reject float 7.4."""
        payload = {
            "sequence_id": "seq_s3_dict",
            "container_header": 7.4,
            "n_pool": 8,
            "chamber_ids": [f"chamber_{i}" for i in range(1, 9)],
            "sucrose_concentrations_mol_m3": [55.0] * 8,
            "temperatures_kelvin": [298.15] * 8,
            "phreeqc_activity_avg_ph": 7.0,
            "phreeqc_charge_imbalance_pct": 0.2,
            "radiolytic_h2o2_scavenged_uM": [15.0] * 8,
            "nutmeg_quarantine_status": ":Accepted",
        }
        with self.assertRaises(CategoryTypeViolation):
            validate_multipool_reactor_envelope(payload)

    def test_header_conflation_in_dict_validator_biofilm(self) -> None:
        """validate_biofilm_session_envelope dict validator must reject int 7."""
        payload = {
            "sequence_id": "seq_s4_dict",
            "container_header": 7,
            "circadian_state": {"M_frq": 1.0, "F_c": 1.0, "F_n": 1.0, "phi_radians": 0.0},
            "cytoplasmic_streaming_velocity_um_s": 25.0,
            "hex1_woronin_plugging_active": False,
            "anastomosis_topology": {"beta_0": 1, "beta_1": 3},
            "biomass_density_kg_m3": [0.5] * 8,
            "tip_density_m3": [1000.0] * 8,
            "eps_streamer_fraction": [0.2] * 8,
        }
        with self.assertRaises(CategoryTypeViolation):
            validate_biofilm_session_envelope(payload)

    def test_header_conflation_in_gate_g2_evaluation(self) -> None:
        """Gate G2 evaluation with conflate_header_as_numeric must trip Boundary defect and reject."""
        res = LogicGatesEvaluator.evaluate_gate_g2(conflate_header_as_numeric=True)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Boundary", res.defect_axes_tripped)
        self.assertIsNotNone(res.error_message)

    def test_header_conflation_in_gate_g2_invalid_tuple(self) -> None:
        """Gate G2 evaluation with mismatched stage headers tuple must trip Boundary defect and reject."""
        res = LogicGatesEvaluator.evaluate_gate_g2(stage_headers=("M7.1", "M7.2"))  # type: ignore[arg-type]
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Boundary", res.defect_axes_tripped)


class TestBettiFloatAndDiscreteAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging discrete Int64 invariants against floats and bools."""

    def test_betti_0_float_1_0_raises_category_violation(self) -> None:
        """beta_0 = 1.0 (float) must raise CategoryTypeViolation in BettiNumbers."""
        with self.assertRaises(CategoryTypeViolation):
            BettiNumbers(beta_0=1.0, beta_1=0)  # type: ignore[arg-type]

    def test_betti_1_float_3_5_raises_category_violation(self) -> None:
        """beta_1 = 3.5 (float) must raise CategoryTypeViolation in BettiNumbers."""
        with self.assertRaises(CategoryTypeViolation):
            BettiNumbers(beta_0=1, beta_1=3.5)  # type: ignore[arg-type]

    def test_betti_0_bool_true_raises_category_violation(self) -> None:
        """beta_0 = True (boolean) must raise CategoryTypeViolation in BettiNumbers."""
        with self.assertRaises(CategoryTypeViolation):
            BettiNumbers(beta_0=True, beta_1=0)  # type: ignore[arg-type]

    def test_betti_1_bool_false_raises_category_violation(self) -> None:
        """beta_1 = False (boolean) must raise CategoryTypeViolation in BettiNumbers."""
        with self.assertRaises(CategoryTypeViolation):
            BettiNumbers(beta_0=1, beta_1=False)  # type: ignore[arg-type]

    def test_betti_numbers_string_raises_category_violation(self) -> None:
        """beta_0 = '1' (string) must raise CategoryTypeViolation in BettiNumbers."""
        with self.assertRaises(CategoryTypeViolation):
            BettiNumbers(beta_0="1", beta_1=0)  # type: ignore[arg-type]

    def test_betti_0_zero_raises_schema_validation_error(self) -> None:
        """beta_0 = 0 (disconnected complex) must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            BettiNumbers(beta_0=0, beta_1=0)

    def test_betti_1_negative_raises_schema_validation_error(self) -> None:
        """beta_1 = -1 (negative 1-cycle) must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            BettiNumbers(beta_0=1, beta_1=-1)

    def test_anastomosis_betti_0_float_raises_category_violation(self) -> None:
        """AnastomosisTopology beta_0 = 1.0 (float) must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            AnastomosisTopology(beta_0=1.0, beta_1=3)  # type: ignore[arg-type]

    def test_anastomosis_betti_1_float_raises_category_violation(self) -> None:
        """AnastomosisTopology beta_1 = 3.5 (float) must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            AnastomosisTopology(beta_0=1, beta_1=3.5)  # type: ignore[arg-type]

    def test_anastomosis_betti_bool_raises_category_violation(self) -> None:
        """AnastomosisTopology beta_0 = True must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            AnastomosisTopology(beta_0=True, beta_1=3)  # type: ignore[arg-type]

    def test_anastomosis_betti_0_not_one_raises_schema_validation_error(self) -> None:
        """Anastomosis network requires beta_0 == 1; beta_0 = 2 must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=2, beta_1=3)

    def test_anastomosis_betti_1_zero_raises_schema_validation_error(self) -> None:
        """Active syncytial anastomosis requires beta_1 >= 1; beta_1 = 0 must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=1, beta_1=0)

    def test_orderbook_betti_float_in_envelope_raises_category_violation(self) -> None:
        """MomentumAutomataEnvelope orderbook_betti_1 = 2.0 must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MomentumAutomataEnvelope(
                sequence_id="seq_s2_adv",
                criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=1.0),
                criticality_regime="CRITICAL_WITHIN_NOISE",
                wbr_mode="Focus",
                hysteresis_loop_area=0.5,
                retention_pool_active=False,
                orderbook_betti_1=2.0,  # type: ignore[arg-type]
            )

    def test_balance_tree_betti_float_in_envelope_raises_category_violation(self) -> None:
        """MomentumAutomataEnvelope balance_tree_betti_1 = 0.0 must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MomentumAutomataEnvelope(
                sequence_id="seq_s2_adv",
                criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=1.0),
                criticality_regime="CRITICAL_WITHIN_NOISE",
                wbr_mode="Focus",
                hysteresis_loop_area=0.5,
                retention_pool_active=False,
                balance_tree_betti_1=0.0,  # type: ignore[arg-type]
            )

    def test_balance_tree_betti_nonzero_raises_schema_validation_error(self) -> None:
        """Balance tree must be an acyclic tree (beta_1 == 0); beta_1 = 1 must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope(
                sequence_id="seq_s2_adv",
                criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=1.0),
                criticality_regime="CRITICAL_WITHIN_NOISE",
                wbr_mode="Focus",
                hysteresis_loop_area=0.5,
                retention_pool_active=False,
                balance_tree_betti_1=1,
            )

    def test_discrete_int64_frame_index_float_raises_category_violation(self) -> None:
        """frame_index = 12.0 in NeuralComposeFixtureEnvelope must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            NeuralComposeFixtureEnvelope(
                sequence_id="seq_s1_adv",
                functor_stage="F_Laya",
                frame_index=12.0,  # type: ignore[arg-type]
                betti_numbers=BettiNumbers(beta_0=1, beta_1=2),
                defect_axes=DefectAxes(),
                toy_drive_active=True,
                mahalanobis_tension_D_M=1.2,
            )

    def test_discrete_int64_n_pool_float_raises_category_violation(self) -> None:
        """n_pool = 8.0 in MultiPoolReactorEnvelope must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MultiPoolReactorEnvelope(
                sequence_id="seq_s3_adv",
                container_header="M7.3",
                n_pool=8.0,  # type: ignore[arg-type]
                chamber_ids=[f"ch_{i}" for i in range(8)],
                sucrose_concentrations_mol_m3=[55.0] * 8,
                temperatures_kelvin=[298.15] * 8,
                phreeqc_activity_avg_ph=7.0,
                phreeqc_charge_imbalance_pct=0.2,
                radiolytic_h2o2_scavenged_uM=[15.0] * 8,
                nutmeg_quarantine_status=":Accepted",
            )

    def test_discrete_int64_recursion_depth_float_raises_category_violation(self) -> None:
        """recursion_depth = 0.0 in MasterEvent must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MasterEvent(
                event_id="evt_adv_001",
                timestamp_utc="2026-11-02T10:00:00Z",
                subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
                envelope_type="NeuralComposeFixtureEnvelope",
                payload={},
                recursion_depth=0.0,  # type: ignore[arg-type]
            )

    def test_discrete_int64_in_gate_g2_trips_boundary(self) -> None:
        """Gate G2 with float in discrete_int64_payload must fail and trip Boundary."""
        res = LogicGatesEvaluator.evaluate_gate_g2(
            discrete_int64_payload={"chamber_index": 1.0}
        )
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Boundary", res.defect_axes_tripped)


class TestContinuousObservableBooleanAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging continuous Float64 SI observables against booleans and non-floats."""

    def test_criticality_k_eff_boolean_true_raises_category_violation(self) -> None:
        """k_eff = True must raise CategoryTypeViolation in CriticalityMetrics."""
        with self.assertRaises(CategoryTypeViolation):
            CriticalityMetrics(k_eff=True, rho_pcm=0.0, z_crit=1.0, chi=1.0)  # type: ignore[arg-type]

    def test_criticality_k_eff_boolean_false_raises_category_violation(self) -> None:
        """k_eff = False must raise CategoryTypeViolation in CriticalityMetrics."""
        with self.assertRaises(CategoryTypeViolation):
            CriticalityMetrics(k_eff=False, rho_pcm=0.0, z_crit=1.0, chi=1.0)  # type: ignore[arg-type]

    def test_criticality_nan_raises_category_violation(self) -> None:
        """k_eff = NaN must raise CategoryTypeViolation in CriticalityMetrics."""
        with self.assertRaises(CategoryTypeViolation):
            CriticalityMetrics(k_eff=float("nan"), rho_pcm=0.0, z_crit=1.0, chi=1.0)

    def test_criticality_inf_raises_category_violation(self) -> None:
        """k_eff = +inf must raise CategoryTypeViolation in CriticalityMetrics."""
        with self.assertRaises(CategoryTypeViolation):
            CriticalityMetrics(k_eff=float("inf"), rho_pcm=0.0, z_crit=1.0, chi=1.0)

    def test_criticality_string_raises_category_violation(self) -> None:
        """k_eff = '1.0' (string) must raise CategoryTypeViolation in CriticalityMetrics."""
        with self.assertRaises(CategoryTypeViolation):
            CriticalityMetrics(k_eff="1.0", rho_pcm=0.0, z_crit=1.0, chi=1.0)  # type: ignore[arg-type]

    def test_criticality_negative_k_eff_raises_schema_validation_error(self) -> None:
        """k_eff = -0.5 must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            CriticalityMetrics(k_eff=-0.5, rho_pcm=0.0, z_crit=1.0, chi=1.0)

    def test_circadian_m_frq_bool_raises_category_violation(self) -> None:
        """M_frq = True in CircadianState must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            CircadianState(M_frq=True, F_c=1.0, F_n=1.0, phi_radians=0.0)  # type: ignore[arg-type]

    def test_circadian_negative_raises_schema_validation_error(self) -> None:
        """M_frq = -0.1 in CircadianState must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            CircadianState(M_frq=-0.1, F_c=1.0, F_n=1.0, phi_radians=0.0)

    def test_mahalanobis_tension_bool_in_fixture_envelope(self) -> None:
        """mahalanobis_tension_D_M = True in NeuralComposeFixtureEnvelope must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            NeuralComposeFixtureEnvelope(
                sequence_id="seq_s1_adv",
                functor_stage="F_Laya",
                frame_index=0,
                betti_numbers=BettiNumbers(beta_0=1, beta_1=2),
                defect_axes=DefectAxes(),
                toy_drive_active=True,
                mahalanobis_tension_D_M=True,  # type: ignore[arg-type]
            )

    def test_hysteresis_area_bool_in_momentum_envelope(self) -> None:
        """hysteresis_loop_area = True in MomentumAutomataEnvelope must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MomentumAutomataEnvelope(
                sequence_id="seq_s2_adv",
                criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=1.0),
                criticality_regime="CRITICAL_WITHIN_NOISE",
                wbr_mode="Focus",
                hysteresis_loop_area=True,  # type: ignore[arg-type]
                retention_pool_active=False,
            )

    def test_phreeqc_ph_bool_in_multipool_envelope(self) -> None:
        """phreeqc_activity_avg_ph = True in MultiPoolReactorEnvelope must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MultiPoolReactorEnvelope(
                sequence_id="seq_s3_adv",
                container_header="M7.3",
                n_pool=8,
                chamber_ids=[f"ch_{i}" for i in range(8)],
                sucrose_concentrations_mol_m3=[55.0] * 8,
                temperatures_kelvin=[298.15] * 8,
                phreeqc_activity_avg_ph=True,  # type: ignore[arg-type]
                phreeqc_charge_imbalance_pct=0.2,
                radiolytic_h2o2_scavenged_uM=[15.0] * 8,
                nutmeg_quarantine_status=":Accepted",
            )

    def test_sucrose_array_bool_in_multipool_envelope(self) -> None:
        """Injecting boolean into sucrose array must raise CategoryTypeViolation."""
        sucrose_array = [55.0, 50.0, True, 40.0, 35.0, 30.0, 25.0, 20.0]  # type: ignore[list-item]
        with self.assertRaises(CategoryTypeViolation):
            MultiPoolReactorEnvelope(
                sequence_id="seq_s3_adv",
                container_header="M7.3",
                n_pool=8,
                chamber_ids=[f"ch_{i}" for i in range(8)],
                sucrose_concentrations_mol_m3=sucrose_array,
                temperatures_kelvin=[298.15] * 8,
                phreeqc_activity_avg_ph=7.0,
                phreeqc_charge_imbalance_pct=0.2,
                radiolytic_h2o2_scavenged_uM=[15.0] * 8,
                nutmeg_quarantine_status=":Accepted",
            )

    def test_temperature_array_bool_in_multipool_envelope(self) -> None:
        """Injecting boolean into temperature array must raise CategoryTypeViolation."""
        temp_array = [298.15, False, 298.15, 298.15, 298.15, 298.15, 298.15, 298.15]  # type: ignore[list-item]
        with self.assertRaises(CategoryTypeViolation):
            MultiPoolReactorEnvelope(
                sequence_id="seq_s3_adv",
                container_header="M7.3",
                n_pool=8,
                chamber_ids=[f"ch_{i}" for i in range(8)],
                sucrose_concentrations_mol_m3=[55.0] * 8,
                temperatures_kelvin=temp_array,
                phreeqc_activity_avg_ph=7.0,
                phreeqc_charge_imbalance_pct=0.2,
                radiolytic_h2o2_scavenged_uM=[15.0] * 8,
                nutmeg_quarantine_status=":Accepted",
            )

    def test_streaming_velocity_bool_in_biofilm_envelope(self) -> None:
        """cytoplasmic_streaming_velocity_um_s = True must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            BiofilmSessionEnvelope(
                sequence_id="seq_s4_adv",
                container_header="M7.8",
                circadian_state=CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=0.0),
                cytoplasmic_streaming_velocity_um_s=True,  # type: ignore[arg-type]
                hex1_woronin_plugging_active=False,
                anastomosis_topology=AnastomosisTopology(beta_0=1, beta_1=3),
                biomass_density_kg_m3=[0.5] * 8,
                tip_density_m3=[1000.0] * 8,
                eps_streamer_fraction=[0.2] * 8,
            )

    def test_biomass_array_bool_in_biofilm_envelope(self) -> None:
        """Injecting boolean into biomass array must raise CategoryTypeViolation."""
        biomass = [0.1, True, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]  # type: ignore[list-item]
        with self.assertRaises(CategoryTypeViolation):
            BiofilmSessionEnvelope(
                sequence_id="seq_s4_adv",
                container_header="M7.8",
                circadian_state=CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=0.0),
                cytoplasmic_streaming_velocity_um_s=25.0,
                hex1_woronin_plugging_active=False,
                anastomosis_topology=AnastomosisTopology(beta_0=1, beta_1=3),
                biomass_density_kg_m3=biomass,
                tip_density_m3=[1000.0] * 8,
                eps_streamer_fraction=[0.2] * 8,
            )

    def test_continuous_observable_bool_in_gate_g2(self) -> None:
        """Gate G2 with boolean in continuous_float64_payload must fail and trip Boundary."""
        res = LogicGatesEvaluator.evaluate_gate_g2(
            continuous_float64_payload={"k_eff": True}
        )
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Boundary", res.defect_axes_tripped)


class TestTarjanCyclicFeedbackAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging acyclic Tarjan DAG invariants against cyclic feedback attacks."""

    def test_matlab_to_openfoam_feedback_edge_detected(self) -> None:
        """Injecting feedback edge from MATLAB back to OpenFOAM must raise TarjanVerificationError."""
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD")
        ]
        with self.assertRaises(TarjanVerificationError) as ctx:
            TarjanBridgeVerifier.verify_solver_pipeline(directed_edges=cyclic_edges)
        err = str(ctx.exception)
        self.assertTrue(
            "Acyclic Tarjan constraint violated" in err
            or "Inter-solver topological loop detected" in err
            or "not nilpotent" in err
        )

    def test_matlab_to_smbr_feedback_edge_detected(self) -> None:
        """Injecting feedback edge from MATLAB back to SMBR must raise TarjanVerificationError."""
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "SmallModularBioReactors_Multiscale_ODE")
        ]
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(directed_edges=cyclic_edges)

    def test_openfoam_self_loop_detected(self) -> None:
        """Injecting self-loop on OpenFOAM node must raise TarjanVerificationError."""
        loop_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("OpenFOAM_FiniteVolume_CFD", "OpenFOAM_FiniteVolume_CFD")
        ]
        with self.assertRaises(TarjanVerificationError) as ctx:
            TarjanBridgeVerifier.verify_solver_pipeline(directed_edges=loop_edges)
        self.assertIn("Self-loop detected", str(ctx.exception))

    def test_two_node_mutual_cycle_detected(self) -> None:
        """Injecting mutual cycle between OpenFOAM and PHREEQC must raise TarjanVerificationError."""
        nodes = ["OpenFOAM_FiniteVolume_CFD", "PHREEQC_Geochemical_Speciation"]
        edges = [
            ("OpenFOAM_FiniteVolume_CFD", "PHREEQC_Geochemical_Speciation"),
            ("PHREEQC_Geochemical_Speciation", "OpenFOAM_FiniteVolume_CFD"),
        ]
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(nodes=nodes, directed_edges=edges)

    def test_tarjan_scc_finds_component_greater_than_one(self) -> None:
        """tarjan_scc must group cyclic nodes into a single component of size > 1."""
        nodes = TarjanBridgeVerifier.DEFAULT_SOLVER_NODES
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD")
        ]
        sccs = tarjan_scc(nodes, cyclic_edges)
        max_scc = max(len(c) for c in sccs)
        self.assertEqual(max_scc, 5)

    def test_nilpotency_fails_on_cyclic_feedback(self) -> None:
        """verify_nilpotent_adjacency must return False when a feedback edge is present."""
        nodes = TarjanBridgeVerifier.DEFAULT_SOLVER_NODES
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD")
        ]
        is_nilpotent, _ = verify_nilpotent_adjacency(nodes, cyclic_edges)
        self.assertFalse(is_nilpotent)

    def test_betti_1_cycle_rank_greater_than_zero_on_feedback(self) -> None:
        """compute_betti_numbers must yield beta_1 == 1 when a cycle is introduced."""
        nodes = TarjanBridgeVerifier.DEFAULT_SOLVER_NODES
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD")
        ]
        beta_0, beta_1 = compute_betti_numbers(nodes, cyclic_edges)
        self.assertEqual(beta_0, 1)
        self.assertEqual(beta_1, 1)

    def test_gate_g3_trips_coordination_on_cyclic_feedback(self) -> None:
        """Gate G3 evaluation with cyclic feedback edge must fail and trip Coordination defect."""
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD")
        ]
        res = LogicGatesEvaluator.evaluate_gate_g3(directed_edges=cyclic_edges)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Coordination", res.defect_axes_tripped)

    def test_orderbook_settlement_reverse_edge_rejected(self) -> None:
        """TarjanBridgeVerifier.verify_orderbook_settlement_bridge must reject reverse edge from ledger."""
        with self.assertRaises(TarjanVerificationError) as ctx:
            TarjanBridgeVerifier.verify_orderbook_settlement_bridge(
                orderbook_edges=[("m1", "m2"), ("m2", "m1")],
                balance_tree_edges=[("ledger_root", "ledger_child")],
                reverse_ledger_to_orderbook_edge=("ledger_child", "m1"),
            )
        self.assertIn("Reverse edge from balance ledger", str(ctx.exception))

    def test_gate_g4_trips_coordination_on_reverse_settlement_edge(self) -> None:
        """Gate G4 evaluation with reverse settlement edge must fail and trip Coordination."""
        res = LogicGatesEvaluator.evaluate_gate_g4(reverse_ledger_to_orderbook_edge=True)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Coordination", res.defect_axes_tripped)


class TestNonRecursiveGuardAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging non-recursive execution invariants (recursion_depth == 0)."""

    def test_recursion_depth_1_in_master_event_raises_schema_validation_error(self) -> None:
        """recursion_depth = 1 in MasterEvent must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError) as ctx:
            MasterEvent(
                event_id="evt_adv_rec_1",
                timestamp_utc="2026-11-02T10:00:00Z",
                subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
                envelope_type="NeuralComposeFixtureEnvelope",
                payload={},
                recursion_depth=1,
            )
        self.assertIn("Non-recursive invariant violated", str(ctx.exception))

    def test_recursion_depth_negative_1_raises_schema_validation_error(self) -> None:
        """recursion_depth = -1 in MasterEvent must raise SchemaValidationError."""
        with self.assertRaises(SchemaValidationError):
            MasterEvent(
                event_id="evt_adv_rec_neg",
                timestamp_utc="2026-11-02T10:00:00Z",
                subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
                envelope_type="NeuralComposeFixtureEnvelope",
                payload={},
                recursion_depth=-1,
            )

    def test_recursion_depth_float_raises_category_violation(self) -> None:
        """recursion_depth = 1.0 (float) in MasterEvent must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MasterEvent(
                event_id="evt_adv_rec_float",
                timestamp_utc="2026-11-02T10:00:00Z",
                subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
                envelope_type="NeuralComposeFixtureEnvelope",
                payload={},
                recursion_depth=1.0,  # type: ignore[arg-type]
            )

    def test_recursion_depth_bool_raises_category_violation(self) -> None:
        """recursion_depth = True (boolean) in MasterEvent must raise CategoryTypeViolation."""
        with self.assertRaises(CategoryTypeViolation):
            MasterEvent(
                event_id="evt_adv_rec_bool",
                timestamp_utc="2026-11-02T10:00:00Z",
                subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
                envelope_type="NeuralComposeFixtureEnvelope",
                payload={},
                recursion_depth=True,  # type: ignore[arg-type]
            )

    def test_validate_master_event_dict_with_recursion_depth_1(self) -> None:
        """validate_master_event dict validator must reject recursion_depth = 1."""
        event_dict = {
            "event_id": "evt_dict_adv",
            "timestamp_utc": "2026-11-02T10:00:00Z",
            "subsystem_id": "S1_NeuralCompose_Functorial_Fixtures",
            "envelope_type": "NeuralComposeFixtureEnvelope",
            "recursion_depth": 1,
            "defect_flags": {"Boundary": False, "Control": False, "Source": False, "Coordination": False},
            "epistemic_status": ":Accepted",
            "payload": {},
        }
        with self.assertRaises(SchemaValidationError):
            validate_master_event(event_dict)

    def test_tarjan_verify_solver_pipeline_recursion_depth_1_raises(self) -> None:
        """TarjanBridgeVerifier.verify_solver_pipeline with recursion_depth = 1 must raise TarjanVerificationError."""
        with self.assertRaises(TarjanVerificationError) as ctx:
            TarjanBridgeVerifier.verify_solver_pipeline(recursion_depth=1)
        self.assertIn("Non-recursive constraint violated", str(ctx.exception))

    def test_tarjan_verify_solver_pipeline_consolidation_rule_mutable_raises(self) -> None:
        """TarjanBridgeVerifier.verify_solver_pipeline with consolidation_rule_immutable = False must raise."""
        with self.assertRaises(TarjanVerificationError) as ctx:
            TarjanBridgeVerifier.verify_solver_pipeline(consolidation_rule_immutable=False)
        self.assertIn("consolidation_rule_immutable must be True", str(ctx.exception))

    def test_gate_g3_trips_coordination_on_recursion_depth_1(self) -> None:
        """Gate G3 evaluation with recursion_depth = 1 must fail and trip Coordination defect."""
        res = LogicGatesEvaluator.evaluate_gate_g3(recursion_depth=1)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Coordination", res.defect_axes_tripped)

    def test_transition_trips_coordination_and_rejects_on_recursion_depth_nonzero(self) -> None:
        """evaluate_transition with recursion_depth = 1 on source event must reject transition."""
        source = MasterEvent(
            event_id="evt_src_rec",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
            envelope_type="NeuralComposeFixtureEnvelope",
            payload={},
            recursion_depth=0,
        )
        target = MasterEvent(
            event_id="evt_tgt_rec",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S2_Momentum_Automata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload={},
            recursion_depth=0,
        )
        # Directly mutate recursion_depth to test transition defense
        object.__setattr__(source, "recursion_depth", 1)

        res = LogicGatesEvaluator.evaluate_transition(source, target)
        self.assertFalse(res.transition_valid)
        self.assertEqual(res.enforced_epistemic_status, ":Rejected")
        self.assertTrue(res.defect_flags["Coordination"])
        self.assertIn("Non-recursive execution invariant violated", res.reasons[0])


class TestDefectAxisTrippingAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging defect axis tripping across Boundary, Control, Source, Coordination."""

    def test_control_axis_tripped_on_zpd_tension_overhang(self) -> None:
        """ZPD tension D_M = 2.8 (> 2.45) in S1 must trip Control defect in S1->S2 transition."""
        s1_payload = NeuralComposeFixtureEnvelope(
            sequence_id="seq_s1_zpd",
            functor_stage="F_Laya",
            frame_index=15,
            betti_numbers=BettiNumbers(beta_0=1, beta_1=3),
            defect_axes=DefectAxes(control=True),
            toy_drive_active=True,
            mahalanobis_tension_D_M=2.80,
        )
        s1_event = MasterEvent(
            event_id="evt_s1_zpd",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
            envelope_type="NeuralComposeFixtureEnvelope",
            payload=s1_payload,
        )
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_wbr",
            criticality_metrics=CriticalityMetrics(k_eff=1.002, rho_pcm=20.0, z_crit=1.0, chi=0.5),
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=0.8,
            retention_pool_active=False,
        )
        # Use subsystem_id matching evaluator logic gate trigger
        s2_event = MasterEvent(
            event_id="evt_s2_wbr",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S2_MomentumAutomata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s1_event, s2_event)
        self.assertTrue(res.defect_flags["Control"])
        self.assertEqual(res.enforced_epistemic_status, ":Incomplete")
        self.assertTrue(res.transition_valid)  # :Incomplete is allowed to proceed quarantined

    def test_control_axis_tripped_on_wbr_panic_mode(self) -> None:
        """Momentum Automata in Panic mode must trip Control defect in S1->S2 transition."""
        s1_payload = NeuralComposeFixtureEnvelope(
            sequence_id="seq_s1_ok",
            functor_stage="F_Laya",
            frame_index=10,
            betti_numbers=BettiNumbers(beta_0=1, beta_1=2),
            defect_axes=DefectAxes(),
            toy_drive_active=True,
            mahalanobis_tension_D_M=1.2,
        )
        s1_event = MasterEvent(
            event_id="evt_s1_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
            envelope_type="NeuralComposeFixtureEnvelope",
            payload=s1_payload,
        )
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_panic",
            criticality_metrics=CriticalityMetrics(k_eff=1.002, rho_pcm=20.0, z_crit=1.0, chi=0.5),
            criticality_regime="PROMPT_SCRAM",
            wbr_mode="Panic",
            hysteresis_loop_area=4.5,
            retention_pool_active=True,
        )
        # Use subsystem_id matching evaluator logic gate trigger
        s2_event = MasterEvent(
            event_id="evt_s2_panic",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S2_MomentumAutomata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s1_event, s2_event)
        self.assertTrue(res.defect_flags["Control"])
        self.assertEqual(res.enforced_epistemic_status, ":Incomplete")

    def test_control_axis_tripped_on_dollar_size_classification(self) -> None:
        """Gate G4 classifying positions by dollar size instead of latency must trip Control defect."""
        res = LogicGatesEvaluator.evaluate_gate_g4(classify_by_dollar_size_instead_of_latency=True)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Control", res.defect_axes_tripped)

    def test_control_axis_tripped_on_unstoppable_cec_trigger(self) -> None:
        """Gate G4 with unstoppable CEC trigger must trip Control defect and reject."""
        res = LogicGatesEvaluator.evaluate_gate_g4(cec_algo_exit_trigger_stoppable=False)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Control", res.defect_axes_tripped)

    def test_control_axis_tripped_on_alara_80_percent_safing(self) -> None:
        """Gate G7 with dose 0.045 Gy (> 0.040 Gy 80% threshold) must trip Control defect."""
        res = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.045)
        self.assertTrue(res.details["payload_safing_triggered"])
        self.assertIn("Control", res.defect_axes_tripped)

    def test_boundary_axis_tripped_on_unit_scale_conflation(self) -> None:
        """Gate G1 with unit_scale != 1000.0 must trip Boundary defect and reject."""
        res = LogicGatesEvaluator.evaluate_gate_g1(unit_scale_km_to_m=100.0)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Boundary", res.defect_axes_tripped)

    def test_boundary_axis_tripped_on_mesh_tearing(self) -> None:
        """Gate G6 with interpolation tearing > 0.001 must trip Boundary defect and reject."""
        res = LogicGatesEvaluator.evaluate_gate_g6(max_interpolation_tearing_residual=0.05)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Boundary", res.defect_axes_tripped)

    def test_boundary_axis_tripped_on_multipool_count_violation(self) -> None:
        """MultiPoolReactorEnvelope with n_pool != 8 in S2->S3 transition must trip Boundary and reject."""
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_ok",
            criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=0.5),
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=0.5,
            retention_pool_active=False,
        )
        s2_event = MasterEvent(
            event_id="evt_s2_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S2_MomentumAutomata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )
        s3_payload = MultiPoolReactorEnvelope(
            sequence_id="seq_s3_bad_npool",
            container_header="M7.3",
            n_pool=8,
            chamber_ids=[f"ch_{i}" for i in range(8)],
            sucrose_concentrations_mol_m3=[55.0] * 8,
            temperatures_kelvin=[298.15] * 8,
            phreeqc_activity_avg_ph=7.0,
            phreeqc_charge_imbalance_pct=0.2,
            radiolytic_h2o2_scavenged_uM=[15.0] * 8,
            nutmeg_quarantine_status=":Accepted",
        )
        # Directly set n_pool to 7 to test transition defense
        object.__setattr__(s3_payload, "n_pool", 7)
        s3_event = MasterEvent(
            event_id="evt_s3_bad",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S3_ReactorPools_SMBR_OpenMC_MATLAB",
            envelope_type="MultiPoolReactorEnvelope",
            payload=s3_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s2_event, s3_event)
        self.assertFalse(res.transition_valid)
        self.assertEqual(res.enforced_epistemic_status, ":Rejected")
        self.assertTrue(res.defect_flags["Boundary"])

    def test_boundary_axis_tripped_on_streaming_velocity_out_of_bounds(self) -> None:
        """Biofilm streaming velocity 65.0 um/s (> 60.0) in S3->S4 transition must trip Boundary and reject."""
        s3_payload = MultiPoolReactorEnvelope(
            sequence_id="seq_s3_ok",
            container_header="M7.3",
            n_pool=8,
            chamber_ids=[f"ch_{i}" for i in range(8)],
            sucrose_concentrations_mol_m3=[55.0] * 8,
            temperatures_kelvin=[298.15] * 8,
            phreeqc_activity_avg_ph=7.0,
            phreeqc_charge_imbalance_pct=0.2,
            radiolytic_h2o2_scavenged_uM=[15.0] * 8,
            nutmeg_quarantine_status=":Accepted",
        )
        s3_event = MasterEvent(
            event_id="evt_s3_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S3_ReactorPools_SMBR_OpenMC_MATLAB",
            envelope_type="MultiPoolReactorEnvelope",
            payload=s3_payload,
        )
        s4_payload = BiofilmSessionEnvelope(
            sequence_id="seq_s4_fast",
            container_header="M7.8",
            circadian_state=CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=0.0),
            cytoplasmic_streaming_velocity_um_s=25.0,
            hex1_woronin_plugging_active=False,
            anastomosis_topology=AnastomosisTopology(beta_0=1, beta_1=3),
            biomass_density_kg_m3=[0.5] * 8,
            tip_density_m3=[1000.0] * 8,
            eps_streamer_fraction=[0.2] * 8,
        )
        # Directly set velocity to 65.0 to test transition defense
        object.__setattr__(s4_payload, "cytoplasmic_streaming_velocity_um_s", 65.0)
        s4_event = MasterEvent(
            event_id="evt_s4_fast",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S4_BiofilmsSessions_Neurospora_M7_Workbench",
            envelope_type="BiofilmSessionEnvelope",
            payload=s4_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s3_event, s4_event)
        self.assertFalse(res.transition_valid)
        self.assertEqual(res.enforced_epistemic_status, ":Rejected")
        self.assertTrue(res.defect_flags["Boundary"])

    def test_source_axis_tripped_on_unverified_spice_body(self) -> None:
        """Gate G1 with spkpos_verified_on_known_body = False must trip Source and quarantine :Incomplete."""
        res = LogicGatesEvaluator.evaluate_gate_g1(spkpos_verified_on_known_body=False)
        self.assertIn("Source", res.defect_axes_tripped)
        self.assertEqual(res.epistemic_status, ":Incomplete")

    def test_source_axis_tripped_on_sub280k_nutmeg_temperature(self) -> None:
        """MultiPool temperature 275.0 K (< 280 K) in S2->S3 transition must trip Source and quarantine :Incomplete."""
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_ok",
            criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=0.5),
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=0.5,
            retention_pool_active=False,
        )
        s2_event = MasterEvent(
            event_id="evt_s2_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S2_MomentumAutomata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )
        s3_payload = MultiPoolReactorEnvelope(
            sequence_id="seq_s3_cold",
            container_header="M7.3",
            n_pool=8,
            chamber_ids=[f"ch_{i}" for i in range(8)],
            sucrose_concentrations_mol_m3=[55.0] * 8,
            temperatures_kelvin=[275.0] + [298.15] * 7,
            phreeqc_activity_avg_ph=7.0,
            phreeqc_charge_imbalance_pct=0.2,
            radiolytic_h2o2_scavenged_uM=[15.0] * 8,
            nutmeg_quarantine_status=":Incomplete",
        )
        s3_event = MasterEvent(
            event_id="evt_s3_cold",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S3_ReactorPools_SMBR_OpenMC_MATLAB",
            envelope_type="MultiPoolReactorEnvelope",
            payload=s3_payload,
            epistemic_status=":Incomplete",
        )

        res = LogicGatesEvaluator.evaluate_transition(s2_event, s3_event)
        self.assertTrue(res.defect_flags["Source"])
        self.assertEqual(res.enforced_epistemic_status, ":Incomplete")
        self.assertTrue(res.transition_valid)  # Quarantined but valid transition

    def test_source_axis_tripped_on_openmc_cross_section_divergence(self) -> None:
        """Gate G6 with divergent OpenMC cross-section tally must trip Source defect and reject."""
        res = LogicGatesEvaluator.evaluate_gate_g6(openmc_dose_rate_jeff33_mSv_hr=0.0200)
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Source", res.defect_axes_tripped)

    def test_coordination_axis_tripped_on_betti_0_fragmentation(self) -> None:
        """NeuralCompose beta_0 = 2 (fragmented graph) in S1->S2 transition must trip Coordination and reject."""
        s1_payload = NeuralComposeFixtureEnvelope(
            sequence_id="seq_s1_frag",
            functor_stage="F_Laya",
            frame_index=10,
            betti_numbers=BettiNumbers(beta_0=2, beta_1=1),
            defect_axes=DefectAxes(coordination=True),
            toy_drive_active=True,
            mahalanobis_tension_D_M=1.2,
        )
        s1_event = MasterEvent(
            event_id="evt_s1_frag",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
            envelope_type="NeuralComposeFixtureEnvelope",
            payload=s1_payload,
        )
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_ok",
            criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=0.5),
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=0.5,
            retention_pool_active=False,
        )
        s2_event = MasterEvent(
            event_id="evt_s2_ok",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S2_MomentumAutomata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s1_event, s2_event)
        self.assertFalse(res.transition_valid)
        self.assertEqual(res.enforced_epistemic_status, ":Rejected")
        self.assertTrue(res.defect_flags["Coordination"])

    def test_coordination_axis_tripped_on_anastomosis_disconnection(self) -> None:
        """Biofilm with disconnected anastomosis in S3->S4 transition must trip Coordination and reject."""
        s3_payload = MultiPoolReactorEnvelope(
            sequence_id="seq_s3_ok",
            container_header="M7.3",
            n_pool=8,
            chamber_ids=[f"ch_{i}" for i in range(8)],
            sucrose_concentrations_mol_m3=[55.0] * 8,
            temperatures_kelvin=[298.15] * 8,
            phreeqc_activity_avg_ph=7.0,
            phreeqc_charge_imbalance_pct=0.2,
            radiolytic_h2o2_scavenged_uM=[15.0] * 8,
            nutmeg_quarantine_status=":Accepted",
        )
        s3_event = MasterEvent(
            event_id="evt_s3_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S3_ReactorPools_SMBR_OpenMC_MATLAB",
            envelope_type="MultiPoolReactorEnvelope",
            payload=s3_payload,
        )
        s4_payload = BiofilmSessionEnvelope(
            sequence_id="seq_s4_disc",
            container_header="M7.8",
            circadian_state=CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=0.0),
            cytoplasmic_streaming_velocity_um_s=25.0,
            hex1_woronin_plugging_active=False,
            anastomosis_topology=AnastomosisTopology(beta_0=1, beta_1=3),
            biomass_density_kg_m3=[0.5] * 8,
            tip_density_m3=[1000.0] * 8,
            eps_streamer_fraction=[0.2] * 8,
        )
        # Directly set anastomosis beta_1 = 0 to test transition defense
        object.__setattr__(s4_payload.anastomosis_topology, "beta_1", 0)
        s4_event = MasterEvent(
            event_id="evt_s4_disc",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S4_BiofilmsSessions_Neurospora_M7_Workbench",
            envelope_type="BiofilmSessionEnvelope",
            payload=s4_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s3_event, s4_event)
        self.assertFalse(res.transition_valid)
        self.assertEqual(res.enforced_epistemic_status, ":Rejected")
        self.assertTrue(res.defect_flags["Coordination"])

    def test_coordination_axis_tripped_on_swarm_cut_vertex(self) -> None:
        """Gate G6 with linear chain swarm (containing cut-vertices) must trip Coordination and reject."""
        linear_nodes = ["agent_1", "agent_2", "agent_3"]
        linear_edges = [("agent_1", "agent_2"), ("agent_2", "agent_3")]
        res = LogicGatesEvaluator.evaluate_gate_g6(
            swarm_nodes=linear_nodes,
            swarm_undirected_edges=linear_edges,
        )
        self.assertFalse(res.passed)
        self.assertEqual(res.epistemic_status, ":Rejected")
        self.assertIn("Coordination", res.defect_axes_tripped)

    # ==========================================================================
    # Empirical Vulnerability Discovery Tests
    # ==========================================================================
    def test_empirical_vulnerability_canonical_subsystem_id_silent_bypass_s1_to_s2(self) -> None:
        """Empirically prove that canonical S2_Momentum_Automata_Criticality_Engine bypasses transition checks.

        Bug cause: LogicGatesEvaluator checks:
            if 'NeuralCompose' in s_sub and 'MomentumAutomata' in t_sub:
        Because canonical t_sub is 'S2_Momentum_Automata_Criticality_Engine' (with underscore),
        'MomentumAutomata' is NOT in t_sub, so the ZPD panic check is silently skipped!
        """
        s1_payload = NeuralComposeFixtureEnvelope(
            sequence_id="seq_s1_zpd",
            functor_stage="F_Laya",
            frame_index=15,
            betti_numbers=BettiNumbers(beta_0=1, beta_1=3),
            defect_axes=DefectAxes(control=True),
            toy_drive_active=True,
            mahalanobis_tension_D_M=2.80,  # Should trip Control defect!
        )
        s1_event = MasterEvent(
            event_id="evt_s1_zpd",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
            envelope_type="NeuralComposeFixtureEnvelope",
            payload=s1_payload,
        )
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_wbr",
            criticality_metrics=CriticalityMetrics(k_eff=1.002, rho_pcm=20.0, z_crit=1.0, chi=0.5),
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=0.8,
            retention_pool_active=False,
        )
        # Using canonical subsystem_id with underscore:
        s2_event = MasterEvent(
            event_id="evt_s2_wbr",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S2_Momentum_Automata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s1_event, s2_event)
        # Under canonical ID with underscore, defect_flags['Control'] is False because the branch was skipped!
        self.assertFalse(
            res.defect_flags["Control"],
            "Vulnerability confirmed: canonical subsystem_id silently bypassed ZPD tension check!",
        )

    def test_empirical_vulnerability_canonical_subsystem_id_silent_bypass_s2_to_s3(self) -> None:
        """Empirically prove that canonical S3_Reactor_Pools_SMBR_OpenMC_MATLAB bypasses sub-280K check.

        Bug cause: LogicGatesEvaluator checks:
            elif 'MomentumAutomata' in s_sub and 'ReactorPools' in t_sub:
        Because canonical s_sub is 'S2_Momentum_Automata_Criticality_Engine' and
        t_sub is 'S3_Reactor_Pools_SMBR_OpenMC_MATLAB', neither contains the un-underscored string!
        """
        s2_payload = MomentumAutomataEnvelope(
            sequence_id="seq_s2_ok",
            criticality_metrics=CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=0.5),
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=0.5,
            retention_pool_active=False,
        )
        s2_event = MasterEvent(
            event_id="evt_s2_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S2_Momentum_Automata_Criticality_Engine",
            envelope_type="MomentumAutomataEnvelope",
            payload=s2_payload,
        )
        s3_payload = MultiPoolReactorEnvelope(
            sequence_id="seq_s3_cold",
            container_header="M7.3",
            n_pool=8,
            chamber_ids=[f"ch_{i}" for i in range(8)],
            sucrose_concentrations_mol_m3=[55.0] * 8,
            temperatures_kelvin=[275.0] + [298.15] * 7,  # Sub-280 K: should trip Source!
            phreeqc_activity_avg_ph=7.0,
            phreeqc_charge_imbalance_pct=0.2,
            radiolytic_h2o2_scavenged_uM=[15.0] * 8,
            nutmeg_quarantine_status=":Incomplete",
        )
        s3_event = MasterEvent(
            event_id="evt_s3_cold",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S3_Reactor_Pools_SMBR_OpenMC_MATLAB",
            envelope_type="MultiPoolReactorEnvelope",
            payload=s3_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s2_event, s3_event)
        # Under canonical ID with underscore, defect_flags['Source'] is False because the branch was skipped!
        self.assertFalse(
            res.defect_flags["Source"],
            "Vulnerability confirmed: canonical subsystem_id silently bypassed sub-280K NutMEG check!",
        )

    def test_empirical_vulnerability_canonical_subsystem_id_silent_bypass_s3_to_s4(self) -> None:
        """Empirically prove that canonical S4_Biofilms_Sessions_Neurospora_M7_Workbench bypasses velocity check.

        Bug cause: LogicGatesEvaluator checks:
            elif 'ReactorPools' in s_sub and 'BiofilmsSessions' in t_sub:
        Because canonical s_sub is 'S3_Reactor_Pools_SMBR_OpenMC_MATLAB' and
        t_sub is 'S4_Biofilms_Sessions_Neurospora_M7_Workbench', neither matches!
        """
        s3_payload = MultiPoolReactorEnvelope(
            sequence_id="seq_s3_ok",
            container_header="M7.3",
            n_pool=8,
            chamber_ids=[f"ch_{i}" for i in range(8)],
            sucrose_concentrations_mol_m3=[55.0] * 8,
            temperatures_kelvin=[298.15] * 8,
            phreeqc_activity_avg_ph=7.0,
            phreeqc_charge_imbalance_pct=0.2,
            radiolytic_h2o2_scavenged_uM=[15.0] * 8,
            nutmeg_quarantine_status=":Accepted",
        )
        s3_event = MasterEvent(
            event_id="evt_s3_ok",
            timestamp_utc="2026-11-02T10:00:00Z",
            subsystem_id="S3_Reactor_Pools_SMBR_OpenMC_MATLAB",
            envelope_type="MultiPoolReactorEnvelope",
            payload=s3_payload,
        )
        s4_payload = BiofilmSessionEnvelope(
            sequence_id="seq_s4_fast",
            container_header="M7.8",
            circadian_state=CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=0.0),
            cytoplasmic_streaming_velocity_um_s=25.0,
            hex1_woronin_plugging_active=False,
            anastomosis_topology=AnastomosisTopology(beta_0=1, beta_1=3),
            biomass_density_kg_m3=[0.5] * 8,
            tip_density_m3=[1000.0] * 8,
            eps_streamer_fraction=[0.2] * 8,
        )
        object.__setattr__(s4_payload, "cytoplasmic_streaming_velocity_um_s", 65.0)  # > 60 um/s!
        s4_event = MasterEvent(
            event_id="evt_s4_fast",
            timestamp_utc="2026-11-02T10:00:01Z",
            subsystem_id="S4_Biofilms_Sessions_Neurospora_M7_Workbench",
            envelope_type="BiofilmSessionEnvelope",
            payload=s4_payload,
        )

        res = LogicGatesEvaluator.evaluate_transition(s3_event, s4_event)
        # Under canonical ID with underscore, transition_valid is True because the check was skipped!
        self.assertTrue(
            res.transition_valid,
            "Vulnerability confirmed: canonical subsystem_id silently bypassed streaming velocity check!",
        )


class TestTypographicHygieneAdversarial(unittest.TestCase):
    """Adversarial stress tests challenging typographic hygiene (strictly zero em-dashes and zero en-dashes)."""

    def test_json_payload_with_em_dash_rejected(self) -> None:
        """MasterEvent.from_json must reject payloads containing Unicode em-dash (U+2014)."""
        em_dash_json = (
            '{\n'
            '  "event_id": "evt_em_dash",\n'
            '  "timestamp_utc": "2026-11-02T10:00:00Z",\n'
            '  "subsystem_id": "S1_NeuralCompose_Functorial_Fixtures",\n'
            '  "envelope_type": "NeuralComposeFixtureEnvelope",\n'
            '  "recursion_depth": 0,\n'
            '  "defect_flags": {"Boundary": false, "Control": false, "Source": false, "Coordination": false},\n'
            '  "epistemic_status": ":Accepted",\n'
            '  "notes": "Invalid \u2014 em dash in text",\n'
            '  "payload": {}\n'
            '}'
        )
        with self.assertRaises(MasterEventContractError) as ctx:
            MasterEvent.from_json(em_dash_json)
        self.assertIn("forbidden em-dash", str(ctx.exception))

    def test_json_payload_with_en_dash_rejected(self) -> None:
        """MasterEvent.from_json must reject payloads containing Unicode en-dash (U+2013)."""
        en_dash_json = (
            '{\n'
            '  "event_id": "evt_en_dash",\n'
            '  "timestamp_utc": "2026-11-02T10:00:00Z",\n'
            '  "subsystem_id": "S1_NeuralCompose_Functorial_Fixtures",\n'
            '  "envelope_type": "NeuralComposeFixtureEnvelope",\n'
            '  "recursion_depth": 0,\n'
            '  "defect_flags": {"Boundary": false, "Control": false, "Source": false, "Coordination": false},\n'
            '  "epistemic_status": ":Accepted",\n'
            '  "notes": "Invalid \u2013 en dash in text",\n'
            '  "payload": {}\n'
            '}'
        )
        with self.assertRaises(MasterEventContractError) as ctx:
            MasterEvent.from_json(en_dash_json)
        self.assertIn("forbidden em-dash or en-dash", str(ctx.exception))

    def test_codebase_typographic_hygiene(self) -> None:
        """Scan all contract implementation files to ensure strictly zero em-dashes and zero en-dashes."""
        target_dirs = [
            REPO_ROOT / "Scripts" / "contracts",
            REPO_ROOT / "configs",
            REPO_ROOT / ".agents" / "teamwork" / "challenger_1",
        ]
        violations: list[str] = []
        for tdir in target_dirs:
            if not tdir.exists():
                continue
            for fpath in tdir.rglob("*"):
                if fpath.is_file() and fpath.suffix in (".py", ".json", ".md"):
                    try:
                        content = fpath.read_text(encoding="utf-8")
                    except Exception:
                        continue
                    if "\u2014" in content:
                        violations.append(f"{fpath} contains em-dash (U+2014)")
                    if "\u2013" in content:
                        violations.append(f"{fpath} contains en-dash (U+2013)")

        self.assertEqual(
            len(violations),
            0,
            f"Typographic violations found ({len(violations)}): {violations}",
        )


def run_adversarial_suite() -> dict[str, Any]:
    """Run all adversarial test cases and produce summary receipt."""
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    classes = [
        TestHeaderConflationAdversarial,
        TestBettiFloatAndDiscreteAdversarial,
        TestContinuousObservableBooleanAdversarial,
        TestTarjanCyclicFeedbackAdversarial,
        TestNonRecursiveGuardAdversarial,
        TestDefectAxisTrippingAdversarial,
        TestTypographicHygieneAdversarial,
    ]
    for cls in classes:
        suite.addTests(loader.loadTestsFromTestCase(cls))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    summary = {
        "total_tests": result.testsRun,
        "passed": result.testsRun - len(result.failures) - len(result.errors),
        "failures": len(result.failures),
        "errors": len(result.errors),
        "all_passed": (len(result.failures) == 0 and len(result.errors) == 0),
        "classes_tested": [cls.__name__ for cls in classes],
    }
    return summary


if __name__ == "__main__":
    res = run_adversarial_suite()
    print("\n" + "=" * 80)
    print("CHALLENGER 1 ADVERSARIAL STRESS TEST SUMMARY")
    print(f"Total Tests Run: {res['total_tests']}")
    print(f"Passed: {res['passed']}")
    print(f"Failures: {res['failures']}")
    print(f"Errors: {res['errors']}")
    print(f"All Passed: {res['all_passed']}")
    print("=" * 80)
    sys.exit(0 if res["all_passed"] else 1)
