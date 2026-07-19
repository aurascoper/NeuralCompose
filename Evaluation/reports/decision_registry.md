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

### 5. Adaptive routing for production (partially evaluated)

- **Decision:** Whether to replace fixed model selection with adaptive routing by input type
- **Evidence:** `3.5-P` evaluated 2026-07-16: Adaptive lands on the 4-way Pareto frontier alongside Fast/Balanced/Quality (quality 0.843, latency 3.010s, memory 3910MB — no policy strictly dominates another on all three axes). Adaptive's routing was resolved against `generation_eval_prompts_v1.json`'s existing categories as a proxy for input type (no corpus is labeled with the routing rule's exact short_command/technical/uncertain taxonomy — see `run_stage_3_5.py`'s module docstring for the full methodology and its caveats, including that the embedding rule's "uncertain -> confidence_gated" branch has no real confidence signal yet and was resolved as a mid_tier proxy). `3.5-B` (adaptive embedding routing specifically) is still unevaluated.
- **Supporting hypotheses:** 3.5-B (adaptive routing, pre-registered, not yet evaluated), 3.5-P (pipeline policies, **evaluated**, PASS)
- **Supporting benchmark(s):** `Evaluation/results/stage_3_5/pipeline_policies.json`, `Evaluation/results/stage_3_5/pipeline_policies.md`
- **Confidence:** Low-Medium — 3.5-P's Pareto result is a real signal, but it's built on an approximate input-type taxonomy and reuses frozen Stage 3.4 leaderboards rather than a purpose-built routing corpus; 3.5-B would sharpen this
- **Status:** Pending Stage 3.5-B (Adaptive being Pareto-optimal in 3.5-P is a necessary but not sufficient condition — it doesn't yet validate the routing rule's category assignments themselves)

### 6. Cascaded generation (pending)

- **Decision:** Whether to use a fast-draft + quality-edit cascade instead of a single generator
- **Evidence:** TBD — Stage 3.5-D will evaluate cascade vs single-model within latency budget
- **Supporting hypotheses:** 3.5-D (cascaded generation)
- **Supporting benchmark(s):** TBD
- **Confidence:** Low — no evidence yet
- **Status:** Pending Stage 3.5-D

### 7. Dream-mode design reviewed as offline wrapper (audit, not build)

- **Decision:** Treat the pasted Python dream-incubation design (`DreamExtractionPipeline`, `SymbolicCache`, `PrimerGenerator`, `DreamSessionFSM`, `subprocess.Popen(['say'])`) as **offline tooling** under the existing Swift-native D1–D8 design in `SLEEP_CYCLE_DESIGN.md`. Production runtime (FSM in `Sources/BCICore/Sleep/`, audio in `Sources/BCIVoice/`, dream-analysis LLM in `Sources/BCILLM/`) stays deferred to Stage 4 per the boundary contract.
- **Evidence:** (a) User confirmed `qwen2.5-0.5b` is the candidate dream-mode LLM (matches `decision_registry.md` entry 2 — accepted default generator). (b) The pasted `DreamSessionFSM` and `say` TTS are Python runtime paths; running them mid-session would add cross-process latency that risks dropping BrainFlow packets, contradicting the project's low-latency, on-device posture. (c) The existing `Sources/BCIVoice/AVSpeechSynthesizerService.swift` already provides Swift-native TTS via AVFoundation (actor, `speak(_:)` async API); a separate `HypnosisSynthesizer` singleton would duplicate it. (d) No labeled sleep-staging dataset exists in the repo — `Recordings/` contains Muse validation (eyes-open/closed alpha) and one calibration labels file, not PSG. (e) The brief's Risk Register already names "Domain shift from PSG datasets (central/occipital channels vs frontal)" as the largest expected source of error; the Random Forest sketch is fine for an MVP offline pipeline test on synthetic data but real-data cross-subject performance is unproven.
- **Supporting hypotheses:** `Evaluation/corpora/dream_mode_hypothesis_registry.json` (4 pre-registered hypotheses: S-1 routing/cascades/policies schema, S-2 Python offline extraction + human-rated drift baseline, S-3 Random Forest sleep-stage classifier on synthetic data, S-4 Stage 4 Swift actor FSM deferred). S-3 has both milestones landed (synthetic generator + RF trainer, per-seed mean macro F1 0.9394 +- 0.0127 on synthetic, honest framing on in-distribution testing). S-2 has milestones 1, 2, and 3 landed (three-pass pipeline passed on synthetic rho 0.9856; FAILED rho >= 0.6 on human-rated fixture with the proxy: 0.1352; LLMDriftScorer backend wired to a real Ollama server with a DriftScoring protocol that preserves the importable API; urllib.request-based zero-deps client; JSON-mode response_format; multi-seed evaluation harness landed 2026-07-19). The full multi-seed bake-off across the qwen2.5 ladder and the r1 reasoning-distill (on n=6 human-rated) found: qwen2.5:0.5b mean -0.08 std 0.38 95% CI [-0.41, +0.25] (in the noise); qwen2.5:1.5b mean -0.09 std 0.24 [-0.30, +0.12] (in the noise); qwen2.5:3b mean +0.00 std 0.00 (deadlocked); deepseek-r1:1.5b + r1 prompt mean +0.27 std 0.56 [-0.36, +0.91] (R1 reasoning hypothesis falsified at 1.5B distill size, CI crosses zero). The only configuration that robustly clears rho >= 0.6 is the cloud `deepseek-v4-flash:cloud` (v1 prompt, 3-run mean rho +0.84 std 0.05 95% CI [+0.75, +0.93], mean|err| 0.12) - a network cloud model, NOT the spec candidate. **S-2 candidate decision is PENDING**: the user's intended replacement (per out-of-band 2026-07-19 correction) is `deepseek-r1:1.5b` (DeepSeek-R1-Distill-Qwen-1.5B), which has been pulled and tested - the r1 prompt topology (think tags + tail JSON, regex extraction) is in place but the 1.5B distill size is empirically undersized for the human-rated fixture. The user is the final call on the candidate; queued candidates for further testing are deepseek-r1:7b/8b/14b/32b (larger R1 distills, ~4-20 GB q4_K_M disk), non-deepseek reasoning families (qwen3, etc.), or accepting deepseek-v4-flash:cloud with the offline-only caveat. The R1 prompt + regex tail-extractor is preserved on disk for the falsification record. S-4 still pre-registered.
- **Supporting benchmark(s):** `Scripts/dream_extraction.py` (S-2 milestone 1: three-pass extraction + drift scoring, Spearman validation), `Data/synthetic_dream_reports.json` (synthetic baseline, rho 0.9856), `Data/human_rated_dream_reports.json` (user-curated real-style fixture, rho 0.1352 — empirically validates the prototype's morphology/synonym limitations), `Scripts/train_rf_model.py` (S-3 milestone 2: LOSO Random Forest), `Scripts/generate_synthetic_sleep.py` (S-3 milestone 1: synthetic hypnogram generator), `Scripts/dream_mode_hypothesis_registry.py` (config manager, landed 2a834de), `Evaluation/corpora/dream_mode_hypothesis_registry.json` (decoupled, S-2 and S-3 status_notes updated with smoke-test evidence and honest framing), `docs/SleepCycleDesign.md` (appended audit section), `Sources/BCIVoice/AVSpeechSynthesizerService.swift` (existing TTS path), `SLEEP_CYCLE_DESIGN.md` (production design), `Evaluation/reports/decision_registry.md` (this entry).
- **Confidence:** Medium — design schema is well-formed (paste-driven, integrated into existing governance); runtime path is unbuilt; boundary contract applies.
- **Status:** Pending Stage 4 entry. No production code lands for the dream-mode runtime in this session. Offline tooling (Python extraction, drift scoring against a human-rated baseline) and the schema-only hypothesis registry can land now; FSM-in-Swift, TTS-cue-path-in-`BCIVoice/`, and dream-analysis-LLM-in-`BCILLM/` all require Stage 4 evidence gate per `decision_registry.md` boundary contract (AA6545F1 / EF7BC788 / B4BBC32A).
<!-- Last updated: 2026-07-19T08:30:00Z (S-2 multi-seed + R1 distill: cloud scorer only; candidate decision pending user's call) -->
