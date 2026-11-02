# Worker Fix Dispatch: Remediation of Reviewer Findings (Iteration 2)

## Mandatory Reading
Read `/Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/ORIGINAL_REQUEST.md` before starting work.
Read `/Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/reviewer_1/handoff.md` and `/Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/reviewer_2/handoff.md`.

## Mandatory Integrity Warning
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

## Remediation Tasks

1. Subsystem ID Normalization in `Scripts/contracts/logic_gates_evaluator.py`:
   In `LogicGatesEvaluator.evaluate_transition`, lines 648, 675, 690:
   Normalize subsystem identifiers:
   ```python
   s_norm = s_sub.replace("_", "").lower()
   t_norm = t_sub.replace("_", "").lower()
   if "neuralcompose" in s_norm and "momentumautomata" in t_norm:
       ...
   elif "momentumautomata" in s_norm and "reactorpools" in t_norm:
       ...
   elif "reactorpools" in s_norm and ("biofilmsessions" in t_norm or "biofilm" in t_norm):
       ...
   ```
   Ensure canonical underscored IDs ("S1_NeuralCompose_Functorial_Fixtures", "S2_Momentum_Automata_Criticality_Engine", "S3_Reactor_Pools_SMBR_OpenMC_MATLAB", "S4_Biofilms_Sessions_Neurospora_M7_Workbench") are properly recognized and evaluated by the transition defect gates.

2. IEEE-754 Precision Boundary Rounding in `Scripts/contracts/alara_closed_loop_controller.py`:
   In `ALARAClosedLoopController.__init__`:
   ```python
   self.safing_threshold_Gy = round(self.safing_fraction * self.max_allowable_dose_Gy, 9)
   ```
   In `step_controller` and `evaluate_epistemic_hippocratism_quarantine`:
   Ensure `state.cumulative_dose_Gy >= self.safing_threshold_Gy - 1e-12` so that exact `0.0400` Gy trips safing shutter closure (`safing_shutter_closed = True`, `mode = "SAFE_HOLD_SHUTTER_CLOSED"`, `epistemic_status = ":Incomplete"`).

3. Remediate Facade Tests and Boundary Assertions in `Tests/e2e/test_master_event_contract_e2e.py` and `tests/e2e/test_master_event_contract_e2e.py`:
   - Replace `test_t2_f24_04_en_dash_in_schema_rejected` with a genuine test that writes a temporary schema file with an en-dash (`\u2013`) and asserts that `load_master_event_contract_schema` raises `ValueError`.
   - Update `test_t2_f24_03_em_dash_in_schema_rejected` to write a temporary schema file with an em-dash (`\u2014`) and assert that `load_master_event_contract_schema` raises `ValueError`.
   - Update `test_t2_f20_02_dose_at_0_0400_safing_triggered` to test exact `cumulative_dose_Gy = 0.0400`.
   - Add negative transition tests in Tier 3:
     - S1 -> S2 with D_M = 3.0 trips Control defect and marks status `:Incomplete`.
     - S1 -> S2 with beta_0 = 2 trips Coordination defect and marks status `:Rejected` (`transition_valid = False`).
     - S2 -> S3 with T = 250.0 K trips Source defect and marks status `:Incomplete`.
     - S3 -> S4 with streaming velocity 65.0 um/s trips Boundary defect and marks status `:Rejected`.
     - S3 -> S4 with anastomosis beta_0 = 2 trips Coordination defect and marks status `:Rejected`.

4. Path Portability:
   Ensure `tests/e2e/run_all_e2e_tests.py` and `pytest` work whether invoked as `tests/e2e` or `Tests/e2e`.

5. Run Verification Commands:
   - `python3 tests/e2e/run_all_e2e_tests.py`
   - `python3 Scripts/contracts/synthetic_event_round_trip.py --json`
   - `python3 Scripts/verify_master_event_contract_gates.py`

6. Verify Typographic Hygiene:
   - Strictly zero em-dashes and zero en-dashes across all files.

7. Write handoff report to `/Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/worker_fix/handoff.md`.

## Exclusive Write Ownership
- `Scripts/contracts/logic_gates_evaluator.py`
- `Scripts/contracts/alara_closed_loop_controller.py`
- `tests/e2e/test_master_event_contract_e2e.py`
- `Tests/e2e/test_master_event_contract_e2e.py`
- `tests/e2e/run_all_e2e_tests.py`
- `TEST_READY.md`


## 2026-11-02T11:09:39Z
[Message] timestamp=2026-11-02T11:09:39Z sender=242da2ff-57a0-4645-9652-7eafacb5b726 priority=MESSAGE_PRIORITY_HIGH content=You are Remediation Worker (worker_fix) for Iteration 2.
Your Working Directory: /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/worker_fix/
Authoritative User Request: /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/ORIGINAL_REQUEST.md
Read ORIGINAL_REQUEST.md first before doing anything else.
Project Scope: /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/orchestrator_1/PROJECT.md
Reviewer 1 Handoff: /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/reviewer_1/handoff.md
Reviewer 2 Handoff: /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/reviewer_2/handoff.md
Task details are also in: /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/worker_fix/DISPATCH.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Your exclusive write ownership:
- Scripts/contracts/logic_gates_evaluator.py
- Scripts/contracts/alara_closed_loop_controller.py
- tests/e2e/test_master_event_contract_e2e.py
- Tests/e2e/test_master_event_contract_e2e.py
- tests/e2e/run_all_e2e_tests.py
- TEST_READY.md

Your mission:
1. Normalize subsystem ID matching in Scripts/contracts/logic_gates_evaluator.py (evaluate_transition) so canonical underscored IDs are recognized.
2. Fix IEEE-754 precision boundary rounding in Scripts/contracts/alara_closed_loop_controller.py so exact 0.0400 Gy trips safing shutter closure.
3. Replace facade tests in test_master_event_contract_e2e.py (test_t2_f24_03 and test_t2_f24_04) with genuine tests using temporary files with forbidden dashes asserting ValueError. Update test_t2_f20_02 to test exact 0.0400 Gy. Add negative transition tests.
4. Ensure path portability between tests/e2e and Tests/e2e.
5. Run full test suite, verify 100% pass, verify zero em-dashes and zero en-dashes.
6. Write handoff to /Users/aurascoper/Developer/NeuralCompose/.agents/teamwork/worker_fix/handoff.md and notify orchestrator.

Constraints:
- Strictly zero em-dashes and zero en-dashes across all code, docstrings, JSON, test output, and messages.
- Update progress.md with timestamps for heartbeat liveness.
