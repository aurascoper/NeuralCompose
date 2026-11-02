"""Directional Logic Gates Evaluator (G1..G7) and Causal Chain Validator.

Connects:
- S1: NeuralCompose Functorial Fixtures
- S2: Momentum Automata Criticality Engine
- S3: Multi-Pool Reactor Hydraulics (N_pool=8)
- S4: Syncytial Hyphal Biofilm Sessions (Neurospora crassa)

Across the 4 multica_channel.jsonl defect axes:
- Boundary: unit conversions, stage headers, container formats, mesh interpolation
- Control: closed-loop LQR/MPC actuators, 80% ALARA safing, stoppable algo triggers
- Source: physical ground truth, SPICE verification, NutMEG 280 K quarantine
- Coordination: acyclic Tarjan bridge (max_scc_size=1, beta_1=0), non-recursive guard

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from pathlib import Path
import sys
from typing import Any, Optional, Union

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from Scripts.contracts.alara_closed_loop_controller import (
    ALARAClosedLoopController,
    ALARAControllerState,
)
from Scripts.contracts.master_event_contract import (
    BiofilmSessionEnvelope,
    MasterEvent,
    MomentumAutomataEnvelope,
    MultiPoolReactorEnvelope,
    NeuralComposeFixtureEnvelope,
    VALID_M7_STAGE_HEADERS,
)
from Scripts.contracts.tarjan_bridge_verifier import (
    TarjanBridgeVerifier,
    find_cut_vertices_and_bridges,
    tarjan_scc,
)


class LogicGateError(ValueError):
    """Raised on logic gate evaluation or causal transition violation."""


@dataclass
class GateEvaluationResult:
    """Result of evaluating a single logic gate."""

    gate_id: str
    passed: bool
    epistemic_status: str
    defect_axes_tripped: list[str] = field(default_factory=list)
    details: dict[str, Any] = field(default_factory=dict)
    error_message: Optional[str] = None


@dataclass
class TransitionEvaluationResult:
    """Result of evaluating a causal transition between two subsystem events."""

    source_subsystem: str
    target_subsystem: str
    transition_valid: bool
    defect_flags: dict[str, bool] = field(
        default_factory=lambda: {
            "Boundary": False,
            "Control": False,
            "Source": False,
            "Coordination": False,
        }
    )
    enforced_epistemic_status: str = ":Accepted"
    reasons: list[str] = field(default_factory=list)


class LogicGatesEvaluator:
    """Evaluates gates G1..G7 and cross-subsystem causal transitions."""

    # ==========================================================================
    # Gate G1: SPICE to Basilisk SI Boundary and Separate IAU DCM Diff
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g1(
        raw_position_km: tuple[float, float, float] = (206655000.0, 0.0, 0.0),
        raw_velocity_km_s: tuple[float, float, float] = (0.0, 26.5, 0.0),
        basilisk_ref_position_m: tuple[float, float, float] = (206655000000.0, 0.0, 0.0),
        basilisk_ref_velocity_m_s: tuple[float, float, float] = (0.0, 26500.0, 0.0),
        unit_scale_km_to_m: float = 1000.0,
        iau_angle_pck_v1_rad: float = 0.0850000,
        iau_angle_pck_v2_rad: float = 0.0850002,
        spkpos_verified_on_known_body: bool = True,
        conflate_unit_scale_with_propulsion_or_dcm: bool = False,
    ) -> GateEvaluationResult:
        """Gate G1: Isolate 1000.0 SI scale, verify against Basilisk, carry DCM separately."""
        tripped: list[str] = []
        if conflate_unit_scale_with_propulsion_or_dcm or unit_scale_km_to_m != 1000.0:
            tripped.append("Boundary")
            return GateEvaluationResult(
                gate_id="G1",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="1000.0 SI unit scale must be exact and not conflated with DCM",
            )

        conv_pos_m = tuple(x * unit_scale_km_to_m for x in raw_position_km)
        conv_vel_m_s = tuple(v * unit_scale_km_to_m for v in raw_velocity_km_s)

        pos_norm_ref = max(1e-15, math.sqrt(sum(x * x for x in basilisk_ref_position_m)))
        vel_norm_ref = max(1e-15, math.sqrt(sum(v * v for v in basilisk_ref_velocity_m_s)))
        pos_rel_err = (
            math.sqrt(sum((a - b) ** 2 for a, b in zip(conv_pos_m, basilisk_ref_position_m)))
            / pos_norm_ref
        )
        vel_rel_err = (
            math.sqrt(sum((a - b) ** 2 for a, b in zip(conv_vel_m_s, basilisk_ref_velocity_m_s)))
            / vel_norm_ref
        )

        c1, s1 = math.cos(iau_angle_pck_v1_rad), math.sin(iau_angle_pck_v1_rad)
        c2, s2 = math.cos(iau_angle_pck_v2_rad), math.sin(iau_angle_pck_v2_rad)
        dcm_v1 = ((c1, s1, 0.0), (-s1, c1, 0.0), (0.0, 0.0, 1.0))
        dcm_v2 = ((c2, s2, 0.0), (-s2, c2, 0.0), (0.0, 0.0, 1.0))

        orth_sq = 0.0
        for i in range(3):
            for j in range(3):
                dot_ij = sum(dcm_v1[k][i] * dcm_v1[k][j] for k in range(3))
                target = 1.0 if i == j else 0.0
                orth_sq += (dot_ij - target) ** 2
        dcm_orthogonality_err = math.sqrt(orth_sq)
        dcm_diff = math.sqrt(
            sum((dcm_v1[i][j] - dcm_v2[i][j]) ** 2 for i in range(3) for j in range(3))
        )

        if not spkpos_verified_on_known_body:
            tripped.append("Source")
            epistemic = ":Incomplete"
        else:
            epistemic = ":Accepted"

        passed = (
            pos_rel_err <= 1.0e-9
            and vel_rel_err <= 1.0e-9
            and dcm_orthogonality_err <= 1.0e-12
            and dcm_diff < 1.0e-3
        )
        if not passed:
            tripped.append("Boundary")

        return GateEvaluationResult(
            gate_id="G1",
            passed=passed,
            epistemic_status=epistemic,
            defect_axes_tripped=sorted(list(set(tripped))),
            details={
                "pos_rel_err": pos_rel_err,
                "vel_rel_err": vel_rel_err,
                "dcm_orthogonality_err": dcm_orthogonality_err,
                "dcm_diff": dcm_diff,
            },
        )

    # ==========================================================================
    # Gate G2: M7 Container Headers vs Int64 & Float64 Type Separation
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g2(
        stage_headers: tuple[str, ...] = VALID_M7_STAGE_HEADERS,
        discrete_int64_payload: Optional[dict[str, Any]] = None,
        continuous_float64_payload: Optional[dict[str, Any]] = None,
        conflate_header_as_numeric: bool = False,
    ) -> GateEvaluationResult:
        """Gate G2: Enforce category type separation."""
        tripped: list[str] = []
        if conflate_header_as_numeric:
            tripped.append("Boundary")
            return GateEvaluationResult(
                gate_id="G2",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Stage headers must never be conflated with numeric literals",
            )

        if tuple(stage_headers) != VALID_M7_STAGE_HEADERS:
            tripped.append("Boundary")
            return GateEvaluationResult(
                gate_id="G2",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message=f"stage_headers must match {VALID_M7_STAGE_HEADERS}",
            )

        if discrete_int64_payload is None:
            discrete_int64_payload = {
                "n_pool": 8,
                "chamber_index": 1,
                "codon_count": 240,
                "beta_0": 1,
                "beta_1": 3,
                "beta_2": 0,
            }
        if continuous_float64_payload is None:
            continuous_float64_payload = {
                "FSC_A": 142500.0,
                "SSC_A": 102960.0,
                "FL1_A": 18420.5,
                "melanin_pg_cell": 14.8,
                "position_m": 0.0005,
                "velocity_m_s": 0.000125,
                "pressure_Pa": 101325.0,
                "temperature_K": 298.15,
                "concentration_mol_m3": 55.0,
                "dose_rate_Gy_s": 8.2e-7,
            }

        for k, v in discrete_int64_payload.items():
            if isinstance(v, bool) or not isinstance(v, int):
                tripped.append("Boundary")
                return GateEvaluationResult(
                    gate_id="G2",
                    passed=False,
                    epistemic_status=":Rejected",
                    defect_axes_tripped=tripped,
                    error_message=f"Discrete field '{k}' must be Int64, got {type(v).__name__}",
                )

        for k, v in continuous_float64_payload.items():
            if isinstance(v, bool) or not isinstance(v, (float, int)) or not math.isfinite(float(v)):
                tripped.append("Boundary")
                return GateEvaluationResult(
                    gate_id="G2",
                    passed=False,
                    epistemic_status=":Rejected",
                    defect_axes_tripped=tripped,
                    error_message=f"Continuous field '{k}' must be finite Float64, got {v!r}",
                )

        return GateEvaluationResult(
            gate_id="G2",
            passed=True,
            epistemic_status=":Accepted",
            details={
                "stage_headers_verified": list(stage_headers),
                "int64_keys": sorted(discrete_int64_payload.keys()),
                "float64_keys": sorted(continuous_float64_payload.keys()),
            },
        )

    # ==========================================================================
    # Gate G3: Acyclic Tarjan Solver Bridge & POD/DMD Cache-Miss Gate
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g3(
        nodes: Optional[list[str]] = None,
        directed_edges: Optional[list[tuple[str, str]]] = None,
        recursion_depth: int = 0,
        consolidation_rule_immutable: bool = True,
        pod_dmd_residual: float = 0.012,
        pod_dmd_tolerance: float = 0.050,
        live_openfoam_calls_in_session: int = 1,
        session_openfoam_call_ceiling: int = 4,
    ) -> GateEvaluationResult:
        """Gate G3: Acyclic Tarjan Solver DAG (max_scc_size=1, beta_1=0, recursion_depth=0)."""
        tripped: list[str] = []
        try:
            res = TarjanBridgeVerifier.verify_solver_pipeline(
                nodes=nodes,
                directed_edges=directed_edges,
                recursion_depth=recursion_depth,
                consolidation_rule_immutable=consolidation_rule_immutable,
            )
        except Exception as e:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G3",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message=str(e),
            )

        if live_openfoam_calls_in_session > session_openfoam_call_ceiling:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G3",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Live OpenFOAM call ceiling exceeded",
            )

        cache_miss = pod_dmd_residual > pod_dmd_tolerance
        return GateEvaluationResult(
            gate_id="G3",
            passed=True,
            epistemic_status=":Accepted",
            details={
                "max_scc_size": res["max_scc_size"],
                "beta_1_inter_solver": res["beta_1_inter_solver"],
                "recursion_depth": res["recursion_depth"],
                "cache_miss_solve_triggered": cache_miss,
            },
        )

    # ==========================================================================
    # Gate G4: One-Way Settlement Bridge & Redemption Latency Clock Assignment
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g4(
        orderbook_beta_1: int = 2,
        balance_tree_beta_1: int = 0,
        settlement_bridge_max_scc_size: int = 1,
        reverse_ledger_to_orderbook_edge: bool = False,
        classify_by_dollar_size_instead_of_latency: bool = False,
        cec_algo_exit_trigger_stoppable: bool = True,
    ) -> GateEvaluationResult:
        """Gate G4: Cyclic matching engine into acyclic balance tree with latency clocks."""
        tripped: list[str] = []
        if reverse_ledger_to_orderbook_edge or settlement_bridge_max_scc_size != 1:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G4",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Reverse ledger-to-orderbook edge or non-trivial SCC detected",
            )
        if orderbook_beta_1 < 1 or balance_tree_beta_1 != 0:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G4",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Orderbook requires beta_1 >= 1 and balance tree requires beta_1 == 0",
            )
        if classify_by_dollar_size_instead_of_latency:
            tripped.append("Control")
            return GateEvaluationResult(
                gate_id="G4",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Positions must be classified by redemption latency, not dollar size",
            )
        if not cec_algo_exit_trigger_stoppable:
            tripped.append("Control")
            return GateEvaluationResult(
                gate_id="G4",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Algorithmic trading ladder requires an explicit stoppable exit trigger",
            )

        return GateEvaluationResult(
            gate_id="G4",
            passed=True,
            epistemic_status=":Accepted",
            details={
                "orderbook_beta_1": orderbook_beta_1,
                "balance_tree_beta_1": balance_tree_beta_1,
                "settlement_bridge_max_scc_size": settlement_bridge_max_scc_size,
                "cec_algo_exit_trigger_stoppable": cec_algo_exit_trigger_stoppable,
            },
        )

    # ==========================================================================
    # Gate G5: Horizon-Collar Leaf Pull Seam (MATLAB -> NeuralCompose)
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g5(
        collar_leaves: tuple[str, ...] = ("u_valve", "z_shield", "Phi_light"),
        assume_shared_in_memory_process: bool = False,
        mat_v7_magic_ok: bool = True,
        mat_v73_hdf5_magic_ok: bool = True,
        json_fixture_ok: bool = True,
    ) -> GateEvaluationResult:
        """Gate G5: Double-tree collar leaf attachment contributing Delta_beta_1 = c - 1."""
        tripped: list[str] = []
        if assume_shared_in_memory_process:
            tripped.extend(["Boundary", "Coordination"])
            return GateEvaluationResult(
                gate_id="G5",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=sorted(list(set(tripped))),
                error_message="Cross-process collar boundary required (no shared in-memory shortcuts)",
            )
        if not (mat_v7_magic_ok and mat_v73_hdf5_magic_ok and json_fixture_ok):
            tripped.append("Boundary")
            return GateEvaluationResult(
                gate_id="G5",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="Collar containers (MAT v7, MAT v7.3 HDF5, JSON) must be valid",
            )
        c = len(collar_leaves)
        delta_beta_1 = c - 1
        if delta_beta_1 != 2:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G5",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message=f"Expected Delta_beta_1 == 2 from c=3 leaves, got {delta_beta_1}",
            )

        return GateEvaluationResult(
            gate_id="G5",
            passed=True,
            epistemic_status=":Accepted",
            details={
                "collar_leaves": list(collar_leaves),
                "collar_leaf_count_c": c,
                "delta_beta_1": delta_beta_1,
                "beta_1_inter_solver": 0,
            },
        )

    # ==========================================================================
    # Gate G6: Unified Headless Substrate-Swap Verification Primitive (L29..L32)
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g6(
        openfoam_mesh_beta_0: int = 1,
        openfoam_mesh_beta_1: int = 2,
        matlab_interpolated_beta_0: int = 1,
        matlab_interpolated_beta_1: int = 2,
        max_interpolation_tearing_residual: float = 1.2e-6,
        max_allowed_tearing_residual: float = 1.0e-3,
        swarm_nodes: Optional[list[str]] = None,
        swarm_undirected_edges: Optional[list[tuple[str, str]]] = None,
        agent_triggers_feed_a: Optional[dict[str, tuple[str, ...]]] = None,
        agent_triggers_feed_b_swapped: Optional[dict[str, tuple[str, ...]]] = None,
        candidate_items: Optional[list[dict[str, Any]]] = None,
        log_stage_rejects_separately: bool = True,
        openmc_dose_rate_endfb80_mSv_hr: float = 0.0142,
        openmc_dose_rate_jeff33_mSv_hr: float = 0.0145,
        openmc_tally_rel_variance_tol: float = 0.05,
        icrp116_flux_to_dose_verified_separately: bool = True,
        workplace_regulatory_geometry_verified: bool = True,
    ) -> GateEvaluationResult:
        """Gate G6: 4-domain substrate-swap primitive across L29, L30, L31, L32."""
        tripped: list[str] = []

        # (a) L29 Mesh-field interpolation
        delta_beta_0 = matlab_interpolated_beta_0 - openfoam_mesh_beta_0
        delta_beta_1 = matlab_interpolated_beta_1 - openfoam_mesh_beta_1
        if delta_beta_0 != 0 or delta_beta_1 != 0 or max_interpolation_tearing_residual > max_allowed_tearing_residual:
            tripped.append("Boundary")
            return GateEvaluationResult(
                gate_id="G6",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message=f"L29 mesh interpolation tearing: Delta_beta_0={delta_beta_0}, Delta_beta_1={delta_beta_1}",
            )

        # (b) L30 Biconnected swarm
        if swarm_nodes is None:
            swarm_nodes = ["agent_warrant", "agent_task", "agent_haiku", "agent_auditor"]
        if swarm_undirected_edges is None:
            swarm_undirected_edges = [
                ("agent_warrant", "agent_task"),
                ("agent_task", "agent_haiku"),
                ("agent_haiku", "agent_auditor"),
                ("agent_auditor", "agent_warrant"),
                ("agent_warrant", "agent_haiku"),
            ]
        cut_vertices, bridge_edges = find_cut_vertices_and_bridges(swarm_nodes, swarm_undirected_edges)
        beta_1_swarm = len(swarm_undirected_edges) - len(swarm_nodes) + 1
        if len(cut_vertices) > 0 or len(bridge_edges) > 0 or beta_1_swarm < 2:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G6",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message=f"L30 swarm not biconnected: beta_1={beta_1_swarm}, cuts={cut_vertices}",
            )

        if agent_triggers_feed_a is None:
            agent_triggers_feed_a = {"warrant": ("sigma <= 1.05",)}
        if agent_triggers_feed_b_swapped is None:
            agent_triggers_feed_b_swapped = dict(agent_triggers_feed_a)
        if agent_triggers_feed_a != agent_triggers_feed_b_swapped:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G6",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="L30 swarm triggers diverged under counterfactual feed swap",
            )

        # (c) L31 Sequential reject logging
        if not log_stage_rejects_separately:
            tripped.append("Coordination")
            return GateEvaluationResult(
                gate_id="G6",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="L31 requires separate logging of stage rejects",
            )

        # (d) L32 OpenMC cross-section library swap
        if not icrp116_flux_to_dose_verified_separately or not workplace_regulatory_geometry_verified:
            tripped.append("Source")
            return GateEvaluationResult(
                gate_id="G6",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message="L32 requires separate ICRP-116 dosimetry and verified workplace geometry",
            )

        denom = max(1e-12, 0.5 * (openmc_dose_rate_endfb80_mSv_hr + openmc_dose_rate_jeff33_mSv_hr))
        rel_diff = abs(openmc_dose_rate_endfb80_mSv_hr - openmc_dose_rate_jeff33_mSv_hr) / denom
        if rel_diff > openmc_tally_rel_variance_tol:
            tripped.append("Source")
            return GateEvaluationResult(
                gate_id="G6",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=tripped,
                error_message=f"L32 OpenMC cross-section swap tally diff {rel_diff:.4f} > {openmc_tally_rel_variance_tol}",
            )

        return GateEvaluationResult(
            gate_id="G6",
            passed=True,
            epistemic_status=":Accepted",
            details={
                "delta_beta_0": delta_beta_0,
                "delta_beta_1": delta_beta_1,
                "beta_1_swarm": beta_1_swarm,
                "openmc_tally_rel_diff": round(rel_diff, 6),
            },
        )

    # ==========================================================================
    # Gate G7: Health-Physics ALARA & Epistemic Hippocratism 3-Valued Quarantine
    # ==========================================================================
    @staticmethod
    def evaluate_gate_g7(
        cumulative_dose_Gy: float = 0.0295,
        max_allowable_dose_Gy: float = 0.050,
        standoff_distance_m: float = 10.0,
        reference_distance_m: float = 1.0,
        shielding_thickness_m: float = 0.10,
        melanin_mass_fraction: float = 0.18,
        temperature_K: float = 298.15,
        spice_units_verified_by_spkpos: bool = True,
        promote_unverified_hormesis: bool = False,
        promote_unverified_atp: bool = False,
        force_collapse_incomplete_to_rejected: bool = False,
    ) -> GateEvaluationResult:
        """Gate G7: 80% ALARA payload safing (0.040 Gy) and 3-valued quarantine."""
        tripped: list[str] = []
        controller = ALARAClosedLoopController(max_allowable_dose_Gy=max_allowable_dose_Gy)
        state = ALARAControllerState(
            cumulative_dose_Gy=cumulative_dose_Gy,
            standoff_distance_m=standoff_distance_m,
            reference_distance_m=reference_distance_m,
            shield_thickness_m=shielding_thickness_m,
            melanin_mass_fraction=melanin_mass_fraction,
            temperature_K=temperature_K,
            spice_units_verified_by_spkpos=spice_units_verified_by_spkpos,
            max_allowable_dose_Gy=max_allowable_dose_Gy,
        )

        try:
            res = controller.evaluate_epistemic_hippocratism_quarantine(
                state=state,
                promote_unverified_hormesis=promote_unverified_hormesis,
                promote_unverified_atp=promote_unverified_atp,
                force_collapse_incomplete_to_rejected=force_collapse_incomplete_to_rejected,
            )
        except Exception as e:
            tripped.extend(["Control", "Source"])
            return GateEvaluationResult(
                gate_id="G7",
                passed=False,
                epistemic_status=":Rejected",
                defect_axes_tripped=sorted(list(set(tripped))),
                error_message=str(e),
            )

        verdict = res["verdict"]
        passed = verdict in (":Accepted", ":Incomplete") and not res["ceiling_exceeded"]

        if res["payload_safing_triggered"]:
            tripped.append("Control")
        if res["below_280K_nutmeg"] or not state.spice_units_verified_by_spkpos:
            tripped.append("Source")
        if res["ceiling_exceeded"]:
            tripped.extend(["Control", "Source"])

        return GateEvaluationResult(
            gate_id="G7",
            passed=passed,
            epistemic_status=verdict,
            defect_axes_tripped=sorted(list(set(tripped))),
            details=res,
        )

    # ==========================================================================
    # Cross-Subsystem Causal Transition Validation
    # ==========================================================================
    @classmethod
    def evaluate_transition(
        cls, source_event: MasterEvent, target_event: MasterEvent
    ) -> TransitionEvaluationResult:
        """Validate directional transition between two subsystem events."""
        reasons: list[str] = []
        flags = {
            "Boundary": False,
            "Control": False,
            "Source": False,
            "Coordination": False,
        }
        status = ":Accepted"

        # Check recursion depth invariant on both events
        if source_event.recursion_depth != 0 or target_event.recursion_depth != 0:
            flags["Coordination"] = True
            reasons.append("Non-recursive execution invariant violated (recursion_depth != 0)")
            status = ":Rejected"

        s_sub = source_event.subsystem_id
        t_sub = target_event.subsystem_id
        s_norm = s_sub.replace("_", "").lower()
        t_norm = t_sub.replace("_", "").lower()

        # Transition S1 -> S2 (NeuralCompose -> Momentum Automata)
        if "neuralcompose" in s_norm and "momentumautomata" in t_norm:
            s_payload = source_event.payload
            t_payload = target_event.payload
            if isinstance(s_payload, NeuralComposeFixtureEnvelope):
                # Tension check
                if s_payload.mahalanobis_tension_D_M > 2.45:
                    flags["Control"] = True
                    reasons.append(
                        f"ZPD panic overhang: D_M={s_payload.mahalanobis_tension_D_M:.2f} > 2.45"
                    )
                    status = ":Incomplete"
                # Beta_0 fragmentation check
                if s_payload.betti_numbers.beta_0 > 1:
                    flags["Coordination"] = True
                    reasons.append(
                        f"Fragmented topology: beta_0={s_payload.betti_numbers.beta_0} > 1"
                    )
                    status = ":Rejected"
            if isinstance(t_payload, MomentumAutomataEnvelope):
                if t_payload.wbr_mode == "Panic":
                    flags["Control"] = True
                    reasons.append("Momentum Automata in Panic mode")
                    if status != ":Rejected":
                        status = ":Incomplete"

        # Transition S2 -> S3 (Momentum Automata -> Reactor Pools)
        elif "momentumautomata" in s_norm and "reactorpools" in t_norm:
            t_payload = target_event.payload
            if isinstance(t_payload, MultiPoolReactorEnvelope):
                if t_payload.n_pool != 8:
                    flags["Boundary"] = True
                    reasons.append(f"Multi-pool array requires n_pool==8, got {t_payload.n_pool}")
                    status = ":Rejected"
                # Sub-280 K NutMEG check
                if any(temp < 280.0 for temp in t_payload.temperatures_kelvin):
                    flags["Source"] = True
                    reasons.append("Sub-280 K temperature encountered; NutMEG quarantined :Incomplete")
                    if status != ":Rejected":
                        status = ":Incomplete"

        # Transition S3 -> S4 (Reactor Pools -> Biofilm Sessions)
        elif "reactorpools" in s_norm and ("biofilmsessions" in t_norm or "biofilm" in t_norm):
            t_payload = target_event.payload
            if isinstance(t_payload, BiofilmSessionEnvelope):
                # Cytoplasmic streaming check [5.0, 60.0] um/s
                v = t_payload.cytoplasmic_streaming_velocity_um_s
                if not (5.0 <= v <= 60.0):
                    flags["Boundary"] = True
                    reasons.append(f"Cytoplasmic streaming velocity {v:.1f} um/s out of bounds [5.0, 60.0]")
                    status = ":Rejected"
                # Anastomosis topology check
                if t_payload.anastomosis_topology.beta_0 != 1 or t_payload.anastomosis_topology.beta_1 < 1:
                    flags["Coordination"] = True
                    reasons.append("Anastomosis network requires beta_0==1 and beta_1>=1")
                    status = ":Rejected"

        # If any defect flag tripped, update event defect_flags
        target_event.defect_flags.update(flags)
        if status != ":Accepted":
            target_event.epistemic_status = status

        return TransitionEvaluationResult(
            source_subsystem=s_sub,
            target_subsystem=t_sub,
            transition_valid=(status != ":Rejected"),
            defect_flags=flags,
            enforced_epistemic_status=status,
            reasons=reasons,
        )

    @classmethod
    def evaluate_all_gates(cls) -> dict[str, GateEvaluationResult]:
        """Evaluate baseline configuration across all 7 logic gates."""
        return {
            "G1": cls.evaluate_gate_g1(),
            "G2": cls.evaluate_gate_g2(),
            "G3": cls.evaluate_gate_g3(),
            "G4": cls.evaluate_gate_g4(),
            "G5": cls.evaluate_gate_g5(),
            "G6": cls.evaluate_gate_g6(),
            "G7": cls.evaluate_gate_g7(),
        }
