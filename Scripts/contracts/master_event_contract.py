"""Master Event Contract schema models and validation engine.

Connects NeuralCompose functorial fixtures, Momentum Automata criticality engine,
Reactor Pools (N_pool=8), and Biofilms Sessions (Neurospora crassa circadian gating,
cytoplasmic streaming 5-60 um/s, HEX-1 Woronin body plugging, anastomosis topology).

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
import json
import math
from pathlib import Path
from typing import Any, Optional, Union

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCHEMA_PATH = REPO_ROOT / "configs" / "master_event_contract_schema_v1.json"

VALID_M7_STAGE_HEADERS = (
    "M7.1",
    "M7.2",
    "M7.3",
    "M7.4",
    "M7.5",
    "M7.6",
    "M7.7",
    "M7.8",
)

VALID_FUNCTOR_STAGES = ("F_Laya", "F_ST", "F_Mem", "F_MM")
VALID_CRITICALITY_REGIMES = (
    "SUBCRITICAL",
    "CRITICAL_WITHIN_NOISE",
    "SUPERCRITICAL",
    "PROMPT_SCRAM",
)
VALID_WBR_MODES = ("Focus", "Frustration", "Panic")
VALID_EPISTEMIC_STATUSES = (
    ":Accepted",
    ":Incomplete",
    ":Rejected",
    "Accepted",
    "Incomplete",
    "Rejected",
)
VALID_DEFECT_AXES = ("Boundary", "Control", "Source", "Coordination")


def sanitize_dashes(text: str) -> str:
    """Enforce strictly zero em-dashes and zero en-dashes."""
    return text.replace("\u2014", " - ").replace("\u2013", "-")


class MasterEventContractError(ValueError):
    """Base exception for Master Event Contract violations."""


class SchemaValidationError(MasterEventContractError):
    """Raised when an event envelope fails schema validation."""


class CategoryTypeViolation(MasterEventContractError):
    """Raised when type separation invariants are violated (Turn L14/L16)."""


def assert_stage_header(value: Any, field_name: str = "container_header") -> str:
    """Verify that stage header is a String in M7.1..M7.8, never an int or float."""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        raise CategoryTypeViolation(
            f"Category-Level Schema Violation (Turn L16): M7.1..M7.8 are pipeline stage headers "
            f"(container labels), never Float64 or Int64 numeric literals, got {value!r}"
        )
    if not isinstance(value, str):
        raise CategoryTypeViolation(
            f"Field '{field_name}' must be String header in {VALID_M7_STAGE_HEADERS}, got {type(value).__name__}"
        )
    if value not in VALID_M7_STAGE_HEADERS:
        raise CategoryTypeViolation(
            f"Field '{field_name}' must be one of {VALID_M7_STAGE_HEADERS}, got {value!r}"
        )
    return value


def assert_int64(value: Any, field_name: str) -> int:
    """Verify that value is a strict integer (Int64), not float or bool."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise CategoryTypeViolation(
            f"Field '{field_name}' must be exact Int64 discrete integer, got {type(value).__name__}: {value!r}"
        )
    return value


def assert_float64(value: Any, field_name: str) -> float:
    """Verify that value is a finite IEEE-754 float (Float64), not bool."""
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise CategoryTypeViolation(
            f"Field '{field_name}' must be continuous Float64 SI observable, got {type(value).__name__}: {value!r}"
        )
    val_f = float(value)
    if not math.isfinite(val_f):
        raise CategoryTypeViolation(
            f"Field '{field_name}' must be finite Float64, got {value!r}"
        )
    return val_f


@dataclass
class BettiNumbers:
    """Topological Betti numbers (beta_0 connected components, beta_1 1-cycles)."""

    beta_0: int = 1
    beta_1: int = 0

    def __post_init__(self) -> None:
        assert_int64(self.beta_0, "beta_0")
        assert_int64(self.beta_1, "beta_1")
        if self.beta_0 < 1:
            raise SchemaValidationError(f"beta_0 must be at least 1, got {self.beta_0}")
        if self.beta_1 < 0:
            raise SchemaValidationError(f"beta_1 must be non-negative, got {self.beta_1}")


@dataclass
class DefectAxes:
    """4 multica defect axes: Boundary, Control, Source, Coordination."""

    boundary: bool = False
    control: bool = False
    source: bool = False
    coordination: bool = False

    def is_clean(self) -> bool:
        return not (self.boundary or self.control or self.source or self.coordination)


