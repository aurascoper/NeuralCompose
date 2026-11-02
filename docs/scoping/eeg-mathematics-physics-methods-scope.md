# Scope — EEG Mathematics, Physics, and Methods

**Status:** scoped, 2026-07-22
**Applies to:** `EXP-NC-EEG-ENC-001` and its immediate prerequisites

## Decision

NeuralCompose will not treat mathematics, physics, optimization, and systems
theory as one undifferentiated research program. The current work uses a
layered scope:

1. a compact mathematical spine needed to collect and evaluate the
   four-channel encoder experiment;
2. a separate methods layer that can be introduced only when it answers a
   registered analysis question; and
3. a later control and policy layer, after an offline encoder has earned a
   stable structured-state contract.

This keeps the current question narrow:

> Given protocol-observable, four-channel Muse windows, which fixed encoder
> condition generalizes across complete recording sessions?

It does not ask whether NeuralCompose can infer thought, control dialogue from
EEG, solve a generic inverse problem, or build a general-purpose agent. Those
are different questions with different evidence requirements.

The governing experiment is
[`EXP-NC-EEG-ENC-001`](../../NeuralComposeEEG/experiments/EXP-NC-EEG-ENC-001.md).
Its source contract, grouped evaluation, and non-promotion rule take priority
over a method being mathematically interesting.

## The Scope Layers

### Layer 0 — Required Now

| Area | Working material | Concrete role |
| --- | --- | --- |
| Linear algebra | vectors, bases, projections, least squares, eigensystems, SVD, condition number | four-channel windows, calibration transforms, M0 linear probes, embeddings, PCA diagnostics |
| Signal processing | sampling, windowing, causal filtering, spectra, band power, cross-channel features, artifact quality | canonical 4 s / 256 Hz windows and deterministic M0 features |
| Probability and statistical learning | random variables, expectation, variance, losses, calibration, uncertainty | held-out scores and confidence intervals rather than training-loss claims |
| Evaluation design | confusion matrix, balanced accuracy, precision/recall/F1, AUROC where defined, Brier score, ECE, cost matrix | preregistered encoder outcomes and falsifiers |
| Dependence control | session-grouped splitting, train-only normalization, leakage analysis | overlapping one-second-stride windows remain within a complete recording session |
| Acquisition physics | clock provenance, four-channel montage, sampling rate, sensor contact, transport events | eligible physical recordings, not a theoretical convenience |

