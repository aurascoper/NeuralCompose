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

---

## 7 — Objective A/B: SIGReg vs VICReg, with an encoder-alignment arm (2026-08-01, commit 208cbcd)
- Category: Benchmark
- Hypothesis: the ceiling is the training objective. LeJEPA/Laya (arXiv 2511.08544; Laya arXiv 2603.16281)
  replace heuristic anti-collapse terms with **SIGReg** — a sketched isotropic-Gaussian regularizer — and the
  identifiability paper (Klindt, LeCun & Balestriero, arXiv 2605.26379) argues an isotropic latent makes
  Euclidean geometry meaningful, which is what a distance-based planner needs. Swap VICReg's var+cov for
  SIGReg, hold everything else fixed, and `mpc_success` should move.
- Prediction (preregistered, before running): if SIGReg does **not** move `mpc_success`, the first hypothesis
  is that `ParticleNavigatorEnv` falls outside the paper's world class — §3.1/§3.1.1 assume stationary,
  additive-noise transitions (Ornstein–Uhlenbeck for Gaussian latents), and our walls reflect velocity with
  `restitution=0.6`, which is neither. That is a better-shaped null than "didn't work."
- Implementation: `loss.py` (+`SIGRegConfig`, `sigreg_loss`, `epps_pulley_statistic`: Epps–Pulley
  goodness-of-fit on random 1-D projections per Cramér–Wold, O(batch·proj·freq) — linear in batch, unlike the
  O(batch²) pairwise form; directions resampled every call so no fixed basis can be gamed). `train.py`
  (`--objective {vicreg,sigreg}`, dispatch, lazy metric aggregation). Invariance term unchanged on both arms —
  it is the prediction objective, not anti-collapse machinery; var/cov are still computed under SIGReg as
  pure diagnostics. **Arm B** (`mpc.py` `goal_latent_from_online_encoder`, default OFF; `sweep.py`
  passthrough) encodes z_goal with the online encoder instead of `target_encoder`. `env.py`, `dataset.py`,
  `dataloader.py`, `models.py` untouched; unflagged runs are bit-identical to the historical baseline.
- **Correction to the motivating argument, recorded so it is not inherited.** Theorem 5.4 (Optimal Latent
  Planning) requires `ℓ(Rz,a)=ℓ(z,a)` for *all* `R∈O(n)`. Our cost is a distance to an anchor
  (`Σ‖z−z_goal‖` + `‖z_H−z_goal‖²`), which is **not** invariant under rotating `z` alone — it is equivariant
  in the *pair*. The natural rescue (both sides encoded, so `Q` cancels) also fails as written, because
  z_start uses the online `encoder` and z_goal uses `target_encoder`; under EMA those are two different maps.
  Arm B exists precisely to make them one map. **The theorem was never established to cover this planner**;
  the experiment is empirical, not theorem-backed.
- Evidence: 75 epochs, seed 0, MPS; sweeps = 7 `HARD_CASES` × seeds {0,1,2,3,4} = 35 paired trials per arm.
  - Training side, SIGReg genuinely better: val `inv` 0.0671 → **0.0145** (4.6×); 20-step rollout drift
    6.4044 (vs random 6.2363, **worse than chance**) → 5.9988 (vs random 6.8152, **better than chance**);
    rollout norm ratio 1.20 → **0.98**. Zero collapse warnings on either arm. The norm ratio is the
    mechanism: `relu(gamma − std)` is identically zero once std > 1, so VICReg exerts no downward pressure
    on scale and the latent inflates; SIGReg pins the distribution. A ×3-scaled batch scores worst of all
    fixtures under SIGReg (0.513 vs 0.004 for N(0,I)) — VICReg's hinge cannot express this at all.
  - Control side, **null across every arm**: 0/35 literal successes for all four. Baseline reproduces the
    historical anchor (0/35, mean_final_distance 1.2854 vs 1.2509; ESS 197.4 vs 207.1/512).
  - mean_final_distance: VICReg 1.2854 → SIGReg **1.2017** (Δ −0.084, beats base 22/35, t=−0.60) →
    VICReg+aligned 1.3053 (Δ +0.020, t=+2.02) → SIGReg+aligned **1.0603** (Δ −0.225, 24/35, t=−1.87).
  - **The means are misleading and the per-case table says so.** SIGReg is bimodal, not uniformly better:
    corner_pn_to_np 2.211→0.639, large_b 0.547→0.234, large_a 0.830→0.463 (large gains) but
    corner_np_to_pn 1.623→2.362, corner_nn_to_pp 1.056→1.588, corner_pp_to_nn 2.055→2.542 (large losses).
    4 cases improve, 3 degrade. Further, the entire A+B gain over A is **one case** (corner_nn_to_pp
    1.588→0.611); every other case is within ~0.01. And the t-stats are not trustworthy: 5 seeds within a
    case are correlated, so effective n ≈ 7, not 35 — VICReg+aligned's "significant" t=+2.02 on a +0.02
    effect is the reductio.
