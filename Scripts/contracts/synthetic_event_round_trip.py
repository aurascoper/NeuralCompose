"""Synthetic Event Round-Trip Generator and Cross-Subsystem Evaluator.

Generates realistic synthetic events for:
- S1: NeuralCompose Functorial Fixtures (60 benchmark frames, NetGraph->PhaseHull, Betti numbers)
- S2: Momentum Automata Criticality Engine (k_eff, rho_pcm, z_crit, chi, WBR modes, hysteresis)
- S3: Multi-Pool Reactor Hydraulics (N_pool=8, Vogel's sucrose gradient, PHREEQC pH, NutMEG)
- S4: Syncytial Hyphal Biofilm Sessions (Neurospora crassa circadian ODE, HEX-1 Woronin, streaming)

Performs programmatic round-trip serialization, schema validation, logic gate execution,
causal transition chaining, and ALARA closed-loop regulation.

Strictly zero em-dashes and zero en-dashes across all code, receipts, and documentation.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sys
from typing import Any, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from Scripts.contracts.alara_closed_loop_controller import (
    ALARAClosedLoopController,
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
    sanitize_dashes,
    validate_biofilm_session_envelope,
    validate_master_event,
    validate_momentum_automata_envelope,
    validate_multipool_reactor_envelope,
    validate_neuralcompose_fixture_envelope,
)
from Scripts.contracts.tarjan_bridge_verifier import TarjanBridgeVerifier


# ==============================================================================
# Synthetic Event Generators
# ==============================================================================


def generate_synthetic_neuralcompose_event(
    sequence_id: str = "seq_nc_001",
    frame_index: int = 12,
    functor_stage: str = "F_Laya",
    beta_0: int = 1,
    beta_1: int = 4,
    toy_drive_active: bool = True,
    mahalanobis_tension_D_M: float = 1.15,
    causal_parent_id: Optional[str] = None,
) -> MasterEvent:
    """Generate realistic S1 NeuralCompose Functorial Fixture event."""
    defect_axes = DefectAxes(
        boundary=False,
        control=(mahalanobis_tension_D_M > 2.45),
        source=False,
        coordination=(beta_0 > 1),
    )
    four_pillar_record = {
        "pillar_1_laya": {"le_jepa_query_loss": 0.042, "zca_sigreg_whitened": True},
        "pillar_2_st_jema": {"beta_0": beta_0, "beta_1": beta_1, "tarjan_edge_class": "tree"},
        "pillar_3_memory_dialectic": {
            "tau_fast_s": 1.2,
            "tau_slow_s": 8.0,
            "mahalanobis_tension_D_M": mahalanobis_tension_D_M,
        },
        "pillar_4_musical_laya": {"tempo_bpm": 72.0, "absorption_index": round(1.0 / (1.0 + mahalanobis_tension_D_M), 4)},
    }
    payload = NeuralComposeFixtureEnvelope(
        sequence_id=sequence_id,
        functor_stage=functor_stage,
        frame_index=frame_index,
        betti_numbers=BettiNumbers(beta_0=beta_0, beta_1=beta_1),
        defect_axes=defect_axes,
        toy_drive_active=toy_drive_active,
        mahalanobis_tension_D_M=mahalanobis_tension_D_M,
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        causal_parent_id=causal_parent_id,
        four_pillar_record=four_pillar_record,
    )
    return MasterEvent(
        event_id=f"evt_nc_{sequence_id}_{frame_index}",
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        subsystem_id="S1_NeuralCompose_Functorial_Fixtures",
        envelope_type="NeuralComposeFixtureEnvelope",
        payload=payload,
        causal_parent_id=causal_parent_id,
        recursion_depth=0,
        defect_flags={
            "Boundary": False,
            "Control": (mahalanobis_tension_D_M > 2.45),
            "Source": False,
            "Coordination": (beta_0 > 1),
        },
        epistemic_status=":Accepted" if mahalanobis_tension_D_M <= 2.45 and beta_0 == 1 else ":Incomplete",
    )


def generate_synthetic_momentum_automata_event(
    sequence_id: str = "seq_ma_001",
    k_eff: float = 0.950777,
    rho_pcm: float = -5177.0,
    z_crit: float = -1.404469,
    chi: float = 20.3158,
    criticality_regime: str = "CRITICAL_WITHIN_NOISE",
    wbr_mode: str = "Focus",
    hysteresis_loop_area: float = 9.26,
    retention_pool_active: bool = True,
    causal_parent_id: Optional[str] = None,
) -> MasterEvent:
    """Generate realistic S2 Momentum Automata Criticality Engine event."""
    metrics = CriticalityMetrics(
        k_eff=k_eff,
        rho_pcm=rho_pcm,
        z_crit=z_crit,
        chi=chi,
    )
    payload = MomentumAutomataEnvelope(
        sequence_id=sequence_id,
        criticality_metrics=metrics,
        criticality_regime=criticality_regime,
        wbr_mode=wbr_mode,
        hysteresis_loop_area=hysteresis_loop_area,
        retention_pool_active=retention_pool_active,
        orderbook_betti_1=2,
        balance_tree_betti_1=0,
        cec_algo_exit_trigger_stoppable=True,
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        causal_parent_id=causal_parent_id,
    )
    is_panic = wbr_mode == "Panic"
    return MasterEvent(
        event_id=f"evt_ma_{sequence_id}",
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        subsystem_id="S2_Momentum_Automata_Criticality_Engine",
        envelope_type="MomentumAutomataEnvelope",
        payload=payload,
        causal_parent_id=causal_parent_id,
        recursion_depth=0,
        defect_flags={
            "Boundary": False,
            "Control": is_panic,
            "Source": False,
            "Coordination": False,
        },
        epistemic_status=":Incomplete" if is_panic else ":Accepted",
    )


def generate_synthetic_reactor_pools_event(
    sequence_id: str = "seq_rp_001",
    container_header: str = "M7.3",
    temperatures_kelvin: Optional[list[float]] = None,
    phreeqc_activity_avg_ph: float = 7.18,
    phreeqc_charge_imbalance_pct: float = 0.42,
    causal_parent_id: Optional[str] = None,
) -> MasterEvent:
    """Generate realistic S3 Multi-Pool Reactor Hydraulics event (N_pool=8)."""
    if temperatures_kelvin is None:
        temperatures_kelvin = [298.15, 298.18, 298.20, 298.22, 298.25, 298.27, 298.29, 298.31]

    chamber_ids = [f"vogels_pool_{i}" for i in range(1, 9)]
    sucrose_concentrations = [55.0, 51.2, 47.6, 44.1, 40.8, 37.6, 34.5, 31.6]
    radiolytic_h2o2 = [18.5, 17.8, 17.1, 16.4, 15.7, 15.0, 14.3, 13.6]

    is_cold = any(t < 280.0 for t in temperatures_kelvin)
    nutmeg_status = ":Incomplete" if is_cold else ":Accepted"

    payload = MultiPoolReactorEnvelope(
        sequence_id=sequence_id,
        container_header=container_header,
        n_pool=8,
        chamber_ids=chamber_ids,
        sucrose_concentrations_mol_m3=sucrose_concentrations,
        temperatures_kelvin=temperatures_kelvin,
        phreeqc_activity_avg_ph=phreeqc_activity_avg_ph,
        phreeqc_charge_imbalance_pct=phreeqc_charge_imbalance_pct,
        radiolytic_h2o2_scavenged_uM=radiolytic_h2o2,
        nutmeg_quarantine_status=nutmeg_status,
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        causal_parent_id=causal_parent_id,
    )
    return MasterEvent(
        event_id=f"evt_rp_{sequence_id}",
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        subsystem_id="S3_Reactor_Pools_SMBR_OpenMC_MATLAB",
        envelope_type="MultiPoolReactorEnvelope",
        payload=payload,
        causal_parent_id=causal_parent_id,
        recursion_depth=0,
        defect_flags={
            "Boundary": False,
            "Control": False,
            "Source": is_cold,
            "Coordination": False,
        },
        epistemic_status=nutmeg_status,
    )


def generate_synthetic_biofilm_session_event(
    sequence_id: str = "seq_bf_001",
    container_header: str = "M7.1",
    cytoplasmic_streaming_velocity_um_s: float = 24.5,
    hex1_woronin_plugging_active: bool = False,
    anastomosis_beta_1: int = 3,
    causal_parent_id: Optional[str] = None,
) -> MasterEvent:
    """Generate realistic S4 Syncytial Hyphal Biofilm Sessions event."""
    circadian = CircadianState(
        M_frq=1.25,
        F_c=0.85,
        F_n=0.62,
        phi_radians=0.45,
    )
    biomass_density = [0.84, 0.80, 0.76, 0.72, 0.68, 0.64, 0.60, 0.56]
    tip_density = [1.45e9, 1.38e9, 1.31e9, 1.24e9, 1.18e9, 1.12e9, 1.06e9, 1.01e9]
    eps_streamers = [0.22, 0.21, 0.20, 0.19, 0.18, 0.17, 0.16, 0.15]
    wall_shear = [0.045, 0.043, 0.041, 0.039, 0.038, 0.036, 0.035, 0.033]

    topology = AnastomosisTopology(beta_0=1, beta_1=anastomosis_beta_1)
    payload = BiofilmSessionEnvelope(
        sequence_id=sequence_id,
        container_header=container_header,
        circadian_state=circadian,
        cytoplasmic_streaming_velocity_um_s=cytoplasmic_streaming_velocity_um_s,
        hex1_woronin_plugging_active=hex1_woronin_plugging_active,
        anastomosis_topology=topology,
        biomass_density_kg_m3=biomass_density,
        tip_density_m3=tip_density,
        eps_streamer_fraction=eps_streamers,
        wall_shear_stress_Pa=wall_shear,
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        causal_parent_id=causal_parent_id,
    )
    return MasterEvent(
        event_id=f"evt_bf_{sequence_id}",
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        subsystem_id="S4_Biofilms_Sessions_Neurospora_M7_Workbench",
        envelope_type="BiofilmSessionEnvelope",
        payload=payload,
        causal_parent_id=causal_parent_id,
        recursion_depth=0,
        defect_flags={
            "Boundary": False,
            "Control": False,
            "Source": False,
            "Coordination": False,
        },
        epistemic_status=":Accepted",
    )


# ==============================================================================
# Round-Trip Test Runner
# ==============================================================================


class SyntheticEventRoundTripRunner:
    """Executes programmatic round-trip test battery and verifies all invariants."""

    def __init__(self) -> None:
        self.results: dict[str, Any] = {}

    def test_round_trip_serialization_all_subsystems(self) -> dict[str, bool]:
        """Test round-trip JSON serialization and deserialization across S1..S4."""
        e1 = generate_synthetic_neuralcompose_event()
        e2 = generate_synthetic_momentum_automata_event(causal_parent_id=e1.event_id)
        e3 = generate_synthetic_reactor_pools_event(causal_parent_id=e2.event_id)
        e4 = generate_synthetic_biofilm_session_event(causal_parent_id=e3.event_id)

        passed: dict[str, bool] = {}
        for idx, event in enumerate([e1, e2, e3, e4], start=1):
            json_str = event.to_json()
            assert "\u2014" not in json_str and "\u2013" not in json_str

            reconstructed = MasterEvent.from_json(json_str)
            assert reconstructed.event_id == event.event_id
            assert reconstructed.subsystem_id == event.subsystem_id
            assert reconstructed.envelope_type == event.envelope_type
            assert reconstructed.recursion_depth == 0
            passed[f"S{idx}_round_trip"] = True

        return passed

    def test_causal_chain_transitions(self) -> list[TransitionEvaluationResult]:
        """Test directional transitions connecting S1 -> S2 -> S3 -> S4."""
        e1 = generate_synthetic_neuralcompose_event(sequence_id="chain_s1")
        e2 = generate_synthetic_momentum_automata_event(
            sequence_id="chain_s2", causal_parent_id=e1.event_id
        )
        e3 = generate_synthetic_reactor_pools_event(
            sequence_id="chain_s3", causal_parent_id=e2.event_id
        )
        e4 = generate_synthetic_biofilm_session_event(
            sequence_id="chain_s4", causal_parent_id=e3.event_id
        )

        t12 = LogicGatesEvaluator.evaluate_transition(e1, e2)
        t23 = LogicGatesEvaluator.evaluate_transition(e2, e3)
        t34 = LogicGatesEvaluator.evaluate_transition(e3, e4)

        assert t12.transition_valid is True
        assert t23.transition_valid is True
        assert t34.transition_valid is True
        return [t12, t23, t34]

    def test_category_type_separation_violations(self) -> dict[str, bool]:
        """Verify that category-level violations raise CategoryTypeViolation."""
        checks: dict[str, bool] = {}

        # 1. Conflation of stage header with float literal
        try:
            generate_synthetic_reactor_pools_event(container_header=7.3)  # type: ignore[arg-type]
            checks["header_float_conflation_caught"] = False
        except CategoryTypeViolation:
            checks["header_float_conflation_caught"] = True

        # 2. Conflation of stage header with int literal
        try:
            generate_synthetic_biofilm_session_event(container_header=7)  # type: ignore[arg-type]
            checks["header_int_conflation_caught"] = False
        except CategoryTypeViolation:
            checks["header_int_conflation_caught"] = True

        # 3. Discrete Betti number stored as float
        try:
            BettiNumbers(beta_0=1.5, beta_1=3)  # type: ignore[arg-type]
            checks["betti_float_conflation_caught"] = False
        except CategoryTypeViolation:
            checks["betti_float_conflation_caught"] = True

        # 4. Continuous observable stored as boolean
        try:
            CriticalityMetrics(k_eff=True, rho_pcm=-5000.0, z_crit=-1.4, chi=20.0)  # type: ignore[arg-type]
            checks["continuous_bool_conflation_caught"] = False
        except CategoryTypeViolation:
            checks["continuous_bool_conflation_caught"] = True

        return checks

    def test_alara_80pct_safing_and_hippocratism_quarantine(self) -> dict[str, Any]:
        """Verify 80% safing (0.040 Gy) and Epistemic Hippocratism 3-valued quarantine."""
        ctrl = ALARAClosedLoopController(max_allowable_dose_Gy=0.050)
        checks: dict[str, Any] = {}

        # 1. Nominal dose (0.025 Gy) -> :Accepted, shutter open
        s_nom = ALARAControllerState(cumulative_dose_Gy=0.025)
        out_nom = ctrl.step_controller(s_nom)
        assert out_nom.epistemic_status == ":Accepted"
        assert out_nom.safing_shutter_closed is False
        checks["nominal_accepted"] = True

        # 2. Safing trip dose (0.041 Gy >= 0.040 Gy safing limit) -> :Incomplete, shutter closed
        s_safe = ALARAControllerState(cumulative_dose_Gy=0.041)
        out_safe = ctrl.step_controller(s_safe)
        assert out_safe.epistemic_status == ":Incomplete"
        assert out_safe.safing_shutter_closed is True
        assert out_safe.controller_mode == "SAFE_HOLD_SHUTTER_CLOSED"
        checks["safing_trip_incomplete"] = True

        # 3. Exceeded dose (0.055 Gy > 0.050 Gy max) -> :Rejected, SCRAM
        s_scram = ALARAControllerState(cumulative_dose_Gy=0.055)
        out_scram = ctrl.step_controller(s_scram)
        assert out_scram.epistemic_status == ":Rejected"
        assert out_scram.controller_mode == "EMERGENCY_SCRAM_ISOLATE"
        checks["scram_rejected"] = True

        # 4. Sub-280 K NutMEG gate -> :Incomplete, never collapsed to :Rejected
        s_cold = ALARAControllerState(temperature_K=273.15)
        out_cold = ctrl.step_controller(s_cold)
        assert out_cold.epistemic_status == ":Incomplete"
        assert out_cold.controller_mode == "THERMAL_HIBERNATION_HOLD"
        checks["cold_nutmeg_incomplete"] = True

        # 5. Hormesis promotion rejected by Epistemic Hippocratism
        try:
            ctrl.evaluate_epistemic_hippocratism_quarantine(
                s_nom, promote_unverified_hormesis=True
            )
            checks["hormesis_promotion_forbidden"] = False
        except Exception:
            checks["hormesis_promotion_forbidden"] = True

        return checks

    def test_tarjan_pipeline_acyclicity_and_nilpotency(self) -> dict[str, Any]:
        """Verify Tarjan cross-solver pipeline DAG and A^5 == 0 nilpotency."""
        res = TarjanBridgeVerifier.verify_solver_pipeline()
        assert res["verified"] is True
        assert res["max_scc_size"] == 1
        assert res["beta_1_inter_solver"] == 0
        assert res["recursion_depth"] == 0
        assert res["is_nilpotent"] is True
        assert res["nilpotency_degree"] == 5

        # Also verify that a feedback loop causes verification failure
        cyclic_edges = list(TarjanBridgeVerifier.DEFAULT_SOLVER_EDGES) + [
            ("MATLAB_R2026b_Simulink_Simscape_3D_EDA", "OpenFOAM_FiniteVolume_CFD")
        ]
        feedback_caught = False
        try:
            TarjanBridgeVerifier.verify_solver_pipeline(
                directed_edges=cyclic_edges
            )
        except Exception:
            feedback_caught = True

        return {
            "pipeline_dag_verified": True,
            "nilpotency_degree": res["nilpotency_degree"],
            "feedback_cycle_caught": feedback_caught,
        }

    def run_all_round_trip_tests(self) -> dict[str, Any]:
        """Execute full round-trip verification suite and produce JSON receipt."""
        subsystem_rt = self.test_round_trip_serialization_all_subsystems()
        transitions = self.test_causal_chain_transitions()
        type_checks = self.test_category_type_separation_violations()
        alara_checks = self.test_alara_80pct_safing_and_hippocratism_quarantine()
        tarjan_checks = self.test_tarjan_pipeline_acyclicity_and_nilpotency()
        all_gates = LogicGatesEvaluator.evaluate_all_gates()

        all_passed = (
            all(subsystem_rt.values())
            and all(t.transition_valid for t in transitions)
            and all(type_checks.values())
            and all(alara_checks.values())
            and tarjan_checks["pipeline_dag_verified"]
            and tarjan_checks["feedback_cycle_caught"]
            and all(g.passed for g in all_gates.values())
        )

        receipt = {
            "receipt_id": "synthetic_event_round_trip_receipt_v1",
            "verified_at_utc": datetime.now(timezone.utc).isoformat(),
            "all_tests_passed": all_passed,
            "subsystem_round_trip": subsystem_rt,
            "causal_transitions_count": len(transitions),
            "category_type_separation_checks": type_checks,
            "alara_closed_loop_checks": alara_checks,
            "tarjan_pipeline_checks": tarjan_checks,
            "logic_gates_evaluated": {k: g.passed for k, g in all_gates.items()},
        }
        return receipt


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run synthetic event round-trip generator and evaluator across all four subsystems."
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Path to save output JSON receipt",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output JSON receipt to stdout",
    )
    args = parser.parse_args(argv)

    runner = SyntheticEventRoundTripRunner()
    receipt = runner.run_all_round_trip_tests()
    receipt_str = sanitize_dashes(json.dumps(receipt, indent=2)) + "\n"

    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(receipt_str, encoding="utf-8")

    if args.json:
        print(receipt_str)
    else:
        print(
            f"SYNTHETIC_ROUND_TRIP_VERIFIED: all_tests_passed={receipt['all_tests_passed']} "
            f"subsystems=4 gates=G1..G7 safing_80pct=0.040Gy/0.050Gy "
            f"nilpotency_degree={receipt['tarjan_pipeline_checks']['nilpotency_degree']}"
        )

    return 0 if receipt["all_tests_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
