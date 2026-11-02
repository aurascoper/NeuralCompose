# Project: NeuralCompose Master Event Contract and Cross-Subsystem Plan

## Architecture
The system establishes a formal, schema-validated Master Event Contract and directional logic gates connecting four subsystems:
1. NeuralCompose Functorial Fixtures:
   - Functor F: NetGraph -> PhaseHull over 60 benchmark frames
   - FourPillarFrameRecord (Pillar 1 Laya, Pillar 2 ST-JEMA, Pillar 3 Memory Dialectic, Pillar 4 Musical Laya)
   - 4 Defect Axes in multica_channel.jsonl (Boundary, Control, Source, Coordination)
   - Live sensor toy drive
2. Momentum Automata Criticality Engine:
   - OrderBookCriticalityEngine (k_eff, rho_pcm, z_crit, chi)
   - Hysteresis loop area and dual-band MOMENTUM_RETENTION_POOL
   - WBR scaffolding modes (Focus, Frustration, Panic)
   - Topological Betti numbers (beta_0 = 1, beta_1 in [2..9]) and phase transitions
3. Multi-Pool Reactor Hydraulics and Geochemical Speciation:
   - N_pool = 8 modular chambers in SmallModularBioReactors.jl (vogels_pool_1 .. vogels_pool_8)
   - Aerobic Vogel's minimal medium sucrose gradient (55.0 to 31.6 mol/m^3)
   - USGS PHREEQC activity-averaged pH and electrical charge balance (imbalance <= 1.0%)
   - Radiolytic H2O2 radical scavenging and DHN-melanin quenching (eta = 0.35)
   - NutMEG maintenance power gate quarantined below 280 K
4. Syncytial Hyphal Biofilm and Circadian Gating:
   - Neurospora crassa circadian frq / wc-1 / wc-2 oscillator (3-variable ODE in ode15s) and phase phi(t)
   - Cytoplasmic streaming (5 to 60 um/s mass flow) and HEX-1 Woronin body septal plugging
   - Anastomosis network topology (beta_0 = 1, beta_1 >= 1 Int64, B_i <= 1.20 kg/m^3, rho_tip_i, phi_EPS_i, tau_w_i)

Cross-Solver Bridge Orchestration:
Acyclic Tarjan DAG (OpenFOAM -> PHREEQC -> FlowCytometry -> SmallModularBioReactors -> MATLAB) with max_scc_size == 1, beta_1_inter_solver == 0, and recursion_depth == 0.