@dataclass
class CriticalityMetrics:
    """Neutron-transport-isomorphic order book criticality metrics."""

    k_eff: float
    rho_pcm: float
    z_crit: float
    chi: float

    def __post_init__(self) -> None:
        assert_float64(self.k_eff, "k_eff")
        assert_float64(self.rho_pcm, "rho_pcm")
        assert_float64(self.z_crit, "z_crit")
        assert_float64(self.chi, "chi")
        if self.k_eff < 0.0:
            raise SchemaValidationError(f"k_eff must be non-negative, got {self.k_eff}")
        if self.chi < 0.0:
            raise SchemaValidationError(f"chi must be non-negative, got {self.chi}")


@dataclass
class CircadianState:
    """Neurospora crassa circadian oscillator states."""

    M_frq: float
    F_c: float
    F_n: float
    phi_radians: float

    def __post_init__(self) -> None:
        assert_float64(self.M_frq, "M_frq")
        assert_float64(self.F_c, "F_c")
        assert_float64(self.F_n, "F_n")
        assert_float64(self.phi_radians, "phi_radians")
        if self.M_frq < 0.0:
            raise SchemaValidationError(f"M_frq must be non-negative, got {self.M_frq}")
        if self.F_c < 0.0:
            raise SchemaValidationError(f"F_c must be non-negative, got {self.F_c}")
        if self.F_n < 0.0:
            raise SchemaValidationError(f"F_n must be non-negative, got {self.F_n}")


@dataclass
class AnastomosisTopology:
    """Syncytial hyphal network topology."""

    beta_0: int = 1
    beta_1: int = 3

    def __post_init__(self) -> None:
        assert_int64(self.beta_0, "beta_0")
        assert_int64(self.beta_1, "beta_1")
        if self.beta_0 != 1:
            raise SchemaValidationError(
                f"Syncytial hyphal network must be connected (beta_0 == 1), got {self.beta_0}"
            )
        if self.beta_1 < 1:
            raise SchemaValidationError(
                f"Active anastomosis network requires beta_1 >= 1, got {self.beta_1}"
            )


@dataclass
class NeuralComposeFixtureEnvelope:
    """S1: NeuralCompose Functorial Fixtures envelope."""

    sequence_id: str
    functor_stage: str
    frame_index: int
    betti_numbers: BettiNumbers
    defect_axes: DefectAxes
    toy_drive_active: bool
    mahalanobis_tension_D_M: float
    subsystem_id: str = "S1_NeuralCompose_Functorial_Fixtures"
    timestamp_utc: Optional[str] = None
    causal_parent_id: Optional[str] = None
    four_pillar_record: Optional[dict[str, Any]] = None

    def __post_init__(self) -> None:
        if not isinstance(self.sequence_id, str) or not self.sequence_id:
            raise SchemaValidationError("sequence_id must be non-empty String")
        if self.functor_stage not in VALID_FUNCTOR_STAGES:
            raise SchemaValidationError(
                f"functor_stage must be one of {VALID_FUNCTOR_STAGES}, got {self.functor_stage!r}"
            )
        assert_int64(self.frame_index, "frame_index")
        if not (0 <= self.frame_index <= 59):
            raise SchemaValidationError(
                f"frame_index must be in [0..59], got {self.frame_index}"
            )
        assert_float64(self.mahalanobis_tension_D_M, "mahalanobis_tension_D_M")
        if self.mahalanobis_tension_D_M < 0.0:
            raise SchemaValidationError(
                f"mahalanobis_tension_D_M must be non-negative, got {self.mahalanobis_tension_D_M}"
            )


