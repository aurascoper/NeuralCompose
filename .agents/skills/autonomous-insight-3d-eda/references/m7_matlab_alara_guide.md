# M7.1-M7.8 MATLAB R2026b 3D EDA, Tarjan Bridge & Health-Physics ALARA Reference

## 1. M7.1 Through M7.8 Stage Architecture vs Data Types (Turn L14 & Turn L16)

- **Container Headers (`String`)**: `"M7.1"` through `"M7.8"` identify the eight discrete stages of the multiscale workbench (`Coordinate/Mesh` -> `OpenFOAM/GLMM` -> `PHREEQC/Menke` -> `Three-Clock/SPICE-Basilisk` -> `Biofilm/NutMEG/Neurospora` -> `Health-Physics ALARA/Hippocratism` -> `Sobolev/Reticulated ASR` -> `4D Explorer/Vizard/MATLAB 3D EDA`).
- **Discrete Indices (`Int64`)**: Cell indices (`1..4`), chamber counts, Cantor leaves (`64`), and Betti numbers (`beta_0`, `beta_1`, `beta_2`).
- **Continuous Observables (`Float64`)**: IEEE-754 double-precision SI physical fields (`PositionVector` in `m`, `VelocityVector` in `m/s`, pressure in `Pa`, temperature in `K`, concentrations in `mol/m^3`, dose rate in `Gy/s`).

## 2. Acyclic Tarjan Bridge Pipeline (Turn L21)

Cross-solver coupling follows a strict directed acyclic graph (`DAG`) where every inter-solver handoff is a **Tarjan bridge edge** (`max_scc_size == 1`, `beta_1_inter_solver == 0`):

`OpenFOAM_FiniteVolume_CFD -> PHREEQC_Geochemical_Speciation -> FlowCytometry_SingleCell_Bridge -> SmallModularBioReactors_Multiscale_ODE -> MATLAB_R2026b_Simulink_Simscape_3D_EDA`

## 3. Health-Physics ALARA & Epistemic Hippocratism (Primum Non Nocere)

- **Time (`Delta_t`)**: Exposure window bounded by `max_safe_exposure_time_s`, with automated payload safing at `80%` of `max_allowable_cumulative_dose_Gy`.
- **Distance (`1/r^2`)**: Inverse-square geometric attenuation `(r_ref / r_standoff)^2` from external Mars Kilopower surface fission bus (`10 m` standoff -> `0.01x` flux).
- **Shielding (`exp(-mu*z)` + Biological Scavenging)**: Composite regolith + water/clay attenuation paired with 4-stage `MelaninResponse` (`Cryptococcus neoformans` and `Neurospora crassa` `frq`/`wc-1`/`wc-2` syncytium).
- **Epistemic Hippocratism**: Unverified low-dose radiation hormesis, direct ATP radiosynthesis without electron-donor mass balance, `T < 280 K` maintenance power, and unverified `SPICE.jl` unit assumptions remain in `:Incomplete` (or quarantined) and are never silently promoted to `:Accepted`.
