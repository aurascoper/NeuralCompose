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
- **Evidence:** Stage 3.3 benchmark: score 0.606, 1980 emb/s, 497MB RSS, stability 0.868. Pareto-optimal on throughput + memory + quality. 6/6 Pareto-optimal models identified, MiniLM dominates on speed/memory.
- **Supporting hypotheses:** (pending 3.4-A runtime consistency confirmation)
- **Supporting benchmark(s):** `Evaluation/results/embeddings/all-MiniLM-L6-v2/python/benchmark.json`, `Evaluation/results/embeddings/leaderboard.json`
- **Confidence:** Medium — pending Stage 3.4 cross-runtime consistency and cross-model agreement analyses
- **Status:** Accepted (provisional — will revisit if 3.4-A shows runtime drift or 3.4-D shows high disagreement)

### 2. Qwen2.5-0.5B as default generator

- **Decision:** qwen2.5-0.5b is the default generator (latency binding constraint for EEG communication)
- **Evidence:** Stage 3.3 benchmark: 40.9 tok/s vs gemma-3n-e2b 7.2 tok/s (p<0.0001, d=17.7). Pareto-optimal on latency. Gemma slightly higher cosine (0.771 vs 0.744, not significant after Bonferroni).
- **Supporting hypotheses:** 3.4-E (generator comparison)
- **Supporting benchmark(s):** `Evaluation/results/raw.json`, `Evaluation/results/leaderboard.json`
- **Confidence:** Medium — pending Stage 3.4-E generator agreement analysis
- **Status:** Accepted (provisional)

### 3. Gemma-3n-E2B as optional quality generator

- **Decision:** gemma-3n-e2b as optional generator for quality-critical tasks
- **Evidence:** Stage 3.3 benchmark: Pareto-optimal on quality. Slightly higher cosine than Qwen (not significant after Bonferroni). 7.2 tok/s — too slow for real-time EEG but viable for non-time-critical rewrites.
- **Supporting hypotheses:** 3.4-E (generator comparison), 3.5-D (cascaded generation)
- **Supporting benchmark(s):** `Evaluation/results/raw.json`, `Evaluation/results/leaderboard.json`
- **Confidence:** Medium
- **Status:** Deferred (pending 3.5-D cascade evaluation — may become the "quality edit" stage in a fast-draft + quality-edit cascade)

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