@dataclass
class MomentumAutomataEnvelope:
    """S2: Momentum Automata Criticality Engine envelope."""

    sequence_id: str
    criticality_metrics: CriticalityMetrics
    criticality_regime: str
    wbr_mode: str
    hysteresis_loop_area: float
    retention_pool_active: bool
    subsystem_id: str = "S2_Momentum_Automata_Criticality_Engine"
    orderbook_betti_1: int = 2
    balance_tree_betti_1: int = 0
    cec_algo_exit_trigger_stoppable: bool = True
    timestamp_utc: Optional[str] = None
    causal_parent_id: Optional[str] = None

    def __post_init__(self) -> None:
        if not isinstance(self.sequence_id, str) or not self.sequence_id:
            raise SchemaValidationError("sequence_id must be non-empty String")
        if self.criticality_regime not in VALID_CRITICALITY_REGIMES:
            raise SchemaValidationError(
                f"criticality_regime must be one of {VALID_CRITICALITY_REGIMES}, got {self.criticality_regime!r}"
            )
        if self.wbr_mode not in VALID_WBR_MODES:
            raise SchemaValidationError(
                f"wbr_mode must be one of {VALID_WBR_MODES}, got {self.wbr_mode!r}"
            )
        assert_float64(self.hysteresis_loop_area, "hysteresis_loop_area")
        if self.hysteresis_loop_area < 0.0:
            raise SchemaValidationError(
                f"hysteresis_loop_area must be non-negative, got {self.hysteresis_loop_area}"
            )
        assert_int64(self.orderbook_betti_1, "orderbook_betti_1")
        if self.orderbook_betti_1 < 1:
            raise SchemaValidationError(
                f"Order book matching engine requires beta_1 >= 1, got {self.orderbook_betti_1}"
            )
        assert_int64(self.balance_tree_betti_1, "balance_tree_betti_1")
        if self.balance_tree_betti_1 != 0:
            raise SchemaValidationError(
                f"Balance tree requires beta_1 == 0, got {self.balance_tree_betti_1}"
            )


@dataclass
class MultiPoolReactorEnvelope:
    """S3: Multi-Pool Reactor Hydraulics and Geochemical Speciation envelope."""

    sequence_id: str
    container_header: str
    n_pool: int
    chamber_ids: list[str]
    sucrose_concentrations_mol_m3: list[float]
    temperatures_kelvin: list[float]
    phreeqc_activity_avg_ph: float
    phreeqc_charge_imbalance_pct: float
    radiolytic_h2o2_scavenged_uM: list[float]
    nutmeg_quarantine_status: str
    subsystem_id: str = "S3_Reactor_Pools_SMBR_OpenMC_MATLAB"
    timestamp_utc: Optional[str] = None
    causal_parent_id: Optional[str] = None

    def __post_init__(self) -> None:
        if not isinstance(self.sequence_id, str) or not self.sequence_id:
            raise SchemaValidationError("sequence_id must be non-empty String")
        assert_stage_header(self.container_header, "container_header")
        assert_int64(self.n_pool, "n_pool")
        if self.n_pool != 8:
            raise SchemaValidationError(f"n_pool must be exactly 8, got {self.n_pool}")
        if len(self.chamber_ids) != 8:
            raise SchemaValidationError(
                f"chamber_ids must have length 8, got {len(self.chamber_ids)}"
            )
        if len(self.sucrose_concentrations_mol_m3) != 8:
            raise SchemaValidationError(
                f"sucrose_concentrations_mol_m3 must have length 8, got {len(self.sucrose_concentrations_mol_m3)}"
            )
        for s in self.sucrose_concentrations_mol_m3:
            assert_float64(s, "sucrose_concentrations_mol_m3 item")
            if s < 0.0:
                raise SchemaValidationError(f"Sucrose concentration must be non-negative, got {s}")
        if len(self.temperatures_kelvin) != 8:
            raise SchemaValidationError(
                f"temperatures_kelvin must have length 8, got {len(self.temperatures_kelvin)}"
            )
        for t in self.temperatures_kelvin:
            assert_float64(t, "temperatures_kelvin item")
            if t < 0.0:
                raise SchemaValidationError(f"Temperature must be non-negative, got {t}")
        assert_float64(self.phreeqc_activity_avg_ph, "phreeqc_activity_avg_ph")
        if not (0.0 <= self.phreeqc_activity_avg_ph <= 14.0):
            raise SchemaValidationError(
                f"phreeqc_activity_avg_ph must be in [0..14], got {self.phreeqc_activity_avg_ph}"
            )
        assert_float64(self.phreeqc_charge_imbalance_pct, "phreeqc_charge_imbalance_pct")
        if self.phreeqc_charge_imbalance_pct < 0.0:
            raise SchemaValidationError(
                f"phreeqc_charge_imbalance_pct must be non-negative, got {self.phreeqc_charge_imbalance_pct}"
            )
        if len(self.radiolytic_h2o2_scavenged_uM) != 8:
            raise SchemaValidationError(
                f"radiolytic_h2o2_scavenged_uM must have length 8, got {len(self.radiolytic_h2o2_scavenged_uM)}"
            )
        for h in self.radiolytic_h2o2_scavenged_uM:
            assert_float64(h, "radiolytic_h2o2_scavenged_uM item")
        if self.nutmeg_quarantine_status not in VALID_EPISTEMIC_STATUSES:
            raise SchemaValidationError(
                f"nutmeg_quarantine_status must be in {VALID_EPISTEMIC_STATUSES}, got {self.nutmeg_quarantine_status!r}"
            )


