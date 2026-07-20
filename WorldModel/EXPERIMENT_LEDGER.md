# WorldModel Experiment Ledger

The durable, reviewable record for the WorldModel `/loop` (see
`~/.claude/plans/check-recent-commits-and-cosmic-babbage.md` for the contract). One entry per milestone —
captures *why* the work happened, not just *what* changed. A **negative result is a successful experiment.**

Sequence: **Integrate → Benchmark → Optimize → Stop.** The loop resumes from the last entry below.

Entry template:
```
## <n> — <short title>  (<date>, commit <sha>)
- Category: Integrate | Benchmark | Test | Optimize | Document
- Hypothesis:
- Prediction:
- Implementation:      (files touched; provenance: ported-from / reason / differences)
- Evidence:            (measured numbers — smoke-test result and/or benchmark metric vs baseline)
- Decision:            (kept / rejected / deferred — and why)
- Next question:
```

---

## 0 — Groundwork (2026-07-20, commit <pending>)
- Category: Document
- Hypothesis: n/a — establishing the scientific grounding + ledger before touching code.
- Implementation: added `WorldModel/RESEARCH_spectral_geometry.md` (the deep-research brief distilled: 1/f may
  be *signal*; the forward metric panel; the decision rule; geometry as a future/out-of-scope direction) and
  this ledger.
- Evidence: n/a (docs only).
- Decision: kept — the loop reads the research doc rather than re-deriving it.
- Next question: Phase A — cherry-pick the backward-validated 1/f transform (`0102e19` clip_sigma → `d3898c2`
  1/f) onto the working branch, prove default-off = identity, and document that "validated" is *backward
  only* (safe, not beneficial).

## 1 — Integrate the 1/f transform (Phase A) (2026-07-20, commits fa7647b + ea0afbc)
- Category: Integrate
- Hypothesis: the transform can be brought onto the working branch without changing default behavior
  ("default-off = identity"), preserving its backward-validation guards.
- Prediction: cherry-picks apply cleanly (both touch only `eeg_jepa.py`); smoke-test stays green; default
  outputs are unchanged for well-behaved data.
- Implementation: `git cherry-pick 0102e19` (clip_sigma cap) → `git cherry-pick d3898c2` (1/f log-transform),
  authorship preserved. Provenance: ported-from `fix/preflight-gates-2-3`; reason = reuse the
  backward-validated normalizer; differences = none (clean cherry-pick, no conflicts).
- Evidence:
  - `python WorldModel/eeg_jepa.py --smoke-test` → **passed** (finite under log(0), bounded by clip_sigma,
    export round-trip — the log-feature path included).
  - Golden-vector identity: on deterministic `_smoke_record` data, `default(clip=8, log=off)` ≡ `no-clip`
    (**identical=True**, `max|z|=1.617 ≪ 8`); mean/std raw-space identical (log off). → **default = identity in
    practice**; `clip_sigma` fires only for >8σ near-dead-channel outliers (its intended guard).
- Decision: **kept** (default-off, integrated). Status labelled **"hypothesis under test," not "validated"** —
  the only evidence is *backward* (safe), never *forward* (beneficial). README + research doc updated to say so.