The codebase already implements much of this layer. In particular, it uses
calibration-only normalization and complete-session splits; no held-out session
may fit scaling, model parameters, class weights, or selection decisions. This
is the appropriate response to within-recording dependence, not a generic
random-fold exercise. The [scikit-learn grouped cross-validation
guidance](https://scikit-learn.org/stable/modules/cross_validation.html) makes
the same point: dependent samples from a group must not appear on both sides of
a generalization split.

`docs/Math.md` remains the home for mathematical definitions used by the
runtime or analysis. This document only decides *which subjects justify work*
in the current program.

### Layer 1 — Learn Now, Implement Only With a Registered Question

#### Measure, integration, and functional analysis

Study sets and sigma-algebras only far enough to make measurable maps,
expectations, integrals, product measures, convergence, and `L^p` spaces
usable. Then study normed spaces, Banach and Hilbert spaces, bounded operators,
duality, weak topology, and regularization as the language of stability for
noisy, partially observed signals.

Hahn-Banach, uniform boundedness, the open mapping theorem, and closed graph
theorem are valuable in this order: they clarify what continuity, stability,
and inverse maps demand. They do **not** by themselves authorize an EEG
algorithm. The [MIT functional-analysis notes](https://ocw.mit.edu/courses/18-102-introduction-to-functional-analysis-spring-2021/resources/lecture-notes/)
provide this applied sequence of Banach spaces, bounded operators, open mapping,
and Hahn-Banach.

Use this layer for a later, separately preregistered inverse-problem or
regularization study. Do not call the four-channel encoder benchmark a source
localization experiment.

The deterministic `EXP-FUNC-SYN-000` package rehearses empirical measures,
derivative distinctions, finite-basis Sobolev/Tikhonov fitting, Egorov's
theorem fixture, bounded-operator checks, and mixed-measure integration without
reading EEG or changing this experiment. See the [function-space decision
memo](../research/function-space-foundations-decision-memo-v0.md) and
[contract](../../configs/function-space-foundations-v0.json). A passing
synthetic fixture remains `insufficient_evidence`; it does not authorize a
preprocessing method.

#### Electroquasistatics and EEG forward models

The physical model worth learning is the low-frequency EEG forward problem:
scalar potential, conductivity, Gauss/Coulomb intuition, Poisson/Laplace
equations, Green-function reasoning, and Dirichlet/Neumann boundary conditions.
Under the EEG quasi-static approximation, this is the relevant mathematical
boundary-value problem, with BEM/FEM/FDM as later numerical methods. The
[EEG forward-problem review](https://pmc.ncbi.nlm.nih.gov/articles/PMC2234413/)
derives this Poisson/boundary-condition formulation.

This study is preparation for a future forward-model falsification experiment,
not an attempt to infer cortical sources from four Muse channels. Any such
experiment needs its own sensor geometry, conductivity assumptions, target,
error metric, and failure criterion.

#### IMU-assisted artifact work

Accelerometer and gyroscope signals belong in a sensor-fusion and artifact
quality track. They may later support movement-aware labels, rejection masks,
or late-fusion comparisons. They are not cognitive labels and are not inputs to
`EXP-NC-EEG-ENC-001` unless a new protocol revision explicitly adds them.

This is a practical priority for wearable EEG, where movement artifacts are
common and auxiliary IMUs remain underused; see the recent [wearable-EEG
artifact review](https://pmc.ncbi.nlm.nih.gov/articles/PMC12473706/). Preserve
the present separation: raw EEG remains the encoder input, while IMU evidence
can later be evaluated as quality or artifact information.

### Layer 2 — Optional Analysis Toolbox

Introduce one of these methods only when an experiment says what decision it
could change and what null result would retire it.

| Method | Allowed use | Guardrail |
| --- | --- | --- |
| PCA, ICA/FastICA, factor analysis, kernel or probabilistic PCA | train-only diagnostic, whitening study, representation inspection | never fit on held-out sessions; never substitute clusters for protocol labels |
| UMAP or other nonlinear visualization | exploratory plotting | never a primary generalization claim |
| K-means, DBSCAN, silhouette | data-quality and latent-structure checks | no post-hoc relabeling to improve encoder accuracy |
| Trees, random forests, shallow MLP, ELM | explicitly named secondary baseline | fixed budget, grouped evaluation, no promotion by speed alone |
| Cost-sensitive scoring | when a declared artifact or safety cost matrix exists | report total cost and the full confusion matrix, not accuracy alone |
| Survival/Cox methods | only with a genuine time-to-event endpoint | not a substitute for ordinary classification metrics |
| Monte Carlo or evolutionary search | bounded sensitivity study | seed, budget, objective, and stopping rule are versioned |

For Julia prototypes, use `MultivariateStats.jl` for PCA/ICA/factor-analysis
work and keep its column-as-observation convention explicit. Its
[documentation](https://juliastats.org/MultivariateStats.jl/dev/) lists the
available multivariate methods. Use JuMP with
[MathOptInterface](https://jump.dev/MathOptInterface.jl/stable/background/motivation/)
for optimization work; MathOptInterface replaces MathProgBase. Optim.jl is the
appropriate smaller tool for local smooth optimization. Julia remains an
offline scientific reference environment, following the
[Julia Science Workspace](../architecture/julia-science-workspace.md) boundary.

### Layer 3 — Deferred Policy and Control Theory

Game theory, operator-theoretic control, phase-transition models, agentic
reasoning, ARC transfer, and language-model policy belong only after all of
the following are true:

1. multiple protocol-complete physical sessions support a grouped encoder
   comparison;
2. an encoder condition is selected by its preregistered offline evidence;
3. the encoder exposes a frozen structured-state contract; and
4. a separate shadow-policy experiment defines a decision target, baseline,
   counterfactual controls, and safety constraints.

The current roadmap already reserves that work for `EXP-NC-ARC-XFER-001`. It
must consume structured state records, not raw EEG, and it cannot alter the
live app while it is being evaluated.

## Explicit Deferrals

The following are valid subjects, but are not load-bearing for the current
encoder experiment:

- full electrodynamics: plane waves, radiation, retarded solutions,
  waveguides, resonant cavities, optical fibres, scattering, diffraction,
  relativistic transformations, magnetic monopoles, and Dirac quantization;
- using electromagnetic-wave language as a metaphor for RPC/gRPC, cloud/local
  placement, CPU/GPU/ANE placement, or application control flow;
- broad general topology and complex analysis beyond the metric, continuity,
  compactness, weak-topology, and Fourier material needed by later analysis;
- full operator-theoretic control, game-theoretic policy selection, or any live
  language-model decision path;
- genetic algorithms, generalized disjunctive programming, or large operations
  research stacks as default encoder methods;
- a Rust kernel, Core ML conversion, or app integration for any unvalidated
  analysis result.

Deferral is a scope decision, not a judgement that these ideas are unworthy.
Each needs an experiment that makes it capable of being wrong.

## Named-Topic Disposition

The broad topic list is retained below as a decision register. “Learn” means
background study or a worked Julia/Python notebook; it does not grant a new
runtime dependency, telemetry field, or production algorithm.

| Topic family | Disposition | Constraint |
| --- | --- | --- |
| Set theory, metric spaces, vector sums/bases, linear maps, SVD | **Now** | learn through concrete matrices, calibration, projections, and low-rank diagnostics |
| General topology, local convexity, weak topologies, `C(X)`, complex analysis | **Learn for Pass 2** | use only where an inverse-problem or function-space hypothesis needs it |
| Measurability, integrals, measures, convergence, `L^p` spaces | **Now as foundation** | support uncertainty, losses, and signal/function-space reasoning; no measure-theory subsystem |
| Banach spaces, duality, Hahn-Banach, open mapping, bounded operators | **Learn for Pass 2** | motivate stability and regularization; no theorem becomes a product feature |
| PCA, ICA, factor analysis, discernibility or dimensionality diagnostics | **Layer 2** | fit inside training partitions; report instability and do not use an embedding plot as evidence |
| Confusion matrix, accuracy/balanced accuracy, weighted scores, precision/recall/F1, ROC/AUC/Gini | **Now** | choose outcomes before evaluation; ROC/AUC/Gini only for valid score/label settings |
| MSE, RMSE, SSE, curve fitting, regression trees/MLPs | **Conditional** | only for an explicitly continuous target; they do not replace the encoder’s classification contract |
| K-fold CV | **Conditional** | use a grouped form only; complete sessions, never overlapping windows, are the split unit |
| K-means, DBSCAN, silhouette | **Layer 2** | exploratory quality checks only; clusters never become retrospective ground truth |
| Pareto analysis, Cox survival, cost matrices | **Conditional** | Pareto requires declared competing objectives; Cox requires a genuine time-to-event endpoint; a cost matrix requires an approved error cost |
| ELM, genetic algorithms, Monte Carlo, Lagrangian relaxation, solver heuristics | **Deferred toolbox** | version seed, budget, objective, and falsification rule before a bounded comparison |
| Simplex, network optimization, generalized optimization | **Deferred** | enter only with an actual resource-allocation or graph-flow problem, not as encoder machinery |
| JuMP, Optim, MathOptInterface | **Layer 2 scientific tooling** | JuMP/MOI for a specified optimization model; Optim.jl for local smooth fits; never MathProgBase |
| Units/dimensions | **Now for physical artifacts** | record SI units and sampling/clock units in acquisition and forward-model artifacts; add `Unitful.jl` only when a Julia model needs dimensional checking |
| Gadfly, Makie, PyPlot/Matplotlib | **Output hygiene** | visualization is exploratory unless an experiment specifies it; publication PDF output must avoid Type 3 fonts and preserve reproducible plotting configuration |
| Coulomb/Gauss/scalar potential/surface discontinuities/Poisson/Laplace/Green functions/uniqueness | **Pass 2** | electroquasistatic EEG forward-model foundations, not a four-channel source-localization claim |
| Retarded fields, Poynting theorem, radiation, transformations, monopoles, waves/cavities/fibres | **Out of current program** | retain as a separate electromagnetism curriculum, without systems-computing metaphors |
| Accelerometer, gyroscope, contact and movement sensing | **Pass 2 sensor fusion** | begin as aligned artifact/quality evidence; add it to an encoder only under a new protocol and matched-control experiment |
| Locks, queues, monotonic clocks, deterministic replay | **Engineering, not mathematical scope** | protect acquisition timing and reproducibility; they are not state-estimation features |
| Phase transitions, operator theory, game theory, ARC or language-model reasoning | **Pass 4** | offline structured-state policy study after encoder selection; no raw EEG or live-control path |

## Four Research Passes

| Pass | Scope | Entry gate | Deliverable |
| --- | --- | --- | --- |
| 1. Encoder evidence | acquisition contract, deterministic windows, M0–M4, grouped metrics | eligible multi-day `encoder-pilot-v1` recordings | non-promotable benchmark report |
| 2. Forward/inverse foundations | regularization, electroquasistatic forward models, BEM/FEM intuition | a specific source/forward-model hypothesis | falsifiable Julia reference experiment |
| 3. Methods broadening | PCA/ICA, cost matrix, clustering, optimization, plotting hygiene | a documented decision gap in Pass 1 or 2 | versioned analysis artifact with controls |
| 4. Shadow policy | game/control ideas, structured-state reasoning, transfer controls | selected frozen encoder and state contract | offline policy experiment, never raw EEG to live control |

`EXP-NC-EEG-ENC-001` is only Pass 1. Its pilot result is always
`insufficient_evidence` and `promotion_status: not_eligible`; neither clever
mathematics nor a high training score changes that status.

## Ownership and Artifact Rules

This scope follows the [three orthogonal
concerns](../architecture/three-orthogonal-concerns.md):

- **Science:** questions, mathematical models, Julia experiments, registered
  hypotheses, and papers;
- **Engineering:** frozen acquisition build, protocol logs, telemetry, capture
  manifests, and measurement integrity;
- **Computation:** deterministic Swift/Rust interfaces and offline Julia/Python
  reference implementations.

No theory becomes an app setting merely because it has a name. A theory may
generate an observable, a prediction, and a falsification criterion. Only a
validated deterministic computation can later be considered for a Rust kernel;
Swift remains the interaction and orchestration layer.

## Immediate Next Work

1. Collect the first clean `encoder-pilot-v1` Muse session with the frozen
   acquisition contract; validate it without training an encoder.
2. Collect a second eligible session on a different day under the same stimuli,
   build the canonical dataset, and run M0/M1 as pipeline evidence only.
3. Record any mathematical question that cannot be answered by Pass 1 as a
   separate hypothesis before adding a package, model, or runtime path.

`EXP-FUNC-SYN-000` may run in parallel because it uses embedded synthetic
parameters only. It is not a prerequisite for the first physical capture and
must not delay the D0-to-D1 acquisition sequence.