@dataclass
class BiofilmSessionEnvelope:
    """S4: Syncytial Hyphal Biofilm and Circadian Gating envelope."""

    sequence_id: str
    container_header: str
    circadian_state: CircadianState
    cytoplasmic_streaming_velocity_um_s: float
    hex1_woronin_plugging_active: bool
    anastomosis_topology: AnastomosisTopology
    biomass_density_kg_m3: list[float]
    tip_density_m3: list[float]
    eps_streamer_fraction: list[float]
    subsystem_id: str = "S4_Biofilms_Sessions_Neurospora_M7_Workbench"
    wall_shear_stress_Pa: Optional[list[float]] = None
    timestamp_utc: Optional[str] = None
    causal_parent_id: Optional[str] = None

    def __post_init__(self) -> None:
        if not isinstance(self.sequence_id, str) or not self.sequence_id:
            raise SchemaValidationError("sequence_id must be non-empty String")
        assert_stage_header(self.container_header, "container_header")
        assert_float64(
            self.cytoplasmic_streaming_velocity_um_s,
            "cytoplasmic_streaming_velocity_um_s",
        )
        if not (5.0 <= self.cytoplasmic_streaming_velocity_um_s <= 60.0):
            raise SchemaValidationError(
                f"cytoplasmic_streaming_velocity_um_s must be in [5.0, 60.0], got {self.cytoplasmic_streaming_velocity_um_s}"
            )
        if len(self.biomass_density_kg_m3) != 8:
            raise SchemaValidationError(
                f"biomass_density_kg_m3 must have length 8, got {len(self.biomass_density_kg_m3)}"
            )
        for b in self.biomass_density_kg_m3:
            assert_float64(b, "biomass_density_kg_m3 item")
            if not (0.0 <= b <= 1.20):
                raise SchemaValidationError(
                    f"Biomass density must be in [0.0, 1.20] kg/m^3, got {b}"
                )
        if len(self.tip_density_m3) != 8:
            raise SchemaValidationError(
                f"tip_density_m3 must have length 8, got {len(self.tip_density_m3)}"
            )
        for t in self.tip_density_m3:
            assert_float64(t, "tip_density_m3 item")
            if t < 0.0:
                raise SchemaValidationError(f"Tip density must be non-negative, got {t}")
        if len(self.eps_streamer_fraction) != 8:
            raise SchemaValidationError(
                f"eps_streamer_fraction must have length 8, got {len(self.eps_streamer_fraction)}"
            )
        for e in self.eps_streamer_fraction:
            assert_float64(e, "eps_streamer_fraction item")
            if not (0.0 <= e <= 1.0):
                raise SchemaValidationError(
                    f"EPS streamer fraction must be in [0.0, 1.0], got {e}"
                )


