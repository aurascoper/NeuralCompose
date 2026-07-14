# Stage 3.4 Audit (closure)

**Date:** 2026-07-14 (overnight closure run)
**Auditor:** autonomous closure loop, gated by `validate_checkpoints.py`
**Supersedes:** the 02:12 mid-stage progress audit previously at this path (preserved in git history, commits `d691e25`/`d79af03`); an independent parallel audit lives at `stage_3_4_audit_independent.md`.
**Evidence freeze:** `Evaluation/stage_3_4/frozen/` (183 files, 6.7 MB, all checksums verify via `shasum -c`)
**Git state at audit:** branch `research/lit-review-methodology` == `feat/generation-eval-harness`; closure commits tonight: `a85bc73`, `42b93ef`, `989278a`, `7afc85d`, `35bf132`, `2040b7b`, `df47242`, `a65886d`, `ceb9826`, `5da1765`, `c3eebb0`, `320b28d`, `75cbb38`, `20f6de8`
**GenerationEval campaign binary:** sha256 `3ae8bf84e1102fbf…` (stamped into every generation checkpoint; preserved copy at `Evaluation/results/repro/bin/GenerationEval-campaign`)

## 1. Hypotheses — evaluated / blocked / deferred

| ID | Status | Outcome |
|----|--------|---------|
| 3.4-A runtime consistency | **evaluated** | Runtime equivalence CONFIRMED: 4/4 cross-runtime comparisons (MiniLM py↔mlx-swift; bge-small py↔mlx-swift, py↔coreml, mlx-swift↔coreml) at mean cosine 1.000000, N=10 stored samples per model. Two Swift-harness defects were caught by this very analysis and fixed before the final runs (see §5). |
| 3.4-B joint embeddings | **deferred (pre-registered)** | By design; `joint_embeddings.py` not implemented. |
| 3.4-C embedding-space geometry | **evaluated (pilot)** | N=10 stored samples; CKA biased high at small N (documented in status_note). Full-corpus analysis is future work. |
| 3.4-D cross-model agreement | **evaluated (pilot)** | 3 models with stored samples, pairwise Jaccard@5 0.66–0.80, N=10, k=5 of pool 9. |
| 3.4-E generator comparison | **evaluated (strong)** | 10 generators, 45 pairs, 27 prompts; mean pairwise cosine ≈ 0.55 — generators genuinely divergent. |
| 3.4-F offline fusion | **deferred (pre-registered)** | By design, with 3.4-B. |

## 2. Evidence base

- **Embedding track: 17/17 candidates terminal** — 11 evaluated; 6 recorded permanent failures with provenance and preserved failed attempts (`benchmark.failed-<ts>.json`): stella (xformers not installable in this environment), jina-v3 (custom remote code incompatible with the pinned transformers; rescuing it would have forked the environment under every other checkpoint, so recorded instead), gte-base (upstream repo resolution broken), gte-large (upstream tokenizer index bug), both `-mlx` 4-bit variants (loadable by neither `mlx_lm` — no BERT support — nor transformers).
- **Generation track: 18/18 candidates terminal** via the v3 fixture on the single preserved binary — 16 evaluated, gemma-3-4b recorded smoke-test failure, openelm-3b recorded unavailable (no instruct conversion; a base model is not comparable).
- **RQ1 instrumentation:** `MLXSentenceEmbedder` (BCILLM) + `EmbeddingBench --backend`, emitting reduced-schema checkpoints (runtimes `coreml`, `mlx-swift`) — commit `5da1765`. Explicitly not a production backend; nothing constructs it in `AppContainer`.
- **Superseded evidence** (harness-drift and RQ1 pre-fix runs) preserved as `benchmark.superseded-<ts>.json` — never deleted.

## 3. Evidence quality

- Every artifact produced tonight is provenance-stamped (git commit/branch/dirty, device, macOS, RAM, Python + package versions, corpus fixture sha256+version; generation checkpoints also carry binary sha256). Legacy artifacts are **not** backfilled — the validator marks them WARN ("pre-provenance legacy artifact"), honest history (18 warnings at freeze, 0 failures).
- Aggregate traceability is machine-enforced: every leaderboard row must re-derive from its on-disk checkpoint within 1e-6 (`validate_checkpoints.py`); this caught and retired the orphaned MiniLM 1980 emb/s value.
- Corpora are versioned-immutable with `MANIFEST.sha256` (7 fixtures, write permission removed). The hypothesis registry stays live by design; its Stage 3.4 snapshot is inside `frozen/manifest.json`.

## 4. Statistical power

- **RQ4 is adequately powered** for its claim (45 generator pairs × 27 prompts).
- **RQ2/RQ3 are pilots**: N=10 stored embedding samples per model; CKA known biased-high at this N. No geometry conclusion should be promoted to a decision without a full-corpus rerun.
- **Reproducibility is n=1 per track**: the variance numbers in §6 are single-pair observations, not distributions. A 5× repro series would turn them into real variance estimates; not run tonight (would not change the verdict class — see §6).
- Scored instruction-following uses a 5-prompt subset → granularity 0.2; a one-step difference is one prompt flipping.

## 5. Threats to validity

