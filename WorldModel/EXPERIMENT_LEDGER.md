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

## 5 — Goal-conditioned MPC/CEM planning success (Phase B) (2026-07-20, commit <pending>)
- Category: Benchmark
- Hypothesis: the last of the three decision-rule anchors — can the JEPA's latent dynamics be *used* to plan
  actions that reach a goal in the *true* environment? A latent CEM planner scored against the true synthetic_1f
  dynamics measures control-usefulness, not just prediction accuracy.
- Prediction: well-formed (success_rate ∈ [0,1], mean_final_distance ≥ 0, deterministic); on a well-trained model
  MPC beats a random-action baseline (an undertrained *smoke* model: MPC ≈ random).
- Implementation: `WorldModel/forward_eval.py` — `_encode_states` (render → normalize-on-TRAIN-stats → encode;
  online encoder for start, target encoder for goal), `_cem_plan` (CEM over horizon-step action sequences,
  predictor as the latent forward model, minimize latent distance to the goal; CPU-seeded sampling → deterministic,
  device rollout), `_mpc_success` (per episode: sample start + goal `pos`, CEM-plan, **execute in the true env**
  via `synthetic_1f._step`, score `|final_pos − goal| < tol`; plus a random-action baseline). Panel gains
  `mpc_success{success_rate, mean_final_distance, random_baseline_success}`; `mpc_episodes/mpc_horizon` on
  `evaluate()`. `WorldModel/`-only.
- Evidence: `--smoke-test` → **passed** (deterministic): `mpc=0.17 vs rand 0.17` (1/6 each — undertrained tiny
  model, no planning advantage yet, as predicted), `pred_err=0.039`, `rollout[1→4]=0.043→0.044`, `chi_R²=0.864`.
  Metric plumbing validated; the MPC-beats-random *signal* is a full-model / A/B question.
- Decision: **kept** — all THREE decision-rule anchors (pred/rollout, MPC, factor-recovery incl. chi) are now in
  the panel. **The forward benchmark is complete.**
- Next question: run the **transform A/B** — {none, standardize, symlog, log-band-power, specparam, 1/f-flatten} ×
  {signal, nuisance} × multi-seed through `evaluate()`, keeping a transform only if it improves rollout+MPC WITHOUT
  degrading chi-recovery. A negative result is the target-quality outcome. Machinery gap to close first: the arms
  beyond the current default need a `transform` param threaded through the dataset/`evaluate()` path — {log-band-power,
  specparam, 1/f-flatten} require the specparam front-end (Math §11.2); the A/B iteration builds that seam.

## 6 — Transform A/B, arm 1: log-band-power into the encoder (node 33) (2026-07-20, commit <pending>)
- Category: Benchmark
- Hypothesis: (dialectic node 33) feed the JEPA encoder **log-compressed** 1/f spectral state — the log-band-power
  transform applied at the `JEPATransitionDataset` seam — instead of raw z-scored power, and it improves the forward
  metrics (rollout + MPC). "Use the 1/f log-transform *backwards*": validated for numerical safety in Phase A, now
  fed to the encoder and measured forward.
- Prediction: the README predicted log-compression would **degrade chi-recovery** — the aperiodic 1/f slope may *be*
  signal (E/I balance), so blindly compressing it could delete the most informative factor. Expected chi_R² to drop;
  a negative result is the target-quality outcome.
- Implementation: `WorldModel/forward_eval.py` — threaded `log_features`/`log_epsilon` (reusing `eeg_jepa`'s
  `JEPATransitionDataset(log_features=…)`) through `evaluate()` into ALL THREE dataset constructions — train (`:358`),
  `_multi_step_rollout` (`:223`), `_encode_states` (`:261`) — so train/rollout/MPC encode in ONE input space (a
  mismatch would train on log windows while rollout/MPC feed raw). Added `--log-features`/`--log-epsilon` CLI +
  `config.log_features` in the panel; smoke-test asserts the log-on path stays finite. `WorldModel/`-only. A/B:
  {log off/on} × {signal, nuisance} × seeds {0,1,2}, n=384, 22 epochs, CPU.
- Evidence: log ON vs OFF (means over 3 seeds):
  - `rollout_error` 0.0079 → 0.0108 — **+37%, WORSE** (both modes).
  - `mpc_success` 0.375 → 0.354 (signal, WORSE); 0.396 → 0.396 (nuisance, neutral).
  - `chi_R²` 0.950 → **0.987** (+0.036, **BETTER**, both modes).
  The prediction was **wrong on chi**: log-compression *helps* chi-recovery (log-power is linear in the 1/f exponent,
  so the linear probe reads chi more easily) — it does not delete it.
- Decision: **REJECT — `log_features` stays default OFF.** It fails the rule (must improve rollout+MPC without
  degrading chi; instead it degrades rollout+MPC while *improving* chi). The real finding is a clean dissociation:
  the transform improves a **static linear factor-probe** (chi) yet **hurts the forward dynamics + control** the world
  model actually needs. A transform that looks good on a linear probe can be wrong for the objective — exactly what
  the forward benchmark exists to catch; a probe-only eval would have wrongly promoted it.
- Next question: WHY does log help the chi-probe but hurt rollout/MPC? Hypothesis: the true `synthetic_1f._step` is
  affine in raw power, so log warps the local dynamics geometry the predictor relies on. Remaining arms {standardize,
  symlog, specparam periodic+aperiodic, 1/f-flatten} — do any improve BOTH forward metrics AND chi? {specparam,
  1/f-flatten} still need the specparam front-end (Math §11.2). Provisional: raw z-scored power may already be the
  right encoder input for forward dynamics.

## 7 — Transform A/B, arm 2 audit: "standardize" is the baseline, not a treatment (2026-07-21, commit <pending>)
- Category: Document
- Hypothesis: the "standardize" arm listed in node 33's remaining set is a distinct input-space transform to A/B like `log_features`.
- Prediction: n/a — a code audit, not an experiment; the outcome is either a distinct transform to build or a redundancy to retire.
- Implementation: audited the normalization seam `JEPATransitionDataset` (`WorldModel/eeg_jepa.py`). `__init__` (:57) defaults `normalize=True`; with no `mean`/`std` supplied it computes per-feature train stats (`mean = all_states.mean(0)`, `std = all_states.std(0).clamp_min(1e-6)`, :114-115); `__getitem__` z-scores and clamps to `clip_sigma=8.0` (:226). There is no un-standardized path. So the `log_features=OFF` baseline that node 33 calls "raw z-scored" IS standardization.
- Evidence: the default dataset already subtracts the per-feature train mean and divides by the per-feature train std (a `state_dim` vector), which is exactly a z-score standardization; a separate "standardize" arm adds nothing over the control.
- Decision: DROP "standardize" as an A/B arm — it is the control, not a treatment. Node 33's provisional ("raw z-scored power may already be the right encoder input for forward dynamics") therefore stands as the standing result: standardization is already in force and is the baseline every arm is measured against. No code change; documentation only, so no smoke-test needed.
- Next question: the next genuinely-distinct, buildable arm is `symlog` — `sign(x) * log1p(|x|)` — a signed log that, unlike `log_features`, handles the negative z-scored values without an epsilon floor and compresses large-magnitude outliers symmetrically. Integrate it at the `JEPATransitionDataset` seam (mirror the `log_features` threading through `evaluate()`'s three dataset constructions) and A/B {symlog off/on} x {signal, nuisance} x seeds. Remaining after: specparam + 1/f-flatten (still blocked on the specparam front-end, Math §11.2).