@dataclass
class MasterEvent:
    """Unified Master Event envelope crossing all four subsystems."""

    event_id: str
    timestamp_utc: str
    subsystem_id: str
    envelope_type: str
    payload: Union[
        NeuralComposeFixtureEnvelope,
        MomentumAutomataEnvelope,
        MultiPoolReactorEnvelope,
        BiofilmSessionEnvelope,
        dict[str, Any],
    ]
    causal_parent_id: Optional[str] = None
    recursion_depth: int = 0
    defect_flags: dict[str, bool] = field(
        default_factory=lambda: {
            "Boundary": False,
            "Control": False,
            "Source": False,
            "Coordination": False,
        }
    )
    epistemic_status: str = ":Accepted"

    def __post_init__(self) -> None:
        if not isinstance(self.event_id, str) or not self.event_id:
            raise SchemaValidationError("event_id must be non-empty String")
        if not isinstance(self.timestamp_utc, str):
            raise SchemaValidationError("timestamp_utc must be String")
        assert_int64(self.recursion_depth, "recursion_depth")
        if self.recursion_depth != 0:
            raise SchemaValidationError(
                f"Non-recursive invariant violated (Turn L112/L20): recursion_depth must be 0, got {self.recursion_depth}"
            )
        if self.epistemic_status not in VALID_EPISTEMIC_STATUSES:
            raise SchemaValidationError(
                f"epistemic_status must be in {VALID_EPISTEMIC_STATUSES}, got {self.epistemic_status!r}"
            )
        for ax in VALID_DEFECT_AXES:
            if ax not in self.defect_flags:
                self.defect_flags[ax] = False

    def to_dict(self) -> dict[str, Any]:
        """Convert MasterEvent to clean dictionary."""
        p_dict = (
            asdict(self.payload)
            if hasattr(self.payload, "__dataclass_fields__")
            else self.payload
        )
        return {
            "event_id": self.event_id,
            "timestamp_utc": self.timestamp_utc,
            "subsystem_id": self.subsystem_id,
            "envelope_type": self.envelope_type,
            "causal_parent_id": self.causal_parent_id,
            "recursion_depth": self.recursion_depth,
            "defect_flags": dict(self.defect_flags),
            "epistemic_status": self.epistemic_status,
            "payload": p_dict,
        }

    def to_json(self) -> str:
        """Convert MasterEvent to serialized JSON string with zero em/en dashes."""
        d = self.to_dict()
        return sanitize_dashes(json.dumps(d, indent=2)) + "\n"

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MasterEvent:
        """Construct and validate MasterEvent from dictionary."""
        validate_master_event(data)
        env_type = data["envelope_type"]
        p_data = data["payload"]
        parsed_payload: Any = p_data

        if env_type == "NeuralComposeFixtureEnvelope":
            parsed_payload = NeuralComposeFixtureEnvelope(
                sequence_id=p_data["sequence_id"],
                functor_stage=p_data["functor_stage"],
                frame_index=int(p_data["frame_index"]),
                betti_numbers=BettiNumbers(**p_data["betti_numbers"]),
                defect_axes=DefectAxes(**p_data["defect_axes"]),
                toy_drive_active=bool(p_data["toy_drive_active"]),
                mahalanobis_tension_D_M=float(p_data["mahalanobis_tension_D_M"]),
                subsystem_id=p_data.get(
                    "subsystem_id", "S1_NeuralCompose_Functorial_Fixtures"
                ),
                timestamp_utc=p_data.get("timestamp_utc"),
                causal_parent_id=p_data.get("causal_parent_id"),
                four_pillar_record=p_data.get("four_pillar_record"),
            )
        elif env_type == "MomentumAutomataEnvelope":
            parsed_payload = MomentumAutomataEnvelope(
                sequence_id=p_data["sequence_id"],
                criticality_metrics=CriticalityMetrics(**p_data["criticality_metrics"]),
                criticality_regime=p_data["criticality_regime"],
                wbr_mode=p_data["wbr_mode"],
                hysteresis_loop_area=float(p_data["hysteresis_loop_area"]),
                retention_pool_active=bool(p_data["retention_pool_active"]),
                subsystem_id=p_data.get(
                    "subsystem_id", "S2_Momentum_Automata_Criticality_Engine"
                ),
                orderbook_betti_1=int(p_data.get("orderbook_betti_1", 2)),
                balance_tree_betti_1=int(p_data.get("balance_tree_betti_1", 0)),
                cec_algo_exit_trigger_stoppable=bool(
                    p_data.get("cec_algo_exit_trigger_stoppable", True)
                ),
                timestamp_utc=p_data.get("timestamp_utc"),
                causal_parent_id=p_data.get("causal_parent_id"),
            )
        elif env_type == "MultiPoolReactorEnvelope":
            parsed_payload = MultiPoolReactorEnvelope(
                sequence_id=p_data["sequence_id"],
                container_header=p_data["container_header"],
                n_pool=int(p_data["n_pool"]),
                chamber_ids=list(p_data["chamber_ids"]),
                sucrose_concentrations_mol_m3=[
                    float(x) for x in p_data["sucrose_concentrations_mol_m3"]
                ],
                temperatures_kelvin=[
                    float(x) for x in p_data["temperatures_kelvin"]
                ],
                phreeqc_activity_avg_ph=float(p_data["phreeqc_activity_avg_ph"]),
                phreeqc_charge_imbalance_pct=float(
                    p_data["phreeqc_charge_imbalance_pct"]
                ),
                radiolytic_h2o2_scavenged_uM=[
                    float(x) for x in p_data["radiolytic_h2o2_scavenged_uM"]
                ],
                nutmeg_quarantine_status=p_data["nutmeg_quarantine_status"],
                subsystem_id=p_data.get(
                    "subsystem_id", "S3_Reactor_Pools_SMBR_OpenMC_MATLAB"
                ),
                timestamp_utc=p_data.get("timestamp_utc"),
                causal_parent_id=p_data.get("causal_parent_id"),
            )
        elif env_type == "BiofilmSessionEnvelope":
            parsed_payload = BiofilmSessionEnvelope(
                sequence_id=p_data["sequence_id"],
                container_header=p_data["container_header"],
                circadian_state=CircadianState(**p_data["circadian_state"]),
                cytoplasmic_streaming_velocity_um_s=float(
                    p_data["cytoplasmic_streaming_velocity_um_s"]
                ),
                hex1_woronin_plugging_active=bool(
                    p_data["hex1_woronin_plugging_active"]
                ),
                anastomosis_topology=AnastomosisTopology(
                    **p_data["anastomosis_topology"]
                ),
                biomass_density_kg_m3=[
                    float(x) for x in p_data["biomass_density_kg_m3"]
                ],
                tip_density_m3=[float(x) for x in p_data["tip_density_m3"]],
                eps_streamer_fraction=[
                    float(x) for x in p_data["eps_streamer_fraction"]
                ],
                subsystem_id=p_data.get(
                    "subsystem_id", "S4_Biofilms_Sessions_Neurospora_M7_Workbench"
                ),
                wall_shear_stress_Pa=[float(x) for x in p_data["wall_shear_stress_Pa"]]
                if p_data.get("wall_shear_stress_Pa") is not None
                else None,
                timestamp_utc=p_data.get("timestamp_utc"),
                causal_parent_id=p_data.get("causal_parent_id"),
            )

        return cls(
            event_id=data["event_id"],
            timestamp_utc=data["timestamp_utc"],
            subsystem_id=data["subsystem_id"],
            envelope_type=data["envelope_type"],
            payload=parsed_payload,
            causal_parent_id=data.get("causal_parent_id"),
            recursion_depth=int(data.get("recursion_depth", 0)),
            defect_flags=dict(data.get("defect_flags", {})),
            epistemic_status=data.get("epistemic_status", ":Accepted"),
        )

    @classmethod
    def from_json(cls, json_str: str) -> MasterEvent:
        """Construct MasterEvent from JSON string."""
        if "\u2014" in json_str or "\u2013" in json_str:
            raise MasterEventContractError(
                "JSON payload contains forbidden em-dash or en-dash characters"
            )
        data = json.loads(json_str)
        return cls.from_dict(data)


