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

## 8 — Transform A/B, arm 3: symlog into the encoder (node 7 follow-through) (2026-07-21, commit <pending>)
- Category: Integrate
- Hypothesis: symlog — `sign(x) * log1p(|x|)` — log-compresses the heavy-tailed powers like `log_features` but, because `log1p(0)=0`, avoids the epsilon-floor artifact where a zero/near-dead channel maps to `log(1e-6) ~= -13.8`, a large negative outlier the z-score amplifies. If node 33's rollout/MPC harm came from those epsilon outliers (not from log-compression per se), symlog may recover the chi benefit WITHOUT the forward-metric harm.
- Prediction: (measured next fire) symlog improves or matches chi vs the standardized baseline while keeping rollout+MPC at least as good as baseline — the pass condition. If it degrades rollout/MPC like `log_features` did, the harm is intrinsic to log-compression, not the epsilon floor.
- Implementation: added `symlog` to `JEPATransitionDataset` (`WorldModel/eeg_jepa.py`) as a mutually-exclusive-with-`log_features` transform applied pre-normalization (`sign * log1p` on pre/post windows; stats then computed in symlog-space so `__getitem__` normalizes the transformed windows). Threaded `symlog` through `evaluate()` and ALL THREE dataset constructions (train, `_multi_step_rollout`, `_encode_states`/MPC) so train/rollout/MPC share ONE input space. Added `--symlog` CLI + `config.symlog` in the panel + a smoke assertion that the symlog path stays finite end-to-end. `WorldModel/`-only, two files. Smoke test passes with the symlog arm exercised.
- Evidence: `venv/bin/python WorldModel/forward_eval.py --smoke-test` passes with symlog=True run finite (pred_err/chi/rollout all finite); full A/B pending (launched to background this fire).
- Decision: PENDING — Benchmark next fire. A/B {symlog off/on} x {signal, nuisance} x seeds {0,1,2}, n=384, 22 epochs, CPU. Keep symlog ONLY if it improves rollout+MPC without degrading chi (same rule as node 33).
- Next question: compare symlog's A/B against node 33's `log_features` numbers (rollout 0.0079 -> 0.0108 WORSE, chi 0.950 -> 0.987 BETTER). Does symlog's zero-preserving log recover the chi gain without the rollout/MPC harm?

## 9 — Transform A/B, arm 3 benchmark: symlog is forward-metric-neutral (2026-07-21, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 8) symlog recovers log_features' chi gain WITHOUT its rollout/MPC harm, because `log1p(0)=0` removes the epsilon-floor outlier that `log_features` created at dead channels.
- Prediction: symlog improves-or-matches chi while keeping rollout+MPC at least as good as the standardized baseline.
- Implementation: ran {symlog off/on} x {signal, nuisance} x seeds {0,1,2}, n=384, 22 epochs, CPU (background nohup, 12 cells).
- Evidence (pooled OFF -> ON, +/- is seed pstdev):
  - rollout_mean 0.0120+/-0.0022 -> 0.0122+/-0.0015 (delta +0.0002 — an order of magnitude BELOW the +/-0.0022 seed noise: NO significant change; NOT the +37% harm log_features caused).
  - mpc_success 0.342+/-0.151 -> 0.358+/-0.137 (delta +0.017, within the large +/-0.15 noise — directionally up, not significant).
  - chi 0.9501+/-0.0026 -> 0.9545+/-0.0055 (delta +0.0044; chi is the tightest metric — a small consistent gain).
  Contrast with node 33 log_features: rollout +37% WORSE, MPC worse. symlog's forward-metric harm is GONE.