- Next question: Phase B — build a controllable synthetic 1/f generator (dial-able aperiodic exponent + known
  latent factors) and the forward metric panel, so the transform can finally be A/B'd on a *forward* number,
  with the aperiodic-exponent-recovery guard. **A negative result ("log-compression hurts on 1/f-dependent
  factors") is the target-quality outcome.**

## 2 — Synthetic 1/f generator (Phase B) (2026-07-20, commit <pending>)
- Category: Benchmark
- Hypothesis: a controllable synthetic generator with a dial-able aperiodic exponent + known factors makes
  "is 1/f signal or nuisance?" *measurable* on synthetic data (no hardware).
- Prediction: the aperiodic exponent `chi` is linearly recoverable from the rendered observation (a well-posed
  factor-recovery target); `mode="signal"` couples chi to the dynamics, `mode="nuisance"` does not.
- Implementation: `WorldModel/synthetic_1f.py` — emits `JEPATransition` JSONL (the schema
  `eeg_jepa.JEPATransitionDataset` reads), latent `{pos, vel, chi, peak_amp, offset}`, `signal`/`nuisance`
  modes, band power(f)=10^offset·f^(−chi)(+alpha peak); ground-truth factors attached under `_latent` (ignored
  by the dataset, read by the Phase-B probes).
- Evidence: `venv/bin/python WorldModel/synthetic_1f.py --smoke-test` → **passed**: deterministic under seed;
  `JEPATransitionDataset` loads it (state shape (5,5)); **chi-recovery R²=0.690** (target well-posed);
  signal-mode chi changes post-velocity, nuisance-mode does not (`|Δvel|<1e-9`).
- Decision: kept — the generator is the Phase-B substrate for the A/B.
- Next question: build the **forward metric panel** as a runnable eval over a JEPA trained on this synthetic
  data — latent multi-step rollout error, goal-conditioned MPC success, linear-probe factor recovery
  (**including an aperiodic-exponent probe**), RankMe/α-ReQ/LiDAR, VICReg var/cov, alignment/uniformity.

## 3 — Forward metric panel v1 (Phase B) (2026-07-20, commit <pending>)
- Category: Benchmark
- Hypothesis: a runnable forward-eval panel over a JEPA trained on `synthetic_1f` data makes the transform A/B
  measurable on *forward* numbers (prediction, factor recovery incl. chi, geometry), not just backward safety.
- Prediction: deterministic under seed; the aperiodic exponent `chi` is recoverable from the JEPA latent
  (well-posed information-destruction detector); geometry metrics finite + in range.
- Implementation: `WorldModel/forward_eval.py` — trains `eeg_jepa.EEGJEPAModule` on freshly-generated
  `synthetic_1f` transitions, then reports: `pred_error_1step` (predictor vs EMA-target-encoder latent MSE);
  held-out linear-probe R² per known factor {pos,vel,chi,peak_amp,offset} **incl. the chi probe**; RankMe
  (Garrido 2023); α-ReQ (Agrawal 2022); VICReg var/cov; alignment/uniformity (Wang & Isola). Reuses
  `train_jepa` + `JEPATransitionDataset` + `synthetic_1f.generate` — no new model. Provenance: ported-from =
  none (new); reason = the eval must exist before any transform change (evidence gate); differences = n/a.
  Scoped to `WorldModel/` (no `Sources/`, no BCI*, no network).
- Evidence: `venv/bin/python WorldModel/forward_eval.py --smoke-test` → **passed**: deterministic (identical
  loss 0.135→0.067→0.035 across two runs); `pred_err=0.039`, `RankMe=4.42` (∈(0,16]), **chi_R²=0.864**,
  `pos_R²=0.609`. → the JEPA latent **preserves the aperiodic exponent well** (0.864 vs 0.690 from the raw
  observation) — the forward baseline the A/B must not degrade.
- Decision: **kept** — the panel is the Phase-B forward-eval substrate. `evaluate()` is the reusable entry point.
- Next question: extend the panel with the two DEFERRED metrics the decision rule also anchors on — (a)
  **multi-step latent rollout error** (needs a sequential-trajectory synthetic generator) and (b)
  **goal-conditioned MPC/CEM planning success** (needs a latent-space planner + true-env rollout) — plus LiDAR.
  Then run the transform A/B {none, standardize, symlog, log-band-power, specparam, 1/f-flatten} × {signal,
  nuisance} × multi-seed through `evaluate()`, keeping a transform only if it improves pred/rollout+MPC WITHOUT
  degrading chi-recovery. **A negative result there is the target-quality outcome.**

## 4 — Multi-step latent rollout (Phase B) (2026-07-20, commit <pending>)
- Category: Benchmark
- Hypothesis: the panel needs a *multi-step* (not just 1-step) forward number; a closed-loop latent rollout over
  sequential-trajectory synthetic data measures how prediction error compounds — one of the two metrics the
  transform-A/B decision rule anchors on (alongside factor recovery; MPC-success still to come).
- Prediction: deterministic under seed; 1-step rollout error ≈ `pred_error_1step` (both 1-step MSE); error
  grows-or-holds with horizon.
- Implementation: `WorldModel/forward_eval.py` — `_generate_trajectories` (n chained single-step transitions per
  trajectory, reusing `synthetic_1f._sample_latent/_step/_render_state`) + `_multi_step_rollout` (encode the first
  window, roll the predictor *closed-loop* with the true actions, MSE each horizon vs the EMA-target encoding;
  trajectory windows z-scored on the **TRAIN** mean/std so they live in the JEPA input space). Added
  `rollout_error{per_horizon, step1, final_step, mean}` to the panel + `rollout_traj/rollout_len` params on
  `evaluate()`. Provenance: new; reuses `train_jepa` + `JEPATransitionDataset(mean,std)` + the synthetic_1f
  dynamics. `WorldModel/`-only, no Sources/, no network.
- Evidence: `venv/bin/python WorldModel/forward_eval.py --smoke-test` → **passed** (deterministic): `pred_err=0.039`,
  **`rollout[1→4]=0.043→0.044`** (step1 ≈ pred_err_1step ✓; near-flat → the latent dynamics are stable over 4 steps
  on this generator), `rankme=4.42`, `chi_R²=0.864` (unchanged).
- Decision: **kept** — `rollout_error` is the second forward number for the A/B.
- Next question: add **goal-conditioned MPC/CEM planning success** in latent space (needs a latent-space planner +
  a true-env rollout) — the last decision-rule anchor. THEN run the transform A/B × {signal, nuisance} × multi-seed
  through `evaluate()`.