# ==============================================================================
# Validation functions
# ==============================================================================


def validate_neuralcompose_fixture_envelope(
    env: Union[NeuralComposeFixtureEnvelope, dict[str, Any]],
) -> None:
    """Validate S1 NeuralCompose Fixture payload."""
    if isinstance(env, NeuralComposeFixtureEnvelope):
        return
    if not isinstance(env, dict):
        raise SchemaValidationError("NeuralCompose payload must be a dict")
    required = [
        "sequence_id",
        "functor_stage",
        "frame_index",
        "betti_numbers",
        "defect_axes",
        "toy_drive_active",
        "mahalanobis_tension_D_M",
    ]
    for r in required:
        if r not in env:
            raise SchemaValidationError(f"Missing required field '{r}' in NeuralCompose payload")
    if env["functor_stage"] not in VALID_FUNCTOR_STAGES:
        raise SchemaValidationError(f"Invalid functor_stage: {env['functor_stage']}")
    assert_int64(env["frame_index"], "frame_index")
    if not (0 <= env["frame_index"] <= 59):
        raise SchemaValidationError(f"frame_index out of range [0..59]: {env['frame_index']}")
    bn = env["betti_numbers"]
    if not isinstance(bn, dict) or "beta_0" not in bn or "beta_1" not in bn:
        raise SchemaValidationError("betti_numbers must contain beta_0 and beta_1")
    assert_int64(bn["beta_0"], "beta_0")
    assert_int64(bn["beta_1"], "beta_1")
    da = env["defect_axes"]
    if not isinstance(da, dict):
        raise SchemaValidationError("defect_axes must be a dict")
    for ax in ("boundary", "control", "source", "coordination"):
        if ax not in da or not isinstance(da[ax], bool):
            raise SchemaValidationError(f"defect_axes must contain boolean '{ax}'")
    assert_float64(env["mahalanobis_tension_D_M"], "mahalanobis_tension_D_M")
    if float(env["mahalanobis_tension_D_M"]) < 0.0:
        raise SchemaValidationError("mahalanobis_tension_D_M must be non-negative")


