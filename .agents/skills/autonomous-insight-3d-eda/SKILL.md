---
name: autonomous-insight-3d-eda
description: >-
  Use this skill when the user asks to run or schedule the ~3-minute (180 s)
  autonomous non-recursive self-improvement poller, integrate real-time
  dialectic insights, audit Health-Physics ALARA and Epistemic Hippocratism,
  or execute the MATLAB R2026b / Simulink / Simscape / ParaView 3D EDA bridge
  across M7.1 through M7.8, SmallModularBioReactors.jl, M7Multiscale, and
  flow-cytometry-model-bridge.
---

# Autonomous Non-Recursive Insight Poller, Health-Physics ALARA & MATLAB 3D EDA Skill

This skill provides the operational procedure for running the ~3-minute (`180 s`)
non-recursive self-improvement poller, integrating real-time voice/dialectic
insights, verifying Health-Physics ALARA (`Time`, `Distance`, `Shielding` +
`Melanin/Neurospora` radioprotection) and Epistemic Hippocratism (`primum non
nocere`), and executing the MATLAB R2026b / Simulink / Simscape 3D Exploratory
Data Analysis (`3D EDA`) workflow across `M7.1` through `M7.8`.

## Workflow Steps

1. **Execute Single-Pass Non-Recursive Poller & MATLAB R2026b 3D EDA Verification**:
   Run the bundled helper script:
   [run_3min_insight_poller_and_matlab_3d_eda.sh](./scripts/run_3min_insight_poller_and_matlab_3d_eda.sh)

2. **Schedule Recurring ~3-Minute (`180 s`) Autonomous Poller**:
   Use Antigravity's native `schedule` tool (`DurationSeconds: 180` for a
   one-shot 3-minute check or `CronExpression: "*/3 * * * *"` for recurring
   3-minute cycles; never use shell `sleep`):
   - Verify `recursion_depth == 0` and `consolidation_rule_immutable == true`
     in `/Users/aurascoper/Documents/NeuralCompose/InteractionLogs/poller-self-improvement-synthesis-v2.json`.
   - Verify live swap/compressor headroom (`sysctl vm.swapusage` free >= 256 MB).

3. **Verify MATLAB R2026b + Simulink/Simscape 3D EDA Receipt & Figure**:
   - Inspect `matlab_fixtures/m7_matlab_r2026b_verification_receipt.json` and
     confirm `all_checks_passed == true`, `all_14_student_suite_toolboxes_present == true`,
     `m7_schema_headers_vs_types_valid == true`, `tarjan_bridge_dag_valid == true`,
     and `health_physics_alara_valid == true`.
   - Confirm `matlab_fixtures/m7_3d_eda_spatiotemporal_summary.png` has dimensions
     at least `1920x1080`.

4. **Consult Detailed Reference Architecture**:
   Read [m7_matlab_alara_guide.md](./references/m7_matlab_alara_guide.md) when
   troubleshooting `M7.1..M7.8` stage schemas, `SPICE.jl` (`km`, `km/s`) to
   `Basilisk` (`m`, `m/s`) unit conversions, Selfish-Gene vs Nathaniel Comfort
   reticulated ASR (`beta_1 >= 1`), or Health-Physics ALARA / Epistemic
   Hippocratism gates.