- Decision: DO NOT PROMOTE — symlog stays default OFF, but for a DIFFERENT reason than log_features: not because it harms the forward metrics (it does not — they are flat within noise) but because it does not clearly IMPROVE them (the keep-bar). Chi-only improvement is insufficient (node 33's lesson: the forward metrics are the objective, not the linear probe). The node-8 hypothesis is CONFIRMED: the epsilon floor was the source of log_features' rollout harm — removing it (symlog) drops the rollout degradation from +37% to ~0.
- Next question: two arms remain — specparam (periodic+aperiodic) and 1/f-flatten — both blocked on the specparam front-end (Math §11.2), a larger build than a one-line transform. Accumulating result across arms: standardize = baseline (node 7), log_features = reject (node 33), symlog = neutral (node 9) — NO input-space transform has yet improved the forward metrics over the standardized baseline, strengthening node 33's provisional "raw z-scored power is already the right encoder input for forward dynamics." Decide next fire: build the specparam front-end, or declare the transform-A/B line converged (raw z-score wins) and pivot.

## 10 — Pivot to MPC: expose CEM knobs (user redirect) (2026-07-21, commit <pending>)
- Category: Integrate
- Hypothesis: (user redirect, live overnight comm) the transform-A/B line has converged — no input-space transform beats raw z-score (nodes 7/33/9) — so pivot to the WEAKEST forward metric: MPC success barely beats random (~0.34 vs ~0.33). Hypothesis: this is partly a PLANNER-BUDGET limit — the CEM defaults (cem_iters=3, n_samples=64) under-search the action space, so more CEM iterations/samples should lift success WITHOUT touching the predictor.
- Prediction: raising cem_iters and n_samples improves mpc_success (more planning compute finds better action sequences), up to the ceiling set by predictor quality.
- Implementation: exposed the CEM knobs (mpc_cem_iters, mpc_n_samples, mpc_elite_frac) through evaluate() and the CLI (they were hardcoded in _mpc_success at 3/64/0.2); added them to the config panel for provenance. WorldModel/forward_eval.py only. Smoke test passes (defaults unchanged).
- Evidence: single-seed sanity (n=128, 10 episodes, 8 epochs, signal): base (3/64) MPC=0.300 vs rand 0.200; tuned (cem_iters=8, n_samples=192) MPC=0.400 vs rand 0.200 — +0.10 from more planning budget, same predictor. Directionally promising but noisy (1 seed, small n).
- Decision: PENDING — proper A/B next fire. Launched a background CEM sweep {default (3/64) vs tuned (8/192)} x {signal, nuisance} x seeds {0,1,2}, n=384, 22 epochs. Keep the tuned CEM as the MPC-eval default ONLY if it lifts mpc_success beyond seed noise without hurting rollout/chi.
- Next question: does the CEM-budget lift survive multi-seed at full scale? If yes, the MPC weakness was under-planning (cheap fix — more CEM budget). If the lift vanishes at scale, the ceiling is the PREDICTOR's latent dynamics, not the planner — which redirects to predictor quality (longer training / better encoder), a bigger lever.

## 11 — MPC CEM-budget sweep: the planner is NOT the bottleneck (2026-07-21, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 10) more CEM budget (cem_iters 3->8, n_samples 64->192) lifts mpc_success — the barely-beats-random MPC is under-planning.
- Prediction: tuned CEM improves mpc_success beyond seed noise (single-seed sanity had shown 0.30 -> 0.40).
- Implementation: A/B {default(3,64) vs tuned(8,192)} x {signal, nuisance} x seeds {0,1,2}, n=384, 22 epochs (background, 12 cells).
- Evidence: mpc_success default=0.342+/-0.151 vs tuned=0.325+/-0.144 (delta -0.017, WITHIN the +/-0.15 seed noise — NO lift; if anything marginally down). rollout/chi unchanged (CEM knobs do not touch training). random_baseline=0.292, so BOTH configs beat random by only ~0.03-0.05. Per (mode,seed) the tuned plans are nearly identical to default (e.g. signal-seed1 = 0.55 for both) — more budget finds the SAME plans. The single-seed 0.30 -> 0.40 sanity was NOISE.
- Decision: REJECT the CEM-budget hypothesis — keep the default CEM (3/64). The planner is NOT the bottleneck; the CEM already extracts near-optimal plans from the predictor. The MPC ceiling (~0.34, barely above 0.29 random) is the PREDICTOR's latent-dynamics accuracy, not planning compute. A negative result that correctly redirects the lever.
- Next question: does PREDICTOR quality lift MPC? Test a bounded predictor-capacity/training A/B — e.g. epochs 22 -> 44 and/or latent_dim 32 -> 64 — measured on mpc_success. If MPC rises with predictor quality, the latent forward model was under-trained/under-capacity for control. If it stays flat, the synthetic_1f control task may be near its achievable ceiling given the JEPA objective (which optimizes representation, not control) — a deeper design question to ledger, not build (per the stop rule).

## 12 — Predictor-quality sweep: MORE capacity/training HURTS control (2026-07-21, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 11) the MPC ceiling is the predictor's latent-dynamics accuracy, so a bigger + longer-trained predictor (epochs 22->44, latent_dim 32->64) should lift mpc_success.
- Prediction: pushed predictor improves mpc_success (better latent dynamics -> better plans reach goals).
- Implementation: A/B {default(22ep,32d) vs pushed(44ep,64d)} x {signal,nuisance} x seeds{0,1,2}, n=384 (background, 12 cells).
- Evidence: REFUTED and REVERSED. mpc_success 0.342+/-0.151 -> 0.292+/-0.134 (delta -0.050 — pushed lands EXACTLY at the 0.2917 random baseline: control collapses to chance). rollout_mean 0.0120 -> 0.0478 (+0.0358, ~4x WORSE forward error). chi 0.9501 -> 0.9744 (+0.024, BETTER static factor recovery). So a bigger/longer predictor improves the STATIC linear probe (chi) but DEGRADES the forward dynamics (rollout 4x) and control (MPC to chance) — the same dissociation as node 33's log_features. Confound: epochs and latent_dim moved together; the 4x rollout jump points at latent_dim=64 (a bigger latent is harder to roll out accurately) more than the extra epochs.
- Decision: REJECT the naive capacity/training lever — keep default (22ep, 32d). Pushing predictor capacity does NOT fix the MPC; it collapses control to chance while polishing the representation. THIRD time the forward-eval has caught a change that helps a static/representation metric but hurts forward dynamics+control (log_features node 33, predictor-capacity node 12; symlog node 9 was the neutral case).
- Next question (STOP-and-DEFINE, per the loop stop rule): NO knob in the current design — input transform (nodes 7/9/33), planner budget (node 11), predictor capacity/training (node 12) — lifts control above ~0.34 (barely > 0.29 chance), while every representation-improving change leaves control flat or hurts it. The ceiling is the OBJECTIVE: the JEPA/VICReg loss optimizes representation quality, NOT forward-dynamics-for-control. Fixing control needs a different training signal (an explicit multi-step latent-prediction / model-based-control loss) — a DESIGN decision for the user, not an autonomous overnight build. ONE clean bounded follow-up remains that is not a new-objective build: decouple the confound (epochs-only 44/32 vs latent-only 22/64) to confirm latent_dim is the control-killer. Do that once, then declare the knob-tuning line CONVERGED and park.