def validate_momentum_automata_envelope(
    env: Union[MomentumAutomataEnvelope, dict[str, Any]],
) -> None:
    """Validate S2 Momentum Automata Criticality Engine payload."""
    if isinstance(env, MomentumAutomataEnvelope):
        return
    if not isinstance(env, dict):
        raise SchemaValidationError("MomentumAutomata payload must be a dict")
    required = [
        "sequence_id",
        "criticality_metrics",
        "criticality_regime",
        "wbr_mode",
        "hysteresis_loop_area",
        "retention_pool_active",
    ]
    for r in required:
        if r not in env:
            raise SchemaValidationError(f"Missing required field '{r}' in MomentumAutomata payload")
    cm = env["criticality_metrics"]
    if not isinstance(cm, dict):
        raise SchemaValidationError("criticality_metrics must be a dict")
    for f in ("k_eff", "rho_pcm", "z_crit", "chi"):
        if f not in cm:
            raise SchemaValidationError(f"criticality_metrics must contain '{f}'")
        assert_float64(cm[f], f)
    if env["criticality_regime"] not in VALID_CRITICALITY_REGIMES:
        raise SchemaValidationError(f"Invalid criticality_regime: {env['criticality_regime']}")
    if env["wbr_mode"] not in VALID_WBR_MODES:
        raise SchemaValidationError(f"Invalid wbr_mode: {env['wbr_mode']}")
    assert_float64(env["hysteresis_loop_area"], "hysteresis_loop_area")
    if "orderbook_betti_1" in env:
        assert_int64(env["orderbook_betti_1"], "orderbook_betti_1")
    if "balance_tree_betti_1" in env:
        assert_int64(env["balance_tree_betti_1"], "balance_tree_betti_1")
        if env["balance_tree_betti_1"] != 0:
            raise SchemaValidationError("balance_tree_betti_1 must be 0")


def validate_multipool_reactor_envelope(
    env: Union[MultiPoolReactorEnvelope, dict[str, Any]],
) -> None:
    """Validate S3 Multi-Pool Reactor Hydraulics payload."""
    if isinstance(env, MultiPoolReactorEnvelope):
        return
    if not isinstance(env, dict):
        raise SchemaValidationError("MultiPoolReactor payload must be a dict")
    required = [
        "sequence_id",
        "container_header",
        "n_pool",
        "chamber_ids",
        "sucrose_concentrations_mol_m3",
        "temperatures_kelvin",
        "phreeqc_activity_avg_ph",
        "phreeqc_charge_imbalance_pct",
        "radiolytic_h2o2_scavenged_uM",
        "nutmeg_quarantine_status",
    ]
    for r in required:
        if r not in env:
            raise SchemaValidationError(f"Missing required field '{r}' in MultiPoolReactor payload")
    assert_stage_header(env["container_header"], "container_header")
    assert_int64(env["n_pool"], "n_pool")
    if env["n_pool"] != 8:
        raise SchemaValidationError(f"n_pool must be exactly 8, got {env['n_pool']}")
    for array_key in (
        "chamber_ids",
        "sucrose_concentrations_mol_m3",
        "temperatures_kelvin",
        "radiolytic_h2o2_scavenged_uM",
    ):
        arr = env[array_key]
        if not isinstance(arr, list) or len(arr) != 8:
            raise SchemaValidationError(f"'{array_key}' must be an array of length 8")
    for s in env["sucrose_concentrations_mol_m3"]:
        assert_float64(s, "sucrose concentration")
        if s < 0.0:
            raise SchemaValidationError("Sucrose concentration must be non-negative")
    for t in env["temperatures_kelvin"]:
        assert_float64(t, "temperature")
        if t < 0.0:
            raise SchemaValidationError("Temperature must be non-negative")
    assert_float64(env["phreeqc_activity_avg_ph"], "phreeqc_activity_avg_ph")
    assert_float64(env["phreeqc_charge_imbalance_pct"], "phreeqc_charge_imbalance_pct")
    if env["nutmeg_quarantine_status"] not in VALID_EPISTEMIC_STATUSES:
        raise SchemaValidationError(
            f"Invalid nutmeg_quarantine_status: {env['nutmeg_quarantine_status']}"
        )