- Decision: **REJECT for promotion; KEEP the code behind a default-OFF flag.** SIGReg does not move the
  control metric, and its mean-distance edge is not robust under per-case inspection. This is the **fourth**
  time this benchmark has caught a change that improves a representation/forward metric while control does
  not follow (cf. node 6's chi-vs-rollout dissociation) — and the first where the improving metric was the
  *forward rollout* itself, which is a stronger version of the same trap. Arm B alone does essentially
  nothing under VICReg (all cases within ~0.01), consistent with the prediction that encoder alignment can
  only matter once the geometry is isotropic; but the SIGReg+alignment interaction rests on a single case and
  is not evidence.
- Next question: two, and the second may matter more.
  (1) The preregistered follow-up: run an **unbounded-arena variant** (no walls, no restitution) so the
  dynamics sit inside the additive-noise class. If SIGReg moves control there and not here, the null is about
  the environment, not the objective.
  (2) **The benchmark is at its floor and cannot discriminate.** Every arm and both historical anchors score
  0/35 or 1/35; a metric that returns 0 for every condition carries no signal, and mean_final_distance is
  doing all the work while varying ±1.9 across cases. Before another objective is tried, the success
  criterion needs resolution in the regime the arms actually occupy — otherwise the next A/B is unfalsifiable
  in the same way.

---

## 8 — Preregistered arena test: the null is not the environment (2026-08-01, commit 90df662)
- Category: Benchmark
- Hypothesis: node 7's preregistered explanation for its own null — SIGReg failed to move control because
  `ParticleNavigatorEnv`'s wall reflection (`vel = -vel * restitution`, restitution 0.6) is nonlinear and
  non-additive, putting the dynamics outside the world class (arXiv 2605.26379 §3.1/§3.1.1) whose
  identifiability results motivated the arm. Remove the walls and SIGReg should convert its representation
  advantage into control.
- Prediction: SIGReg gains control success in the unbounded arena; VICReg does not, or gains less.
- Implementation: `env.py` `EnvConfig.bounded` (default True; the wall loop becomes
  `for dim in range(2) if c.bounded else ()`), threaded as `--unbounded` through `dataset.py`, `sweep.py`,
  `mpc.py`. Default-off, so every existing path is bit-identical. Fresh dataset generated under the
  unbounded env, both arms retrained on it (75 epochs, seed 0), both swept. Two arms only — no VISReg, no
  alignment lever — so the environment is the single changed variable versus node 7.
  Honest scope, recorded in `env.py`: removing the walls removes the REFLECTION nonlinearity. It does **not**
  produce an Ornstein–Uhlenbeck process — the dynamics stay a deterministic double integrator with an accel
  clip and speed cap, with no mean reversion and no process noise.
- Evidence:
  - Unbounded training: VICReg val `inv` 0.0567, SIGReg **0.0063** (9×). Rollout drift now far better than
    chance on BOTH arms (3.72 vs random 7.46; 3.99 vs 7.50) — removing the walls made the dynamics much more
    predictable, as expected.
  - Control: VICReg **4/35 (11.4%)**, mean_final_distance 1.7298; SIGReg **0/35 (0.0%)**, 1.3611.
  - Case-level paired (n=7 independent cases; five seeds within a case vary only MPPI candidate draws and are
    NOT independent environments): mean Δ final_distance (SIGReg − VICReg) = **−0.369**, sd 1.996, se 0.754,
    **t = −0.49**, SIGReg closer on 3/7 cases. No effect.
  - **All four VICReg successes come from one case** (`large_c` 4/5). Every other case is 0/5 for both arms.
- Decision: **The preregistered hypothesis is REFUTED.** The node 7 null was not caused by the wall
  nonlinearity. SIGReg scores 0/35 in both arenas, and in the unbounded arena it is 9× better at one-step
  prediction while being *worse* on literal success than VICReg. Two consequences:
  (1) The prediction-vs-control dissociation is now much stronger than node 7 showed. In node 7 the improving
  metric was the forward rollout; here BOTH arms have healthy better-than-chance rollouts and 9× separation
  in prediction error, and control does not follow either. **One-step prediction quality and rollout quality
  are close to decoupled from control success in this harness.** That is the fifth instance of the pattern
  and the most direct one — it points at the planner/metric, not the objective.
  (2) The n=35 paired t-statistics in node 7 were overstated, as suspected. Node 7's best arm showed t=−1.87
  over 35 trials; the correct unit (n=7 cases) gives t=−0.49 here with a per-case sd of 2.0 against a mean of
  0.37. **Report case-level paired differences from now on; never treat seeds within a case as independent.**
- Next question: benchmark repair, before any further objective work. The unbounded arena did buy *some*
  resolution (VICReg 0/35 → 4/35), confirming the bounded box contributed to the floor — but it is one case
  out of seven, which still cannot discriminate between arms. Design a preregistered control measure with
  resolution in the regime the arms actually occupy (the per-case final distances span 0.10–4.84), then
  re-examine.
  **VISReg (arXiv 2606.02572) is deliberately NOT run yet.** Its symmetric scale term
  `mean_j (1 − sigma_j)²` targets exactly the inflation node 7 found — and its authors motivate it by
  SIGReg's "vanishing gradients under collapse" and failure to decouple scale from shape. But SIGReg already
  pinned scale here (norm ratio 1.20 → 0.98), and neither collapse nor residual scale drift was the observed
  blocker, so VISReg would most likely become the *sixth* representation-side improvement this benchmark
  cannot resolve. It also cannot help with the Theorem 5.4 obstruction: an isotropic objective leaves the
  orthogonal gauge maximally unconstrained (`z ~ N(0,I)` ⟹ `Rz ~ N(0,I)`), so it can never establish that the
  online and target encoders share a frame. Correct order: repair the benchmark, then run
  {symmetric-scale-only, SIGReg, VISReg} so "scale stabilization" and "full distribution shape" are separable.

---

## 9 — Benchmark repair: the planner is the binding constraint, not the objective (2026-08-01, commit 60433e8)
- Category: Test
- Hypothesis: node 8 left the control benchmark unable to discriminate — every objective arm scored 0/35 and
  five consecutive representation improvements moved it not at all. Before another objective is tried, find
  out whether `reached` is measuring anything.
- Prediction: the binary criterion lacks resolution near the achievable ceiling, and a graded measure will
  separate arms that the binary collapses to zero.
- Implementation: `mpc.py` — `oracle_action` (PD on TRUE state, `ORACLE_KP=ORACLE_KD=2.0`) plus
  `policy="oracle"`; `best_distance` / `initial_distance` / `normalized_progress` added to `run_episode`'s
  result. `sweep.py` — `--policy`, graded metrics in rows and in the aggregate line.
  `benchmark_reference.py` (new) — runs oracle/random/zero/mpc over the same `HARD_CASES` and **rejects the
  measure** (exit 1) if the oracle fails to separate from random/zero. Case-level aggregation throughout, per
  node 8. All additions are default-off or additive: the unflagged `sweep.py` path still reports
  `0/35, mean_final_distance=1.2854`, identical to node 7.
- Evidence:
  - **The prediction was wrong about the diagnosis, and the truth is worse.** A two-line PD controller reaches
    **7/7 cases in 21–33 of the 50 available steps**, stably across gains {(1.0,1.5),(2.0,2.0),(3.0,2.5)}.
    The task is not near any ceiling — it is trivially feasible, and latent MPC scores 0/35 on something a
    reference controller solves with 17 steps to spare. `0/35` was never "no resolution near the ceiling";
    it was "the planner fails."
  - Measure validation (bounded, VICReg ckpt), case-level: oracle `reached` 1.000 / progress **0.961**;
    mpc 0.000 / **0.392**; random 0.000 / **0.233**; zero 0.000 / **0.000**. The binary collapses three of
    four policies to zero; `normalized_progress` orders all four correctly. Measure accepted.
  - **mpc sits at 21.8% of the usable oracle-to-random span.**
  - Applied to the objective arms, case level (n=7): BOUNDED mean Δ (SIGReg − VICReg) = **+0.081**, sd 0.327,
    **t=+0.66**, better on 4/7. UNBOUNDED **+0.047**, sd 0.522, **t=+0.24**, better on 4/7. Both null.
  - Per-case swings dwarf the arm difference: SIGReg ranges +0.694 to −0.270 (bounded) and +0.713 to −0.749
    (unbounded). Case identity explains far more than objective choice.
  - Sanity checks that the measure behaves: oracle scores identically in both arenas (0.961 — it goes straight
    to the goal and never touches a wall), while random drops 0.233 → 0.121 unbounded (reflections were
    accidentally returning it toward the goal).
- Decision: **Benchmark repaired and the repair changed the conclusion.** The measure now demonstrably
  discriminates, and with resolution restored the objectives *still* do not differ — so this is now an
  informative null rather than a floor artifact. The binding constraint is the **planner**: it captures about
  a fifth of what the task admits, and closing that gap is not something any representation objective can do.
  Five representation-side improvements produced no control movement because control was never
  representation-limited here.
  Note the binary criterion is not itself broken — it cleanly separates oracle from everything else. Its
  defect is narrower: it cannot rank policies that all fall short, which is the entire regime the arms occupy.
- Next question: the objective line is **closed** until the planner is addressed; running
  {symmetric-scale-only, SIGReg, VISReg} now would measure a component that is not limiting. The open
  question is why MPPI over a latent that rolls out better than chance still captures only ~20% of the span —
  candidate explanations, in the order I would test them: (1) the horizon-10 budget cannot represent a ~22-step
  maneuver, so no candidate sequence in the batch ever encodes the solution; (2) the latent distance is too
  weak a proxy to rank candidates (the standing `r≈0.63`); (3) the cost's goal anchor is in a different
  frame from the rollout (the node 7 obstruction, still unresolved and untouched by any isotropic objective).
  (1) is cheap and testable immediately by sweeping horizon against the oracle's 21–33-step solution times.
