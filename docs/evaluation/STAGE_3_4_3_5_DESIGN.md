# Stage 3.4/3.5 Evaluation Design

> The roadmap now decomposes into a **scientific program** rather than
> just an engineering roadmap.
>
> - Stage 3.1–3.3 establish **individual component validity**.
> - Stage 3.4 establishes **interaction science**.
> - Stage 3.5 establishes **system engineering**.
> - Stage 4 deploys only what the evidence supports.

## Stage boundaries

| Stage | Scope | Production code changes? |
|-------|-------|---------------------------|
| 3.1–3.3 (done) | Individual component validity | No |
| 3.4 | Interaction science | **No** — offline analysis only |
| 3.5 | System engineering | **No** — offline policy evaluation only |
| 4 (future) | Deploy evidence-supported changes | Yes — Stage 4 **consumes** evidence, not generates it |

---

## Stage 3.4 — Cross-Model & Cross-Runtime Science

This stage answers five research questions.

### RQ1 — Runtime Equivalence

> Do identical models behave the same across runtimes?

Measure embedding cosine drift, nearest-neighbor preservation, ranking
stability, numerical precision, latency, and RSS across
Python → Core ML → MLX. The outcome isn't "which runtime is faster" but
**whether switching runtimes changes semantics**.

### RQ2 — Geometry

