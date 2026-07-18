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

### Day 3 — The Representation Loss & Training Loop (not started)

The hard part: avoiding representation collapse (mapping every state to a
constant so prediction loss is trivially zero).

$$\mathcal{L}_{pred} = \lVert P_\phi(E_\theta(s_t), a_t) - E_{\bar\theta}(s_{t+1}) \rVert_2^2$$

EMA update, never via gradient descent: $\bar\theta \leftarrow \tau\bar\theta + (1-\tau)\theta$.

Deliverable: a predictor that unrolls latent trajectories across a
multi-step horizon without diverging.

### Day 4 — Latent Model Predictive Control (not started)

Freeze the trained JEPA. Sample $N$ candidate action sequences over horizon
$H$, unroll each in latent space via the frozen predictor, score by distance
to a goal latent, execute the first action of the best sequence, replan
(receding horizon). This is where the `goal` concept enters the environment
for the first time.

## Explicitly out of scope for this spike (so far)

- Any connection to real EEG data, `SpectralState`, or `TelemetryEvent` —
  a future decision, made only after the architecture is proven here.
- Any change to `InteractionLogging`/`interactionLoggingEnabled`'s opt-in
  default — that's ADR-005's invariant, untouched by this work.
