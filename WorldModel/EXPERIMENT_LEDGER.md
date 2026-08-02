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

## 6 — Transform A/B, arm 1: log-band-power into the encoder (dialectic node 33) (2026-07-20, commit <pending>)
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
- Hypothesis: the "standardize" arm listed in dialectic node 33's remaining set is a distinct input-space transform to A/B like `log_features`.
- Prediction: n/a — a code audit, not an experiment; the outcome is either a distinct transform to build or a redundancy to retire.
- Implementation: audited the normalization seam `JEPATransitionDataset` (`WorldModel/eeg_jepa.py`). `__init__` (:57) defaults `normalize=True`; with no `mean`/`std` supplied it computes per-feature train stats (`mean = all_states.mean(0)`, `std = all_states.std(0).clamp_min(1e-6)`, :114-115); `__getitem__` z-scores and clamps to `clip_sigma=8.0` (:226). There is no un-standardized path. So the `log_features=OFF` baseline that dialectic node 33 calls "raw z-scored" IS standardization.
- Evidence: the default dataset already subtracts the per-feature train mean and divides by the per-feature train std (a `state_dim` vector), which is exactly a z-score standardization; a separate "standardize" arm adds nothing over the control.
- Decision: DROP "standardize" as an A/B arm — it is the control, not a treatment. Dialectic node 33's provisional ("raw z-scored power may already be the right encoder input for forward dynamics") therefore stands as the standing result: standardization is already in force and is the baseline every arm is measured against. No code change; documentation only, so no smoke-test needed.
- Next question: the next genuinely-distinct, buildable arm is `symlog` — `sign(x) * log1p(|x|)` — a signed log that, unlike `log_features`, handles the negative z-scored values without an epsilon floor and compresses large-magnitude outliers symmetrically. Integrate it at the `JEPATransitionDataset` seam (mirror the `log_features` threading through `evaluate()`'s three dataset constructions) and A/B {symlog off/on} x {signal, nuisance} x seeds. Remaining after: specparam + 1/f-flatten (still blocked on the specparam front-end, Math §11.2).

## 8 — Transform A/B, arm 3: symlog into the encoder (node 7 follow-through) (2026-07-21, commit <pending>)
- Category: Integrate
- Hypothesis: symlog — `sign(x) * log1p(|x|)` — log-compresses the heavy-tailed powers like `log_features` but, because `log1p(0)=0`, avoids the epsilon-floor artifact where a zero/near-dead channel maps to `log(1e-6) ~= -13.8`, a large negative outlier the z-score amplifies. If dialectic node 33's rollout/MPC harm came from those epsilon outliers (not from log-compression per se), symlog may recover the chi benefit WITHOUT the forward-metric harm.
- Prediction: (measured next fire) symlog improves or matches chi vs the standardized baseline while keeping rollout+MPC at least as good as baseline — the pass condition. If it degrades rollout/MPC like `log_features` did, the harm is intrinsic to log-compression, not the epsilon floor.
- Implementation: added `symlog` to `JEPATransitionDataset` (`WorldModel/eeg_jepa.py`) as a mutually-exclusive-with-`log_features` transform applied pre-normalization (`sign * log1p` on pre/post windows; stats then computed in symlog-space so `__getitem__` normalizes the transformed windows). Threaded `symlog` through `evaluate()` and ALL THREE dataset constructions (train, `_multi_step_rollout`, `_encode_states`/MPC) so train/rollout/MPC share ONE input space. Added `--symlog` CLI + `config.symlog` in the panel + a smoke assertion that the symlog path stays finite end-to-end. `WorldModel/`-only, two files. Smoke test passes with the symlog arm exercised.
- Evidence: `venv/bin/python WorldModel/forward_eval.py --smoke-test` passes with symlog=True run finite (pred_err/chi/rollout all finite); full A/B pending (launched to background this fire).
- Decision: PENDING — Benchmark next fire. A/B {symlog off/on} x {signal, nuisance} x seeds {0,1,2}, n=384, 22 epochs, CPU. Keep symlog ONLY if it improves rollout+MPC without degrading chi (same rule as dialectic node 33).
- Next question: compare symlog's A/B against dialectic node 33's `log_features` numbers (rollout 0.0079 -> 0.0108 WORSE, chi 0.950 -> 0.987 BETTER). Does symlog's zero-preserving log recover the chi gain without the rollout/MPC harm?

## 9 — Transform A/B, arm 3 benchmark: symlog is forward-metric-neutral (2026-07-21, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 8) symlog recovers log_features' chi gain WITHOUT its rollout/MPC harm, because `log1p(0)=0` removes the epsilon-floor outlier that `log_features` created at dead channels.
- Prediction: symlog improves-or-matches chi while keeping rollout+MPC at least as good as the standardized baseline.
- Implementation: ran {symlog off/on} x {signal, nuisance} x seeds {0,1,2}, n=384, 22 epochs, CPU (background nohup, 12 cells).
- Evidence (pooled OFF -> ON, +/- is seed pstdev):
  - rollout_mean 0.0120+/-0.0022 -> 0.0122+/-0.0015 (delta +0.0002 — an order of magnitude BELOW the +/-0.0022 seed noise: NO significant change; NOT the +37% harm log_features caused).
  - mpc_success 0.342+/-0.151 -> 0.358+/-0.137 (delta +0.017, within the large +/-0.15 noise — directionally up, not significant).
  - chi 0.9501+/-0.0026 -> 0.9545+/-0.0055 (delta +0.0044; chi is the tightest metric — a small consistent gain).
  Contrast with dialectic node 33 log_features: rollout +37% WORSE, MPC worse. symlog's forward-metric harm is GONE.
- Decision: DO NOT PROMOTE — symlog stays default OFF, but for a DIFFERENT reason than log_features: not because it harms the forward metrics (it does not — they are flat within noise) but because it does not clearly IMPROVE them (the keep-bar). Chi-only improvement is insufficient (dialectic node 33's lesson: the forward metrics are the objective, not the linear probe). The node-8 hypothesis is CONFIRMED: the epsilon floor was the source of log_features' rollout harm — removing it (symlog) drops the rollout degradation from +37% to ~0.
- Next question: two arms remain — specparam (periodic+aperiodic) and 1/f-flatten — both blocked on the specparam front-end (Math §11.2), a larger build than a one-line transform. Accumulating result across arms: standardize = baseline (node 7), log_features = reject (dialectic node 33), symlog = neutral (node 9) — NO input-space transform has yet improved the forward metrics over the standardized baseline, strengthening dialectic node 33's provisional "raw z-scored power is already the right encoder input for forward dynamics." Decide next fire: build the specparam front-end, or declare the transform-A/B line converged (raw z-score wins) and pivot.

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
- Evidence: REFUTED and REVERSED. mpc_success 0.342+/-0.151 -> 0.292+/-0.134 (delta -0.050 — pushed lands EXACTLY at the 0.2917 random baseline: control collapses to chance). rollout_mean 0.0120 -> 0.0478 (+0.0358, ~4x WORSE forward error). chi 0.9501 -> 0.9744 (+0.024, BETTER static factor recovery). So a bigger/longer predictor improves the STATIC linear probe (chi) but DEGRADES the forward dynamics (rollout 4x) and control (MPC to chance) — the same dissociation as dialectic node 33's log_features. Confound: epochs and latent_dim moved together; the 4x rollout jump points at latent_dim=64 (a bigger latent is harder to roll out accurately) more than the extra epochs.
- Decision: REJECT the naive capacity/training lever — keep default (22ep, 32d). Pushing predictor capacity does NOT fix the MPC; it collapses control to chance while polishing the representation. THIRD time the forward-eval has caught a change that helps a static/representation metric but hurts forward dynamics+control (log_features dialectic node 33, predictor-capacity node 12; symlog node 9 was the neutral case).
- Next question (STOP-and-DEFINE, per the loop stop rule): NO knob in the current design — input transform (nodes 7/9/33), planner budget (node 11), predictor capacity/training (node 12) — lifts control above ~0.34 (barely > 0.29 chance), while every representation-improving change leaves control flat or hurts it. The ceiling is the OBJECTIVE: the JEPA/VICReg loss optimizes representation quality, NOT forward-dynamics-for-control. Fixing control needs a different training signal (an explicit multi-step latent-prediction / model-based-control loss) — a DESIGN decision for the user, not an autonomous overnight build. ONE clean bounded follow-up remains that is not a new-objective build: decouple the confound (epochs-only 44/32 vs latent-only 22/64) to confirm latent_dim is the control-killer. Do that once, then declare the knob-tuning line CONVERGED and park.

## 13 — Decoupling: epochs and latent_dim hit DIFFERENT metrics (corrects node 12) (2026-07-21, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 12) the 4x rollout jump in the pushed predictor was driven by latent_dim=64; isolate epochs-only vs latent-only to confirm.
- Prediction: latent_only(64d) shows the 4x rollout blow-up AND the MPC collapse; epochs_only(32d) stays near default.
- Implementation: A/B {epochs_only(44,32) vs latent_only(22,64)} x {signal,nuisance} x seeds{0,1,2}, n=384, vs the node-12 default(22,32) anchor (mpc 0.342, rollout 0.0120, chi 0.9501).
- Evidence — a clean TRIPLE DISSOCIATION that REFUTES node 12's attribution:
  - epochs_only(44,32): rollout 0.0120 -> 0.0494 (4x WORSE) but mpc 0.342 -> 0.333 (UNCHANGED), chi ~flat (0.947).
  - latent_only(22,64): rollout 0.0120 -> 0.0105 (UNCHANGED) but mpc 0.342 -> 0.217 (CRASHES to BELOW the 0.292 random baseline), chi 0.950 -> 0.970 (BETTER).
  So MORE EPOCHS blows up the rollout metric (multi-step prediction overfits) while control is robust to it; the BIGGER LATENT crashes control (MPC below chance) while leaving rollout fine and chi better. Node 12's "the 4x rollout fingers latent_dim" was WRONG — the 4x rollout was EPOCHS; the MPC collapse was LATENT_DIM.
- Decision: KEEP default (22ep, 32d) — confirmed optimal among the knobs. Two findings: (1) rollout_error and mpc_success are driven by DIFFERENT knobs and are NOT interchangeable proxies — rollout can worsen 4x with zero control effect (epochs), and control can crash with zero rollout effect (latent). (2) latent_dim -> MPC harm WITH rollout flat and chi up is the sharpest representation-vs-control dissociation yet: a higher-dim latent is a BETTER representation (chi) and an equally-good 1-step predictor (rollout) yet a WORSE substrate for goal-conditioned planning — the goal-latent distance geometry degrades with dimension even as the encoding improves.
- Next question: NONE that is a bounded build — the knob-tuning line is CONVERGED. Across nodes 7-13, no input transform, planner budget, predictor epochs, or latent dim improves control above ~0.34 (barely > 0.29 chance); every representation-improving change is neutral-to-harmful for control. The ceiling is (a) the JEPA objective (optimizes representation, not control) and (b) the goal-latent-distance planning geometry. Both fixes are DESIGN decisions for the user — a model-based-control training signal, and/or a control-aware goal metric — explicitly NOT autonomous overnight builds (per the stop rule; coupled-spaces/hyperbolic also OUT). PARK the WorldModel knob line here; the morning owner picks the next objective.

## Review clarifications (PR #22 code-review, 2026-07-21)
Two reviewers verified the delivered synthetic A/Bs are sound (symlog threaded identically into train/rollout/MPC-encode; stats computed in-space; mutual-exclusion enforced; CEM knobs effective). Fixes applied from the review:
- Finding A (provenance, MEDIUM): added `mpc_elite_frac` to the `forward_eval.py` config panel — node 10 claimed all three CEM knobs were logged for provenance but `elite_frac` was missing. The node-11 sweep held it at the 0.2 default, so those numbers are unaffected; the gap only meant a future elite_frac arm would be indistinguishable in the panel.
- Finding B (latent trap, MEDIUM): added `--symlog` to the real-data trainer `eeg_jepa.py` (+ threaded into the train and val constructions) — it had `--log-features` but not `--symlog`, so a future real-EEG symlog A/B through that entry point would have silently trained the baseline. `forward_eval.py` (the synthetic path this branch actually ran) was already complete, so no delivered result is affected.
- Finding C (accuracy, no code change): symlog is applied to the raw NON-NEGATIVE power windows (pre-normalization), so `sign(x)=+1` and `symlog == log1p` here; the "handles negative z-scored values" phrasing in node 8 is moot for this feature space. The REAL and delivered distinction from `log_features` is the absent epsilon floor (`log1p(0)=0` vs `log(1e-6)=-13.8`), so the node-8/9 conclusion stands unchanged.

## 14 — Frame mismatch is real, enormous, and NOT the cause of the control null (2026-08-02, commit <pending>)
- Category: Benchmark
- Hypothesis: `_mpc_success` plans across two encoders — `z0` from the ONLINE encoder (`forward_eval.py:317`), `zg` from the TARGET encoder (`:319`) — while the goal state differs from the start state in `pos` ALONE (`:316`, at most `goal_offset=0.4`). If those two maps, tied only by an EMA at `tau=0.99`, disagree by more than a 0.4 position shift moves the latent, then the planner's cost is dominated by a constant offset it cannot reduce by acting, and control cannot improve however good the predictor gets. Sub-hypothesis: an isotropic objective leaves the rotational gauge maximally free (for orthogonal R, `z ~ N(0,I)` implies `Rz ~ N(0,I)`), so the disagreement should be largely ROTATIONAL.
- Prediction (pre-registered in `frame_diagnostic.py` before any number existed, and in commit 8533ea8): `mismatch_to_displacement_ratio > 1.0` means the frame offset exceeds the entire goal signal; `< 0.3` rejects the hypothesis. `procrustes_residual_ratio < 0.2` means mostly rotational (the free gauge); `> 0.5` means rotation is NOT the mechanism.
- Implementation: `WorldModel/frame_diagnostic.py` + a 12-line hook in `_mpc_success` that reuses the SAME `_encode_states` path the planner uses, on the SAME matched start/goal pairs. Cannot run from a checkpoint — `torch.save` (`eeg_jepa.py:593`) persists `encoder_state_dict` and `predictor_state_dict` only, and `__init__` rebuilds the target as `copy.deepcopy(self.encoder)`, so a loaded model reports zero mismatch: a false negative reading as a clean result. Run config: `n=384, epochs=22, mode=signal, latent_dim {32,64}, seeds {0..4}`, torch 2.13.0+cpu, 12 threads. 10 runs.
- Evidence — the hypothesis is CONFIRMED as geometry and REFUTED as cause:
  - **Ratio A/B: median 70.64 (32d) and 86.68 (64d), range 27.96–120.57 across all 10 runs.** The step-0 cost is ~70x the goal signal it is supposed to read. Threshold was 1.0; exceeded by one to two orders of magnitude in every single run.
  - **`procrustes_residual_ratio` 0.956–0.976 (median 0.970 / 0.962).** Threshold for "rotational" was < 0.2; observed > 0.5 everywhere. **The gauge sub-hypothesis is FALSIFIED.** `rotation_from_identity` is 0.574–0.665, so the frames ARE rotated by ~70–80 degrees — but rotating does not reduce the residual, so rotation is present and is not the cause.
  - **`centroid_gap` 0.83–2.51 against total mismatch 1.26–3.09: ~75–80% of the disagreement is a pure TRANSLATION** between the two encoders' outputs, which is what an EMA-lagged mean produces. SIGReg and VISReg constrain rotational gauge and distribution shape; NEITHER addresses a mean offset. The registered cross-arm prediction (SIGReg ratio >= VICReg ratio) is therefore moot, not merely unmet.
  - **Remedy test (EXPLORATORY, not pre-registered): encoding the goal with the ONLINE encoder drives A/B to 0 by construction and does NOT rescue control.** 32d: 0.350+/-0.114 -> 0.360+/-0.116, paired delta +0.010 (2/5 up, 2/5 down). 64d: 0.300+/-0.084 -> 0.370+/-0.075, paired delta +0.070 (4/5 up, 0/5 down) — inside the +/-0.084 seed spread, and landing at 0.370 against a random baseline of 0.350, i.e. still chance.
  - **The benchmark cannot resolve this.** `random_baseline_success` ranges **0.15 to 0.45 across five seeds** at `mpc_episodes=20`, while every arm sits at ~0.35. A chance baseline swinging +/-0.15 cannot resolve a 0.07 effect. This is measurement, not preference.
- Decision: **REJECT frame mismatch as the explanation for the control null, and KEEP the diagnostic.** The mismatch is real and large, so `_encode_states`' two-encoder split is a genuine defect in the planner's geometry — but removing it entirely leaves control at chance, so it is not the binding constraint. Also **DROP the isotropy/gauge line as a route to control**: the disagreement is a translation, and no isotropic regularizer addresses translations. This is the fourth time (nodes 9, 11, 12, 13) a representation-side change has been measured and found not to reach control, and the first where the mechanism was measured precisely enough to be excluded rather than merely not-supported.
- Next question: NOT another objective. **The benchmark's resolving power is now the blocker, and it is measured rather than asserted** — a random baseline varying 0.15–0.45 at n=20 episodes cannot adjudicate any regularizer. Repair that first, specified blind (using only the existing MSE baseline and the zero/random policies, never a candidate arm) and required to separate zero from random from MSE on existing data before adoption. A scale-only vs SIGReg vs VISReg comparison run on this benchmark as it stands would be unfalsifiable in exactly the way this node was almost allowed to be.

## Corrections to node 14 (2026-08-02)

- **Correction A (factual, does not change node 14's result).** Node 14's Implementation section says a checkpoint-loaded model "reports zero mismatch: a false negative reading as a clean result", on the grounds that `target_encoder == encoder`. That is wrong, and the truth is worse. `EEGJEPAModule.__init__` deep-copies the target from the encoder **at construction, before any load**, so a format-v1 restore leaves the target at its RANDOM INITIALIZATION. Measured: after loading `encoder_state_dict` into a fresh module, the target is byte-identical to that module's own random init (0.00e+00), **2.04** away from the loaded online encoder and **0.39** from the trained target it should have been. `target == encoder` holds only if you construct and never load, which is not what using a checkpoint means. A v1-restored model plans toward goal latents produced by an **untrained** network — not the one-frame remedy arm, and not any condition that was ever run.
- **Node 14's measurements stand.** `forward_eval.py` contains no `torch.load`; it trains in-process via `train_jepa`, so nothing it reported came from a restored checkpoint. Only the parenthetical account of the hazard was wrong.
- **Consequence for the benchmark repair.** The registered acceptance criterion — that the repair must separate zero from random from MSE *on existing data* — cannot be run against v1 checkpoints at all. It would be scoring an untrained goal encoder. `eeg_jepa.py` now writes format **v2** with `target_encoder_state_dict`; a v2 restore is exact (verified: max parameter difference 0.00e+00 against the original target). Acceptance runs must use v2 checkpoints or run in-process.
- **Correction B (measurement, refines node 14's "0.15 to 0.45" reading).** That swing was attributed to the episode-limited binomial noise of estimating the baseline at one draw per episode. Decomposed, it is roughly **half** that and half genuine episode-set difficulty, because `starts` and `goal_pos` are redrawn from `random.Random(seed)` so each seed scores a different episode set. Holding the episode set fixed and varying only the random draw: sd **0.0750** at reps=1, **0.0054** at reps=100, **0.0022** at reps=500. Varying the episode set with reps pinned at 100: sd **0.0853**, essentially the original spread. So raising reps removes one half for the price of env steps — the baseline touches no encoder, predictor or CEM — and decoupling the episode seed from the model seed is required for the other half.

## Corrections to node 14, part 2 (2026-08-02)

- **Node 14's `success_rate` values are superseded, deliberately.** Per-episode CEM generators change the planner's sampling noise, so the recorded 32d/64d rates no longer reproduce. The EPISODE SET for model-seed 0 is unchanged — `evaluate()` previously passed `seed = model_seed + 2` and the new fixed `episode_seed` is 2 — but every seed now scores that same set, where before each scored its own. Node 14's *conclusions* are untouched: the frame ratio, the Procrustes residual and the one-frame remedy were all measured within a run, not across seeds.
- **The baseline is now a constant.** Across 10 runs (2 latent dims x 5 seeds) `random_baseline_success` is 0.303 for every one, against 0.254-0.483 before. It is a property of the episode set, as it should be, and no longer contributes anything to arm-vs-baseline comparisons.
- **The per-episode CEM generator is not cosmetic.** A single generator consumed sequentially made the planning noise on episode i depend on the draws taken by episodes 0..i-1, i.e. on `n_samples * cem_iters * horizon`. Any arm touching a CEM knob got different noise on the same episode. Nodes 10 and 11 swept exactly those knobs. That sweep was therefore not the paired comparison it appeared to be — it is not necessarily wrong, but its "within seed noise" reading rested on an assumption that did not hold.
- **The continuous endpoint helps, by less than predicted.** Measured paired, ld32 vs ld64 on identical episodes and identical planner noise: mean |t| of 0.62 for the per-episode binary against 0.88 for per-episode `log(d_final/d_start)`, a factor of **1.43**, implying median n for |t|=2 of ~248 versus ~154. A power simulation had suggested nearer 3-4x. Only 3-8 of 20 pairs are discordant, which is why the binary endpoint is weak and is the mechanism the simulation got roughly right while overstating the size. Both endpoints are now returned per episode so this can be recomputed rather than re-derived.
- **`log_distance_ratio_mean` is reported, NOT adopted as the adjudicator.** Switching the primary endpoint in the same change that repins the episode set would confound the two. Adoption is a separate pre-registered decision, and it still has to clear the blind criterion: separate zero from random from MSE on existing data.

## 15 — Benchmark repair: what it bought, and the power claim it refuted (2026-08-02, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 14) the control benchmark cannot resolve a 0.07 effect because its chance baseline swings 0.15-0.45 across five seeds. Repairing the noise sources — persist the EMA target, pin the baseline, fix the episode set, give each episode its own planner stream, adopt a paired continuous endpoint, raise n — should make it able to adjudicate.
- Prediction: each repair removes an identified noise source, and |t| for a real effect then grows as sqrt(n).
- Implementation: `eeg_jepa.py` checkpoint format v2; `forward_eval.py` `baseline_reps` (100), `episode_seed` (2, replacing a `seed` that tracked the model seed), a `torch.Generator` per episode, per-episode `log(d_final/d_start)` and `final_distance_per_episode`, `n_episodes` 20 -> 200.
- Evidence:
  - **Noise sources removed, measured.** Baseline sampling sd **0.0750 -> 0.0054** at reps=100. Baseline across 10 runs (2 latent dims x 5 seeds) **0.254-0.483 -> 0.303 for every run**. Episode sets across seeds **5 distinct -> 1, byte-identical**. `random_baseline_stderr` **0.0761 -> 0.0250** at n=200, against a sqrt(10)=3.16 prediction and a measured factor of 3.04.
  - **Cost is nil.** Wall clock is flat at ~1.1s from n=20 to n=200; the run is dominated by training, not by the MPC block. n was never a compute decision.
  - **THE POWER CLAIM IN THE PREVIOUS ENTRY IS REFUTED.** That entry reported "median n for |t|=2: binary ~248, log-ratio ~154", extrapolated from a paired ld32-vs-ld64 comparison at n=20. Scaling n directly shows |t| does NOT grow — 0.88, 0.21, 0.81, 0.54 at n = 20, 50, 100, 200. That is the null distribution: ld32 vs ld64 has no real effect, so no n reaches |t|=2 and a required-n extrapolated from it is meaningless. The 1.43x sensitivity RATIO at fixed n stands (it compares two endpoints on identical data); the required-n figures do not.
  - **Against a KNOWN effect (2 epochs vs 22), the endpoints separate sharply.** log-ratio |t| = 0.43, 0.80, 0.76, **1.48** at n = 20, 50, 100, 200, tracking its sqrt(n) prediction of 0.43, 0.69, 0.97, 1.38. Binary |t| = 0.94, 0.63, 0.62, **0.68** — flat. Thresholding at `goal_tol` destroys the effect, so **more episodes buy the binary endpoint nothing at any n**.
  - **The repaired benchmark is still underpowered.** At n=200, against a deliberately large effect (an eleven-fold difference in training), the continuous endpoint reaches only |t| = 1.48. Extrapolating on the sqrt(n) behaviour it does exhibit, |t|=2 needs n ~ 365; on 3 seeds that estimate is itself noisy.
- Decision: **KEEP all six repairs** — every one removes a measured noise source and n=200 is free. **DO NOT declare the benchmark repaired.** It can now adjudicate a large effect at n~400; it cannot adjudicate the 0.07-scale effects the objective A/B line cares about, and raising n alone will not get there because the binary endpoint does not respond to n. Adopting `log_distance_ratio_mean` as the adjudicator is now a prerequisite rather than an option, and remains a separate pre-registered decision that must still clear the blind criterion.
- Next question: the ceiling is now `goal_tol` and the horizon, not the sample size. A success criterion that discards the distance it is computed from cannot be fixed by more episodes. Before any regularizer A/B: decide the adjudicating endpoint under the blind criterion, and re-examine whether `goal_tol=0.15` at `horizon=6` leaves any resolvable signal at all. Also outstanding — nodes 10 and 11 swept CEM knobs under the shared-generator defect, so their paired reading did not hold; re-running them is cheap and would either confirm "the planner is not the bottleneck" on sound footing or overturn it.

## 16 — CEM-budget sweep re-run on the repaired benchmark: node 11 confirmed, its point estimate refuted, and a worse finding underneath (2026-08-02, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 15) nodes 10 and 11 swept CEM knobs under the shared-generator defect — one `torch.Generator` consumed sequentially, so planning noise on episode i depended on `n_samples * cem_iters * horizon`. Any arm changing a budget knob got different noise on the same episode, so node 11's "within seed noise" reading rested on a comparison that was not paired. Re-run it with per-episode generators, a fixed episode set, n=200 and the continuous endpoint.
- Prediction: node 11's conclusion (more budget does not lift control) either survives on sound footing or is overturned.
- Implementation: `default(cem_iters=3, n_samples=64)` vs `tuned(8, 192)`, x {signal, nuisance}, seeds 0-4, `n=384`, 22 epochs, latent_dim 32, `episode_seed=2`, `n_episodes=200`. Trivial-policy controls (zero-action and random-action) computed on the same episode construction.
- Evidence:
  - **Node 11's CONCLUSION SURVIVES.** More CEM budget does not lift control: 0/5 seeds reach paired |t| = 2 on either endpoint in either mode. Mean paired |t| for signal is 0.86 binary / 0.48 log; for nuisance 0.85 / 0.89.
  - **But its seed spread was 14x too wide, and its POINT ESTIMATE HAD THE WRONG SIGN.** Node 11 reported default 0.342+/-0.151 vs tuned 0.325+/-0.144, delta **-0.017** — tuned slightly worse. Repaired: signal default **0.335+/-0.011** vs tuned **0.360+/-0.016**, delta **+0.025**; nuisance 0.337+/-0.023 vs 0.354+/-0.025, delta **+0.017**. The +/-0.15 that node 11 called seed noise was mostly the benchmark's own defects, and the direction it reported was noise. A conclusion can be right while every number supporting it is not.
  - **THE PLANNER ENDS FARTHER FROM THE GOAL THAN IT STARTED.** `log(d_final/d_start)` is POSITIVE in all 20 runs: signal +0.108 (default) / +0.082 (tuned), nuisance +0.128 / +0.097. Mean final distance is ~9-14% GREATER than the starting distance.
  - **And it is worse than doing nothing.** Zero-action on the same episodes gives +0.034 (signal) / +0.029 (nuisance); random-action +0.046 / +0.060. Paired per-episode, planner minus zero-action is positive in **6/6** mode x seed comparisons (deltas +0.055 to +0.155, sign test p ~ 0.03), though only 1/6 individually clears |t| = 2. Same direction against random-action, 6/6.
- Decision: **KEEP node 11's decision (reject the CEM-budget lever) and REPLACE its evidence.** The lever genuinely does not work, now measured with a seed spread of +/-0.011 rather than +/-0.15. **REFRAME the open question.** Nodes 11-15 asked why the planner fails to beat chance; that framing is too generous. On the distance endpoint it is consistently worse than taking no action at all, which is not what an uninformative planner looks like — an uninformative planner scores like the zero policy. Something is systematically pointing it away from the goal.
- Next question: this is a directional defect, not a power problem, and it is cheap to localise. Candidates, in order: (a) the goal latent, already known from node 14 to sit ~70x further from the start latent than the goal displacement warrants, so the cost gradient may point almost anywhere; (b) sign or axis convention between the latent displacement and the action applied in `_step`; (c) the predictor's rollout diverging over `horizon=6` so the minimised cost is computed on a state that does not correspond to the executed trajectory. Test (b) first — it is a one-line check and would explain the sign exactly. NOTE that node 14's one-frame remedy did NOT fix control, so (a) alone is not sufficient.

## 17 — The control defect localised: the predictor under-represents the action by ~3.5x (2026-08-02, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 16) the planner is worse than the zero policy, so something is systematically pointing it away from the goal. Node 16 named a sign/axis convention between the latent displacement and the action applied in `_step` as the cheapest discriminating test.
- Prediction: if a sign error exists, the displacement the planner produces is anti-correlated with the displacement it needs.
- Implementation: read `_step` and `generate` for convention; computed the EXACT reachable set (the dynamics are linear in the actions, so the reachable interval is base +/- sum of per-action-coefficient magnitudes); ran the trained planner on the fixed 200-episode set and compared needed against produced displacement; measured predictor sensitivity to action versus state in latent space and against the true env.
- Evidence:
  - **The convention is consistent and there is NO sign error.** `generate` records the action that produced the transition (`_step(z, action, mode)` -> `post`), so training sees the true mapping. Measured on 200 episodes: correlation(needed displacement, produced displacement) = **+0.0375**, sign agreement **45.5%** against a 50% +/- 7% chance interval. A sign error would give strong negative correlation. **Candidate (b) from node 16 is REFUTED.**
  - **The task is feasible; this is not a reachability problem.** Action authority is a half-width of **0.459** (median) against a median **0.207** to be closed, and the goal is reachable within `goal_tol` in **200/200** episodes in both modes. Uncontrolled drift is only 0.077-0.112.
  - **The planner uses ~16% of the authority it has.** Mean |produced| **0.0734** against mean |needed| **0.2224** and a reachable half-width of 0.459.
  - **ROOT CAUSE: the action barely exists in latent space.** Full action swing (-1 -> +1) moves the predicted latent **0.1378** while different states are **2.2613** apart — the action is **6.1%** of the state signal. In the TRUE env the same swing moves `pos` by 0.1200 against a state sd of 0.5640 — **21.3%**. The predictor therefore **under-represents the action by ~3.5x**, and in the true env actions beat drift 5.66x. There is ample control authority; it is attenuated on the way into the latent.
- Decision: **REJECT node 16's "systematically pointing it away" reframing, and REPLACE it.** The planner is not adversarial, it is uninformative — and an uninformative planner that still ACTS scores worse than the zero policy, because uncorrelated displacement added to a position increases expected distance. That fully accounts for node 16's "worse than doing nothing" with no directional defect. Node 16's claim that "an uninformative planner scores like the zero policy" was wrong: that holds only for a planner emitting zero actions. The MEASUREMENT in node 16 stands; the inference drawn from it does not.
- This also reconciles the whole nodes 6-16 arc. Every representation-side change was measured against metrics dominated by the per-trajectory factors (`chi`, `peak_amp`, `offset`), which are constants and easy to encode. `pos` — the only variable control acts on — is the one the encoder represents weakly (node 13: latent-to-position r ~ 0.63). Improving `chi` recovery while `pos` stays weakly encoded improves the panel and cannot improve control. The planner was never the bottleneck (node 11, confirmed in node 16), the objective was not the bottleneck (node 14), and the frame offset was not sufficient (node 14) — the ACTION CHANNEL is.
- Next question: this is a training-signal problem, not a planner, objective or benchmark problem. The one-step JEPA target gives the action a 6% footprint in a latent whose variance is dominated by frozen per-trajectory factors. Bounded, ordered candidates: (a) train the predictor on MULTI-STEP transitions so the action's compounded effect is visible in the target; (b) scale the action's authority per step (`DT`, or an action gain) so one step carries a larger footprint; (c) an action-conditioned auxiliary loss that requires the latent to predict the action from a (pre, post) pair — a direct measurement of how much action information the representation retains, and a candidate for the panel regardless. Test (c) FIRST: it is diagnostic rather than corrective, it needs no retraining of anything else, and it converts "the action is 6% of the signal" into a number the panel reports every run.

## 18 — Action-conditioned probe: the representation retains NO recoverable action information (2026-08-02, commit <pending>)
- Category: Benchmark
- Hypothesis: (node 17) the action is under-represented in latent space — the predictor moves only 6.1% of the state signal across the full action range against 21.3% in the true env. A held-out linear probe recovering the action from a (z_pre, z_post) pair should therefore score well below its true-state ceiling.
- Prediction: latent action recovery is positive but far below the ceiling.
- Implementation: `_action_recovery` in `forward_eval.py` — held-out linear-probe R^2 per action dimension from `[z_pre, z_post]`, 80/20 split with a bias column, matching `_factor_recovery`. Added to the panel. Two controls come free: `action[2]` is the mode bit, which `_step` never reads, so it MUST score at or below zero; and the same probe on the TRUE (pre, post) states gives the ceiling.
- Evidence — **the prediction was too generous. Recovery is not low, it is absent.**
  - **Ceiling, from the true states:** `ay` **R^2 = 1.0000** (exact — the algebra is linear: `ay = (pos' - pos - vel'*DT) / (0.5*DT)`), `ax` 0.7096 (short of 1.0 only because `decay` depends on `chi`, making `vel*decay` a product a linear probe cannot form).
  - **From the latent pair: `ax` -0.1676, `ay` -0.1199.** Negative R^2 is worse than predicting the mean — the representation carries **nothing** a linear probe can use. Not the ~6% node 17 implied; zero.
  - **Both controls behave.** `mode_bit` -0.2600 (latent) and -0.0547 (true state), i.e. unrecoverable as it must be. `z_pre` alone, which cannot see the transition, gives -0.1183 / -0.0845.
  - **THE MECHANISM IS THE ENCODER, AND `vel` IS THE SHARPEST NUMBER IN THIS LEDGER.** Factor recovery: `peak_amp` **0.9971**, `chi` **0.9498**, `offset` 0.6856, `pos` 0.6537, **`vel` 0.0326**. The three near-perfect factors are per-trajectory CONSTANTS. The two that EVOLVE are the two worst, and `vel` — the channel `ax` acts through — is at zero. `ax` is therefore unrecoverable in principle: recovering it needs `vel` and `vel'`, and neither is encoded.
  - **For `pos` the arithmetic is just as decisive.** R^2 0.6537 against sd 0.5812 leaves an encoder residual of **0.342**, while the one-step action effect on `pos` is **0.120** — a signal-to-noise ratio of **0.35**. The action's fingerprint is a third the size of the encoder's own noise on the only variable it can move.
- Decision: **ADOPT `action_recovery` into the panel permanently**, with the `mode_bit` negative control asserted in `smoke_test` — mutation-checked: leaking the target makes `mode_bit` score 1.000 and the assertion fires. **REPLACE node 17's "under-represents by ~3.5x" with "does not represent at all".** Node 17 measured the PREDICTOR's response to an action it receives as an explicit input; this measures whether the ENCODED TRANSITION retains which action was taken. The second is the load-bearing quantity and it is zero, which also means node 17's 6.1% predictor response is fitting noise rather than a weak signal.
- This closes the nodes 6-17 arc. Control was never reachable from any representation-side change, because the encoder discards the action's effect and encodes the frozen per-trajectory factors nearly perfectly instead. Every panel metric that improved was measuring the constants. `vel` at R^2 = 0.033 was visible in every run since node 3 and was never read as a control result.
- Next question: this is now a `_render_state` / encoder-capacity question, not a planner, objective, benchmark or predictor question. Ordered and bounded: (a) check whether `vel` is even present in the rendered observation — if the spectral window at a fixed `t` does not carry velocity, no encoder can recover it and the task is unobservable rather than hard, which would be a generator defect and would retire the entire control line as specified; (b) if it IS present, raise the encoder's capacity for the evolving factors, e.g. by feeding a two-window stack so a difference is representable; (c) only then revisit multi-step training targets. Test (a) FIRST — it is a read of `_render_state` plus one probe, and it decides whether the remaining candidates are worth anything.
