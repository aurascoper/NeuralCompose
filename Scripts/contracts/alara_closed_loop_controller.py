"""Health-Physics ALARA and Closed-Loop Simulink Controller with Epistemic Hippocratism.

Implements:
- 3 ALARA Pillars: Time (Delta_t), Distance (1/r^2), Shielding (exp(-mu*z) + Melanin/Neurospora radical scavenging)
- 80% payload safing threshold (0.040 Gy of 0.050 Gy limit) automated shutter isolation
- 3-valued Epistemic Hippocratism quarantine (:Accepted, :Incomplete, :Rejected)
- NutMEG maintenance power gate quarantined as :Incomplete below 280 K
- Closed-loop LQR/MPC state regulation: u_valve(t), z_shield(t), Phi_light(t)

Strictly zero em-dashes and zero en-dashes across all code and documentation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import math
from typing import Any, Optional


class ALARAControllerError(ValueError):
    """Raised on ALARA control or Epistemic Hippocratism violations."""


@dataclass
class ALARAControllerState:
    """State vector for closed-loop ALARA radiation regulation."""

    cumulative_dose_Gy: float = 0.025
    dose_rate_Gy_s: float = 8.2e-7
    standoff_distance_m: float = 10.0
    reference_distance_m: float = 1.0
    shield_thickness_m: float = 0.10
    melanin_mass_fraction: float = 0.18
    temperature_K: float = 298.15
    circadian_phase_rad: float = 0.0
    spice_units_verified_by_spkpos: bool = True
    max_allowable_dose_Gy: float = 0.050
    linear_attenuation_coeff_mu: float = 23.5  # m^-1 for regolith/water/clay matrix
    melanin_quenching_efficiency: float = 0.35


@dataclass
class ALARAActuatorOutput:
    """Actuator commands from closed-loop LQR/MPC controller."""

    u_valve_m3_s: float
    z_shield_m: float
    Phi_light_umol_m2_s: float
    controller_mode: str
    epistemic_status: str
    safing_shutter_closed: bool
    cumulative_dose_Gy: float
    safing_threshold_Gy: float
    max_allowable_dose_Gy: float
    diagnostics: dict[str, Any] = field(default_factory=dict)


class ALARAClosedLoopController:
    """Closed-loop regulator enforcing ALARA shielding, 80% safing, and 3-valued quarantine."""

    DEFAULT_MAX_DOSE_GY = 0.050
    SAFING_FRACTION = 0.80  # 80% safing threshold -> 0.040 Gy for 0.050 Gy limit

    def __init__(
        self,
        max_allowable_dose_Gy: float = DEFAULT_MAX_DOSE_GY,
        safing_fraction: float = SAFING_FRACTION,
    ) -> None:
        self.max_allowable_dose_Gy = float(max_allowable_dose_Gy)
        self.safing_fraction = float(safing_fraction)
        self.safing_threshold_Gy = round(self.safing_fraction * self.max_allowable_dose_Gy, 9)

    def compute_effective_dose_rate(
        self,
        unshielded_dose_rate_Gy_s: float,
        standoff_distance_m: float,
        reference_distance_m: float,
        shield_thickness_m: float,
        mu_m_inv: float,
        melanin_fraction: float,
        eta_melanin: float = 0.35,
    ) -> float:
        """Compute shielded effective dose rate D_dot_eff via point kernel and melanin quenching."""
        if standoff_distance_m < reference_distance_m:
            raise ALARAControllerError("standoff_distance_m must be >= reference_distance_m")
        if shield_thickness_m < 0.0:
            raise ALARAControllerError("shield_thickness_m must be non-negative")

        # Geometric 1/r^2 standoff
        geom_factor = (reference_distance_m / standoff_distance_m) ** 2

        # Material exponential attenuation exp(-mu * z)
        mat_factor = math.exp(-mu_m_inv * shield_thickness_m)

        # Radical scavenging factor from melanin
        melanin_factor = 1.0 - (eta_melanin * min(1.0, melanin_fraction / 0.30))

        return unshielded_dose_rate_Gy_s * geom_factor * mat_factor * max(0.01, melanin_factor)

    def compute_radiolytic_yields(
        self,
        dose_rate_Gy_s: float,
        melanin_fraction: float,
        water_density_kg_m3: float = 1000.0,
    ) -> dict[str, float]:
        """Compute primary water radiolysis chemical production rates (mol/(m^3*s))."""
        scavenge_factor = 1.0 / (1.0 + 4.5 * max(0.0, melanin_fraction))
        r_h2 = dose_rate_Gy_s * (water_density_kg_m3 * 0.45e-7)
        r_h2o2 = dose_rate_Gy_s * (water_density_kg_m3 * 0.70e-7 * scavenge_factor)
        r_oh = dose_rate_Gy_s * (water_density_kg_m3 * 2.80e-7 * scavenge_factor)
        return {
            "R_H2_mol_m3_s": r_h2,
            "R_H2O2_mol_m3_s": r_h2o2,
            "R_OH_mol_m3_s": r_oh,
            "scavenge_factor": scavenge_factor,
        }

    def evaluate_epistemic_hippocratism_quarantine(
        self,
        state: ALARAControllerState,
        promote_unverified_hormesis: bool = False,
        promote_unverified_atp: bool = False,
        force_collapse_incomplete_to_rejected: bool = False,
    ) -> dict[str, Any]:
        """Evaluate 3-valued Epistemic Hippocratism gate (:Accepted, :Incomplete, :Rejected)."""
        if promote_unverified_hormesis:
            raise ALARAControllerError(
                "Epistemic Hippocratism Violation: unverified low-dose radiation hormesis "
                "must remain in :Incomplete quarantine and cannot relax ALARA shielding"
            )
        if promote_unverified_atp:
            raise ALARAControllerError(
                "Epistemic Hippocratism Violation: direct net metabolic ATP radiosynthesis "
                "without electron-donor mass balance must remain in :Incomplete quarantine"
            )
        if force_collapse_incomplete_to_rejected:
            raise ALARAControllerError(
                "Epistemic Hippocratism Violation: Incomplete verdict must NEVER collapse into "
                "Rejected without explicit refutation evidence"
            )

        safing_limit = self.safing_threshold_Gy
        is_safing_triggered = state.cumulative_dose_Gy >= (safing_limit - 1e-12)
        is_ceiling_exceeded = state.cumulative_dose_Gy > self.max_allowable_dose_Gy
        is_cold_nutmeg = state.temperature_K < 280.0
        is_unverified_spice = not state.spice_units_verified_by_spkpos

        if is_ceiling_exceeded:
            verdict = ":Rejected"
            mode = "EMERGENCY_SCRAM_ISOLATE"
        elif is_safing_triggered:
            verdict = ":Incomplete"
            mode = "SAFE_HOLD_SHUTTER_CLOSED"
        elif is_cold_nutmeg or is_unverified_spice:
            verdict = ":Incomplete"
            mode = "THERMAL_HIBERNATION_HOLD" if is_cold_nutmeg else "EPHEMERIS_CALIBRATION_HOLD"
        else:
            verdict = ":Accepted"
            mode = "NOMINAL_BIOREACTOR_SCIENCE"

        return {
            "verdict": verdict,
            "mode": mode,
            "cumulative_dose_Gy": state.cumulative_dose_Gy,
            "safing_threshold_Gy": safing_limit,
            "max_allowable_dose_Gy": self.max_allowable_dose_Gy,
            "payload_safing_triggered": is_safing_triggered,
            "ceiling_exceeded": is_ceiling_exceeded,
            "below_280K_nutmeg": is_cold_nutmeg,
            "spice_units_verified": state.spice_units_verified_by_spkpos,
            "quarantined_hypotheses": {
                "unverified_low_dose_radiation_hormesis": ":Incomplete",
                "direct_net_atp_radiosynthesis_without_electron_donor_mass_balance": ":Incomplete",
                "nutmeg_maintenance_power_below_280K": ":Incomplete",
                "unverified_spice_jl_units_prior_to_spkpos_check": ":Incomplete",
            },
        }

    def step_controller(
        self,
        state: ALARAControllerState,
        dt_s: float = 1.0,
    ) -> ALARAActuatorOutput:
        """Execute one LQR/MPC regulation time step, computing u_valve, z_shield, Phi_light."""
        # Update cumulative dose
        eff_dose_rate = self.compute_effective_dose_rate(
            unshielded_dose_rate_Gy_s=state.dose_rate_Gy_s,
            standoff_distance_m=state.standoff_distance_m,
            reference_distance_m=state.reference_distance_m,
            shield_thickness_m=state.shield_thickness_m,
            mu_m_inv=state.linear_attenuation_coeff_mu,
            melanin_fraction=state.melanin_mass_fraction,
            eta_melanin=state.melanin_quenching_efficiency,
        )
        new_cumulative_dose = state.cumulative_dose_Gy + eff_dose_rate * dt_s

        eval_res = self.evaluate_epistemic_hippocratism_quarantine(state)
        mode = eval_res["mode"]
        verdict = eval_res["verdict"]

        # Regulation logic
        if mode == "EMERGENCY_SCRAM_ISOLATE":
            u_valve = 0.0
            z_shield = 0.200  # maximum physical shielding deploy
            phi_light = 0.0
            shutter_closed = True
        elif mode == "SAFE_HOLD_SHUTTER_CLOSED":
            # 80% safing threshold reached: shutter isolated, feed throttled, shield thickened
            u_valve = 0.00005  # 20% maintenance trickle flow
            z_shield = min(0.180, state.shield_thickness_m + 0.025)
            phi_light = 10.0  # minimal safe maintenance photon flux
            shutter_closed = True
        elif mode == "THERMAL_HIBERNATION_HOLD":
            # Sub-280 K: reduce metabolic activity, hold shutter safe
            u_valve = 0.00010
            z_shield = state.shield_thickness_m
            phi_light = 5.0
            shutter_closed = True
        else:
            # Nominal bioreactor science: PI regulation around setpoints
            dose_fraction = new_cumulative_dose / self.safing_threshold_Gy
            # Dynamic shield thickness adjustment: baseline 0.100 m, thickening as dose increases
            z_shield = 0.100 + 0.035 * max(0.0, min(1.0, dose_fraction))
            # Nominal Vogel's medium flow rate: 0.00025 m^3/s (0.25 L/s)
            u_valve = 0.00025 * (1.0 - 0.20 * max(0.0, min(1.0, dose_fraction)))
            # Photoentrainment flux (circa 45 umol/(m^2*s)) modulated by circadian phase
            phi_light = max(0.0, 45.0 * (1.0 + 0.5 * math.cos(state.circadian_phase_rad)))
            shutter_closed = False

        yields = self.compute_radiolytic_yields(
            eff_dose_rate, state.melanin_mass_fraction
        )

        return ALARAActuatorOutput(
            u_valve_m3_s=round(u_valve, 6),
            z_shield_m=round(z_shield, 4),
            Phi_light_umol_m2_s=round(phi_light, 2),
            controller_mode=mode,
            epistemic_status=verdict,
            safing_shutter_closed=shutter_closed,
            cumulative_dose_Gy=round(new_cumulative_dose, 6),
            safing_threshold_Gy=self.safing_threshold_Gy,
            max_allowable_dose_Gy=self.max_allowable_dose_Gy,
            diagnostics={
                "effective_dose_rate_Gy_s": eff_dose_rate,
                "radiolytic_yields": yields,
                "quarantine_summary": eval_res,
            },
        )
