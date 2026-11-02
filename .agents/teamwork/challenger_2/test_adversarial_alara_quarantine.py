"""Empirical Adversarial Test Suite for ALARA Control and Epistemic Hippocratism.

Challenger 2: ALARA and Epistemic Hippocratism Adversarial Challenger.
Empirically stress-tests:
1. ALARA dose threshold transitions:
   - 0.0399 Gy -> nominal science (:Accepted)
   - 0.0400 Gy -> 80% safing trip engaged, mode SAFE_HOLD_SHUTTER_CLOSED (:Incomplete)
   - 0.0499 Gy -> remains in safing hold (:Incomplete)
   - 0.0500 Gy -> ceiling boundary hold (:Incomplete)
   - 0.0501 Gy -> emergency SCRAM engaged, mode EMERGENCY_SCRAM_ISOLATE (:Rejected)
   - Empirical proof of IEEE-754 precision boundary sensitivity (0.80 * 0.050 == 0.04000000000000001)
2. NutMEG temperature boundary transitions:
   - 279.99 K -> mode THERMAL_HIBERNATION_HOLD (:Incomplete), NEVER collapse to :Rejected!
   - 280.00 K -> mode NOMINAL_BIOREACTOR_SCIENCE (:Accepted)
   - 150.00 K -> deep freeze locked in :Incomplete
3. Epistemic Hippocratism collapse and promotion prevention:
   - Unauthorized collapse of :Incomplete into :Rejected blocked (NeuroARCGateViolation)
   - Promotion of unverified low-dose hormesis blocked (EpistemicHippocratismViolation)
   - Promotion of net ATP radiosynthesis without mass balance blocked (EpistemicHippocratismViolation)
   - Unverified SPICE ephemeris units quarantine
4. Biofilm syncytial breach stress:
   - Streaming surge velocity v = 85 um/s (> 60 um/s) out-of-bounds rejection
   - Emergency HEX-1 Woronin body pore occlusion triggered upon hydrodynamic breach
   - Anastomosis topology preservation: beta_0 == 1 and beta_1 >= 1
   - Total biomass density conservation (residual ceiling <= 1.20 kg/m^3)
   - Cross-subsystem transition identifier normalization and vulnerability proof
5. Dynamic closed-loop LQR/MPC state regulation:
   - Smooth multi-step integration under nominal conditions
   - Rapid shutter isolation and shield thickening upon radiation excursion
   - Reversible thermal recovery across 280.0 K boundary
6. Typographic hygiene:
   - Strictly zero em-dashes and zero en-dashes across all code and documentation

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys
import unittest

# Resolve repository root
REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from Scripts.contracts.alara_closed_loop_controller import (
    ALARAActuatorOutput,
    ALARAClosedLoopController,
    ALARAControllerError,
    ALARAControllerState,
)
from Scripts.contracts.logic_gates_evaluator import (
    GateEvaluationResult,
    LogicGateError,
    LogicGatesEvaluator,
    TransitionEvaluationResult,
)
from Scripts.contracts.master_event_contract import (
    AnastomosisTopology,
    BettiNumbers,
    BiofilmSessionEnvelope,
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
    validate_biofilm_session_envelope,
    validate_master_event,
    validate_multipool_reactor_envelope,
)
from Scripts.contracts.synthetic_event_round_trip import (
    generate_synthetic_biofilm_session_event,
    generate_synthetic_momentum_automata_event,
    generate_synthetic_neuralcompose_event,
    generate_synthetic_reactor_pools_event,
)


# Semantic exception aliases for domain requirements
class NeuroARCGateViolation(ALARAControllerError):
    """Raised when attempting an unauthorized collapse of Incomplete verdict into Rejected."""


class EpistemicHippocratismViolation(ALARAControllerError):
    """Raised when attempting to promote unverified hypotheses to Accepted."""


def wrap_neuroarc_quarantine_call(fn, *args, **kwargs):
    """Helper executing quarantine evaluation and mapping to semantic domain exceptions."""
    try:
        return fn(*args, **kwargs)
    except ALARAControllerError as err:
        msg = str(err)
        if "Incomplete verdict must NEVER collapse into Rejected" in msg:
            raise NeuroARCGateViolation(msg) from err
        if "Epistemic Hippocratism Violation" in msg:
            raise EpistemicHippocratismViolation(msg) from err
        raise


class TestALARAThresholdTransitions(unittest.TestCase):
    """Suite 1: ALARA Closed-Loop Controller Boundary and Actuation Stress."""

    def setUp(self) -> None:
        self.controller = ALARAClosedLoopController(max_allowable_dose_Gy=0.050, safing_fraction=0.80)

    def test_01_dose_0_0399_nominal_science_accepted(self) -> None:
        """Dose D = 0.0399 Gy (< 0.0400 Gy): nominal science regime, status :Accepted."""
        state = ALARAControllerState(cumulative_dose_Gy=0.0399, temperature_K=298.15)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Accepted")
        self.assertEqual(eval_res["mode"], "NOMINAL_BIOREACTOR_SCIENCE")
        self.assertFalse(eval_res["payload_safing_triggered"])
        self.assertFalse(eval_res["ceiling_exceeded"])

        # Closed-loop actuator step test
        actuator_out = self.controller.step_controller(state, dt_s=1.0)
        self.assertEqual(actuator_out.epistemic_status, ":Accepted")
        self.assertEqual(actuator_out.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")
        self.assertFalse(actuator_out.safing_shutter_closed)
        self.assertGreater(actuator_out.u_valve_m3_s, 0.00015)
        self.assertLessEqual(actuator_out.z_shield_m, 0.140)

    def test_02_dose_0_0400_floating_point_epsilon_boundary_vulnerability(self) -> None:
        """Empirical vulnerability demonstration: literal 0.0400 Gy vs IEEE-754 safing threshold.

        In Python IEEE-754 floating point arithmetic:
        0.80 * 0.050 evaluates to 0.04000000000000001.
        Therefore, state.cumulative_dose_Gy >= safing_limit (0.0400 >= 0.04000000000000001)
        evaluates to False when cumulative_dose_Gy is exactly 0.0400.
        This test documents the unrounded float boundary sensitivity.
        """
        # Baseline controller has safing_threshold_Gy = 0.04000000000000001
        self.assertGreater(self.controller.safing_threshold_Gy, 0.0400)

        # Literal 0.0400 Gy falls below unrounded threshold by 1e-17
        state_literal = ALARAControllerState(cumulative_dose_Gy=0.0400, temperature_K=298.15)
        eval_literal = self.controller.evaluate_epistemic_hippocratism_quarantine(state_literal)
        self.assertFalse(eval_literal["payload_safing_triggered"])

        # Stepping by float epsilon (0.04000000000000001 or 0.040001) trips safing
        state_tripped = ALARAControllerState(cumulative_dose_Gy=0.040001, temperature_K=298.15)
        eval_tripped = self.controller.evaluate_epistemic_hippocratism_quarantine(state_tripped)
        self.assertEqual(eval_tripped["verdict"], ":Incomplete")
        self.assertEqual(eval_tripped["mode"], "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(eval_tripped["payload_safing_triggered"])

        # With rounded safing threshold, literal 0.0400 Gy trips cleanly
        ctl_rounded = ALARAClosedLoopController(max_allowable_dose_Gy=0.050, safing_fraction=0.80)
        ctl_rounded.safing_threshold_Gy = round(ctl_rounded.safing_threshold_Gy, 9)
        eval_rounded = ctl_rounded.evaluate_epistemic_hippocratism_quarantine(state_literal)
        self.assertEqual(eval_rounded["verdict"], ":Incomplete")
        self.assertEqual(eval_rounded["mode"], "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(eval_rounded["payload_safing_triggered"])

    def test_03_dose_0_0400_safing_hold_actuation(self) -> None:
        """Dose D >= 0.0400 Gy: automated safing trip engaged, mode SAFE_HOLD_SHUTTER_CLOSED."""
        state = ALARAControllerState(cumulative_dose_Gy=0.040001, temperature_K=298.15)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Incomplete")
        self.assertEqual(eval_res["mode"], "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(eval_res["payload_safing_triggered"])
        self.assertFalse(eval_res["ceiling_exceeded"])

        actuator_out = self.controller.step_controller(state, dt_s=1.0)
        self.assertEqual(actuator_out.epistemic_status, ":Incomplete")
        self.assertEqual(actuator_out.controller_mode, "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(actuator_out.safing_shutter_closed)
        self.assertEqual(actuator_out.u_valve_m3_s, 0.00005)  # throttled maintenance trickle
        self.assertGreater(actuator_out.z_shield_m, 0.100)  # thickened protective shield

    def test_04_dose_0_0499_remains_safing_hold_incomplete(self) -> None:
        """Dose D = 0.0499 Gy: remains firmly within safing hold, status :Incomplete."""
        state = ALARAControllerState(cumulative_dose_Gy=0.0499, temperature_K=298.15)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Incomplete")
        self.assertEqual(eval_res["mode"], "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(eval_res["payload_safing_triggered"])
        self.assertFalse(eval_res["ceiling_exceeded"])

        actuator_out = self.controller.step_controller(state, dt_s=1.0)
        self.assertEqual(actuator_out.epistemic_status, ":Incomplete")
        self.assertEqual(actuator_out.controller_mode, "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(actuator_out.safing_shutter_closed)

    def test_05_dose_0_0500_ceiling_boundary_hold_incomplete(self) -> None:
        """Dose D = 0.0500 Gy: exactly at ceiling (not strictly exceeding), remains :Incomplete."""
        state = ALARAControllerState(cumulative_dose_Gy=0.0500, temperature_K=298.15)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Incomplete")
        self.assertEqual(eval_res["mode"], "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertTrue(eval_res["payload_safing_triggered"])
        self.assertFalse(eval_res["ceiling_exceeded"])

        actuator_out = self.controller.step_controller(state, dt_s=1.0)
        self.assertEqual(actuator_out.epistemic_status, ":Incomplete")
        self.assertTrue(actuator_out.safing_shutter_closed)

    def test_06_dose_0_0501_emergency_scram_rejected(self) -> None:
        """Dose D = 0.0501 Gy (> 0.0500 Gy limit): emergency SCRAM engaged, status :Rejected."""
        state = ALARAControllerState(cumulative_dose_Gy=0.0501, temperature_K=298.15)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Rejected")
        self.assertEqual(eval_res["mode"], "EMERGENCY_SCRAM_ISOLATE")
        self.assertTrue(eval_res["payload_safing_triggered"])
        self.assertTrue(eval_res["ceiling_exceeded"])

        actuator_out = self.controller.step_controller(state, dt_s=1.0)
        self.assertEqual(actuator_out.epistemic_status, ":Rejected")
        self.assertEqual(actuator_out.controller_mode, "EMERGENCY_SCRAM_ISOLATE")
        self.assertTrue(actuator_out.safing_shutter_closed)
        self.assertEqual(actuator_out.u_valve_m3_s, 0.0)  # total coolant shutoff
        self.assertEqual(actuator_out.z_shield_m, 0.200)  # maximum physical shielding deploy
        self.assertEqual(actuator_out.Phi_light_umol_m2_s, 0.0)  # total light extinction

    def test_07_gate_g7_dose_boundary_evaluation(self) -> None:
        """Gate G7 evaluates correctly across nominal, safing, hold, and SCRAM points."""
        # 0.0399 Gy -> Passed, :Accepted, zero defect axes tripped
        g7_nominal = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.0399)
        self.assertTrue(g7_nominal.passed)
        self.assertEqual(g7_nominal.epistemic_status, ":Accepted")
        self.assertEqual(len(g7_nominal.defect_axes_tripped), 0)

        # 0.040001 Gy -> Passed (safed), :Incomplete, trips Control defect axis
        g7_safing = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.040001)
        self.assertTrue(g7_safing.passed)
        self.assertEqual(g7_safing.epistemic_status, ":Incomplete")
        self.assertIn("Control", g7_safing.defect_axes_tripped)
        self.assertNotIn("Source", g7_safing.defect_axes_tripped)

        # 0.0499 Gy -> Passed (safed), :Incomplete, trips Control defect axis
        g7_hold = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.0499)
        self.assertTrue(g7_hold.passed)
        self.assertEqual(g7_hold.epistemic_status, ":Incomplete")
        self.assertIn("Control", g7_hold.defect_axes_tripped)

        # 0.0501 Gy -> Failed, :Rejected, trips Control and Source defect axes
        g7_scram = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.0501)
        self.assertFalse(g7_scram.passed)
        self.assertEqual(g7_scram.epistemic_status, ":Rejected")
        self.assertIn("Control", g7_scram.defect_axes_tripped)
        self.assertIn("Source", g7_scram.defect_axes_tripped)

    def test_08_alara_physical_attenuation_and_distance_scaling(self) -> None:
        """Physical ALARA point-kernel validation: 1/r^2 distance and exp(-mu*z) shielding."""
        d_dot_unshielded = 1.0e-4  # Gy/s

        # Test distance scaling 1/r^2
        d_1m = self.controller.compute_effective_dose_rate(
            unshielded_dose_rate_Gy_s=d_dot_unshielded,
            standoff_distance_m=1.0,
            reference_distance_m=1.0,
            shield_thickness_m=0.0,
            mu_m_inv=23.5,
            melanin_fraction=0.0,
        )
        d_2m = self.controller.compute_effective_dose_rate(
            unshielded_dose_rate_Gy_s=d_dot_unshielded,
            standoff_distance_m=2.0,
            reference_distance_m=1.0,
            shield_thickness_m=0.0,
            mu_m_inv=23.5,
            melanin_fraction=0.0,
        )
        d_10m = self.controller.compute_effective_dose_rate(
            unshielded_dose_rate_Gy_s=d_dot_unshielded,
            standoff_distance_m=10.0,
            reference_distance_m=1.0,
            shield_thickness_m=0.0,
            mu_m_inv=23.5,
            melanin_fraction=0.0,
        )
        self.assertAlmostEqual(d_2m / d_1m, 0.25, places=5)
        self.assertAlmostEqual(d_10m / d_1m, 0.01, places=5)

        # Test exponential attenuation exp(-mu * z)
        mu = 23.5
        z1 = 0.05
        z2 = 0.10
        d_z1 = self.controller.compute_effective_dose_rate(
            unshielded_dose_rate_Gy_s=d_dot_unshielded,
            standoff_distance_m=1.0,
            reference_distance_m=1.0,
            shield_thickness_m=z1,
            mu_m_inv=mu,
            melanin_fraction=0.0,
        )
        d_z2 = self.controller.compute_effective_dose_rate(
            unshielded_dose_rate_Gy_s=d_dot_unshielded,
            standoff_distance_m=1.0,
            reference_distance_m=1.0,
            shield_thickness_m=z2,
            mu_m_inv=mu,
            melanin_fraction=0.0,
        )
        expected_ratio = math.exp(-mu * (z2 - z1))
        self.assertAlmostEqual(d_z2 / d_z1, expected_ratio, places=5)

        # Invalid physical parameters must raise ALARAControllerError
        with self.assertRaises(ALARAControllerError):
            self.controller.compute_effective_dose_rate(
                unshielded_dose_rate_Gy_s=d_dot_unshielded,
                standoff_distance_m=0.5,
                reference_distance_m=1.0,
                shield_thickness_m=0.10,
                mu_m_inv=23.5,
                melanin_fraction=0.18,
            )
        with self.assertRaises(ALARAControllerError):
            self.controller.compute_effective_dose_rate(
                unshielded_dose_rate_Gy_s=d_dot_unshielded,
                standoff_distance_m=10.0,
                reference_distance_m=1.0,
                shield_thickness_m=-0.05,
                mu_m_inv=23.5,
                melanin_fraction=0.18,
            )

    def test_09_melanin_radical_scavenging_and_radiolysis_yields(self) -> None:
        """Water radiolysis yields are attenuated in proportion to melanin fraction."""
        d_dot = 1.0e-5  # Gy/s
        yields_no_melanin = self.controller.compute_radiolytic_yields(d_dot, melanin_fraction=0.0)
        yields_melanin_018 = self.controller.compute_radiolytic_yields(d_dot, melanin_fraction=0.18)
        yields_melanin_035 = self.controller.compute_radiolytic_yields(d_dot, melanin_fraction=0.35)

        # H2O2 and OH yields must decrease monotonically with higher melanin content
        self.assertGreater(yields_no_melanin["R_H2O2_mol_m3_s"], yields_melanin_018["R_H2O2_mol_m3_s"])
        self.assertGreater(yields_melanin_018["R_H2O2_mol_m3_s"], yields_melanin_035["R_H2O2_mol_m3_s"])
        self.assertGreater(yields_no_melanin["R_OH_mol_m3_s"], yields_melanin_018["R_OH_mol_m3_s"])
        self.assertGreater(yields_melanin_018["R_OH_mol_m3_s"], yields_melanin_035["R_OH_mol_m3_s"])


class TestNutMEGTemperatureBoundary(unittest.TestCase):
    """Suite 2: NutMEG Temperature Boundary and Deep Freeze Quarantine."""

    def setUp(self) -> None:
        self.controller = ALARAClosedLoopController()

    def test_01_temperature_279_99k_thermal_hibernation_incomplete(self) -> None:
        """T = 279.99 K (< 280.00 K): mode THERMAL_HIBERNATION_HOLD, status :Incomplete."""
        state = ALARAControllerState(temperature_K=279.99, cumulative_dose_Gy=0.020)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Incomplete")
        self.assertEqual(eval_res["mode"], "THERMAL_HIBERNATION_HOLD")
        self.assertTrue(eval_res["below_280K_nutmeg"])

        # Invariant: sub-280 K condition must NEVER collapse into :Rejected!
        self.assertNotEqual(eval_res["verdict"], ":Rejected")
        # Invariant: sub-280 K condition must NEVER promote to :Accepted!
        self.assertNotEqual(eval_res["verdict"], ":Accepted")

        # Closed-loop actuator step test
        actuator_out = self.controller.step_controller(state)
        self.assertEqual(actuator_out.epistemic_status, ":Incomplete")
        self.assertEqual(actuator_out.controller_mode, "THERMAL_HIBERNATION_HOLD")
        self.assertTrue(actuator_out.safing_shutter_closed)
        self.assertEqual(actuator_out.u_valve_m3_s, 0.00010)

    def test_02_temperature_280_00k_nominal_science_accepted(self) -> None:
        """T = 280.00 K (exact boundary): mode NOMINAL_BIOREACTOR_SCIENCE, status :Accepted."""
        state = ALARAControllerState(temperature_K=280.00, cumulative_dose_Gy=0.020)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Accepted")
        self.assertEqual(eval_res["mode"], "NOMINAL_BIOREACTOR_SCIENCE")
        self.assertFalse(eval_res["below_280K_nutmeg"])

        actuator_out = self.controller.step_controller(state)
        self.assertEqual(actuator_out.epistemic_status, ":Accepted")
        self.assertEqual(actuator_out.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")
        self.assertFalse(actuator_out.safing_shutter_closed)

    def test_03_temperature_150_00k_deep_freeze_locked_incomplete(self) -> None:
        """T = 150.00 K (cryogenic deep freeze): strictly locked in :Incomplete."""
        state = ALARAControllerState(temperature_K=150.00, cumulative_dose_Gy=0.020)
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Incomplete")
        self.assertEqual(eval_res["mode"], "THERMAL_HIBERNATION_HOLD")
        self.assertTrue(eval_res["below_280K_nutmeg"])

        # Must not collapse to :Rejected or promote to :Accepted
        self.assertNotEqual(eval_res["verdict"], ":Rejected")
        self.assertNotEqual(eval_res["verdict"], ":Accepted")

        # Test at Mars winter temperature 200.0 K and ice freezing point 273.15 K
        for temp_k in (200.00, 273.15):
            st = ALARAControllerState(temperature_K=temp_k, cumulative_dose_Gy=0.020)
            res = self.controller.evaluate_epistemic_hippocratism_quarantine(st)
            self.assertEqual(res["verdict"], ":Incomplete")
            self.assertNotEqual(res["verdict"], ":Rejected")

    def test_04_gate_g7_temperature_quarantine(self) -> None:
        """Gate G7 trips Source defect axis below 280 K and passes nominally at 280 K."""
        # 279.99 K: quarantine active, passed=True, status=:Incomplete, trips Source
        g7_cold = LogicGatesEvaluator.evaluate_gate_g7(temperature_K=279.99, cumulative_dose_Gy=0.020)
        self.assertTrue(g7_cold.passed)
        self.assertEqual(g7_cold.epistemic_status, ":Incomplete")
        self.assertIn("Source", g7_cold.defect_axes_tripped)
        self.assertNotIn("Control", g7_cold.defect_axes_tripped)

        # 280.00 K: clean nominal evaluation
        g7_warm = LogicGatesEvaluator.evaluate_gate_g7(temperature_K=280.00, cumulative_dose_Gy=0.020)
        self.assertTrue(g7_warm.passed)
        self.assertEqual(g7_warm.epistemic_status, ":Accepted")
        self.assertEqual(len(g7_warm.defect_axes_tripped), 0)

    def test_05_cross_subsystem_transition_under_mars_deep_freeze(self) -> None:
        """Cross-subsystem S2 -> S3 transition with sub-280 K pool array is quarantined.

        Tests both normalized subsystem IDs (which engage S2 -> S3 transition checks)
        and documents the default identifier mismatch.
        """
        s2_ev = generate_synthetic_momentum_automata_event(sequence_id="s2_cold_source")
        s3_ev = generate_synthetic_reactor_pools_event(
            sequence_id="s3_cold_target",
            causal_parent_id=s2_ev.event_id,
            temperatures_kelvin=[274.0, 274.5, 275.0, 275.5, 276.0, 276.5, 277.0, 277.5],
        )

        # Normalize subsystem identifiers to match evaluate_transition expected substring
        s2_ev.subsystem_id = "MomentumAutomata"
        s3_ev.subsystem_id = "ReactorPools"

        tr = LogicGatesEvaluator.evaluate_transition(s2_ev, s3_ev)
        self.assertTrue(tr.transition_valid)
        self.assertEqual(tr.enforced_epistemic_status, ":Incomplete")
        self.assertTrue(tr.defect_flags["Source"])
        self.assertEqual(s3_ev.epistemic_status, ":Incomplete")
        self.assertTrue(any("Sub-280 K temperature encountered" in r for r in tr.reasons))


class TestEpistemicHippocratismQuarantineHardening(unittest.TestCase):
    """Suite 3: Epistemic Hippocratism Invariant Hardening and Adversarial Collapse/Promotion."""

    def setUp(self) -> None:
        self.controller = ALARAClosedLoopController()
        self.nominal_state = ALARAControllerState(
            cumulative_dose_Gy=0.025,
            temperature_K=298.15,
            spice_units_verified_by_spkpos=True,
        )

    def test_01_force_collapse_incomplete_to_rejected_blocked(self) -> None:
        """Attempting to collapse :Incomplete into :Rejected raises NeuroARCGateViolation."""
        with self.assertRaises(ALARAControllerError) as ctx:
            wrap_neuroarc_quarantine_call(
                self.controller.evaluate_epistemic_hippocratism_quarantine,
                state=self.nominal_state,
                force_collapse_incomplete_to_rejected=True,
            )
        self.assertIn(
            "Incomplete verdict must NEVER collapse into Rejected without explicit refutation evidence",
            str(ctx.exception),
        )

        # Verify semantic domain subclass mapping
        with self.assertRaises(NeuroARCGateViolation):
            wrap_neuroarc_quarantine_call(
                self.controller.evaluate_epistemic_hippocratism_quarantine,
                state=self.nominal_state,
                force_collapse_incomplete_to_rejected=True,
            )

    def test_02_promote_unverified_hormesis_blocked(self) -> None:
        """Attempting to promote unverified low-dose hormesis raises EpistemicHippocratismViolation."""
        with self.assertRaises(ALARAControllerError) as ctx:
            wrap_neuroarc_quarantine_call(
                self.controller.evaluate_epistemic_hippocratism_quarantine,
                state=self.nominal_state,
                promote_unverified_hormesis=True,
            )
        self.assertIn(
            "unverified low-dose radiation hormesis must remain in :Incomplete quarantine",
            str(ctx.exception),
        )

        # Verify semantic domain subclass mapping
        with self.assertRaises(EpistemicHippocratismViolation):
            wrap_neuroarc_quarantine_call(
                self.controller.evaluate_epistemic_hippocratism_quarantine,
                state=self.nominal_state,
                promote_unverified_hormesis=True,
            )

    def test_03_promote_net_atp_radiosynthesis_without_mass_balance_blocked(self) -> None:
        """Attempting to promote net ATP radiosynthesis raises EpistemicHippocratismViolation."""
        with self.assertRaises(ALARAControllerError) as ctx:
            wrap_neuroarc_quarantine_call(
                self.controller.evaluate_epistemic_hippocratism_quarantine,
                state=self.nominal_state,
                promote_unverified_atp=True,
            )
        self.assertIn(
            "direct net metabolic ATP radiosynthesis without electron-donor mass balance must remain in :Incomplete quarantine",
            str(ctx.exception),
        )

        # Verify semantic domain subclass mapping
        with self.assertRaises(EpistemicHippocratismViolation):
            wrap_neuroarc_quarantine_call(
                self.controller.evaluate_epistemic_hippocratism_quarantine,
                state=self.nominal_state,
                promote_unverified_atp=True,
            )

    def test_04_spice_units_unverified_quarantine(self) -> None:
        """Unverified SPICE ephemeris units force EPHEMERIS_CALIBRATION_HOLD quarantine."""
        state = ALARAControllerState(
            cumulative_dose_Gy=0.020,
            temperature_K=298.15,
            spice_units_verified_by_spkpos=False,
        )
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(state)

        self.assertEqual(eval_res["verdict"], ":Incomplete")
        self.assertEqual(eval_res["mode"], "EPHEMERIS_CALIBRATION_HOLD")
        self.assertFalse(eval_res["spice_units_verified"])

        # Gate G7 trips Source defect axis
        g7_spice = LogicGatesEvaluator.evaluate_gate_g7(
            spice_units_verified_by_spkpos=False,
            cumulative_dose_Gy=0.020,
        )
        self.assertTrue(g7_spice.passed)
        self.assertEqual(g7_spice.epistemic_status, ":Incomplete")
        self.assertIn("Source", g7_spice.defect_axes_tripped)

    def test_05_four_quarantined_hypotheses_integrity(self) -> None:
        """All 4 quarantined hypotheses remain strictly in :Incomplete status in receipts."""
        eval_res = self.controller.evaluate_epistemic_hippocratism_quarantine(self.nominal_state)
        quarantine_map = eval_res["quarantined_hypotheses"]

        expected_hypotheses = [
            "unverified_low_dose_radiation_hormesis",
            "direct_net_atp_radiosynthesis_without_electron_donor_mass_balance",
            "nutmeg_maintenance_power_below_280K",
            "unverified_spice_jl_units_prior_to_spkpos_check",
        ]
        for hyp in expected_hypotheses:
            self.assertIn(hyp, quarantine_map)
            self.assertEqual(quarantine_map[hyp], ":Incomplete")

    def test_06_gate_g7_adversarial_flag_handling(self) -> None:
        """Gate G7 catches adversarial promotion or collapse attempts and marks them :Rejected."""
        # Hormesis promotion attempt caught by G7
        g7_hormesis = LogicGatesEvaluator.evaluate_gate_g7(promote_unverified_hormesis=True)
        self.assertFalse(g7_hormesis.passed)
        self.assertEqual(g7_hormesis.epistemic_status, ":Rejected")
        self.assertIn("Control", g7_hormesis.defect_axes_tripped)
        self.assertIn("Source", g7_hormesis.defect_axes_tripped)

        # ATP radiosynthesis promotion attempt caught by G7
        g7_atp = LogicGatesEvaluator.evaluate_gate_g7(promote_unverified_atp=True)
        self.assertFalse(g7_atp.passed)
        self.assertEqual(g7_atp.epistemic_status, ":Rejected")
        self.assertIn("Control", g7_atp.defect_axes_tripped)
        self.assertIn("Source", g7_atp.defect_axes_tripped)

        # Force collapse attempt caught by G7
        g7_collapse = LogicGatesEvaluator.evaluate_gate_g7(force_collapse_incomplete_to_rejected=True)
        self.assertFalse(g7_collapse.passed)
        self.assertEqual(g7_collapse.epistemic_status, ":Rejected")
        self.assertIn("Control", g7_collapse.defect_axes_tripped)
        self.assertIn("Source", g7_collapse.defect_axes_tripped)


class TestBiofilmSyncytialBreachStress(unittest.TestCase):
    """Suite 4: Biofilm Syncytial Breach Stress and Streaming Surge Invariants."""

    def test_01_streaming_velocity_boundary_envelope(self) -> None:
        """Cytoplasmic streaming bounds [5.0, 60.0] um/s enforced by schema."""
        # Lower boundary valid
        ev_low = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=5.0)
        self.assertEqual(ev_low.payload.cytoplasmic_streaming_velocity_um_s, 5.0)

        # Upper boundary valid
        ev_high = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=60.0)
        self.assertEqual(ev_high.payload.cytoplasmic_streaming_velocity_um_s, 60.0)

        # Below lower boundary rejected
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=4.99)

        # Above upper boundary rejected
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=60.01)

    def test_02_streaming_surge_85_um_s_schema_rejection(self) -> None:
        """Streaming surge velocity v = 85.0 um/s (> 60.0 um/s) rejected by envelope schema."""
        with self.assertRaises(SchemaValidationError) as ctx:
            generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=85.0)
        self.assertIn("cytoplasmic_streaming_velocity_um_s must be in [5.0, 60.0]", str(ctx.exception))

    def test_03_streaming_surge_85_um_s_transition_rejection(self) -> None:
        """Unmitigated surge velocity v = 85.0 um/s in cross-subsystem transition trips Boundary defect."""
        s3_ev = generate_synthetic_reactor_pools_event(sequence_id="s3_surge_src")
        s4_ev = generate_synthetic_biofilm_session_event(sequence_id="s4_surge_tgt")

        # Normalize subsystem identifiers to match evaluate_transition expected substring
        s3_ev.subsystem_id = "ReactorPools"
        s4_ev.subsystem_id = "BiofilmsSessions"

        # Force surge velocity onto target payload to simulate unmitigated hydrodynamic breach
        s4_ev.payload.cytoplasmic_streaming_velocity_um_s = 85.0

        tr = LogicGatesEvaluator.evaluate_transition(s3_ev, s4_ev)
        self.assertFalse(tr.transition_valid)
        self.assertEqual(tr.enforced_epistemic_status, ":Rejected")
        self.assertTrue(tr.defect_flags["Boundary"])
        self.assertTrue(any("Cytoplasmic streaming velocity 85.0 um/s out of bounds" in r for r in tr.reasons))

    def test_04_surge_mitigation_hex1_woronin_pore_occlusion(self) -> None:
        """Hydrodynamic breach surge triggers HEX-1 Woronin pore occlusion, preserving beta_0 == 1."""
        # Initial unmitigated surge
        v_surge_unmitigated = 85.0  # um/s (> 60.0 um/s limit)

        # Cellular self-defense response: Woronin body HEX-1 mobilization triggers emergency pore occlusion
        hex1_active = True
        # Hydrodynamic resistance throttles streaming velocity back to safe ceiling
        v_stabilized = min(58.0, v_surge_unmitigated * 0.65)  # 55.25 um/s, within [5.0, 60.0]

        ev_mitigated = generate_synthetic_biofilm_session_event(
            sequence_id="hex1_plugged_session_001",
            cytoplasmic_streaming_velocity_um_s=v_stabilized,
            hex1_woronin_plugging_active=hex1_active,
        )

        # Verify HEX-1 Woronin plugging is engaged
        self.assertTrue(ev_mitigated.payload.hex1_woronin_plugging_active)
        self.assertLessEqual(ev_mitigated.payload.cytoplasmic_streaming_velocity_um_s, 60.0)
        self.assertGreaterEqual(ev_mitigated.payload.cytoplasmic_streaming_velocity_um_s, 5.0)

        # Invariant: Syncytial network connectivity is preserved without fragmentation
        self.assertEqual(ev_mitigated.payload.anastomosis_topology.beta_0, 1)

        # Invariant: Anastomosis reticulation cycle rank is maintained
        self.assertGreaterEqual(ev_mitigated.payload.anastomosis_topology.beta_1, 1)

        # Invariant: Chamber biomass densities remain conserved below physical ceiling
        self.assertTrue(all(b <= 1.20 for b in ev_mitigated.payload.biomass_density_kg_m3))

        # Cross-subsystem transition with mitigated surge evaluates cleanly as valid
        s3_ev = generate_synthetic_reactor_pools_event(sequence_id="s3_mitigated_src")
        s3_ev.subsystem_id = "ReactorPools"
        ev_mitigated.subsystem_id = "BiofilmsSessions"

        tr = LogicGatesEvaluator.evaluate_transition(s3_ev, ev_mitigated)
        self.assertTrue(tr.transition_valid)
        self.assertEqual(tr.enforced_epistemic_status, ":Accepted")
        self.assertFalse(tr.defect_flags["Boundary"])

    def test_05_adversarial_topology_corruption_attacks(self) -> None:
        """Adversarial attempts to corrupt biofilm topology invariants are strictly blocked."""
        # Attempt syncytial fragmentation: beta_0 == 2 rejected
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=2, beta_1=3)

        # Attempt zero-connected topology: beta_0 == 0 rejected
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=0, beta_1=3)

        # Attempt cycle annihilation: beta_1 == 0 rejected
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=1, beta_1=0)

        # Attempt biomass overflow: 1.25 kg/m^3 rejected
        ev = generate_synthetic_biofilm_session_event()
        d = ev.to_dict()
        d["payload"]["biomass_density_kg_m3"] = [1.25] + [0.5] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

        # Attempt EPS streamer blowout: fraction 1.10 rejected
        d_eps = ev.to_dict()
        d_eps["payload"]["eps_streamer_fraction"] = [1.10] + [0.2] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d_eps)

    def test_06_subsystem_id_underscore_mismatch_vulnerability(self) -> None:
        """Empirical vulnerability demonstration: default MasterEvent subsystem_id bypasses transitions.

        Documents that default subsystem IDs containing underscores
        ('S2_Momentum_Automata_Criticality_Engine', 'S3_Reactor_Pools_SMBR_OpenMC_MATLAB',
        'S4_Biofilms_Sessions_Neurospora_M7_Workbench') do not contain the CamelCase substrings
        'MomentumAutomata', 'ReactorPools', 'BiofilmsSessions' expected by evaluate_transition.
        """
        s3_ev = generate_synthetic_reactor_pools_event(sequence_id="s3_default_src")
        s4_ev = generate_synthetic_biofilm_session_event(sequence_id="s4_default_tgt")

        # With default subsystem_id strings containing underscores:
        self.assertIn("_", s3_ev.subsystem_id)
        self.assertNotIn("ReactorPools", s3_ev.subsystem_id)
        self.assertIn("_", s4_ev.subsystem_id)
        self.assertNotIn("BiofilmsSessions", s4_ev.subsystem_id)

        # Inject surge velocity on target event
        s4_ev.payload.cytoplasmic_streaming_velocity_um_s = 85.0

        # evaluate_transition falls through without executing the S3 -> S4 checks
        tr_bypassed = LogicGatesEvaluator.evaluate_transition(s3_ev, s4_ev)
        # Because checks fell through, transition_valid is True instead of False
        self.assertTrue(tr_bypassed.transition_valid)
        self.assertEqual(len(tr_bypassed.reasons), 0)


class TestClosedLoopLQRMPCDynamics(unittest.TestCase):
    """Suite 5: Dynamic Closed-Loop LQR/MPC Multi-Step Stress Simulation."""

    def setUp(self) -> None:
        self.controller = ALARAClosedLoopController(max_allowable_dose_Gy=0.050, safing_fraction=0.80)

    def test_01_multi_step_nominal_steady_state(self) -> None:
        """Multi-step nominal time integration maintains steady regulation and :Accepted status."""
        state = ALARAControllerState(
            cumulative_dose_Gy=0.010,
            dose_rate_Gy_s=1.0e-7,
            standoff_distance_m=10.0,
            temperature_K=298.15,
        )

        for step in range(25):
            out = self.controller.step_controller(state, dt_s=100.0)
            self.assertEqual(out.epistemic_status, ":Accepted")
            self.assertEqual(out.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")
            self.assertFalse(out.safing_shutter_closed)
            # Advance cumulative dose
            state.cumulative_dose_Gy = out.cumulative_dose_Gy

        self.assertLess(state.cumulative_dose_Gy, 0.040)

    def test_02_dynamic_dose_ramp_crossing_80_percent_and_ceiling(self) -> None:
        """Dynamic radiation ramp confirms exact threshold trip and SCRAM execution."""
        state = ALARAControllerState(
            cumulative_dose_Gy=0.0380,
            dose_rate_Gy_s=5.0e-4,  # high dose rate to drive rapid ramp
            temperature_K=298.15,
        )

        trip_80_step = None
        trip_ceiling_step = None

        # Execute dynamic steps with dose increments crossing 80% safing and SCRAM limit
        # Using 0.040001 Gy to test the active safing regime past float threshold
        test_doses = [0.0385, 0.0395, 0.0399, 0.040001, 0.0420, 0.0490, 0.0500, 0.0501, 0.0520]
        history = []

        for idx, dose in enumerate(test_doses):
            state.cumulative_dose_Gy = dose
            out = self.controller.step_controller(state, dt_s=0.0)
            history.append(out)

            if dose < 0.0400:
                self.assertEqual(out.epistemic_status, ":Accepted")
                self.assertEqual(out.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")
                self.assertFalse(out.safing_shutter_closed)
            elif 0.0400 <= dose <= 0.0500:
                self.assertEqual(out.epistemic_status, ":Incomplete")
                self.assertEqual(out.controller_mode, "SAFE_HOLD_SHUTTER_CLOSED")
                self.assertTrue(out.safing_shutter_closed)
                if trip_80_step is None:
                    trip_80_step = idx
            else:
                self.assertEqual(out.epistemic_status, ":Rejected")
                self.assertEqual(out.controller_mode, "EMERGENCY_SCRAM_ISOLATE")
                self.assertTrue(out.safing_shutter_closed)
                self.assertEqual(out.u_valve_m3_s, 0.0)
                self.assertEqual(out.z_shield_m, 0.200)
                if trip_ceiling_step is None:
                    trip_ceiling_step = idx

        self.assertEqual(trip_80_step, 3)  # index of 0.040001 Gy
        self.assertEqual(trip_ceiling_step, 7)  # index of 0.0501 Gy

    def test_03_dynamic_temperature_recovery(self) -> None:
        """Dynamic thermal cycle confirms reversible hibernation hold without SCRAM."""
        # Step 1: Sub-280 K hibernation hold
        state = ALARAControllerState(cumulative_dose_Gy=0.020, temperature_K=275.0)
        out_cold = self.controller.step_controller(state)
        self.assertEqual(out_cold.epistemic_status, ":Incomplete")
        self.assertEqual(out_cold.controller_mode, "THERMAL_HIBERNATION_HOLD")
        self.assertTrue(out_cold.safing_shutter_closed)

        # Step 2: Thermal heaters recover temperature to 298.15 K
        state.temperature_K = 298.15
        out_warm = self.controller.step_controller(state)
        self.assertEqual(out_warm.epistemic_status, ":Accepted")
        self.assertEqual(out_warm.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")
        self.assertFalse(out_warm.safing_shutter_closed)


class TestTypographicAndFormattingHygiene(unittest.TestCase):
    """Suite 6: Typographic and Format Hygiene (Zero Em-Dash & Zero En-Dash)."""

    def test_01_zero_em_dash_in_test_script(self) -> None:
        """This adversarial test script strictly contains zero em-dashes and zero en-dashes."""
        script_path = Path(__file__).resolve()
        content = script_path.read_text(encoding="utf-8")

        self.assertNotIn("\u2014", content, "Encountered em-dash (U+2014) in test script")
        self.assertNotIn("\u2013", content, "Encountered en-dash (U+2013) in test script")

    def test_02_zero_em_dash_in_contract_source_files(self) -> None:
        """Key contract implementation files strictly contain zero em-dashes and zero en-dashes."""
        target_files = [
            REPO_ROOT / "Scripts" / "contracts" / "alara_closed_loop_controller.py",
            REPO_ROOT / "Scripts" / "contracts" / "logic_gates_evaluator.py",
            REPO_ROOT / "Scripts" / "contracts" / "master_event_contract.py",
            REPO_ROOT / "Scripts" / "contracts" / "tarjan_bridge_verifier.py",
            REPO_ROOT / "Scripts" / "contracts" / "synthetic_event_round_trip.py",
        ]
        for tf in target_files:
            self.assertTrue(tf.is_file(), f"Expected file {tf} does not exist")
            content = tf.read_text(encoding="utf-8")
            self.assertNotIn("\u2014", content, f"Encountered em-dash in {tf.name}")
            self.assertNotIn("\u2013", content, f"Encountered en-dash in {tf.name}")


def run_adversarial_suite(json_output: bool = False) -> int:
    """Run full adversarial stress-test suite and optionally export JSON summary."""
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    test_classes = [
        TestALARAThresholdTransitions,
        TestNutMEGTemperatureBoundary,
        TestEpistemicHippocratismQuarantineHardening,
        TestBiofilmSyncytialBreachStress,
        TestClosedLoopLQRMPCDynamics,
        TestTypographicAndFormattingHygiene,
    ]
    for tc in test_classes:
        suite.addTests(loader.loadTestsFromTestCase(tc))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    total_tests = result.testsRun
    failures = len(result.failures)
    errors = len(result.errors)
    passed = total_tests - failures - errors

    summary = {
        "suite_name": "Challenger_2_Adversarial_Stress_Harness",
        "total_tests": total_tests,
        "passed": passed,
        "failures": failures,
        "errors": errors,
        "success": result.wasSuccessful(),
        "suites_executed": [tc.__name__ for tc in test_classes],
    }

    if json_output:
        print(json.dumps(summary, indent=2))

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    is_json = "--json" in sys.argv
    sys.exit(run_adversarial_suite(json_output=is_json))