def validate_biofilm_session_envelope(
    env: Union[BiofilmSessionEnvelope, dict[str, Any]],
) -> None:
    """Validate S4 Syncytial Hyphal Biofilm Sessions payload."""
    if isinstance(env, BiofilmSessionEnvelope):
        return
    if not isinstance(env, dict):
        raise SchemaValidationError("BiofilmSession payload must be a dict")
    required = [
        "sequence_id",
        "container_header",
        "circadian_state",
        "cytoplasmic_streaming_velocity_um_s",
        "hex1_woronin_plugging_active",
        "anastomosis_topology",
        "biomass_density_kg_m3",
        "tip_density_m3",
        "eps_streamer_fraction",
    ]
    for r in required:
        if r not in env:
            raise SchemaValidationError(f"Missing required field '{r}' in BiofilmSession payload")
    assert_stage_header(env["container_header"], "container_header")
    cs = env["circadian_state"]
    if not isinstance(cs, dict):
        raise SchemaValidationError("circadian_state must be a dict")
    for f in ("M_frq", "F_c", "F_n", "phi_radians"):
        if f not in cs:
            raise SchemaValidationError(f"circadian_state must contain '{f}'")
        assert_float64(cs[f], f)
    assert_float64(
        env["cytoplasmic_streaming_velocity_um_s"],
        "cytoplasmic_streaming_velocity_um_s",
    )
    v = float(env["cytoplasmic_streaming_velocity_um_s"])
    if not (5.0 <= v <= 60.0):
        raise SchemaValidationError(
            f"cytoplasmic_streaming_velocity_um_s must be in [5.0, 60.0], got {v}"
        )
    at = env["anastomosis_topology"]
    if not isinstance(at, dict) or "beta_0" not in at or "beta_1" not in at:
        raise SchemaValidationError("anastomosis_topology must contain beta_0 and beta_1")
    assert_int64(at["beta_0"], "anastomosis beta_0")
    assert_int64(at["beta_1"], "anastomosis beta_1")
    if at["beta_0"] != 1:
        raise SchemaValidationError(f"anastomosis beta_0 must be 1, got {at['beta_0']}")
    if at["beta_1"] < 1:
        raise SchemaValidationError(f"anastomosis beta_1 must be >= 1, got {at['beta_1']}")
    for array_key in ("biomass_density_kg_m3", "tip_density_m3", "eps_streamer_fraction"):
        arr = env[array_key]
        if not isinstance(arr, list) or len(arr) != 8:
            raise SchemaValidationError(f"'{array_key}' must be an array of length 8")
    for b in env["biomass_density_kg_m3"]:
        assert_float64(b, "biomass density")
        if not (0.0 <= b <= 1.20):
            raise SchemaValidationError(
                f"biomass density must be in [0.0, 1.20] kg/m^3, got {b}"
            )
    for t in env["tip_density_m3"]:
        assert_float64(t, "tip density")
        if t < 0.0:
            raise SchemaValidationError("tip density must be non-negative")
    for e in env["eps_streamer_fraction"]:
        assert_float64(e, "eps streamer fraction")
        if not (0.0 <= e <= 1.0):
            raise SchemaValidationError(
                f"eps streamer fraction must be in [0.0, 1.0], got {e}"
            )


def validate_master_event(event: Union[MasterEvent, dict[str, Any]]) -> None:
    """Validate a complete MasterEvent envelope."""
    if isinstance(event, MasterEvent):
        return
    if not isinstance(event, dict):
        raise SchemaValidationError("MasterEvent must be a dict")
    required = [
        "event_id",
        "timestamp_utc",
        "subsystem_id",
        "envelope_type",
        "recursion_depth",
        "defect_flags",
        "epistemic_status",
        "payload",
    ]
    for r in required:
        if r not in event:
            raise SchemaValidationError(f"Missing required field '{r}' in MasterEvent")
    assert_int64(event["recursion_depth"], "recursion_depth")
    if event["recursion_depth"] != 0:
        raise SchemaValidationError(
            f"Non-recursive invariant violated: recursion_depth must be 0, got {event['recursion_depth']}"
        )
    if event["epistemic_status"] not in VALID_EPISTEMIC_STATUSES:
        raise SchemaValidationError(f"Invalid epistemic_status: {event['epistemic_status']}")
    df = event["defect_flags"]
    if not isinstance(df, dict):
        raise SchemaValidationError("defect_flags must be a dict")
    for ax in VALID_DEFECT_AXES:
        if ax not in df or not isinstance(df[ax], bool):
            raise SchemaValidationError(f"defect_flags must contain boolean '{ax}'")

    etype = event["envelope_type"]
    payload = event["payload"]
    if etype == "NeuralComposeFixtureEnvelope":
        validate_neuralcompose_fixture_envelope(payload)
    elif etype == "MomentumAutomataEnvelope":
        validate_momentum_automata_envelope(payload)
    elif etype == "MultiPoolReactorEnvelope":
        validate_multipool_reactor_envelope(payload)
    elif etype == "BiofilmSessionEnvelope":
        validate_biofilm_session_envelope(payload)
    else:
        raise SchemaValidationError(f"Unknown envelope_type: {etype!r}")