Don't use embeddings — study them. The frozen Stage 3.4 evidence base
holds 11 evaluated embedding models (of 17 attempted; 6 recorded
permanent failures), so this becomes interesting. Includes CKA, SVCCA,
scaled Procrustes (superimposition — tolerant of scale differences) and
orthogonal Procrustes (rotation-only — the stronger geometric claim;
see `methodology-review_v1.md`/`v2.md` Pillar A for why these two answer
different questions and shouldn't be conflated), neighborhood overlap,
trustworthiness, continuity, intrinsic dimensionality, spectral decay,
and manifold overlap. This is almost a paper by itself.

### RQ3 — Agreement

Instead of comparing vectors, compare decisions. For each utterance,
compute top-10 neighbors according to each model (MiniLM, BGE, E5,
Jina, ...). How often do they agree? Consensus itself becomes a signal.

### RQ4 — Generator Comparison

Exactly the same prompts → Qwen, Gemma, Phi, SmolLM. Measure
instruction following, verbosity, semantic preservation, decoder
stability, prompt echo, and hallucination. This remains offline. No
routing. No production decisions.

### RQ5 — Joint Representations

Only after benchmarking finishes. Take top 3 or top 5 models. Study
concatenation, weighted fusion, PCA, CCA, reciprocal-rank fusion, and
learned linear projections. Offline only.

---

## Stage 3.5 — Pipeline Engineering

Every experiment changes from "What is true?" to "What should the
software do?" This is a fundamentally different objective.

### Policy Registry

Policies bind to *abstract roles with latency budgets*, not to model
names — concrete models are resolved from the frozen Stage 3.4
leaderboards at policy-evaluation time (the canonical bindings and
budgets live in `Evaluation/corpora/hypothesis_registry.json` →
`policy_registry`). Hard-coding names here rotted once before: an
earlier draft pinned "Quality = BGE-M3", which the completed benchmark
ranks last among evaluated models.

| Policy | Retrieval binding | Generator binding | Latency budget | Goal |
|--------|-------------------|-------------------|----------------|------|
| Fast | auto:fastest_available | auto:fastest_available | 2.0 s | latency |
| Balanced | auto:mid_tier | auto:mid_tier | 5.0 s | compromise |
| Quality | auto:best_overall | auto:best_overall | 15.0 s | quality |
| Adaptive | learned router | selected dynamically | per-query | optimize utility |

### Routing

Adaptive routing becomes meaningful. Instead of "always BGE" you can
ask: technical? → BGE, otherwise → MiniLM. Or: confidence below
threshold? → second model.

### Cascades

Fast draft → quality refinement instead of one generator.

### Confidence

Evaluate single model vs fallback vs ensemble rather than simply
"best model."

---

## Hypothesis Registry

Every experiment is pre-registered in
`Evaluation/corpora/hypothesis_registry.json` **before** any code is
written. For every experiment, record:

- rationale
- expected effect size
- statistical test
- stopping criterion
- success criterion

This makes the evaluation substantially more rigorous.

## Evidence Registry

Every result should link back to:

- benchmark version
- corpus version
- model version
- runtime
- git commit
- hypothesis ID

rather than existing only inside markdown reports. This makes every
recommendation traceable.

## Decision Registry

`Evaluation/reports/decision_registry.md` bridges scientific findings
to future engineering work (Stage 4). Each entry captures Decision,
Evidence, Supporting hypotheses, Supporting benchmark(s), Confidence
(High/Medium/Low), and Status (Accepted/Deferred/Rejected/Pending).

Seeded with 6 entries from Stage 3.3 findings. Updated after every
Stage 3.4/3.5 analysis completes.

---

## Work packages

| WP | Stage | RQ | Script | Description |
|----|-------|-----|--------|-------------|
| A | 3.4 | RQ1 | `cross_runtime_consistency.py` | Cosine drift between Python/CoreML/MLX |
| B | 3.4 | RQ5 | `joint_embeddings.py` (deferred) | Concatenation, weighted, PCA, late fusion |
| C | 3.4 | RQ2 | `embedding_space_analysis.py` | CKA, SVCCA, Procrustes (scaled + orthogonal), neighborhood overlap |
| D | 3.4 | RQ3 | `cross_model_agreement.py` | Jaccard overlap of top-k neighbor sets |
| E | 3.4 | RQ4 | `generator_comparison.py` | Pairwise cosine, BLEU-4, exact match |
| F | 3.4 | RQ5 | `joint_embeddings.py` (deferred) | Fusion strategy comparison |
| A–E, P | 3.5 | — | `run_stage_3_5.py` | Pipeline benchmark, routing, cascade, confidence, policies |

## How to run

```sh
# Phase 1A (immediate — existing artifacts only)
python3 Evaluation/scripts/run_stage_3_4.py

# Phase 1B (deferred — after streaming embedding benchmark completes)
python3 Evaluation/scripts/joint_embeddings.py --top-k 3
python3 Evaluation/scripts/run_stage_3_4.py --include-deferred

# Stage 3.5 (deferred — after Phase 1B)
python3 Evaluation/scripts/run_stage_3_5.py

# Unit tests
python3 Tests/eval/test_eval_stats.py
python3 Tests/eval/test_embedding_space.py
```

## Deferral rationale

Joint embeddings (RQ5) are delayed until the embedding benchmark
completes. Running fusion experiments on an incomplete leaderboard
risks optimizing combinations that won't include the eventual strongest
models. Waiting lets us automatically select the top-K based on
completed evidence and keeps the combinatorial search tractable.

## How results inform Stage 4

The decision registry is the bridge. When Stage 3.4/3.5 analyses
complete, the aggregate runners update the registry with evidence,
confidence levels, and statuses. Stage 4 implementation decisions
should reference specific decision registry entries — not raw benchmark
JSON — so the chain from hypothesis → evidence → decision →
implementation is auditable.

## Documentation loop

Because both embedding and generation benchmarking frameworks are
built, Stage 3.4 and 3.5 feed directly into the documentation overhaul.
Instead of documenting only the implementation, `README.md` and
`docs/Math.md` document:

- the mathematical formulation of joint embeddings,
- the evaluation methodology (bootstrap CIs, Pareto frontiers, hypothesis testing),
- the routing objective functions,
- and the engineering hypotheses that motivate each stage.

This closes the loop between the implementation, the experiments, and
the mathematical specification, making the documentation itself a
faithful description of the scientific program rather than just the
code.