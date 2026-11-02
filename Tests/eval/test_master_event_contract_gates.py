"""Unit and edge-case tests for the Master Event Contract Schema v1 and Logic Gates G1..G7
(configs/master_event_contract_schema_v1.json & Scripts/verify_master_event_contract_gates.py),
including the Unified Headless Substrate-Swap Verification Primitive (Turns L29..L32)."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "configs" / "master_event_contract_schema_v1.json"
VERIFIER_PATH = REPO_ROOT / "Scripts" / "verify_master_event_contract_gates.py"

spec = importlib.util.spec_from_file_location("verify_master_event_contract_gates", str(VERIFIER_PATH))
verifier = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["verify_master_event_contract_gates"] = verifier
spec.loader.exec_module(verifier)


def test_schema_and_verifier_files_exist_with_zero_dashes():
    assert SCHEMA_PATH.exists()
    assert VERIFIER_PATH.exists()
    for p in (SCHEMA_PATH, VERIFIER_PATH):
        txt = p.read_text(encoding="utf-8")
        assert "\u2014" not in txt and "\u2013" not in txt


def test_load_master_event_contract_schema_validates_all_sections():
    schema = verifier.load_master_event_contract_schema(SCHEMA_PATH)
    assert schema["schema_id"] == "neuralcompose-master-event-contract-schema-v1"
    assert set(schema["subsystems"].keys()) == {
        "NeuralCompose",
        "MomentumAutomata",
        "ReactorPools",
        "BiofilmsSessions",
    }
    assert set(schema["multica_defect_axes"].keys()) == {
        "Boundary",
        "Control",
        "Source",
        "Coordination",
    }
    assert set(schema["logic_gates"].keys()) == {"G1", "G2", "G3", "G4", "G5", "G6", "G7"}
    assert schema["neurospora_crassa_matlab_r2026b_blocks"]["n_pool"] == 8


def test_gate_g1_spice_basilisk_si_and_dcm_happy_and_error_paths():
    g1 = verifier.verify_gate_g1_spice_basilisk_si_and_dcm()
    assert g1["gate_passed"] is True
    assert g1["epistemic_verdict"] == "Accepted"
    assert g1["unit_scale_km_to_m"] == 1000.0
    assert g1["dcm_carried_separately"] is True
    assert g1["position_rel_err"] <= 1.0e-9
    assert g1["velocity_rel_err"] <= 1.0e-9

    # Unchecked spkpos must remain in Incomplete quarantine
    g1_unchecked = verifier.verify_gate_g1_spice_basilisk_si_and_dcm(spkpos_verified_on_known_body=False)
    assert g1_unchecked["epistemic_verdict"] == "Incomplete"

    with pytest.raises(ValueError, match="conflated"):
        verifier.verify_gate_g1_spice_basilisk_si_and_dcm(conflate_unit_scale_with_propulsion_or_dcm=True)

    with pytest.raises(ValueError, match="unit_scale_km_to_m"):
        verifier.verify_gate_g1_spice_basilisk_si_and_dcm(unit_scale_km_to_m=1.0)


def test_gate_g2_m7_header_vs_numeric_types_happy_and_error_paths():
    g2 = verifier.verify_gate_g2_m7_header_vs_numeric_types()
    assert g2["gate_passed"] is True
    assert g2["stage_headers"] == ["M7.1", "M7.2", "M7.3", "M7.4", "M7.5", "M7.6", "M7.7", "M7.8"]
    assert g2["ieee754_binary_approximation_residual"] > 0.0

    with pytest.raises(ValueError, match="conflated"):
        verifier.verify_gate_g2_m7_header_vs_numeric_types(conflate_header_as_numeric=True)

    with pytest.raises(ValueError, match="Int64"):
        verifier.verify_gate_g2_m7_header_vs_numeric_types(discrete_int64_payload={"beta_1": 2.5})  # type: ignore[dict-item]

    with pytest.raises(ValueError, match="Float64"):
        verifier.verify_gate_g2_m7_header_vs_numeric_types(continuous_float64_payload={"FSC_A": float("nan")})


def test_gate_g3_acyclic_tarjan_solver_bridge_happy_and_error_paths():
    g3 = verifier.verify_gate_g3_acyclic_tarjan_solver_bridge()
    assert g3["gate_passed"] is True
    assert g3["max_scc_size"] == 1
    assert g3["beta_1_inter_solver"] == 0
    assert g3["recursion_depth"] == 0
    assert g3["consolidation_rule_immutable"] is True
    assert g3["cache_miss_fresh_openfoam_solve_triggered"] is False

    # High ROM residual triggers cache-miss fresh OpenFOAM solve within ceiling
    g3_miss = verifier.verify_gate_g3_acyclic_tarjan_solver_bridge(pod_dmd_residual=0.08, pod_dmd_tolerance=0.05)
    assert g3_miss["cache_miss_fresh_openfoam_solve_triggered"] is True

    # Feedback cycle from MATLAB to OpenFOAM violates DAG acyclicity (max_scc_size > 1)
    with pytest.raises(ValueError, match="not a DAG"):
        verifier.verify_gate_g3_acyclic_tarjan_solver_bridge(
            directed_edges=[
                ("OpenFOAM_FiniteVolume_CFD", "PHREEQC_Geochemical_Speciation"),
                ("PHREEQC_Geochemical_Speciation", "FlowCytometry_SingleCell_Bridge"),
                ("FlowCytometry_SingleCell_Bridge", "SmallModularBioReactors_Multiscale_ODE"),
                ("SmallModularBioReactors_Multiscale_ODE", "MATLAB_R2026b_Simulink_Simscape_3D_EDA"),
                ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD"),
            ]
        )

    with pytest.raises(ValueError, match="recursion_depth"):
        verifier.verify_gate_g3_acyclic_tarjan_solver_bridge(recursion_depth=1)


def test_gate_g4_multiclock_settlement_bridge_happy_and_error_paths():
    g4 = verifier.verify_gate_g4_multiclock_settlement_bridge()
    assert g4["gate_passed"] is True
    assert g4["max_scc_size"] == 1
    assert g4["fast_wireframe"]["positions"] == ["Hyperliquid_perp_150_USDC", "ZEC_USDC_spot"]
    assert g4["slow_core"]["positions"] == ["MEXC_staking_51_USD"]
    assert g4["plasticity_shell"]["stoppable_exit_trigger_lever_verified"] is True

    with pytest.raises(ValueError, match="stoppable exit-trigger"):
        verifier.verify_gate_g4_multiclock_settlement_bridge(cec_algo_exit_trigger_stoppable=False)

    with pytest.raises(ValueError, match="redemption/unwinding latency"):
        verifier.verify_gate_g4_multiclock_settlement_bridge(classify_by_dollar_size_instead_of_latency=True)


def test_gate_g5_horizon_collar_leaf_seam_happy_and_error_paths():
    g5 = verifier.verify_gate_g5_horizon_collar_leaf_seam()
    assert g5["gate_passed"] is True
    assert g5["collar_leaf_count_c"] == 3
    assert g5["delta_beta_1_collar_cycle_rank"] == 2
    assert g5["beta_1_inter_solver"] == 0

    with pytest.raises(ValueError, match="distinct OS processes"):
        verifier.verify_gate_g5_horizon_collar_leaf_seam(assume_shared_in_memory_process_without_collar=True)


def test_gate_g6_unified_substrate_swap_primitive_l29_to_l32():
    g6 = verifier.verify_gate_g6_unified_substrate_swap_primitive()
    assert g6["gate_passed"] is True
    assert g6["L29_mesh_field_substrate_swap"]["delta_beta_0"] == 0
    assert g6["L29_mesh_field_substrate_swap"]["delta_beta_1"] == 0
    assert g6["L30_biconnected_swarm_feed_swap"]["beta_1_swarm_verification_cycles"] == 2
    assert g6["L30_biconnected_swarm_feed_swap"]["cut_vertices"] == []
    assert g6["L31_unified_headless_cli_and_reject_log"]["stage1_mesh_filter_rejects"] == ["cand_torn_mesh_reject"]
    assert g6["L31_unified_headless_cli_and_reject_log"]["stage2_swarm_filter_rejects"] == ["cand_divergent_swarm_reject"]
    assert g6["L31_unified_headless_cli_and_reject_log"]["verified_survivors"] == ["cand_valid_mesh_and_swarm"]
    assert g6["L32_openmc_cross_section_and_dosimetry_swap"]["tally_dose_rel_diff"] < 0.05

    # (a) L29 failure: topological tearing (Delta_beta_1 != 0)
    with pytest.raises(ValueError, match="Turn L29 Violation"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(matlab_interpolated_beta_1=1)

    # (b) L30 failure: single-point-of-failure bridge edge in swarm
    with pytest.raises(ValueError, match="Turn L30 Violation"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(
            swarm_nodes=["a", "b", "c"],
            swarm_undirected_edges=[("a", "b"), ("b", "c")],
        )

    # (b) L30 failure: trigger divergence under counterfactual feed swap
    with pytest.raises(ValueError, match="diverged under counterfactual"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(
            agent_triggers_feed_a={"a": ("sigma <= 1.05",)},
            agent_triggers_feed_b_swapped={"a": ("sigma <= 2.00",)},
        )

    # (c) L31 failure: disabling separate stage-reject logging
    with pytest.raises(ValueError, match="Turn L31 Violation"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(log_stage_rejects_separately=False)

    # (d) L32 failure: OpenMC cross-section library tally variance exceeds tolerance
    with pytest.raises(ValueError, match="Turn L32 Violation"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(
            openmc_dose_rate_endfb80_mSv_hr=0.010,
            openmc_dose_rate_jeff33_mSv_hr=0.025,
        )


def test_gate_g7_health_physics_alara_and_hippocratism_quarantine():
    g7_ok = verifier.verify_gate_g7_health_physics_alara_and_hippocratism(cumulative_dose_Gy=0.0295, max_allowable_dose_Gy=0.050)
    assert g7_ok["gate_passed"] is True
    assert g7_ok["epistemic_hippocratism_verdict"] == "Accepted"
    assert g7_ok["payload_safing_triggered"] is False

    # 80% ALARA safing band -> Incomplete quarantine
    g7_safing = verifier.verify_gate_g7_health_physics_alara_and_hippocratism(cumulative_dose_Gy=0.042, max_allowable_dose_Gy=0.050)
    assert g7_safing["epistemic_hippocratism_verdict"] == "Incomplete"
    assert g7_safing["payload_safing_triggered"] is True

    # Sub-280 K NutMEG -> Incomplete quarantine
    g7_cold = verifier.verify_gate_g7_health_physics_alara_and_hippocratism(temperature_K=273.15)
    assert g7_cold["epistemic_hippocratism_verdict"] == "Incomplete"
    assert g7_cold["below_280K_nutmeg_quarantined"] is True

    # Dose exceeding ceiling -> Rejected
    g7_over = verifier.verify_gate_g7_health_physics_alara_and_hippocratism(cumulative_dose_Gy=0.060, max_allowable_dose_Gy=0.050)
    assert g7_over["epistemic_hippocratism_verdict"] == "Rejected"
    assert g7_over["gate_passed"] is False

    with pytest.raises(ValueError, match="hormesis"):
        verifier.verify_gate_g7_health_physics_alara_and_hippocratism(promote_unverified_radiation_hormesis=True)


def test_full_master_event_contract_evaluation_and_cli(tmp_path: Path):
    out_receipt = tmp_path / "master_event_contract_receipt.json"
    rc = verifier.main(["--out", str(out_receipt)])
    assert rc == 0
    assert out_receipt.exists()
    data = json.loads(out_receipt.read_text(encoding="utf-8"))
    assert data["all_gates_passed"] is True
    assert data["max_scc_size"] == 1
    assert data["beta_1_inter_solver"] == 0
    assert data["recursion_depth"] == 0
    assert data["neurospora_crassa_4block_8pool_summary"]["n_pool"] == 8
    assert data["neuralcompose_session_and_four_pillar_summary"]["verified"] is True
    assert data["four_subsystem_envelopes_summary"]["verified"] is True
    assert data["four_subsystem_envelopes_summary"]["envelope_count"] == 4
    assert all(data["multica_defect_axes_verified"].values())


def test_g3_and_g6_reject_disconnected_graphs_and_bowtie_articulation_vertices():
    # G3: Disconnected graph with an undirected triangle (A->B, B->C, A->C) + isolated edge (D->E)
    # 5 nodes, 4 edges -> |E| - |V| + 1 = 0, but beta_0 = 2 so true beta_1 = 4 - 5 + 2 = 1!
    with pytest.raises(ValueError, match="beta_1_inter_solver == 0 and beta_0 == 1"):
        verifier.verify_gate_g3_acyclic_tarjan_solver_bridge(
            nodes=["A", "B", "C", "D", "E"],
            directed_edges=[("A", "B"), ("B", "C"), ("A", "C"), ("D", "E")],
        )

    # G6: Disconnected 5-agent graph (K_4 on a,b,c,d + isolated agent e)
    # 5 nodes, 6 edges, 0 cut-vertices within components, 0 bridges, but beta_0 = 2
    with pytest.raises(ValueError, match="beta_0 == 1"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(
            swarm_nodes=["a", "b", "c", "d", "e"],
            swarm_undirected_edges=[
                ("a", "b"),
                ("b", "c"),
                ("c", "d"),
                ("d", "a"),
                ("a", "c"),
                ("b", "d"),
            ],
        )

    # G6: Bowtie graph (2 triangles sharing central articulation vertex c)
    # 5 nodes, 6 edges, beta_0 = 1, beta_1 = 2, 0 bridge edges, 1 cut-vertex ("c")
    with pytest.raises(ValueError, match="cut_vertices"):
        verifier.verify_gate_g6_unified_substrate_swap_primitive(
            swarm_nodes=["a", "b", "c", "d", "e"],
            swarm_undirected_edges=[
                ("a", "b"),
                ("b", "c"),
                ("c", "a"),
                ("c", "d"),
                ("d", "e"),
                ("e", "c"),
            ],
        )


def test_g5_inspects_mat_v7_and_v73_header_bytes():
    with pytest.raises(ValueError, match="MAT v7.3 HDF5"):
        verifier.verify_gate_g5_horizon_collar_leaf_seam(
            mat_v73_bytes=b"CORRUPTED_NOT_HDF5_BYTES"
        )
    with pytest.raises(ValueError, match="MAT v7"):
        verifier.verify_gate_g5_horizon_collar_leaf_seam(
            mat_v7_bytes=b"CORRUPTED_NOT_MAT_V7_BYTES"
        )


def test_neuralcompose_session_event_and_four_subsystem_envelopes():
    nc_summary = verifier.verify_neuralcompose_session_event_and_four_pillar_contracts()
    assert nc_summary["verified"] is True
    assert nc_summary["forbidden_stage_claim_rejected"] is True

    env_summary = verifier.verify_four_subsystem_synthetic_event_envelopes()
    assert env_summary["verified"] is True
    assert set(env_summary["subsystems_validated"]) == {
        "NeuralCompose",
        "MomentumAutomata",
        "ReactorPools",
        "BiofilmsSessions",
    }

