# Decision Registry

> Bridge between scientific findings (Stage 3.3/3.4/3.5) and future engineering work (Stage 4).
> Updated after every analysis completes. Each entry links a decision to the evidence that supports it.

## Schema

Each entry:
- **Decision** — the architectural or model choice being considered
- **Evidence** — what data supports or refutes it
- **Supporting hypotheses** — which hypothesis registry IDs (e.g., 3.4-A, 3.5-P)
- **Supporting benchmark(s)** — which benchmark artifacts (file paths)
- **Confidence** — High / Medium / Low
- **Status** — Accepted / Deferred / Rejected / Pending

---

## Entries

### 1. MiniLM remains default embedding

- **Decision:** all-MiniLM-L6-v2 stays the default embedding model for production
- **Evidence:** Frozen Stage 3.4 leaderboard (2026-07-14, 11 evaluated models): rank #1, score 0.855, quality 0.7336, stability 0.868, 1015 emb/s, 506 MB RSS, Pareto-optimal. (An earlier entry cited 1980 emb/s from a lost source JSON — resolved in `throughput_discrepancy.md`: throughput on this machine is load-dependent by >2×, quality metrics reproduce to |Δ|≤0.0008; the leaderboard value now re-derives mechanically from the on-disk checkpoint, enforced by the validator.)
- **Supporting hypotheses:** 3.4-A **evaluated** — runtime equivalence confirmed, 4/4 cross-runtime comparisons (MiniLM py↔mlx-swift; bge-small py↔mlx-swift/py↔coreml/mlx-swift↔coreml) at cosine 1.000000, see `cross_runtime_consistency.json`. 3.4-D evaluated (pilot) — pairwise Jaccard@5 0.66–0.80 across 3 models, see `cross_model_agreement.json`.
- **Supporting benchmark(s):** `Evaluation/results/embeddings/all-MiniLM-L6-v2/python/benchmark.json`, `Evaluation/results/embeddings/leaderboard.json`, `Evaluation/results/stage_3_4/cross_runtime_consistency.json`
- **Confidence:** High — 3.4-A shows no runtime drift; repro run reproduces every quality metric within tolerance
- **Status:** Accepted

### 2. Qwen2.5-0.5B as default generator

- **Decision:** qwen2.5-0.5b is the default generator (latency binding constraint for EEG communication)
- **Evidence:** Stage 3.3 two-model comparison: 40.9 tok/s vs gemma-3n-e2b 7.2 tok/s (p<0.0001, d=17.7); Pareto-optimal on latency. Frozen fleet leaderboard (2026-07-14, 16 evaluated): qwen2.5-0.5b rank #2 (score 0.801), behind tinyllama-1.1b (#1, 0.843) and ahead of smollm2-360m (#3, 0.784) — all three Pareto-optimal. qwen2.5-0.5b has the lowest RSS of the top 3 (707 MB vs tinyllama's 1455 MB). Reproducibility caveat (repro_report, 2026-07-14): generation quality metrics vary run-to-run beyond tolerance (instruction_following ±0.2, stability ±0.06 observed on the qwen repro pair), so the top-3 composite ordering is within measurement noise on its quality components.
- **Supporting hypotheses:** 3.4-E **evaluated** — 10 generators, 45 pairs, 27 prompts, mean pairwise cosine ~0.55 (generators genuinely divergent), see `generator_comparison.json`
- **Supporting benchmark(s):** `Evaluation/results/leaderboard.json`, `Evaluation/results/stage_3_4/generator_comparison.json`, `Evaluation/results/repro/repro_report.json`
- **Confidence:** Medium — fleet evidence complete, but the #1/#2 composite gap is inside observed run-to-run variance
- **Status:** Accepted. Human review completed 2026-07-16 (Stage 3.5 readiness signoff): qwen2.5-0.5b confirmed as default over tinyllama-1.1b. Reasoning — tinyllama's composite advantage (0.843 vs 0.801) is within the run-to-run variance noise documented above, so it isn't a reliable quality edge; qwen's ~2× lower RSS (707 MB vs 1455 MB) matters more here than in a typical eval, since the generator process shares memory with live EEG windowing, classification, and spectral encoding. This resolves `Evaluation/reports/STAGE_3_5_READINESS.md`'s signoff condition #2 and unblocks Stage 3.5 policy-registry work (`3.5-P`, `3.5-D`) from encoding this default.

### 3. Gemma-3n-E2B as optional quality generator

- **Decision:** gemma-3n-e2b as optional generator for quality-critical tasks
- **Evidence:** Stage 3.3 two-model comparison: Pareto-optimal on quality, higher cosine than Qwen (0.771 vs 0.744, not significant after Bonferroni), 7.2 tok/s — too slow for real-time EEG but viable for non-time-critical rewrites. Fleet context (frozen leaderboard 2026-07-14): several evaluated models now post higher meaning cosine at better latency — qwen2.5-3b 0.794, qwen3-4b 0.793, gemma-3-1b 0.791 — so gemma-3n-e2b is no longer the obvious quality pick for a cascade's edit stage.
- **Supporting hypotheses:** 3.4-E **evaluated** — see `generator_comparison.json`; 3.5-D (cascaded generation, pre-registered)
- **Supporting benchmark(s):** `Evaluation/results/leaderboard.json`, `Evaluation/results/stage_3_4/generator_comparison.json`
- **Confidence:** Medium
- **Status:** Deferred (pending 3.5-D cascade evaluation — the quality-edit-stage candidate set should be drawn from the frozen leaderboard, not assumed to be gemma-3n-e2b)

### 4. Joint embeddings for production (pending)

- **Decision:** Whether to adopt joint/fused embeddings for production retrieval
- **Evidence:** TBD — Stage 3.4-B/F will evaluate fusion strategies (concatenation, weighted, PCA, late fusion)
- **Supporting hypotheses:** 3.4-B (joint embeddings), 3.4-F (offline fusion)
- **Supporting benchmark(s):** TBD
- **Confidence:** Low — no evidence yet
- **Status:** Pending Stage 3.4-B+F (deferred until streaming benchmark completes)

### 5. Adaptive routing for production (pending)

- **Decision:** Whether to replace fixed model selection with adaptive routing by input type
- **Evidence:** TBD — Stage 3.5-B will evaluate adaptive embedding routing; Stage 3.5-P will compare Fast/Balanced/Quality/Adaptive policies
- **Supporting hypotheses:** 3.5-B (adaptive routing), 3.5-P (pipeline policies)
- **Supporting benchmark(s):** TBD
- **Confidence:** Low — no evidence yet
- **Status:** Pending Stage 3.5-B + 3.5-P

### 6. Cascaded generation (pending)

- **Decision:** Whether to use a fast-draft + quality-edit cascade instead of a single generator
- **Evidence:** TBD — Stage 3.5-D will evaluate cascade vs single-model within latency budget
- **Supporting hypotheses:** 3.5-D (cascaded generation)
- **Supporting benchmark(s):** TBD
- **Confidence:** Low — no evidence yet
- **Status:** Pending Stage 3.5-D
<!-- Last updated: 2026-07-14T06:42:04Z (Stage 3.4 run) -->
<!-- Last updated: 2026-07-14T12:12:53Z (Stage 3.4 run) -->