Closed-Loop ALARA Control:
Enforces 80% payload safing threshold (0.040 Gy of 0.050 Gy limit) and Epistemic Hippocratism 3-valued quarantine (:Accepted, :Incomplete, :Rejected).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Functorial Fixtures | NetGraph -> PhaseHull functor, FunctorFrameRecord, 60-frame cycle | M1 | survey 1 |
| 2 | FourPillarFrameRecord | Four-pillar representation (Laya, ST-JEMA, Memory Dialectic, Musical Laya) | M1 | survey 1 |
| 3 | Defect Axes Schema | 4 defect axes: Boundary, Control, Source, Coordination | M1 | survey 1 |
| 4 | Live Sensor Toy Drive | Accelerometer/gyroscope/RMS cadence toy drive coupling | M1 | survey 1 |
| 5 | OrderBookCriticalityEngine | k_eff, rho_pcm, z_crit, chi, and criticality regimes | M1 | survey 1 |
| 6 | Category Type Separation | String container headers, Int64 indices/Betti numbers, Float64 continuous SI | M1 | survey 3 |
| 7 | Hysteresis Loop Area | Shoelace integral |oint D_M d(beta_1)| > 4.0 and retention pool | M1 | survey 1 |
| 8 | WBR Scaffolding Modes | Focus (<=1.8), Frustration (1.8-2.45), Panic (>2.45) | M1 | survey 1 |
| 9 | Logic Gates G1-G7 | Formal transition evaluation across S1-S4 envelopes | M1 | survey 1 & 3 |
| 10 | Acyclic Tarjan Solver DAG | OpenFOAM->PHREEQC->FlowCytometry->SMBR->MATLAB (max_scc=1, beta_1=0) | M1 | survey 3 |
| 11 | Non-Recursive Invariant | recursion_depth == 0 enforcement | M1 | survey 3 |
| 12 | 8-Pool Reactor Hydraulics | N_pool = 8 chambers, V_i = 0.25 L, Q = 2.5e-4 L/s, tau_res = 1000 s | M1 | survey 2 |
| 13 | Vogel's Minimal Medium | Sucrose gradient (55.0 to 31.6 mol/m^3), T profile (298.15 to 298.31 K) | M1 | survey 2 |
| 14 | PHREEQC Speciation | Activity-averaged pH (-log10(mean(10^-pH))), charge imbalance <= 1.0% | M1 | survey 2 |
| 15 | Radiolytic Scavenging | G-values, DHN-melanin quenching eta=0.35, H2O2 scavenged 18.5 to 13.6 uM | M1 | survey 2 |
| 16 | Neurospora Circadian ODE | frq/wc-1/wc-2 3-variable ODE, tau_DD=22.5h, tau_LD=24.0h, phase phi(t) | M1 | survey 2 |
| 17 | Cytoplasmic Streaming & HEX-1 | 5-60 um/s mass flow, Woronin body HEX-1 emergency septal pore plugging | M1 | survey 2 |
| 18 | Anastomosis Topology | beta_0=1, beta_1>=1 Int64, B_i<=1.2 kg/m^3, rho_tip_i, phi_EPS_i, tau_w_i | M1 | survey 2 |
| 19 | Conservative CA Biomass | Biomass redistribution conserving total mass (residual < 1e-12) | M1 | survey 2 |
| 20 | NutMEG Quarantine Gate | T < 280 K quarantined as :Incomplete; never collapsed to :Rejected | M1 | survey 2 |
| 21 | Health-Physics ALARA Safing | 80% payload safing threshold (0.040 Gy of 0.050 Gy) automated safing trip | M1 | survey 3 |
| 22 | Simulink Closed-Loop Control | LQR/MPC state-space regulation (u_valve, z_shield, Phi_light) | M1 | survey 3 |
| 23 | Epistemic Hippocratism Gate | 3-valued quarantine (:Accepted, :Incomplete, :Rejected) across all hypotheses | M1 | survey 3 |
| 24 | Synthetic Event Round-Trip | Programmatic round-trip parsing and validation across all 4 subsystems | M1, M2 | original req |
| 25 | E2E Opaque-Box Test Suite | Tiers 1-4 comprehensive test suite passing 100% | M2 | project pattern |
| 26 | Typographic Hygiene | Zero en-dash and zero em-dash verification across all artifacts | M1, M2 | user rules |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Master Event Contract & Logic Gates Implementation | Formal JSON Schema, logic gates G1-G7, Tarjan DAG, ALARA safing, Epistemic Hippocratism, and synthetic event round-trip | none | DONE |
| M2 | E2E Test Suite Pass & Adversarial Hardening | Comprehensive Opaque-Box Test Suite (Tiers 1-4, 270 tests) passing 100%, and adversarial hardening | M1 | DONE |

## Code Layout
Existing layout in /Users/aurascoper/Developer/NeuralCompose:
- `configs/`: Master Event Contract schemas (`master_event_contract_schema_v1.json`)
- `Scripts/functor-hud/`: Functorial fixtures and dialectical HUD scripts
- `Developer/live_trading/`: Momentum Automata criticality engine and hysteresis tests
- `Sources/BCICore/`: Core Swift library and composition pipelines
- `Tests/BCICoreTests/`: Swift test targets
- Implementation files owned by Worker:
  - `configs/master_event_contract_schema_v1.json`
  - `Scripts/contracts/master_event_contract.py`
  - `Scripts/contracts/logic_gates_evaluator.py`
  - `Scripts/contracts/tarjan_bridge_verifier.py`
  - `Scripts/contracts/alara_closed_loop_controller.py`
  - `Scripts/contracts/synthetic_event_round_trip.py`
- Test files owned by Test Writer:
  - `tests/e2e/test_master_event_contract_e2e.py`
  - `tests/e2e/run_all_e2e_tests.py`
  - `TEST_READY.md`
