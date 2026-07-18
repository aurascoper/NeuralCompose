# World Model (JEPA + MPC) research spike

A multi-day, deliberately synthetic architecture exercise: build a real
Joint-Embedding Predictive Architecture (encoder, EMA target encoder, latent
transition predictor, anti-collapse loss) paired with latent-space Model
Predictive Control — the pattern behind Yann LeCun's JEPA proposals.

## Why synthetic, and why decoupled from EEG

This spike exists because of an earlier, more ambitious idea: a "world
model" over NeuralCompose's own EEG-derived cognitive state ($z_t$ =
`SpectralState`, $a_t$ = the `GenerationAdaptation` applied by the carousel
predictor). That idea is real but currently unbuildable — as of 2026-07-17
there is exactly **one night** of processed sleep data
(`session-review.json`'s `sleep_timeline`) and **zero** logged
`(state, action, next_state)` interaction events (`InteractionLogging` /
`TelemetryEvent`, see `ADR-005-local-interaction-logging.md`, is opt-in and
off by default, and nothing has turned it on yet). A JEPA needs volume,
genuine action variation, and temporal transitions — none of which real EEG
data currently provides.

So: prove the architecture on a synthetic continuous-control task first,
where ground truth is known, data is free, and correctness bugs (does the
predictor unroll without diverging? does the representation collapse?) are
easy to detect because we know the true dynamics. Once the JEPA + MPC
pattern actually works here, decide whether and how to point it at real
EEG-derived state — that's a future decision, not assumed by this spike.

This code is intentionally **decoupled from `Sources/`**: no dependency on
`BCICore`/`BCIEEG`/`BCIClassifier`/`BCILLM`, no MLX (this is PyTorch — the
Swift app's own MLX isolation rule doesn't apply here since nothing here
touches the app target graph). It lives in its own top-level directory
rather than nested in `Evaluation/` (which is specifically the embedding-model
benchmark harness — a different research thread with its own hypothesis
registry) or `Scripts/` (EEG-pipeline tooling).

## Platform note

This machine is Apple Silicon. The GPU backend is **`mps`**, not `cuda` —
`WorldModel/dataloader.py::resolve_device()` checks
`torch.backends.mps.is_available()`. `venv/` already has `torch==2.13.0`,
`numpy==1.26.4` — no new dependency was added for this spike.

## The four-day plan

### Day 1 — The Simulator & Data Pipeline (done, 2026-07-17)

Solves the data-starvation problem: build a fast, synthetic 2D continuous
environment and generate volume from it.

- **`env.py`** — `ParticleNavigatorEnv`: a point mass in a bounded 2D arena.
  State `[x, y, vx, vy]` (4-dim — velocity is part of state, so wall
  collisions create real nonlinear dynamics worth predicting). Action
  `[ax, ay]` (2-dim, clipped acceleration). `step()` does velocity
  integration + wall clamp/bounce (with restitution, so post-collision
  velocity stays informative rather than absorbing to zero). No `goal`
  concept yet — that's Day 4's addition, once MPC needs something to plan
  toward.
- **`dataset.py`** — `generate_trajectories()`: each trajectory
  independently rolls a coin (`--policy-mix`, default 0.5) between a
  `"random"` policy (i.i.d. uniform acceleration — cheap coverage, but tends
  to hug arena walls) and a `"heuristic"` policy (a PD controller steering
  toward a periodically resampled waypoint — smoother, more varied interior
  coverage). Saves `(states, actions)` to `data/{train,val}.npz`
  (80/20 split), seeded for reproducibility.
- **`dataloader.py`** — `TrajectoryDataset`: flattens
  `(states[N,T+1,4], actions[N,T,2])` into individual `(s_t, a_t, s_next)`
  transitions — the exact shape Day 2's predictor loss consumes. Run
  directly (`python dataloader.py`) for a sanity check: batch shapes,
  resolved device, state/action range stats, a degeneracy check on position
  variance.

**Verified 2026-07-17**: `dataset.py` (default 2000 trajectories,
horizon=50, ~50/50 policy mix) → `data/train.npz` (1600 traj, 1.9MB),
`data/val.npz` (400 traj, 487KB). `dataloader.py` against both splits:
correct batch shapes `s_t=(B,4) a_t=(B,2) s_next=(B,4)`, `device: mps (mps
available: True)`, position std ~0.56-0.58 on both axes (non-degenerate —
not collapsed into a corner), state range `x,y ∈ [-1,1]` (arena bound)
`vx,vy ∈ [-1.7, 1.7]` (under the `max_speed=2.0` cap), action range exactly
`[-1,1]` (the `max_accel` clip is binding, as expected from a mix of
saturating random noise and a PD controller that saturates near waypoint
resamples).

`data/` is gitignored — regenerate anytime via `./dataset.py` (seeded, so
`--seed 0` reproduces exactly).

### Day 2 — The Core JEPA Architecture (done, 2026-07-17)

Three networks, predicting entirely in latent space (never reconstructing
raw state):
- **`models.py::Encoder`** $E_\theta$: raw state $s_t \to$ latent $z_t$.
  `Linear→LayerNorm→GELU` ×2 then `Linear→LayerNorm` down to `latent_dim`
  (default 32). LayerNorm not BatchNorm — `TrajectoryDataset` transitions
  are shuffled i.i.d. by the DataLoader, so batch statistics would leak
  across otherwise-independent transitions (the same issue BYOL's analysis
  flags for two-tower online/EMA setups); LayerNorm also works correctly at
  `batch_size=1`. The final LayerNorm does *not* by itself prevent
  representation collapse (it normalizes per sample, across the latent
  axis — a batch of identical vectors still satisfies it); Day 3's
  anti-collapse term operates on a different axis entirely (per feature,
  across the batch).
- **`models.py::JEPAModule.target_encoder`** $E_{\bar\theta}$: a
  `copy.deepcopy` of `Encoder`, frozen (`requires_grad=False`), updated
  only by `update_target_ema()` — never by backprop — providing a stable,
  non-moving prediction target.
- **`models.py::LatentPredictor`** $P_\phi$: $(z_t, a_t) \to \hat
  z_{t+1}$, same two hidden blocks as the encoder, no final LayerNorm on
  the output (the target is already normalized; re-normalizing the
  prediction would discard scale information the loss needs).

**Verified 2026-07-17**: `./WorldModel/models.py` (default config:
`latent_dim=32 hidden_dim=128 ema_tau=0.99`, `device=mps`, `batch_size=16`,
random-tensor smoke test, not real data): `forward_online`/`forward_target`
both produce `(16, 32)`, finite, target params confirmed frozen
(`requires_grad=False`). One real SGD step (`lr=0.1`) on the online encoder
against `MSE(z_pred, z_target)=1.084621`, then `update_target_ema()`: all
12 target parameter tensors moved (`max |delta|=0.000136`), all finite. A
second run at `--ema-tau 0.9 --seed 1 --batch-size 4` showed a ~20x larger
`max |delta|=0.0027` — consistent with the EMA formula (lower tau tracks
the online encoder faster), a useful sanity check that the update isn't a
no-op or miswired.

### Day 3 — The Representation Loss & Training Loop (done, 2026-07-17)

The hard part: avoiding representation collapse (mapping every state to a
constant so prediction loss is trivially zero).

$$\mathcal{L}_{pred} = \lVert P_\phi(E_\theta(s_t), a_t) - E_{\bar\theta}(s_{t+1}) \rVert_2^2$$

EMA update, never via gradient descent: $\bar\theta \leftarrow \tau\bar\theta + (1-\tau)\theta$.

Deliverable: a predictor that unrolls latent trajectories across a
multi-step horizon without diverging.

- **`loss.py::vicreg_loss`** (config `VICRegConfig`: `inv_weight=10.0
  var_weight=10.0 cov_weight=1.0 gamma=1.0 eps=1e-4`) — VICReg-style
  invariance/variance/covariance loss, applied to both `z_pred` and
  `z_target`. `std_target_mean` is the collapse-detection metric watched
  every epoch: near `gamma` (1.0) means healthy, near 0 means collapsed.
  `z_target`'s var/cov terms carry no gradient (it arrives already
  detached from `forward_target`'s `@torch.no_grad()`) — they're
  diagnostics, not optimization pressure; only `z_pred`'s terms actually
  backprop into `encoder`/`predictor`.
- **`train.py::TrainConfig`/`main()`** — wires `make_dataloader` (Day 1) +
  `JEPAModule` (Day 2) + `vicreg_loss` into an Adam training loop
  (`encoder`+`predictor` params only, never `target_encoder`, which is
  EMA-only), calling `update_target_ema()` after every step. Per-epoch
  stdout prints train/val loss components and `std_target_mean`, with a
  collapse `WARNING` if it drops below `0.1 * gamma`.
- **`train.py::rollout_check`** — validates the deliverable directly in
  latent space (JEPA has no decoder back to raw state): self-feeds the
  predictor for `rollout_horizon` steps with no teacher forcing, checking
  finiteness, latent-norm growth, and drift from the true final state's
  target encoding relative to a random-trajectory-pair baseline. Runs
  automatically at the end of every `train.py` invocation.
- Checkpoint: `WorldModel/checkpoints/jepa.pt` (gitignored, mirrors
  `WorldModel/data/`), a dict of `model_state_dict` + `jepa_config` +
  `vicreg_config` + final metrics — what Day 4 will load
  (`JEPAModule(JEPAConfig(**ckpt["jepa_config"]))` then
  `load_state_dict`) and freeze.

**Verified 2026-07-17**: `./WorldModel/loss.py` smoke test: collapsed
latents (`1e-6`-scale noise) → `var=1.98` `std_target_mean=0.0100`;
healthy latents (`torch.randn`) → `var=0.023` `std_target_mean=1.0085`;
latents that are high-magnitude but every dimension a scalar multiple of
one shared direction (variance looks mostly fine, redundancy hidden from
`var`) → `cov=58.8`, ~250x the healthy case's `cov=0.23` — confirms the
covariance term catches what the variance term alone misses.

`./WorldModel/train.py` (75 epochs, default config, `data/{train,val}.npz`
from Day 1): train loss `9.1694 → 5.1614`, val loss `9.8014 → 6.9765`
(`inv` component `0.0852 → 0.0680` val); `std_target_mean` held stable in
the `0.75–0.83` range for all 75 epochs with zero collapse `WARNING`s —
the representation did not degrade during training.

`rollout_check` at the default `rollout_horizon=20`: `finite=True`,
latent norm stayed bounded (`ratio=1.18`, no blow-up), but
`final_drift_vs_target=6.33` came out essentially tied with
`random_pair_baseline=6.26` — by 20 steps of unforced autoregressive
rollout, the predictor has lost trajectory-specific information. A
follow-up sweep across horizons on the trained checkpoint clarified this
rather than leaving it as a flat failure: `drift/baseline` rises smoothly
from `0.22` (horizon 1) through `0.51` (horizon 5), `0.74` (horizon 10),
`0.90` (horizon 15), crossing `1.01` right around horizon 18–20, up to
`1.15` by horizon 49 (full episode length) — latent norm never exceeds
`1.2x` its starting value even at horizon 49. So this is compounding
single-step prediction error eroding *information content* over a long
autoregressive rollout, not numerical divergence — the predictor is
genuinely informative (clearly better than a random trajectory guess)
through roughly 15 steps, and degrades to chance beyond that.
**Implication for Day 4**: a receding-horizon MPC planning loop should
keep its horizon comfortably under ~15 steps to trust these latent
rollouts; treating this as a free 50-step horizon would not be
justified by what Day 3 actually measured.

Negative-control ablation (`--var-weight 0 --cov-weight 0`, otherwise
identical config/data/seed, 75 epochs): `std_target_mean` declined
continuously and monotonically the entire run (`0.59 → 0.46`, still
falling at epoch 75, no plateau reached), while the real run held
essentially flat (`0.79 → 0.77`) over the same 75 epochs on identical
data and architecture — direct evidence the variance/covariance terms are
actively opposing a real, ongoing degradation, not decorative. Note this
corrects an a priori guess made while planning this ablation (that
collapse would be visually near-total within 10–15 epochs): the EMA
target (`ema_tau=0.99`) actually tracks the online encoder almost fully
within a few hundred steps, so slow EMA lag doesn't explain the
gentler-than-expected decline — the erosion itself is just slower than
assumed. A longer ablation run would likely continue declining well past
75 epochs; this was not run, since the monotonic-vs-flat contrast over an
identical epoch budget already answers the question the ablation was
for.

### Day 4 — Latent Model Predictive Control (done, 2026-07-17)

Freeze the trained JEPA. Sample $N$ candidate action sequences over horizon
$H$, unroll each in latent space via the frozen predictor, score by distance
to a goal latent, execute the first action of the best sequence, replan
(receding horizon). This is where the `goal` concept enters the environment
for the first time.

Sampling-based (random shooting / MPPI), not gradient-based — a control
loop has no time to backprop through the predictor at every step.

- **`env.py::sample_goal`** — a new free function (not a method;
  `ParticleNavigatorEnv` stays exactly as stateless as it already was),
  returns a full `(4,)` `[x, y, 0, 0]` state so it can be encoded with zero
  API changes elsewhere — the JEPA latent space is opaque (32 unlabeled
  dims), so a goal latent can only be built by encoding a *complete* raw
  state through the same `Encoder` path the predictor was trained against.
  `step()` is unchanged; goal is a planning/eval target, not a dynamics
  concept.
- **`mpc.py::MPCConfig`** — `horizon=10 num_candidates=512 temperature=1.0
  state_cost_weight=1.0 smoothness_cost_weight=0.1`. `horizon` defaults
  well under Day 3's ~15-step trustworthy-rollout finding, with real
  margin rather than budgeting up to that edge.
- **`mpc.py::score_candidates`** — batched latent rollout (`H` forward
  passes through the frozen `predictor`, mirroring `train.py::rollout_check`'s
  loop shape) scored by summed per-step L2 distance to a goal latent (a
  running cost-to-go, not just the final step) plus an action-smoothness
  penalty. No "utility reward" or "fatigue barrier" term — no honest analog
  exists in this task. Current-state latent comes from the **online**
  `encoder` (what the predictor was actually trained to consume as input,
  matching `forward_online`/`rollout_check`'s exact precedent); the goal
  latent comes from `target_encoder` (matching its only role everywhere
  else in the codebase: a fixed comparison anchor, never predictor input).
- **`mpc.py::plan_step`** — MPPI softmax weighting over sampled candidates
  (not greedy argmin), first action of the blended sequence executed
  (receding horizon), diagnostics (`cost_min/mean/max`, effective sample
  size) returned every call so `temperature` miscalibration is visible
  rather than silent.
- **`mpc.py::run_episode`/`main()`** — one shared closed-loop harness for
  three policies (`mpc`, `zero`-action, `random`-action) run against an
  *identical* fixed list of `(start, goal)` pairs, reporting success rate,
  mean/median final distance-to-goal, and (for `mpc`) honestly-measured
  (not budgeted) planning latency and aggregated MPPI diagnostics.

**Verified 2026-07-17**: a direct diagnostic (500 random states, one fixed
sampled goal) found real-position distance and latent distance-to-goal only
moderately correlated (`r=0.63` via the online `encoder`, `r=0.64` via
`target_encoder`) — the trained latent space carries real but noisy
information about true spatial closeness, which bounds how tightly any
planner can steer.

`./WorldModel/mpc.py --episodes 100 --seed 1` at three horizons, all
against the identical 100 `(start, goal)` pairs:

| horizon | mpc success / mean dist | zero success / mean dist | random success / mean dist | mean latency | effective sample size |
|---|---|---|---|---|---|
| 5  | 0.13 / 0.536 | 0.07 / 1.060 | 0.14 / 0.947 | 5.6 ms | 372/512 |
| 10 (default) | 0.13 / 0.449 | 0.07 / 1.060 | 0.11 / 0.990 | 7.4 ms | 157/512 |
| 25 | 0.18 / 0.470 | 0.07 / 1.060 | 0.11 / 1.024 | 11.5 ms | 6/512 |

On the continuous metric, MPC's mean final distance is robustly and
substantially better than both baselines at every horizon tested (roughly
45-55% closer than zero, 40-50% closer than random) — a real, consistent
steering effect. The binary success rate (tight `0.1` tolerance) is noisier
and less decisive at `n=100`: MPC modestly beats both baselines at horizon
10 and 25, but is edged out by the random baseline by one point at horizon
5 (`0.13` vs `0.14`) — well within noise for a tight-tolerance metric on top
of an `r≈0.63` latent-to-position correlation. `zero`'s numbers are
identical across all three rows (`0.07` / `1.060`), confirming the episode
list really is reproduced identically across horizon runs, as designed.

**A genuine finding from the built-in MPPI diagnostics, not a clean
"longer horizon helps/hurts" answer**: effective sample size collapses
from `372/512` (horizon 5) to `157/512` (horizon 10) to `6/512` (horizon
25) at the fixed default `temperature=1.0`. Cost is summed over the whole
horizon, so raw cost magnitude scales with `horizon` while `temperature`
doesn't — at horizon 25 the softmax has become nearly greedy argmin rather
than a true MPPI blend. The horizon-25 row above is therefore confounded
by an uncalibrated temperature, not a clean test of what happens once
planning exceeds Day 3's ~15-step trustworthy-rollout limit. A fair test
would need `temperature` re-tuned (or cost normalized by horizon) at each
horizon — flagged here as a well-motivated follow-up, not implemented in
this landing since it goes beyond what was scoped.

## Explicitly out of scope for this spike (so far)

- Any connection to real EEG data, `SpectralState`, or `TelemetryEvent` —
  a future decision, made only after the architecture is proven here.
- Any change to `InteractionLogging`/`interactionLoggingEnabled`'s opt-in
  default — that's ADR-005's invariant, untouched by this work.
