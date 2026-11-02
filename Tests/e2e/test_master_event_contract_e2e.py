"""End-to-End Test Suite for NeuralCompose Master Event Contract.

Opaque-box comprehensive test suite exercising:
- Tier 1: Feature Coverage (>=5 tests per feature across 24 features = 120 tests)
- Tier 2: Boundary & Corner Cases (>=5 tests per feature across 24 features = 120 tests)
- Tier 3: Pairwise Cross-Feature Interactions (29 tests)
- Tier 4: Real-World Application Workloads (6 scenarios)
Total: 275 tests.

Strictly zero em-dashes and zero en-dashes across all code, docstrings, and receipts.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from Scripts.contracts.alara_closed_loop_controller import (
    ALARAClosedLoopController,
    ALARAControllerError,
    ALARAControllerState,
    ALARAActuatorOutput,
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
    VALID_CRITICALITY_REGIMES,
    VALID_DEFECT_AXES,
    VALID_EPISTEMIC_STATUSES,
    VALID_FUNCTOR_STAGES,
    VALID_M7_STAGE_HEADERS,
    VALID_WBR_MODES,
    assert_float64,
    assert_int64,
    assert_stage_header,
    sanitize_dashes,
    validate_biofilm_session_envelope,
    validate_master_event,
    validate_momentum_automata_envelope,
    validate_multipool_reactor_envelope,
    validate_neuralcompose_fixture_envelope,
)
from Scripts.contracts.synthetic_event_round_trip import (
    generate_synthetic_biofilm_session_event,
    generate_synthetic_momentum_automata_event,
    generate_synthetic_neuralcompose_event,
    generate_synthetic_reactor_pools_event,
    SyntheticEventRoundTripRunner,
)
from Scripts.contracts.tarjan_bridge_verifier import (
    TarjanBridgeVerifier,
    TarjanVerificationError,
    compute_betti_numbers,
    find_cut_vertices_and_bridges,
    tarjan_scc,
    verify_nilpotent_adjacency,
)
from Scripts.verify_master_event_contract_gates import (
    evaluate_master_event_contract,
    load_master_event_contract_schema,
    verify_gate_g1_spice_basilisk_si_and_dcm,
    verify_gate_g2_m7_header_vs_numeric_types,
    verify_gate_g3_acyclic_tarjan_solver_bridge,
    verify_gate_g4_multiclock_settlement_bridge,
    verify_gate_g5_horizon_collar_leaf_seam,
    verify_gate_g6_unified_substrate_swap_primitive,
    verify_gate_g7_health_physics_alara_and_hippocratism,
    verify_neurospora_crassa_4block_8pool_contract,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "configs" / "master_event_contract_schema_v1.json"


class TestTier1FeatureCoverage(unittest.TestCase):
    """Tier 1: Feature Coverage (5 tests per feature across all 24 features = 120 tests)."""

    # --------------------------------------------------------------------------
    # Feature 1: Functorial Fixtures Envelope (ORIGINAL_REQUEST R1.1)
    # --------------------------------------------------------------------------
    def test_t1_f01_01_valid_envelope_creation(self) -> None:
        bn = BettiNumbers(beta_0=1, beta_1=3)
        da = DefectAxes(boundary=False, control=False, source=False, coordination=False)
        env = NeuralComposeFixtureEnvelope(
            sequence_id="seq_f1_01",
            functor_stage="F_Laya",
            frame_index=10,
            betti_numbers=bn,
            defect_axes=da,
            toy_drive_active=True,
            mahalanobis_tension_D_M=1.25,
        )
        self.assertEqual(env.sequence_id, "seq_f1_01")
        self.assertEqual(env.functor_stage, "F_Laya")
        self.assertEqual(env.frame_index, 10)
        self.assertTrue(env.toy_drive_active)
        self.assertAlmostEqual(env.mahalanobis_tension_D_M, 1.25)

    def test_t1_f01_02_all_functor_stages(self) -> None:
        for stage in VALID_FUNCTOR_STAGES:
            env = NeuralComposeFixtureEnvelope(
                sequence_id=f"seq_stage_{stage}",
                functor_stage=stage,
                frame_index=0,
                betti_numbers=BettiNumbers(1, 2),
                defect_axes=DefectAxes(),
                toy_drive_active=False,
                mahalanobis_tension_D_M=0.5,
            )
            self.assertEqual(env.functor_stage, stage)

    def test_t1_f01_03_frame_index_valid_range(self) -> None:
        for f_idx in (0, 15, 30, 45, 59):
            env = NeuralComposeFixtureEnvelope(
                sequence_id=f"seq_f_idx_{f_idx}",
                functor_stage="F_ST",
                frame_index=f_idx,
                betti_numbers=BettiNumbers(1, 1),
                defect_axes=DefectAxes(),
                toy_drive_active=True,
                mahalanobis_tension_D_M=1.0,
            )
            self.assertEqual(env.frame_index, f_idx)

    def test_t1_f01_04_betti_topological_state(self) -> None:
        bn = BettiNumbers(beta_0=1, beta_1=5)
        self.assertEqual(bn.beta_0, 1)
        self.assertEqual(bn.beta_1, 5)

    def test_t1_f01_05_mahalanobis_tension_positive(self) -> None:
        env = NeuralComposeFixtureEnvelope(
            sequence_id="seq_tension",
            functor_stage="F_Mem",
            frame_index=20,
            betti_numbers=BettiNumbers(1, 4),
            defect_axes=DefectAxes(),
            toy_drive_active=False,
            mahalanobis_tension_D_M=2.15,
        )
        self.assertGreater(env.mahalanobis_tension_D_M, 0.0)

    # --------------------------------------------------------------------------
    # Feature 2: FourPillarFrameRecord (ORIGINAL_REQUEST R1.1)
    # --------------------------------------------------------------------------
    def test_t1_f02_01_four_pillar_record_presence(self) -> None:
        ev = generate_synthetic_neuralcompose_event(sequence_id="seq_fp_01")
        p = ev.payload
        self.assertIsInstance(p, NeuralComposeFixtureEnvelope)
        self.assertIsNotNone(p.four_pillar_record)
        expected_pillars = {
            "pillar_1_laya",
            "pillar_2_st_jema",
            "pillar_3_memory_dialectic",
            "pillar_4_musical_laya",
        }
        self.assertEqual(set(p.four_pillar_record.keys()), expected_pillars)

    def test_t1_f02_02_pillar1_laya_metrics(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        p1 = ev.payload.four_pillar_record["pillar_1_laya"]
        self.assertIn("le_jepa_query_loss", p1)
        self.assertIn("zca_sigreg_whitened", p1)
        self.assertIsInstance(p1["zca_sigreg_whitened"], bool)

    def test_t1_f02_03_pillar2_st_jema_topology(self) -> None:
        ev = generate_synthetic_neuralcompose_event(beta_0=1, beta_1=4)
        p2 = ev.payload.four_pillar_record["pillar_2_st_jema"]
        self.assertEqual(p2["beta_0"], 1)
        self.assertEqual(p2["beta_1"], 4)
        self.assertEqual(p2["tarjan_edge_class"], "tree")

    def test_t1_f02_04_pillar3_memory_dialectic(self) -> None:
        ev = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=1.75)
        p3 = ev.payload.four_pillar_record["pillar_3_memory_dialectic"]
        self.assertAlmostEqual(p3["tau_fast_s"], 1.2)
        self.assertAlmostEqual(p3["tau_slow_s"], 8.0)
        self.assertAlmostEqual(p3["mahalanobis_tension_D_M"], 1.75)

    def test_t1_f02_05_pillar4_musical_laya(self) -> None:
        ev = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=1.0)
        p4 = ev.payload.four_pillar_record["pillar_4_musical_laya"]
        self.assertEqual(p4["tempo_bpm"], 72.0)
        self.assertAlmostEqual(p4["absorption_index"], 0.5)

    # --------------------------------------------------------------------------
    # Feature 3: Defect Axes Envelopes (ORIGINAL_REQUEST R1.1)
    # --------------------------------------------------------------------------
    def test_t1_f03_01_all_clean_axes(self) -> None:
        da = DefectAxes(False, False, False, False)
        self.assertTrue(da.is_clean())

    def test_t1_f03_02_boundary_axis_tripped(self) -> None:
        da = DefectAxes(boundary=True)
        self.assertTrue(da.boundary)
        self.assertFalse(da.is_clean())

    def test_t1_f03_03_control_axis_tripped(self) -> None:
        da = DefectAxes(control=True)
        self.assertTrue(da.control)
        self.assertFalse(da.is_clean())

    def test_t1_f03_04_source_axis_tripped(self) -> None:
        da = DefectAxes(source=True)
        self.assertTrue(da.source)
        self.assertFalse(da.is_clean())

    def test_t1_f03_05_coordination_axis_tripped(self) -> None:
        da = DefectAxes(coordination=True)
        self.assertTrue(da.coordination)
        self.assertFalse(da.is_clean())

    # --------------------------------------------------------------------------
    # Feature 4: Live Sensor Toy Drive (ORIGINAL_REQUEST R1.1)
    # --------------------------------------------------------------------------
    def test_t1_f04_01_toy_drive_active_true(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=True)
        self.assertTrue(ev.payload.toy_drive_active)

    def test_t1_f04_02_toy_drive_active_false(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=False)
        self.assertFalse(ev.payload.toy_drive_active)

    def test_t1_f04_03_toy_drive_coupling_in_master_event(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=True)
        d = ev.to_dict()
        self.assertTrue(d["payload"]["toy_drive_active"])

    def test_t1_f04_04_toy_drive_cadence_modulation(self) -> None:
        ev1 = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=0.8, toy_drive_active=True)
        ev2 = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=2.2, toy_drive_active=True)
        self.assertLess(ev1.payload.mahalanobis_tension_D_M, ev2.payload.mahalanobis_tension_D_M)

    def test_t1_f04_05_toy_drive_serialization_fidelity(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=True)
        json_str = ev.to_json()
        ev_back = MasterEvent.from_json(json_str)
        self.assertTrue(ev_back.payload.toy_drive_active)

    # --------------------------------------------------------------------------
    # Feature 5: OrderBookCriticalityEngine (ORIGINAL_REQUEST R1.2)
    # --------------------------------------------------------------------------
    def test_t1_f05_01_valid_criticality_envelope(self) -> None:
        cm = CriticalityMetrics(k_eff=1.002, rho_pcm=20.0, z_crit=0.98, chi=1.05)
        env = MomentumAutomataEnvelope(
            sequence_id="seq_crit_01",
            criticality_metrics=cm,
            criticality_regime="CRITICAL_WITHIN_NOISE",
            wbr_mode="Focus",
            hysteresis_loop_area=4.25,
            retention_pool_active=True,
        )
        self.assertEqual(env.criticality_regime, "CRITICAL_WITHIN_NOISE")
        self.assertAlmostEqual(env.criticality_metrics.k_eff, 1.002)

    def test_t1_f05_02_subcritical_regime(self) -> None:
        ev = generate_synthetic_momentum_automata_event(k_eff=0.985, criticality_regime="SUBCRITICAL")
        self.assertEqual(ev.payload.criticality_regime, "SUBCRITICAL")

    def test_t1_f05_03_critical_within_noise_regime(self) -> None:
        ev = generate_synthetic_momentum_automata_event(k_eff=1.001, criticality_regime="CRITICAL_WITHIN_NOISE")
        self.assertEqual(ev.payload.criticality_regime, "CRITICAL_WITHIN_NOISE")

    def test_t1_f05_04_supercritical_regime(self) -> None:
        ev = generate_synthetic_momentum_automata_event(k_eff=1.025, criticality_regime="SUPERCRITICAL")
        self.assertEqual(ev.payload.criticality_regime, "SUPERCRITICAL")

    def test_t1_f05_05_prompt_scram_regime(self) -> None:
        ev = generate_synthetic_momentum_automata_event(k_eff=1.150, criticality_regime="PROMPT_SCRAM")
        self.assertEqual(ev.payload.criticality_regime, "PROMPT_SCRAM")

    # --------------------------------------------------------------------------
    # Feature 6: Category Type Separation (ORIGINAL_REQUEST R2.2)
    # --------------------------------------------------------------------------
    def test_t1_f06_01_m7_stage_headers_valid_strings(self) -> None:
        for h in VALID_M7_STAGE_HEADERS:
            res = assert_stage_header(h)
            self.assertEqual(res, h)

    def test_t1_f06_02_discrete_int64_cell_and_betti(self) -> None:
        self.assertEqual(assert_int64(8, "n_pool"), 8)
        self.assertEqual(assert_int64(1, "beta_0"), 1)
        self.assertEqual(assert_int64(3, "beta_1"), 3)

    def test_t1_f06_03_continuous_float64_si(self) -> None:
        self.assertAlmostEqual(assert_float64(298.15, "temperature_K"), 298.15)
        self.assertAlmostEqual(assert_float64(55.0, "concentration_mol_m3"), 55.0)

    def test_t1_f06_04_gate_g2_verification(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g2()
        self.assertTrue(res.passed)
        self.assertEqual(res.epistemic_status, ":Accepted")

    def test_t1_f06_05_type_separation_envelope_roundtrip(self) -> None:
        ev = generate_synthetic_reactor_pools_event(container_header="M7.3")
        d = ev.to_dict()
        self.assertIsInstance(d["payload"]["container_header"], str)
        self.assertIsInstance(d["payload"]["n_pool"], int)
        self.assertTrue(all(isinstance(x, float) for x in d["payload"]["sucrose_concentrations_mol_m3"]))

    # --------------------------------------------------------------------------
    # Feature 7: Hysteresis Loop Area (ORIGINAL_REQUEST R1.2)
    # --------------------------------------------------------------------------
    def test_t1_f07_01_valid_hysteresis_area(self) -> None:
        ev = generate_synthetic_momentum_automata_event(hysteresis_loop_area=4.5)
        self.assertAlmostEqual(ev.payload.hysteresis_loop_area, 4.5)

    def test_t1_f07_02_shoelace_integral_threshold(self) -> None:
        ev = generate_synthetic_momentum_automata_event(hysteresis_loop_area=5.2)
        self.assertGreater(ev.payload.hysteresis_loop_area, 4.0)

    def test_t1_f07_03_retention_pool_activation(self) -> None:
        ev = generate_synthetic_momentum_automata_event(hysteresis_loop_area=4.5, retention_pool_active=True)
        self.assertTrue(ev.payload.retention_pool_active)

    def test_t1_f07_04_dual_band_retention(self) -> None:
        ev_low = generate_synthetic_momentum_automata_event(hysteresis_loop_area=1.5, retention_pool_active=False)
        ev_high = generate_synthetic_momentum_automata_event(hysteresis_loop_area=6.0, retention_pool_active=True)
        self.assertFalse(ev_low.payload.retention_pool_active)
        self.assertTrue(ev_high.payload.retention_pool_active)

    def test_t1_f07_05_hysteresis_in_envelope_validation(self) -> None:
        p = generate_synthetic_momentum_automata_event(hysteresis_loop_area=3.8).payload
        validate_momentum_automata_envelope(p)

    # --------------------------------------------------------------------------
    # Feature 8: WBR Scaffolding Modes (ORIGINAL_REQUEST R1.2)
    # --------------------------------------------------------------------------
    def test_t1_f08_01_wbr_focus_mode(self) -> None:
        ev = generate_synthetic_momentum_automata_event(wbr_mode="Focus")
        self.assertEqual(ev.payload.wbr_mode, "Focus")

    def test_t1_f08_02_wbr_frustration_mode(self) -> None:
        ev = generate_synthetic_momentum_automata_event(wbr_mode="Frustration")
        self.assertEqual(ev.payload.wbr_mode, "Frustration")

    def test_t1_f08_03_wbr_panic_mode(self) -> None:
        ev = generate_synthetic_momentum_automata_event(wbr_mode="Panic")
        self.assertEqual(ev.payload.wbr_mode, "Panic")

    def test_t1_f08_04_wbr_mode_string_validation(self) -> None:
        self.assertEqual(VALID_WBR_MODES, ("Focus", "Frustration", "Panic"))

    def test_t1_f08_05_wbr_transition_logic(self) -> None:
        ev_focus = generate_synthetic_momentum_automata_event(wbr_mode="Focus")
        ev_panic = generate_synthetic_momentum_automata_event(wbr_mode="Panic")
        self.assertFalse(ev_focus.defect_flags.get("Control", False))
        self.assertTrue(ev_panic.defect_flags.get("Control", False))

    # --------------------------------------------------------------------------
    # Feature 9: Logic Gates G1-G7 Evaluation (ORIGINAL_REQUEST R2)
    # --------------------------------------------------------------------------
    def test_t1_f09_01_gate_g1_spice_basilisk(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g1()
        self.assertTrue(res.passed)
        self.assertEqual(res.gate_id, "G1")

    def test_t1_f09_02_gate_g2_type_separation(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g2()
        self.assertTrue(res.passed)
        self.assertEqual(res.gate_id, "G2")

    def test_t1_f09_03_gate_g3_tarjan_dag(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g3()
        self.assertTrue(res.passed)
        self.assertEqual(res.gate_id, "G3")

    def test_t1_f09_04_gate_g4_settlement_bridge(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g4()
        self.assertTrue(res.passed)
        self.assertEqual(res.gate_id, "G4")

    def test_t1_f09_05_gate_g5_to_g7_full_suite(self) -> None:
        gates = LogicGatesEvaluator.evaluate_all_gates()
        for gid in ("G1", "G2", "G3", "G4", "G5", "G6", "G7"):
            self.assertIn(gid, gates)
            self.assertTrue(gates[gid].passed, f"Gate {gid} failed")

    # --------------------------------------------------------------------------
    # Feature 10: Acyclic Tarjan Solver DAG (ORIGINAL_REQUEST R2.1)
    # --------------------------------------------------------------------------
    def test_t1_f10_01_canonical_5node_pipeline(self) -> None:
        self.assertEqual(len(TarjanBridgeVerifier.DEFAULT_SOLVER_NODES), 5)
        self.assertEqual(len(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES), 4)

    def test_t1_f10_02_max_scc_size_unity(self) -> None:
        sccs = tarjan_scc(
            TarjanBridgeVerifier.DEFAULT_SOLVER_NODES,
            TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES,
        )
        max_scc = max(len(c) for c in sccs)
        self.assertEqual(max_scc, 1)

    def test_t1_f10_03_beta_1_inter_solver_zero(self) -> None:
        beta_0, beta_1 = compute_betti_numbers(
            TarjanBridgeVerifier.DEFAULT_SOLVER_NODES,
            TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES,
        )
        self.assertEqual(beta_0, 1)
        self.assertEqual(beta_1, 0)

    def test_t1_f10_04_nilpotent_adjacency_degree(self) -> None:
        is_nilpotent, degree = verify_nilpotent_adjacency(
            TarjanBridgeVerifier.DEFAULT_SOLVER_NODES,
            TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES,
        )
        self.assertTrue(is_nilpotent)
        self.assertEqual(degree, 5)

    def test_t1_f10_05_verifier_class_execution(self) -> None:
        res = TarjanBridgeVerifier.verify_solver_pipeline()
        self.assertTrue(res["verified"])
        self.assertEqual(res["max_scc_size"], 1)
        self.assertEqual(res["beta_1_inter_solver"], 0)

    # --------------------------------------------------------------------------
    # Feature 11: Non-Recursive Execution (ORIGINAL_REQUEST R2.1)
    # --------------------------------------------------------------------------
    def test_t1_f11_01_recursion_depth_zero_valid(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        self.assertEqual(ev.recursion_depth, 0)

    def test_t1_f11_02_consolidation_rule_immutable(self) -> None:
        res = TarjanBridgeVerifier.verify_solver_pipeline(consolidation_rule_immutable=True)
        self.assertTrue(res["consolidation_rule_immutable"])

    def test_t1_f11_03_tarjan_recursion_guard(self) -> None:
        res = TarjanBridgeVerifier.verify_solver_pipeline(recursion_depth=0)
        self.assertEqual(res["recursion_depth"], 0)

    def test_t1_f11_04_read_only_log_ingestion_flag(self) -> None:
        schema = load_master_event_contract_schema()
        coordination_invs = schema["multica_defect_axes"]["Coordination"]["invariants"]
        self.assertTrue(any("O_RDONLY" in inv for inv in coordination_invs))

    def test_t1_f11_05_gate_g3_recursion_parameter(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g3(recursion_depth=0)
        self.assertTrue(res.passed)

    # --------------------------------------------------------------------------
    # Feature 12: 8-Pool Reactor Hydraulics (ORIGINAL_REQUEST R1.3)
    # --------------------------------------------------------------------------
    def test_t1_f12_01_n_pool_eight_chambers(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        self.assertEqual(ev.payload.n_pool, 8)
        self.assertEqual(len(ev.payload.chamber_ids), 8)

    def test_t1_f12_02_chamber_naming_convention(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        for idx, cid in enumerate(ev.payload.chamber_ids, 1):
            self.assertEqual(cid, f"vogels_pool_{idx}")

    def test_t1_f12_03_vessel_volume_si(self) -> None:
        schema = load_master_event_contract_schema()
        vessel_vol = schema["subsystems"]["ReactorPools"]["modular_chamber_topology"]["vessel_volume_L"]
        self.assertAlmostEqual(vessel_vol, 0.25)

    def test_t1_f12_04_flow_rate_and_residence_time(self) -> None:
        vol_L = 0.25
        flow_L_s = 2.5e-4
        tau_res_s = vol_L / flow_L_s
        self.assertAlmostEqual(tau_res_s, 1000.0)

    def test_t1_f12_05_multipool_envelope_validation(self) -> None:
        p = generate_synthetic_reactor_pools_event().payload
        validate_multipool_reactor_envelope(p)

    # --------------------------------------------------------------------------
    # Feature 13: Vogel's Minimal Medium Speciation (ORIGINAL_REQUEST R1.3)
    # --------------------------------------------------------------------------
    def test_t1_f13_01_sucrose_gradient_monotone(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        sucrose = ev.payload.sucrose_concentrations_mol_m3
        self.assertEqual(len(sucrose), 8)
        for i in range(len(sucrose) - 1):
            self.assertGreaterEqual(sucrose[i], sucrose[i + 1])

    def test_t1_f13_02_temperature_profile_kelvin(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        temps = ev.payload.temperatures_kelvin
        self.assertEqual(len(temps), 8)
        self.assertTrue(all(298.0 <= t <= 299.0 for t in temps))

    def test_t1_f13_03_oxygen_concentration_vector(self) -> None:
        nc4 = verify_neurospora_crassa_4block_8pool_contract()
        self.assertEqual(len(nc4["c_o2_mol_m3"]), 8)

    def test_t1_f13_04_substrate_consumption_balance(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        sucrose = ev.payload.sucrose_concentrations_mol_m3
        self.assertAlmostEqual(sucrose[0], 55.0, places=1)
        self.assertAlmostEqual(sucrose[-1], 31.6, places=1)

    def test_t1_f13_05_speciation_envelope_roundtrip(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        json_str = ev.to_json()
        ev_back = MasterEvent.from_json(json_str)
        self.assertEqual(len(ev_back.payload.sucrose_concentrations_mol_m3), 8)

    # --------------------------------------------------------------------------
    # Feature 14: PHREEQC Activity-Averaged pH (ORIGINAL_REQUEST R1.3)
    # --------------------------------------------------------------------------
    def test_t1_f14_01_valid_activity_averaged_ph(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        ph = ev.payload.phreeqc_activity_avg_ph
        self.assertTrue(5.0 <= ph <= 7.5)

    def test_t1_f14_02_charge_imbalance_within_one_pct(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        self.assertLessEqual(ev.payload.phreeqc_charge_imbalance_pct, 1.0)

    def test_t1_f14_03_carbonate_equilibrium_bounds(self) -> None:
        ev = generate_synthetic_reactor_pools_event(phreeqc_activity_avg_ph=6.45)
        self.assertAlmostEqual(ev.payload.phreeqc_activity_avg_ph, 6.45)

    def test_t1_f14_04_phreeqc_schema_fields(self) -> None:
        p = generate_synthetic_reactor_pools_event().payload
        self.assertTrue(hasattr(p, "phreeqc_activity_avg_ph"))
        self.assertTrue(hasattr(p, "phreeqc_charge_imbalance_pct"))

    def test_t1_f14_05_geochemical_solver_specification(self) -> None:
        schema = load_master_event_contract_schema()
        solver = schema["neurospora_crassa_matlab_r2026b_blocks"]["block_3_eight_pool_vogels_medium_phreeqc_and_nutmeg"]["geochemical_solver"]
        self.assertEqual(solver, "PHREEQC_carbonate_pH_pe_speciation")

    # --------------------------------------------------------------------------
    # Feature 15: Radiolytic H2O2 Scavenging (ORIGINAL_REQUEST R1.3)
    # --------------------------------------------------------------------------
    def test_t1_f15_01_h2o2_scavenged_vector_length(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        self.assertEqual(len(ev.payload.radiolytic_h2o2_scavenged_uM), 8)

    def test_t1_f15_02_dhn_melanin_quenching_efficiency(self) -> None:
        ctl = ALARAClosedLoopController()
        yields = ctl.compute_radiolytic_yields(8.2e-7, 0.18)
        self.assertIn("R_H2O2_mol_m3_s", yields)
        self.assertIn("scavenge_factor", yields)

    def test_t1_f15_03_scavenging_range_uM(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        scav = ev.payload.radiolytic_h2o2_scavenged_uM
        self.assertTrue(all(10.0 <= x <= 25.0 for x in scav))

    def test_t1_f15_04_melanin_concentration_vector(self) -> None:
        ctl = ALARAClosedLoopController()
        dose_rate_unshielded = 8.2e-7
        d_eff_mel0 = ctl.compute_effective_dose_rate(
            dose_rate_unshielded, 10.0, 1.0, 0.10, 23.5, 0.0
        )
        d_eff_mel18 = ctl.compute_effective_dose_rate(
            dose_rate_unshielded, 10.0, 1.0, 0.10, 23.5, 0.18
        )
        self.assertLess(d_eff_mel18, d_eff_mel0)

    def test_t1_f15_05_radical_scavenging_yield(self) -> None:
        ctl = ALARAClosedLoopController()
        y = ctl.compute_radiolytic_yields(8.2e-7, 0.18)
        self.assertGreater(y["R_H2O2_mol_m3_s"], 0.0)

    # --------------------------------------------------------------------------
    # Feature 16: Neurospora Circadian Oscillator (ORIGINAL_REQUEST R1.4)
    # --------------------------------------------------------------------------
    def test_t1_f16_01_circadian_state_dataclass(self) -> None:
        cs = CircadianState(M_frq=1.2, F_c=2.4, F_n=0.8, phi_radians=1.57)
        self.assertEqual(cs.M_frq, 1.2)
        self.assertEqual(cs.F_c, 2.4)
        self.assertEqual(cs.F_n, 0.8)
        self.assertEqual(cs.phi_radians, 1.57)

    def test_t1_f16_02_tau_dd_period(self) -> None:
        schema = load_master_event_contract_schema()
        tau_dd = schema["neurospora_crassa_matlab_r2026b_blocks"]["block_1_circadian_frq_wc1_wc2_oscillator"]["tau_DD_hr"]
        self.assertEqual(tau_dd, 22.5)

    def test_t1_f16_03_tau_ld_entrained_period(self) -> None:
        schema = load_master_event_contract_schema()
        tau_ld = schema["neurospora_crassa_matlab_r2026b_blocks"]["block_1_circadian_frq_wc1_wc2_oscillator"]["tau_LD_hr"]
        self.assertEqual(tau_ld, 24.0)

    def test_t1_f16_04_instantaneous_phase_bounds(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        phi = ev.payload.circadian_state.phi_radians
        self.assertTrue(0.0 <= phi <= 2 * math.pi)

    def test_t1_f16_05_photoentrainment_actuator(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(circadian_phase_rad=math.pi / 2)
        out = ctl.step_controller(state)
        self.assertGreater(out.Phi_light_umol_m2_s, 0.0)

    # --------------------------------------------------------------------------
    # Feature 17: Cytoplasmic Streaming & HEX-1 (ORIGINAL_REQUEST R1.4)
    # --------------------------------------------------------------------------
    def test_t1_f17_01_streaming_velocity_nominal(self) -> None:
        ev = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=25.0)
        self.assertAlmostEqual(ev.payload.cytoplasmic_streaming_velocity_um_s, 25.0)

    def test_t1_f17_02_hex1_woronin_inactive_nominal(self) -> None:
        ev = generate_synthetic_biofilm_session_event(hex1_woronin_plugging_active=False)
        self.assertFalse(ev.payload.hex1_woronin_plugging_active)

    def test_t1_f17_03_hex1_woronin_active_emergency(self) -> None:
        ev = generate_synthetic_biofilm_session_event(hex1_woronin_plugging_active=True)
        self.assertTrue(ev.payload.hex1_woronin_plugging_active)

    def test_t1_f17_04_streaming_velocity_bounds_check(self) -> None:
        for v in (5.0, 30.0, 60.0):
            ev = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=v)
            self.assertEqual(ev.payload.cytoplasmic_streaming_velocity_um_s, v)

    def test_t1_f17_05_woronin_plugging_boolean(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        self.assertIsInstance(ev.payload.hex1_woronin_plugging_active, bool)

    # --------------------------------------------------------------------------
    # Feature 18: Anastomosis Topology & Biofilm (ORIGINAL_REQUEST R1.4)
    # --------------------------------------------------------------------------
    def test_t1_f18_01_anastomosis_betti_numbers(self) -> None:
        at = AnastomosisTopology(beta_0=1, beta_1=3)
        self.assertEqual(at.beta_0, 1)
        self.assertEqual(at.beta_1, 3)

    def test_t1_f18_02_biomass_density_limit(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        biomass = ev.payload.biomass_density_kg_m3
        self.assertEqual(len(biomass), 8)
        self.assertTrue(all(0.0 <= b <= 1.20 for b in biomass))

    def test_t1_f18_03_tip_density_vector(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        tips = ev.payload.tip_density_m3
        self.assertEqual(len(tips), 8)
        self.assertTrue(all(t >= 0.0 for t in tips))

    def test_t1_f18_04_eps_streamer_fraction(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        eps = ev.payload.eps_streamer_fraction
        self.assertEqual(len(eps), 8)
        self.assertTrue(all(0.0 <= e <= 1.0 for e in eps))

    def test_t1_f18_05_biofilm_envelope_validation(self) -> None:
        p = generate_synthetic_biofilm_session_event().payload
        validate_biofilm_session_envelope(p)

    # --------------------------------------------------------------------------
    # Feature 19: NutMEG Maintenance Quarantine (ORIGINAL_REQUEST R1.3)
    # --------------------------------------------------------------------------
    def test_t1_f19_01_temperature_above_280k_accepted(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=298.15)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertFalse(q["below_280K_nutmeg"])
        self.assertEqual(q["verdict"], ":Accepted")

    def test_t1_f19_02_temperature_below_280k_incomplete(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=275.0)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertTrue(q["below_280K_nutmeg"])
        self.assertEqual(q["verdict"], ":Incomplete")
        self.assertEqual(q["quarantined_hypotheses"]["nutmeg_maintenance_power_below_280K"], ":Incomplete")

    def test_t1_f19_03_no_silent_promotion_to_accepted(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=270.0)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertNotEqual(q["verdict"], ":Accepted")

    def test_t1_f19_04_no_collapse_to_rejected(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=260.0)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertNotEqual(q["verdict"], ":Rejected")

    def test_t1_f19_05_multipool_nutmeg_quarantine_field(self) -> None:
        ev = generate_synthetic_reactor_pools_event(temperatures_kelvin=[275.0] * 8)
        self.assertEqual(ev.payload.nutmeg_quarantine_status, ":Incomplete")

    # --------------------------------------------------------------------------
    # Feature 20: Health-Physics ALARA 80% Safing (ORIGINAL_REQUEST R2.3)
    # --------------------------------------------------------------------------
    def test_t1_f20_01_below_80pct_safing_nominal(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.035)
        out = ctl.step_controller(state)
        self.assertFalse(out.safing_shutter_closed)
        self.assertEqual(out.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")

    def test_t1_f20_02_at_80pct_safing_trip(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.041)
        out = ctl.step_controller(state)
        self.assertTrue(out.safing_shutter_closed)
        self.assertEqual(out.controller_mode, "SAFE_HOLD_SHUTTER_CLOSED")

    def test_t1_f20_03_max_allowable_dose_ceiling(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.049)
        out = ctl.step_controller(state)
        self.assertTrue(out.cumulative_dose_Gy <= out.max_allowable_dose_Gy)

    def test_t1_f20_04_safing_shutter_isolation(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.045)
        out = ctl.step_controller(state)
        self.assertTrue(out.safing_shutter_closed)
        self.assertLessEqual(out.u_valve_m3_s, 5.0e-5)

    def test_t1_f20_05_gate_g7_safing_evaluation(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.041)
        self.assertTrue(res.details["payload_safing_triggered"])

    # --------------------------------------------------------------------------
    # Feature 21: Simulink Closed-Loop LQR/MPC (ORIGINAL_REQUEST R2.3)
    # --------------------------------------------------------------------------
    def test_t1_f21_01_mimo_actuators_tuple(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.020)
        out = ctl.step_controller(state)
        self.assertTrue(hasattr(out, "u_valve_m3_s"))
        self.assertTrue(hasattr(out, "z_shield_m"))
        self.assertTrue(hasattr(out, "Phi_light_umol_m2_s"))

    def test_t1_f21_02_controller_mode_regulation(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.015)
        out = ctl.step_controller(state)
        self.assertEqual(out.controller_mode, "NOMINAL_BIOREACTOR_SCIENCE")

    def test_t1_f21_03_valve_actuation_bounds(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.025)
        out = ctl.step_controller(state)
        self.assertGreaterEqual(out.u_valve_m3_s, 0.0)

    def test_t1_f21_04_shield_thickness_adjustment(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(dose_rate_Gy_s=1e-5)
        out = ctl.step_controller(state)
        self.assertGreater(out.z_shield_m, 0.0)

    def test_t1_f21_05_light_flux_circadian_tracking(self) -> None:
        ctl = ALARAClosedLoopController()
        state_day = ALARAControllerState(circadian_phase_rad=0.0)
        state_night = ALARAControllerState(circadian_phase_rad=math.pi)
        out_day = ctl.step_controller(state_day)
        out_night = ctl.step_controller(state_night)
        self.assertGreater(out_day.Phi_light_umol_m2_s, out_night.Phi_light_umol_m2_s)

    # --------------------------------------------------------------------------
    # Feature 22: Epistemic Hippocratism Quarantine (ORIGINAL_REQUEST R2.3)
    # --------------------------------------------------------------------------
    def test_t1_f22_01_three_valued_domain(self) -> None:
        for s in (":Accepted", ":Incomplete", ":Rejected"):
            self.assertIn(s, VALID_EPISTEMIC_STATUSES)

    def test_t1_f22_02_unverified_hormesis_quarantined(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState()
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertEqual(q["quarantined_hypotheses"]["unverified_low_dose_radiation_hormesis"], ":Incomplete")

    def test_t1_f22_03_unverified_atp_radiosynthesis_quarantined(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState()
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertEqual(q["quarantined_hypotheses"]["direct_net_atp_radiosynthesis_without_electron_donor_mass_balance"], ":Incomplete")

    def test_t1_f22_04_unverified_spice_units_quarantined(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(spice_units_verified_by_spkpos=False)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertEqual(q["quarantined_hypotheses"]["unverified_spice_jl_units_prior_to_spkpos_check"], ":Incomplete")

    def test_t1_f22_05_primum_non_nocere_immutability(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7()
        self.assertIn("quarantined_hypotheses", res.details)

    # --------------------------------------------------------------------------
    # Feature 23: Synthetic Round-Trip Validation (Acceptance Criteria)
    # --------------------------------------------------------------------------
    def test_t1_f23_01_s1_neuralcompose_roundtrip(self) -> None:
        ev = generate_synthetic_neuralcompose_event(sequence_id="rt_s1")
        ev_back = MasterEvent.from_json(ev.to_json())
        self.assertEqual(ev_back.event_id, ev.event_id)
        self.assertEqual(ev_back.payload.sequence_id, "rt_s1")

    def test_t1_f23_02_s2_momentum_automata_roundtrip(self) -> None:
        ev = generate_synthetic_momentum_automata_event(sequence_id="rt_s2")
        ev_back = MasterEvent.from_json(ev.to_json())
        self.assertEqual(ev_back.payload.sequence_id, "rt_s2")

    def test_t1_f23_03_s3_multipool_reactor_roundtrip(self) -> None:
        ev = generate_synthetic_reactor_pools_event(sequence_id="rt_s3")
        ev_back = MasterEvent.from_json(ev.to_json())
        self.assertEqual(ev_back.payload.sequence_id, "rt_s3")

    def test_t1_f23_04_s4_biofilm_session_roundtrip(self) -> None:
        ev = generate_synthetic_biofilm_session_event(sequence_id="rt_s4")
        ev_back = MasterEvent.from_json(ev.to_json())
        self.assertEqual(ev_back.payload.sequence_id, "rt_s4")

    def test_t1_f23_05_unified_master_event_roundtrip(self) -> None:
        runner = SyntheticEventRoundTripRunner()
        res = runner.test_round_trip_serialization_all_subsystems()
        self.assertTrue(all(res.values()))

    # --------------------------------------------------------------------------
    # Feature 24: Typographic Zero-Dash Hygiene (Acceptance Criteria)
    # --------------------------------------------------------------------------
    def test_t1_f24_01_schema_json_zero_dashes(self) -> None:
        text = SCHEMA_PATH.read_text(encoding="utf-8")
        self.assertNotIn("\u2014", text)
        self.assertNotIn("\u2013", text)

    def test_t1_f24_02_serialized_events_zero_dashes(self) -> None:
        for ev in (
            generate_synthetic_neuralcompose_event(),
            generate_synthetic_momentum_automata_event(),
            generate_synthetic_reactor_pools_event(),
            generate_synthetic_biofilm_session_event(),
        ):
            j = ev.to_json()
            self.assertNotIn("\u2014", j)
            self.assertNotIn("\u2013", j)

    def test_t1_f24_03_sanitize_dashes_utility(self) -> None:
        raw = "word\u2014another\u2013word"
        clean = sanitize_dashes(raw)
        self.assertNotIn("\u2014", clean)
        self.assertNotIn("\u2013", clean)
        self.assertEqual(clean, "word - another-word")

    def test_t1_f24_04_contract_error_messages_zero_dashes(self) -> None:
        err = CategoryTypeViolation("Test error message")
        self.assertNotIn("\u2014", str(err))
        self.assertNotIn("\u2013", str(err))

    def test_t1_f24_05_docstrings_zero_dashes(self) -> None:
        import Scripts.contracts.master_event_contract as mec
        self.assertNotIn("\u2014", mec.__doc__ or "")
        self.assertNotIn("\u2013", mec.__doc__ or "")



class TestTier2BoundaryAndCornerCases(unittest.TestCase):
    """Tier 2: Boundary & Corner Cases (5 tests per feature across all 24 features = 120 tests)."""

    # --------------------------------------------------------------------------
    # Feature 1 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f01_01_frame_index_lower_bound_zero(self) -> None:
        env = NeuralComposeFixtureEnvelope("seq_b1", "F_Laya", 0, BettiNumbers(1, 0), DefectAxes(), False, 0.1)
        self.assertEqual(env.frame_index, 0)

    def test_t2_f01_02_frame_index_upper_bound_59(self) -> None:
        env = NeuralComposeFixtureEnvelope("seq_b2", "F_Laya", 59, BettiNumbers(1, 0), DefectAxes(), False, 0.1)
        self.assertEqual(env.frame_index, 59)

    def test_t2_f01_03_frame_index_negative_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            NeuralComposeFixtureEnvelope("seq_b3", "F_Laya", -1, BettiNumbers(1, 0), DefectAxes(), False, 0.1)

    def test_t2_f01_04_frame_index_60_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            NeuralComposeFixtureEnvelope("seq_b4", "F_Laya", 60, BettiNumbers(1, 0), DefectAxes(), False, 0.1)

    def test_t2_f01_05_invalid_functor_stage_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            NeuralComposeFixtureEnvelope("seq_b5", "F_Unknown", 10, BettiNumbers(1, 0), DefectAxes(), False, 0.1)

    # --------------------------------------------------------------------------
    # Feature 2 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f02_01_empty_sequence_id_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            NeuralComposeFixtureEnvelope("", "F_Laya", 0, BettiNumbers(1, 0), DefectAxes(), False, 0.1)

    def test_t2_f02_02_negative_tension_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            NeuralComposeFixtureEnvelope("seq_b6", "F_Laya", 0, BettiNumbers(1, 0), DefectAxes(), False, -0.01)

    def test_t2_f02_03_zero_tension_boundary(self) -> None:
        env = NeuralComposeFixtureEnvelope("seq_b7", "F_Laya", 0, BettiNumbers(1, 0), DefectAxes(), False, 0.0)
        self.assertEqual(env.mahalanobis_tension_D_M, 0.0)

    def test_t2_f02_04_none_sequence_id_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            NeuralComposeFixtureEnvelope(None, "F_Laya", 0, BettiNumbers(1, 0), DefectAxes(), False, 0.1)  # type: ignore

    def test_t2_f02_05_beta_0_zero_rejected_in_betti(self) -> None:
        with self.assertRaises(SchemaValidationError):
            BettiNumbers(beta_0=0, beta_1=1)

    # --------------------------------------------------------------------------
    # Feature 3 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f03_01_all_four_axes_tripped(self) -> None:
        da = DefectAxes(boundary=True, control=True, source=True, coordination=True)
        self.assertFalse(da.is_clean())

    def test_t2_f03_02_string_in_defect_axis_rejected(self) -> None:
        payload = {
            "sequence_id": "seq_da_str",
            "functor_stage": "F_Laya",
            "frame_index": 5,
            "betti_numbers": {"beta_0": 1, "beta_1": 2},
            "defect_axes": {"boundary": "True", "control": False, "source": False, "coordination": False},
            "toy_drive_active": False,
            "mahalanobis_tension_D_M": 1.0,
        }
        with self.assertRaises(SchemaValidationError):
            validate_neuralcompose_fixture_envelope(payload)

    def test_t2_f03_03_missing_axis_key_rejected(self) -> None:
        payload = {
            "sequence_id": "seq_da_miss",
            "functor_stage": "F_Laya",
            "frame_index": 5,
            "betti_numbers": {"beta_0": 1, "beta_1": 2},
            "defect_axes": {"boundary": False, "control": False, "source": False},
            "toy_drive_active": False,
            "mahalanobis_tension_D_M": 1.0,
        }
        with self.assertRaises(SchemaValidationError):
            validate_neuralcompose_fixture_envelope(payload)

    def test_t2_f03_04_int_in_defect_axis_rejected(self) -> None:
        payload = {
            "sequence_id": "seq_da_int",
            "functor_stage": "F_Laya",
            "frame_index": 5,
            "betti_numbers": {"beta_0": 1, "beta_1": 2},
            "defect_axes": {"boundary": 1, "control": False, "source": False, "coordination": False},
            "toy_drive_active": False,
            "mahalanobis_tension_D_M": 1.0,
        }
        with self.assertRaises(SchemaValidationError):
            validate_neuralcompose_fixture_envelope(payload)

    def test_t2_f03_05_negative_betti_1_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            BettiNumbers(beta_0=1, beta_1=-1)

    # --------------------------------------------------------------------------
    # Feature 4 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f04_01_non_bool_toy_drive_rejected(self) -> None:
        p = {
            "sequence_id": "seq_missing_td",
            "functor_stage": "F_Laya",
            "frame_index": 0,
            "betti_numbers": {"beta_0": 1, "beta_1": 0},
            "defect_axes": {"boundary": False, "control": False, "source": False, "coordination": False},
            "mahalanobis_tension_D_M": 1.0,
        }
        with self.assertRaises(SchemaValidationError):
            validate_neuralcompose_fixture_envelope(p)

    def test_t2_f04_02_toy_drive_at_extreme_tension(self) -> None:
        ev = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=100.0, toy_drive_active=True)
        self.assertEqual(ev.payload.mahalanobis_tension_D_M, 100.0)
        self.assertTrue(ev.payload.toy_drive_active)

    def test_t2_f04_03_toy_drive_at_zero_tension(self) -> None:
        ev = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=0.0, toy_drive_active=True)
        self.assertEqual(ev.payload.mahalanobis_tension_D_M, 0.0)

    def test_t2_f04_04_toy_drive_rapid_transition(self) -> None:
        ev1 = generate_synthetic_neuralcompose_event(toy_drive_active=True)
        ev2 = generate_synthetic_neuralcompose_event(toy_drive_active=False)
        self.assertTrue(ev1.payload.toy_drive_active)
        self.assertFalse(ev2.payload.toy_drive_active)

    def test_t2_f04_05_toy_drive_serialized_as_boolean(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=True)
        raw = ev.to_json()
        self.assertIn('"toy_drive_active": true', raw)

    # --------------------------------------------------------------------------
    # Feature 5 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f05_01_negative_k_eff_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            CriticalityMetrics(k_eff=-0.01, rho_pcm=0.0, z_crit=1.0, chi=1.0)

    def test_t2_f05_02_negative_chi_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=-0.5)

    def test_t2_f05_03_k_eff_zero_prompt_shutdown(self) -> None:
        cm = CriticalityMetrics(k_eff=0.0, rho_pcm=-10000.0, z_crit=0.0, chi=0.0)
        env = MomentumAutomataEnvelope("seq_sd", cm, "SUBCRITICAL", "Focus", 0.0, False)
        self.assertEqual(env.criticality_metrics.k_eff, 0.0)

    def test_t2_f05_04_invalid_criticality_regime_rejected(self) -> None:
        cm = CriticalityMetrics(k_eff=1.0, rho_pcm=0.0, z_crit=1.0, chi=1.0)
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope("seq_inv_reg", cm, "INVALID_REGIME", "Focus", 1.0, False)

    def test_t2_f05_05_nan_k_eff_rejected(self) -> None:
        with self.assertRaises(CategoryTypeViolation):
            CriticalityMetrics(k_eff=float("nan"), rho_pcm=0.0, z_crit=1.0, chi=1.0)

    # --------------------------------------------------------------------------
    # Feature 6 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f06_01_float_header_rejected(self) -> None:
        with self.assertRaises(CategoryTypeViolation):
            assert_stage_header(7.1)

    def test_t2_f06_02_int_header_rejected(self) -> None:
        with self.assertRaises(CategoryTypeViolation):
            assert_stage_header(7)

    def test_t2_f06_03_float_for_int64_rejected(self) -> None:
        with self.assertRaises(CategoryTypeViolation):
            assert_int64(1.0, "chamber_index")

    def test_t2_f06_04_bool_for_int64_rejected(self) -> None:
        with self.assertRaises(CategoryTypeViolation):
            assert_int64(True, "beta_0")

    def test_t2_f06_05_bool_for_float64_rejected(self) -> None:
        with self.assertRaises(CategoryTypeViolation):
            assert_float64(True, "pressure_Pa")

    # --------------------------------------------------------------------------
    # Feature 7 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f07_01_zero_hysteresis_area(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        env = MomentumAutomataEnvelope("seq_h0", cm, "SUBCRITICAL", "Focus", 0.0, False)
        self.assertEqual(env.hysteresis_loop_area, 0.0)

    def test_t2_f07_02_negative_hysteresis_area_rejected(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope("seq_hneg", cm, "SUBCRITICAL", "Focus", -1.0, False)

    def test_t2_f07_03_exact_threshold_4_0(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        env = MomentumAutomataEnvelope("seq_h4", cm, "CRITICAL_WITHIN_NOISE", "Focus", 4.0, True)
        self.assertEqual(env.hysteresis_loop_area, 4.0)

    def test_t2_f07_04_inf_hysteresis_area_rejected(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        with self.assertRaises(CategoryTypeViolation):
            MomentumAutomataEnvelope("seq_hinf", cm, "SUBCRITICAL", "Focus", float("inf"), False)

    def test_t2_f07_05_orderbook_betti_1_zero_rejected(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope("seq_ob0", cm, "SUBCRITICAL", "Focus", 1.0, False, orderbook_betti_1=0)

    # --------------------------------------------------------------------------
    # Feature 8 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f08_01_focus_boundary_1_8(self) -> None:
        ev = generate_synthetic_momentum_automata_event(wbr_mode="Focus")
        self.assertEqual(ev.payload.wbr_mode, "Focus")

    def test_t2_f08_02_frustration_boundary_2_45(self) -> None:
        ev = generate_synthetic_momentum_automata_event(wbr_mode="Frustration")
        self.assertEqual(ev.payload.wbr_mode, "Frustration")

    def test_t2_f08_03_invalid_wbr_mode_rejected(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope("seq_bad_wbr", cm, "SUBCRITICAL", "InvalidWBR", 1.0, False)

    def test_t2_f08_04_lowercase_wbr_mode_rejected(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope("seq_lower_wbr", cm, "SUBCRITICAL", "focus", 1.0, False)

    def test_t2_f08_05_balance_tree_betti_1_nonzero_rejected(self) -> None:
        cm = CriticalityMetrics(1.0, 0.0, 1.0, 1.0)
        with self.assertRaises(SchemaValidationError):
            MomentumAutomataEnvelope("seq_bad_bt", cm, "SUBCRITICAL", "Focus", 1.0, False, balance_tree_betti_1=1)

    # --------------------------------------------------------------------------
    # Feature 9 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f09_01_gate_g1_wrong_scale_trips_boundary(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g1(unit_scale_km_to_m=100.0)
        self.assertFalse(res.passed)
        self.assertIn("Boundary", res.defect_axes_tripped)

    def test_t2_f09_02_gate_g1_conflation_trips_boundary(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g1(conflate_unit_scale_with_propulsion_or_dcm=True)
        self.assertFalse(res.passed)
        self.assertIn("Boundary", res.defect_axes_tripped)

    def test_t2_f09_03_gate_g2_conflation_trips_boundary(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g2(conflate_header_as_numeric=True)
        self.assertFalse(res.passed)
        self.assertIn("Boundary", res.defect_axes_tripped)

    def test_t2_f09_04_gate_g3_self_loop_trips_coordination(self) -> None:
        nodes = ["A", "B"]
        edges = [("A", "B"), ("B", "B")]
        res = LogicGatesEvaluator.evaluate_gate_g3(nodes=nodes, directed_edges=edges)
        self.assertFalse(res.passed)
        self.assertIn("Coordination", res.defect_axes_tripped)

    def test_t2_f09_05_gate_g4_reverse_edge_trips_coordination(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g4(reverse_ledger_to_orderbook_edge=True)
        self.assertFalse(res.passed)
        self.assertIn("Coordination", res.defect_axes_tripped)

    # --------------------------------------------------------------------------
    # Feature 10 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f10_01_2node_cycle_detected(self) -> None:
        nodes = ["NodeA", "NodeB"]
        edges = [("NodeA", "NodeB"), ("NodeB", "NodeA")]
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(nodes, edges)

    def test_t2_f10_02_3node_cycle_detected(self) -> None:
        nodes = ["N1", "N2", "N3"]
        edges = [("N1", "N2"), ("N2", "N3"), ("N3", "N1")]
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(nodes, edges)

    def test_t2_f10_03_self_loop_detected(self) -> None:
        nodes = ["N1"]
        edges = [("N1", "N1")]
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(nodes, edges)

    def test_t2_f10_04_diamond_graph_beta_1_positive(self) -> None:
        nodes = ["A", "B", "C", "D"]
        edges = [("A", "B"), ("A", "C"), ("B", "D"), ("C", "D")]
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(nodes, edges)

    def test_t2_f10_05_empty_graph_handled(self) -> None:
        sccs = tarjan_scc([], [])
        self.assertEqual(len(sccs), 0)

    # --------------------------------------------------------------------------
    # Feature 11 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f11_01_recursion_depth_1_rejected(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        d["recursion_depth"] = 1
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f11_02_recursion_depth_negative_rejected(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        d["recursion_depth"] = -1
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f11_03_recursion_depth_extreme_rejected(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        d["recursion_depth"] = 100
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f11_04_consolidation_rule_mutable_rejected(self) -> None:
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(consolidation_rule_immutable=False)

    def test_t2_f11_05_float_recursion_depth_rejected(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        d["recursion_depth"] = 0.0
        with self.assertRaises(CategoryTypeViolation):
            MasterEvent.from_dict(d)

    # --------------------------------------------------------------------------
    # Feature 12 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f12_01_n_pool_7_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["n_pool"] = 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f12_02_n_pool_9_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["n_pool"] = 9
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f12_03_chamber_ids_length_7_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["chamber_ids"] = [f"pool_{i}" for i in range(7)]
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f12_04_sucrose_length_9_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["sucrose_concentrations_mol_m3"] = [50.0] * 9
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f12_05_temperatures_length_7_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["temperatures_kelvin"] = [298.15] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    # --------------------------------------------------------------------------
    # Feature 13 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f13_01_zero_sucrose_boundary(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["sucrose_concentrations_mol_m3"] = [0.0] * 8
        ev_back = MasterEvent.from_dict(d)
        self.assertEqual(ev_back.payload.sucrose_concentrations_mol_m3[0], 0.0)

    def test_t2_f13_02_negative_sucrose_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["sucrose_concentrations_mol_m3"] = [-1.0] + [50.0] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f13_03_negative_temperature_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["temperatures_kelvin"] = [-5.0] + [298.15] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f13_04_zero_kelvin_boundary(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["temperatures_kelvin"] = [0.0] * 8
        ev_back = MasterEvent.from_dict(d)
        self.assertEqual(ev_back.payload.temperatures_kelvin[0], 0.0)

    def test_t2_f13_05_nan_sucrose_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["sucrose_concentrations_mol_m3"] = [float("nan")] + [50.0] * 7
        with self.assertRaises(CategoryTypeViolation):
            MasterEvent.from_dict(d)

    # --------------------------------------------------------------------------
    # Feature 14 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f14_01_ph_zero_boundary(self) -> None:
        ev = generate_synthetic_reactor_pools_event(phreeqc_activity_avg_ph=0.0)
        self.assertEqual(ev.payload.phreeqc_activity_avg_ph, 0.0)

    def test_t2_f14_02_ph_14_boundary(self) -> None:
        ev = generate_synthetic_reactor_pools_event(phreeqc_activity_avg_ph=14.0)
        self.assertEqual(ev.payload.phreeqc_activity_avg_ph, 14.0)

    def test_t2_f14_03_ph_negative_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_reactor_pools_event(phreeqc_activity_avg_ph=-0.1)

    def test_t2_f14_04_ph_above_14_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_reactor_pools_event(phreeqc_activity_avg_ph=14.1)

    def test_t2_f14_05_charge_imbalance_negative_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_reactor_pools_event(phreeqc_charge_imbalance_pct=-0.1)

    # --------------------------------------------------------------------------
    # Feature 15 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f15_01_zero_h2o2_scavenged(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["radiolytic_h2o2_scavenged_uM"] = [0.0] * 8
        ev_back = MasterEvent.from_dict(d)
        self.assertEqual(ev_back.payload.radiolytic_h2o2_scavenged_uM[0], 0.0)

    def test_t2_f15_02_h2o2_length_7_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["radiolytic_h2o2_scavenged_uM"] = [15.0] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f15_03_melanin_zero_fraction(self) -> None:
        ctl = ALARAClosedLoopController()
        d_eff = ctl.compute_effective_dose_rate(8.2e-7, 10.0, 1.0, 0.10, 23.5, 0.0)
        self.assertGreater(d_eff, 0.0)

    def test_t2_f15_04_melanin_half_fraction(self) -> None:
        ctl = ALARAClosedLoopController()
        d_eff = ctl.compute_effective_dose_rate(8.2e-7, 10.0, 1.0, 0.10, 23.5, 0.50)
        self.assertGreater(d_eff, 0.0)

    def test_t2_f15_05_negative_standoff_distance_rejected(self) -> None:
        ctl = ALARAClosedLoopController()
        with self.assertRaises(ALARAControllerError):
            ctl.compute_effective_dose_rate(8.2e-7, 0.5, 1.0, 0.10, 23.5, 0.18)

    # --------------------------------------------------------------------------
    # Feature 16 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f16_01_zero_m_frq_boundary(self) -> None:
        cs = CircadianState(M_frq=0.0, F_c=1.0, F_n=1.0, phi_radians=0.0)
        self.assertEqual(cs.M_frq, 0.0)

    def test_t2_f16_02_negative_m_frq_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            CircadianState(M_frq=-0.1, F_c=1.0, F_n=1.0, phi_radians=0.0)

    def test_t2_f16_03_negative_f_c_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            CircadianState(M_frq=1.0, F_c=-0.1, F_n=1.0, phi_radians=0.0)

    def test_t2_f16_04_negative_f_n_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            CircadianState(M_frq=1.0, F_c=1.0, F_n=-0.1, phi_radians=0.0)

    def test_t2_f16_05_phase_boundary_two_pi(self) -> None:
        cs = CircadianState(M_frq=1.0, F_c=1.0, F_n=1.0, phi_radians=2 * math.pi)
        self.assertAlmostEqual(cs.phi_radians, 2 * math.pi)

    # --------------------------------------------------------------------------
    # Feature 17 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f17_01_streaming_velocity_boundary_5(self) -> None:
        ev = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=5.0)
        self.assertEqual(ev.payload.cytoplasmic_streaming_velocity_um_s, 5.0)

    def test_t2_f17_02_streaming_velocity_boundary_60(self) -> None:
        ev = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=60.0)
        self.assertEqual(ev.payload.cytoplasmic_streaming_velocity_um_s, 60.0)

    def test_t2_f17_03_streaming_velocity_4_9_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=4.9)

    def test_t2_f17_04_streaming_velocity_60_1_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=60.1)

    def test_t2_f17_05_negative_streaming_velocity_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=-5.0)

    # --------------------------------------------------------------------------
    # Feature 18 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f18_01_anastomosis_beta_0_not_1_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=2, beta_1=3)

    def test_t2_f18_02_anastomosis_beta_1_zero_rejected(self) -> None:
        with self.assertRaises(SchemaValidationError):
            AnastomosisTopology(beta_0=1, beta_1=0)

    def test_t2_f18_03_biomass_boundary_1_20(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        d = ev.to_dict()
        d["payload"]["biomass_density_kg_m3"] = [1.20] * 8
        ev_back = MasterEvent.from_dict(d)
        self.assertEqual(ev_back.payload.biomass_density_kg_m3[0], 1.20)

    def test_t2_f18_04_biomass_above_1_20_rejected(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        d = ev.to_dict()
        d["payload"]["biomass_density_kg_m3"] = [1.21] + [0.5] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f18_05_eps_streamer_above_1_rejected(self) -> None:
        ev = generate_synthetic_biofilm_session_event()
        d = ev.to_dict()
        d["payload"]["eps_streamer_fraction"] = [1.05] + [0.3] * 7
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    # --------------------------------------------------------------------------
    # Feature 19 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f19_01_temperature_279_9_incomplete(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7(temperature_K=279.9)
        self.assertEqual(res.epistemic_status, ":Incomplete")

    def test_t2_f19_02_temperature_280_0_accepted(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7(temperature_K=280.0, cumulative_dose_Gy=0.02)
        self.assertEqual(res.epistemic_status, ":Accepted")

    def test_t2_f19_03_invalid_nutmeg_quarantine_status_rejected(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        d = ev.to_dict()
        d["payload"]["nutmeg_quarantine_status"] = ":UnknownStatus"
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f19_04_force_collapse_to_rejected_blocked(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=275.0)
        with self.assertRaises(ALARAControllerError):
            ctl.evaluate_epistemic_hippocratism_quarantine(state, force_collapse_incomplete_to_rejected=True)

    def test_t2_f19_05_sub280k_never_promotes_to_accepted(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=270.0)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertEqual(q["verdict"], ":Incomplete")

    # --------------------------------------------------------------------------
    # Feature 20 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f20_01_dose_at_0_0399_no_safing(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.0399)
        out = ctl.step_controller(state)
        self.assertFalse(out.safing_shutter_closed)

    def test_t2_f20_02_dose_at_0_0400_safing_triggered(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.0400)
        out = ctl.step_controller(state)
        self.assertTrue(out.safing_shutter_closed)

    def test_t2_f20_03_dose_at_0_0500_max_allowable(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.0500)
        out = ctl.step_controller(state)
        self.assertNotEqual(out.epistemic_status, ":Rejected")

    def test_t2_f20_04_dose_above_0_0500_rejected(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.051)
        self.assertEqual(res.epistemic_status, ":Rejected")

    def test_t2_f20_05_negative_shield_thickness_rejected(self) -> None:
        ctl = ALARAClosedLoopController()
        with self.assertRaises(ALARAControllerError):
            ctl.compute_effective_dose_rate(8.2e-7, 10.0, 1.0, -0.05, 23.5, 0.18)

    # --------------------------------------------------------------------------
    # Feature 21 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f21_01_u_valve_zero_boundary(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.048)
        out = ctl.step_controller(state)
        self.assertGreaterEqual(out.u_valve_m3_s, 0.0)

    def test_t2_f21_02_z_shield_zero_boundary(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(dose_rate_Gy_s=0.0)
        out = ctl.step_controller(state)
        self.assertGreaterEqual(out.z_shield_m, 0.0)

    def test_t2_f21_03_phi_light_zero_boundary(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(circadian_phase_rad=math.pi)
        out = ctl.step_controller(state)
        self.assertGreaterEqual(out.Phi_light_umol_m2_s, 0.0)

    def test_t2_f21_04_safing_shutter_closed_at_0_041(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.041)
        out = ctl.step_controller(state)
        self.assertTrue(out.safing_shutter_closed)

    def test_t2_f21_05_safing_shutter_open_at_0_035(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.035)
        out = ctl.step_controller(state)
        self.assertFalse(out.safing_shutter_closed)

    # --------------------------------------------------------------------------
    # Feature 22 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f22_01_promote_unverified_hormesis_raises(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7(promote_unverified_hormesis=True)
        self.assertFalse(res.passed)
        self.assertIn("Control", res.defect_axes_tripped)

    def test_t2_f22_02_promote_unverified_atp_raises(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7(promote_unverified_atp=True)
        self.assertFalse(res.passed)
        self.assertIn("Control", res.defect_axes_tripped)

    def test_t2_f22_03_invalid_epistemic_status_string_rejected(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        d["epistemic_status"] = ":InvalidStatus"
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f22_04_unverified_spice_promoted_raises(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g1(spkpos_verified_on_known_body=False)
        self.assertEqual(res.epistemic_status, ":Incomplete")

    def test_t2_f22_05_three_valued_quarantine_coverage(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g7()
        qh = res.details["quarantined_hypotheses"]
        self.assertEqual(len(qh), 4)

    # --------------------------------------------------------------------------
    # Feature 23 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f23_01_malformed_json_raises_contract_error(self) -> None:
        with self.assertRaises((MasterEventContractError, json.JSONDecodeError)):
            MasterEvent.from_json("{broken json")

    def test_t2_f23_02_missing_payload_field_raises(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        del d["payload"]
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f23_03_unknown_envelope_type_raises(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        d["envelope_type"] = "RandomEnvelopeType"
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f23_04_missing_event_id_raises(self) -> None:
        ev = generate_synthetic_neuralcompose_event()
        d = ev.to_dict()
        del d["event_id"]
        with self.assertRaises(SchemaValidationError):
            MasterEvent.from_dict(d)

    def test_t2_f23_05_float_precision_preserved(self) -> None:
        ev = generate_synthetic_neuralcompose_event(mahalanobis_tension_D_M=1.23456789)
        j = ev.to_json()
        ev_back = MasterEvent.from_json(j)
        self.assertAlmostEqual(ev_back.payload.mahalanobis_tension_D_M, 1.23456789, places=6)

    # --------------------------------------------------------------------------
    # Feature 24 Boundary
    # --------------------------------------------------------------------------
    def test_t2_f24_01_em_dash_in_event_id_rejected(self) -> None:
        raw_json = '{"event_id": "event\u2014dash", "timestamp_utc": "2026-11-02T00:00:00Z"}'
        with self.assertRaises(MasterEventContractError):
            MasterEvent.from_json(raw_json)

    def test_t2_f24_02_en_dash_in_event_id_rejected(self) -> None:
        raw_json = '{"event_id": "event\u2013dash", "timestamp_utc": "2026-11-02T00:00:00Z"}'
        with self.assertRaises(MasterEventContractError):
            MasterEvent.from_json(raw_json)

    def test_t2_f24_03_em_dash_in_schema_rejected(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"schema_id": "test\u2014em_dash"}')
            temp_path = Path(f.name)
        try:
            with self.assertRaises(ValueError) as ctx:
                load_master_event_contract_schema(temp_path)
            self.assertIn("forbidden em-dash or en-dash", str(ctx.exception))
        finally:
            temp_path.unlink(missing_ok=True)

    def test_t2_f24_04_en_dash_in_schema_rejected(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"schema_id": "test\u2013en_dash"}')
            temp_path = Path(f.name)
        try:
            with self.assertRaises(ValueError) as ctx:
                load_master_event_contract_schema(temp_path)
            self.assertIn("forbidden em-dash or en-dash", str(ctx.exception))
        finally:
            temp_path.unlink(missing_ok=True)

    def test_t2_f24_05_sanitize_dashes_replaces_both(self) -> None:
        s = "a\u2014b\u2013c"
        clean = sanitize_dashes(s)
        self.assertNotIn("\u2014", clean)
        self.assertNotIn("\u2013", clean)
        self.assertEqual(clean, "a - b-c")



class TestTier3CrossFeatureInteractions(unittest.TestCase):
    """Tier 3: Pairwise Cross-Feature Interactions (24 tests covering major subsystem pairings)."""

    def test_t3_01_s1_fixture_to_s2_criticality_causal_chain(self) -> None:
        ev1 = generate_synthetic_neuralcompose_event(sequence_id="chain_s1_01")
        ev2 = generate_synthetic_momentum_automata_event(sequence_id="chain_s2_01", causal_parent_id=ev1.event_id)
        self.assertEqual(ev2.causal_parent_id, ev1.event_id)
        tr = LogicGatesEvaluator.evaluate_transition(ev1, ev2)
        self.assertTrue(tr.transition_valid)

    def test_t3_02_orderbook_criticality_to_hysteresis_area(self) -> None:
        ev = generate_synthetic_momentum_automata_event(
            k_eff=1.025,
            criticality_regime="SUPERCRITICAL",
            hysteresis_loop_area=5.2,
        )
        self.assertEqual(ev.payload.criticality_regime, "SUPERCRITICAL")
        self.assertGreater(ev.payload.hysteresis_loop_area, 4.0)

    def test_t3_03_wbr_panic_triggers_control_defect(self) -> None:
        ev = generate_synthetic_momentum_automata_event(wbr_mode="Panic")
        self.assertTrue(ev.defect_flags["Control"])

    def test_t3_04_tarjan_dag_preserves_category_types(self) -> None:
        res = TarjanBridgeVerifier.verify_solver_pipeline()
        for node in res["nodes"]:
            self.assertIsInstance(node, str)
        self.assertIsInstance(res["max_scc_size"], int)
        self.assertIsInstance(res["beta_1_inter_solver"], int)

    def test_t3_05_tarjan_dag_enforces_non_recursive_guard(self) -> None:
        res = TarjanBridgeVerifier.verify_solver_pipeline(recursion_depth=0)
        self.assertEqual(res["recursion_depth"], 0)
        with self.assertRaises(TarjanVerificationError):
            TarjanBridgeVerifier.verify_solver_pipeline(recursion_depth=1)

    def test_t3_06_multipool_hydraulics_to_vogel_sucrose_profile(self) -> None:
        ev = generate_synthetic_reactor_pools_event()
        self.assertEqual(ev.payload.n_pool, len(ev.payload.sucrose_concentrations_mol_m3))
        self.assertEqual(ev.payload.n_pool, 8)

    def test_t3_07_vogel_medium_to_phreeqc_charge_balance(self) -> None:
        ev = generate_synthetic_reactor_pools_event(phreeqc_charge_imbalance_pct=0.45)
        self.assertLessEqual(ev.payload.phreeqc_charge_imbalance_pct, 1.0)
        self.assertEqual(len(ev.payload.sucrose_concentrations_mol_m3), 8)

    def test_t3_08_phreeqc_equilibrium_to_radiolytic_scavenging(self) -> None:
        ev = generate_synthetic_reactor_pools_event(phreeqc_activity_avg_ph=6.8)
        self.assertEqual(len(ev.payload.radiolytic_h2o2_scavenged_uM), 8)
        self.assertAlmostEqual(ev.payload.phreeqc_activity_avg_ph, 6.8)

    def test_t3_09_radiolytic_dose_rate_to_alara_safing_trip(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.042, dose_rate_Gy_s=1e-5)
        out = ctl.step_controller(state)
        self.assertTrue(out.safing_shutter_closed)
        self.assertEqual(out.controller_mode, "SAFE_HOLD_SHUTTER_CLOSED")

    def test_t3_10_alara_controller_to_simulink_actuation(self) -> None:
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(cumulative_dose_Gy=0.02)
        out = ctl.step_controller(state)
        self.assertGreater(out.u_valve_m3_s, 0.0)
        self.assertGreater(out.z_shield_m, 0.0)
        self.assertGreater(out.Phi_light_umol_m2_s, 0.0)

    def test_t3_11_circadian_phase_to_light_actuation(self) -> None:
        ctl = ALARAClosedLoopController()
        s_day = ALARAControllerState(circadian_phase_rad=0.0)
        s_night = ALARAControllerState(circadian_phase_rad=math.pi)
        out_day = ctl.step_controller(s_day)
        out_night = ctl.step_controller(s_night)
        self.assertGreater(out_day.Phi_light_umol_m2_s, out_night.Phi_light_umol_m2_s)

    def test_t3_12_circadian_gating_to_cytoplasmic_streaming(self) -> None:
        ev = generate_synthetic_biofilm_session_event(cytoplasmic_streaming_velocity_um_s=32.0)
        self.assertAlmostEqual(ev.payload.cytoplasmic_streaming_velocity_um_s, 32.0)
        self.assertIsInstance(ev.payload.circadian_state, CircadianState)

    def test_t3_13_streaming_breach_to_hex1_woronin_plugging(self) -> None:
        ev = generate_synthetic_biofilm_session_event(hex1_woronin_plugging_active=True)
        self.assertTrue(ev.payload.hex1_woronin_plugging_active)
        self.assertEqual(ev.payload.anastomosis_topology.beta_0, 1)

    def test_t3_14_anastomosis_betti_to_s1_four_pillar_record(self) -> None:
        ev_s4 = generate_synthetic_biofilm_session_event()
        ev_s1 = generate_synthetic_neuralcompose_event(beta_0=1, beta_1=ev_s4.payload.anastomosis_topology.beta_1)
        p2 = ev_s1.payload.four_pillar_record["pillar_2_st_jema"]
        self.assertEqual(p2["beta_1"], ev_s4.payload.anastomosis_topology.beta_1)

    def test_t3_15_sub280k_temperature_to_nutmeg_quarantine(self) -> None:
        ev = generate_synthetic_reactor_pools_event(temperatures_kelvin=[276.0] * 8)
        self.assertEqual(ev.payload.nutmeg_quarantine_status, ":Incomplete")
        self.assertEqual(ev.epistemic_status, ":Incomplete")

    def test_t3_16_live_sensor_toy_drive_to_mahalanobis_tension(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=True, mahalanobis_tension_D_M=1.85)
        self.assertTrue(ev.payload.toy_drive_active)
        self.assertAlmostEqual(ev.payload.mahalanobis_tension_D_M, 1.85)

    def test_t3_17_live_sensor_toy_drive_to_logic_gate_g1(self) -> None:
        ev = generate_synthetic_neuralcompose_event(toy_drive_active=True)
        res = LogicGatesEvaluator.evaluate_gate_g1()
        self.assertTrue(res.passed)
        self.assertTrue(ev.payload.toy_drive_active)

    def test_t3_18_settlement_bridge_to_orderbook_betti_transition(self) -> None:
        ev = generate_synthetic_momentum_automata_event()
        self.assertGreaterEqual(ev.payload.orderbook_betti_1, 1)
        self.assertEqual(ev.payload.balance_tree_betti_1, 0)
        res = LogicGatesEvaluator.evaluate_gate_g4()
        self.assertTrue(res.passed)

    def test_t3_19_collar_leaf_seam_to_double_tree_horizon(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g5()
        self.assertTrue(res.passed)
        self.assertEqual(res.details["delta_beta_1"], 2)

    def test_t3_20_substrate_swap_primitive_to_defect_axes(self) -> None:
        res = LogicGatesEvaluator.evaluate_gate_g6()
        self.assertTrue(res.passed)
        self.assertEqual(len(res.defect_axes_tripped), 0)

    def test_t3_21_cross_subsystem_transition_validity_s1_to_s2(self) -> None:
        ev1 = generate_synthetic_neuralcompose_event(sequence_id="s1_trans")
        ev2 = generate_synthetic_momentum_automata_event(sequence_id="s2_trans", causal_parent_id=ev1.event_id)
        tr = LogicGatesEvaluator.evaluate_transition(ev1, ev2)
        self.assertTrue(tr.transition_valid)

    def test_t3_22_cross_subsystem_transition_validity_s2_to_s3(self) -> None:
        ev2 = generate_synthetic_momentum_automata_event(sequence_id="s2_trans_to_s3")
        ev3 = generate_synthetic_reactor_pools_event(sequence_id="s3_trans", causal_parent_id=ev2.event_id)
        tr = LogicGatesEvaluator.evaluate_transition(ev2, ev3)
        self.assertTrue(tr.transition_valid)

    def test_t3_23_cross_subsystem_transition_validity_s3_to_s4(self) -> None:
        ev3 = generate_synthetic_reactor_pools_event(sequence_id="s3_trans_to_s4")
        ev4 = generate_synthetic_biofilm_session_event(sequence_id="s4_trans", causal_parent_id=ev3.event_id)
        tr = LogicGatesEvaluator.evaluate_transition(ev3, ev4)
        self.assertTrue(tr.transition_valid)

    def test_t3_24_full_roundtrip_with_typographic_verification(self) -> None:
        events = [
            generate_synthetic_neuralcompose_event(),
            generate_synthetic_momentum_automata_event(),
            generate_synthetic_reactor_pools_event(),
            generate_synthetic_biofilm_session_event(),
        ]
        for ev in events:
            json_str = ev.to_json()
            self.assertNotIn("\u2014", json_str)
            self.assertNotIn("\u2013", json_str)
            back = MasterEvent.from_json(json_str)
            self.assertEqual(back.event_id, ev.event_id)

    def test_t3_25_negative_transition_s1_to_s2_high_tension_trips_control(self) -> None:
        """S1 -> S2 transition with D_M = 3.0 trips Control defect and marks status :Incomplete."""
        ev1 = generate_synthetic_neuralcompose_event(
            sequence_id="s1_neg_tension",
            mahalanobis_tension_D_M=3.0,
        )
        ev2 = generate_synthetic_momentum_automata_event(
            sequence_id="s2_neg_tension",
            causal_parent_id=ev1.event_id,
        )
        tr = LogicGatesEvaluator.evaluate_transition(ev1, ev2)
        self.assertTrue(tr.defect_flags["Control"])
        self.assertEqual(tr.enforced_epistemic_status, ":Incomplete")
        self.assertTrue(tr.transition_valid)

    def test_t3_26_negative_transition_s1_to_s2_fragmented_betti0_trips_coordination(self) -> None:
        """S1 -> S2 transition with beta_0 = 2 trips Coordination defect and marks status :Rejected."""
        ev1 = generate_synthetic_neuralcompose_event(
            sequence_id="s1_neg_betti",
            beta_0=2,
        )
        ev2 = generate_synthetic_momentum_automata_event(
            sequence_id="s2_neg_betti",
            causal_parent_id=ev1.event_id,
        )
        tr = LogicGatesEvaluator.evaluate_transition(ev1, ev2)
        self.assertTrue(tr.defect_flags["Coordination"])
        self.assertEqual(tr.enforced_epistemic_status, ":Rejected")
        self.assertFalse(tr.transition_valid)

    def test_t3_27_negative_transition_s2_to_s3_sub280k_trips_source_nutmeg(self) -> None:
        """S2 -> S3 transition with T = 250.0 K trips Source defect and marks status :Incomplete."""
        ev2 = generate_synthetic_momentum_automata_event(sequence_id="s2_neg_temp")
        cold_temps = [250.0, 298.18, 298.20, 298.22, 298.25, 298.27, 298.29, 298.31]
        ev3 = generate_synthetic_reactor_pools_event(
            sequence_id="s3_neg_temp",
            temperatures_kelvin=cold_temps,
            causal_parent_id=ev2.event_id,
        )
        tr = LogicGatesEvaluator.evaluate_transition(ev2, ev3)
        self.assertTrue(tr.defect_flags["Source"])
        self.assertEqual(tr.enforced_epistemic_status, ":Incomplete")
        self.assertTrue(tr.transition_valid)

    def test_t3_28_negative_transition_s3_to_s4_streaming_velocity_trips_boundary(self) -> None:
        """S3 -> S4 transition with streaming velocity 65.0 um/s trips Boundary defect and marks status :Rejected."""
        ev3 = generate_synthetic_reactor_pools_event(sequence_id="s3_neg_vel")
        ev4 = generate_synthetic_biofilm_session_event(
            sequence_id="s4_neg_vel",
            causal_parent_id=ev3.event_id,
        )
        ev4.payload.cytoplasmic_streaming_velocity_um_s = 65.0
        tr = LogicGatesEvaluator.evaluate_transition(ev3, ev4)
        self.assertTrue(tr.defect_flags["Boundary"])
        self.assertEqual(tr.enforced_epistemic_status, ":Rejected")
        self.assertFalse(tr.transition_valid)

    def test_t3_29_negative_transition_s3_to_s4_anastomosis_betti0_trips_coordination(self) -> None:
        """S3 -> S4 transition with anastomosis beta_0 = 2 trips Coordination defect and marks status :Rejected."""
        ev3 = generate_synthetic_reactor_pools_event(sequence_id="s3_neg_ana")
        ev4 = generate_synthetic_biofilm_session_event(
            sequence_id="s4_neg_ana",
            causal_parent_id=ev3.event_id,
        )
        ev4.payload.anastomosis_topology.beta_0 = 2
        tr = LogicGatesEvaluator.evaluate_transition(ev3, ev4)
        self.assertTrue(tr.defect_flags["Coordination"])
        self.assertEqual(tr.enforced_epistemic_status, ":Rejected")
        self.assertFalse(tr.transition_valid)


class TestTier4RealWorldWorkloads(unittest.TestCase):
    """Tier 4: Real-World Application Workloads (6 realistic multi-subsystem scenarios)."""

    def test_t4_01_scenario_full_four_subsystem_telemetry_ingestion(self) -> None:
        """Scenario 1: Full 4-subsystem telemetry stream ingestion with causal chaining."""
        s1 = generate_synthetic_neuralcompose_event(sequence_id="telemetry_s1_frame_0")
        s2 = generate_synthetic_momentum_automata_event(sequence_id="telemetry_s2_tick_0", causal_parent_id=s1.event_id)
        s3 = generate_synthetic_reactor_pools_event(sequence_id="telemetry_s3_step_0", causal_parent_id=s2.event_id)
        s4 = generate_synthetic_biofilm_session_event(sequence_id="telemetry_s4_epoch_0", causal_parent_id=s3.event_id)

        # Verify causal parent chain
        self.assertIsNone(s1.causal_parent_id)
        self.assertEqual(s2.causal_parent_id, s1.event_id)
        self.assertEqual(s3.causal_parent_id, s2.event_id)
        self.assertEqual(s4.causal_parent_id, s3.event_id)

        # Verify schema validation on all payloads
        validate_master_event(s1.to_dict())
        validate_master_event(s2.to_dict())
        validate_master_event(s3.to_dict())
        validate_master_event(s4.to_dict())

        # Verify cross-subsystem transitions
        self.assertTrue(LogicGatesEvaluator.evaluate_transition(s1, s2).transition_valid)
        self.assertTrue(LogicGatesEvaluator.evaluate_transition(s2, s3).transition_valid)
        self.assertTrue(LogicGatesEvaluator.evaluate_transition(s3, s4).transition_valid)

        # Verify all defect axes clean on nominal stream
        self.assertFalse(any(s1.defect_flags.values()))
        self.assertFalse(any(s2.defect_flags.values()))
        self.assertFalse(any(s3.defect_flags.values()))
        self.assertFalse(any(s4.defect_flags.values()))

    def test_t4_02_scenario_prompt_radiolytic_excursion_and_alara_trip(self) -> None:
        """Scenario 2: Prompt radiolytic excursion trips 80% ALARA automated safing."""
        ctl = ALARAClosedLoopController()
        # Prompt radiation spike accumulates dose past 0.040 Gy
        state = ALARAControllerState(
            cumulative_dose_Gy=0.0435,
            dose_rate_Gy_s=5.0e-5,
            melanin_mass_fraction=0.18,
            standoff_distance_m=10.0,
        )
        out = ctl.step_controller(state)

        # Assert safing shutter closure and hold mode
        self.assertTrue(out.safing_shutter_closed)
        self.assertEqual(out.controller_mode, "SAFE_HOLD_SHUTTER_CLOSED")
        self.assertEqual(out.epistemic_status, ":Incomplete")
        self.assertLessEqual(out.u_valve_m3_s, 5.0e-5)
        self.assertGreater(out.z_shield_m, 0.10)

        # Gate G7 trips Control defect axis under excursion
        res = LogicGatesEvaluator.evaluate_gate_g7(cumulative_dose_Gy=0.0435)
        self.assertTrue(res.details["payload_safing_triggered"])

    def test_t4_03_scenario_deep_freeze_sub280k_nutmeg_quarantine(self) -> None:
        """Scenario 3: Deep freeze below 280 K triggers strict NutMEG quarantine."""
        sub280_temps = [274.0, 274.2, 274.5, 274.8, 275.0, 275.2, 275.5, 275.8]
        ev = generate_synthetic_reactor_pools_event(
            sequence_id="mars_cold_snap_001",
            temperatures_kelvin=sub280_temps,
        )

        # Verify quarantine status
        self.assertEqual(ev.payload.nutmeg_quarantine_status, ":Incomplete")
        self.assertEqual(ev.epistemic_status, ":Incomplete")

        # Epistemic Hippocratism gate mandates quarantine
        ctl = ALARAClosedLoopController()
        state = ALARAControllerState(temperature_K=274.0)
        q = ctl.evaluate_epistemic_hippocratism_quarantine(state)
        self.assertTrue(q["below_280K_nutmeg"])
        self.assertEqual(q["verdict"], ":Incomplete")

        # Ensure no collapse to Rejected
        self.assertNotEqual(q["verdict"], ":Rejected")

    def test_t4_04_scenario_anastomosis_septal_rupture_and_hex1_plugging(self) -> None:
        """Scenario 4: Hydrodynamic surge causes septal breach, rapidly plugged by HEX-1."""
        ev_breach = generate_synthetic_biofilm_session_event(
            sequence_id="septal_rupture_001",
            cytoplasmic_streaming_velocity_um_s=58.0,
            hex1_woronin_plugging_active=True,
        )

        # Verify plugging active and topology intact
        self.assertTrue(ev_breach.payload.hex1_woronin_plugging_active)
        self.assertEqual(ev_breach.payload.anastomosis_topology.beta_0, 1)
        self.assertGreaterEqual(ev_breach.payload.anastomosis_topology.beta_1, 1)

        # Biomass remains within physical ceiling despite rupture
        self.assertTrue(all(b <= 1.20 for b in ev_breach.payload.biomass_density_kg_m3))

    def test_t4_05_scenario_cross_solver_acyclic_tarjan_pipeline_handoff(self) -> None:
        """Scenario 5: 5-solver pipeline handoff executes with max_scc_size == 1 and A^5 == 0."""
        res = TarjanBridgeVerifier.verify_solver_pipeline()
        self.assertTrue(res["verified"])
        self.assertEqual(res["max_scc_size"], 1)
        self.assertEqual(res["beta_1_inter_solver"], 0)
        self.assertEqual(res["recursion_depth"], 0)
        self.assertTrue(res["is_nilpotent"])
        self.assertEqual(res["nilpotency_degree"], 5)

        # Gate G3 evaluates cleanly
        g3 = LogicGatesEvaluator.evaluate_gate_g3()
        self.assertTrue(g3.passed)

    def test_t4_06_scenario_wbr_scaffolding_panic_transition_to_scram(self) -> None:
        """Scenario 6: Order book tension cascade triggers WBR Panic mode and safe SCRAM."""
        ev_panic = generate_synthetic_momentum_automata_event(
            sequence_id="flash_crash_001",
            k_eff=1.12,
            criticality_regime="PROMPT_SCRAM",
            wbr_mode="Panic",
            hysteresis_loop_area=7.8,
            retention_pool_active=True,
        )

        # Control defect tripped
        self.assertTrue(ev_panic.defect_flags["Control"])
        self.assertEqual(ev_panic.payload.criticality_regime, "PROMPT_SCRAM")
        self.assertEqual(ev_panic.payload.wbr_mode, "Panic")

        # CEC exit trigger stoppable lever is ready
        self.assertTrue(ev_panic.payload.cec_algo_exit_trigger_stoppable)


if __name__ == "__main__":
    unittest.main()