1. **Load-dependent performance metrics.** The controlled rerun measured MiniLM throughput 2.5× faster than the canonical mid-campaign value (2538 vs 1015 emb/s) while every quality metric reproduced within |Δ| ≤ 0.0008. Absolute perf numbers are lower bounds; cross-model perf comparisons are only meaningful within one campaign context (`throughput_discrepancy.md` Resolution, 2026-07-14).
2. **Generation quality metrics carry run-to-run variance** (temperature-0.7 sampling): meaning Δ0.014, stability Δ0.062, instruction-following Δ0.2 on the qwen2.5-0.5b repro pair — beyond the approved 0.005 quality tolerance. Composite-score gaps smaller than these bands (e.g. tinyllama 0.843 vs qwen 0.801) are within measurement noise on their quality components.
3. **Single-reference risk.** RQ1 equivalence is measured against the python sentence-transformers pipeline. Two Swift-side defects (MLXEmbedders omits the segment-0 token-type embedding when ids are nil; `.cls` pooling prefers the tanh pooler head) were caught because the python reference disagreed — an equivalent defect in the *reference itself* would be invisible. Triple agreement (python↔coreml↔mlx-swift) on bge-small mitigates but does not eliminate this.
4. **Single machine, single OS** (M4 16 GB; exact versions in provenance). No cross-device claims.
5. **Min-max normalized composite scores are pool-relative** — rankings shifted when new candidates landed; scores are only comparable within one frozen leaderboard generation.
6. **RQ1 covers 2 models, fp32-family weights, N=10 texts.** Quantized-weight runtime equivalence is untested.

## 6. Known failures and unmet criteria (recorded, not reinterpreted)

- **Generation reproducibility FAILS the approved 0.005 quality tolerance** (`Evaluation/results/repro/repro_report.md`). This is a *finding about generator nondeterminism*, not a data defect: latency/RSS/tok-s reproduce within ±13%. The mechanical exit-report rule therefore leaves "Reproducibility report PASS" unchecked and prints "not ready to close" — that rule was deliberately NOT relaxed tonight. Whether to close Stage 3.4 with the condition documented (this audit's recommendation) or to first require a variance-characterization addendum (e.g. 5× repro series with per-metric-class tolerance bands) is a **human decision**.
- The 0.005 tolerance was approved with deterministic embedding pipelines in mind; applying it to sampled generation conflates nondeterminism with irreproducibility. Flagged rather than silently rebanded.

## 7. Unsupported assumptions (labeled hypotheses, not conclusions)

- gemma-3-4b's smoke failure is *attributed* to the gemma-3 architecture predating the pinned mlx-swift — mechanism not confirmed (stderr preserved in the checkpoint).
- The orphaned 1980 emb/s value "plausibly an intermediate load state" is a hypothesis; its source JSON remains lost.
- jina-v3's `all_tied_weights_keys` failure is attributed to a transformers-version/remote-code mismatch from the error signature; no bisection was performed.

## 8. Tech debt

1. **`Sources/GenerationEval/` is uncommitted** (plus its Package.swift product/target hunks). Every generation checkpoint records the binary sha256, but the source that produced the campaign binary is not in git — the largest reproducibility gap in the evidence base. Commit it (separately from the pending predictor fix) as a fast follow.
2. Pending predictor fix (`MLXNextWordPredictor.swift`, `GenerationConfigurationTests.swift`) awaits the user's local validation — kept out of all closure commits.
3. `generate_exit_report.py` treats any repro FAIL as prerequisite-unmet; consider distinguishing metric classes (deterministic quality vs sampled quality vs perf) — only with user sign-off on the tolerance-policy change.
4. `overnight-preflight.sh` pgrep misses `*_streaming_benchmark.py` processes (pre-existing note).
5. `Scripts/build-xcode-mlx.sh` hardcodes the app scheme; EmbeddingBench/GenerationEval need manual `xcodebuild -scheme`.
6. Permanent environment constraints recorded: stella needs xformers; jina-v3 needs a different transformers pin; python `mlx_lm` cannot load encoders (Swift MLXEmbedders is the only MLX embedding runtime).
7. The preserved campaign-binary copy cannot run outside its build directory (metallib lookup) — repro used the hash-verified in-place binary; future archival should include the metallib or the whole products directory.

## 9. Reproducibility summary

| Track | Quality | Performance |
|-------|---------|-------------|
| Embedding (MiniLM, python) | PASS — every metric within Δ ≤ 0.0008 (tolerance 0.005) | cold-load & RSS PASS; throughput/warm-encode FAIL (load-dependent; resolved & documented) |
| Generation (qwen2.5-0.5b, campaign binary) | FAIL at 0.005 — nondeterministic sampling (Δmeaning 0.014, Δstability 0.062, Δinstr 0.2) | PASS except generate_time_mean (23% vs 20% band) |

## 10. Versions

- Corpus fixtures: generation candidates **v3**, prompts v1, embedding corpus v1, embedding candidates v1 (hashes in `Evaluation/corpora/MANIFEST.sha256`).
- Toolchain and package versions: recorded per-artifact in `provenance` blocks and at freeze time in `frozen/provenance.json` (Python 3.11 venv; mlx 0.32.0 / mlx-lm / einops installed mid-campaign 2026-07-14 — provenance distinguishes pre/post artifacts).
- Swift: mlx-swift-examples 2.25.7 (`MLXEmbedders`), full-Xcode build for Metal kernels.
