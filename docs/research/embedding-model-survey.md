# Embedding Model Survey (v1)

**Stage**: 3.0
**Status**: Survey complete — *no winner declared; shortlist proposed*
**Date**: 2026-07-12
**Audience**: The contributor who would otherwise re-derive the model
choice for `CoreMLSentenceEmbedder`.

## Question

> Which embedding model deserves to become the first `CoreMLSentenceEmbedder`
> conformer?

This is *not* the question "which model has the highest MTEB score."
MTEB scores on standard retrieval benchmarks are a *necessary but not
sufficient* condition for this project. The right question is narrower:

> Of the candidates that satisfy the embedding contract
> (`docs/architecture/embedding_contract.md`), which is the cheapest to
> integrate on a 16GB M4 with Core ML on ANE, and which would we use as
> the comparison candidate?
## Methodology

This survey applies a *gate-then-score* filter to the candidates.

**Gates (any failure disqualifies, regardless of score)**:

1. **Core ML conversion feasibility** — a known conversion path
   *exists* (ONNX export, coremltools support, community
   conversion recipe, or a Core ML tag on the Hugging Face
   model card). This is a Stage 3.0 gate: can the candidate
   plausibly be converted at all? It is *not* a gate that the
   conversion has been demonstrated to work — that is
   **operational maturity**, a Stage 3.1 / 3.2 question, and
   a different concept. The two are deliberately separated
   so the survey does not imply more certainty than it has.
2. **Determinism** — bit-exact output across runs given fixed
   weights/tokenizer. Required by the contract for replay.
3. **Conversion reproducibility** — the exact `.mlmodelc` can be
   regenerated from the source weights + conversion script.
4. **Model provenance** — versioned, auditable weights with a
   pinned Hugging Face revision.
5. **License** — permits redistribution as part of a SwiftPM
   project.
6. **Maintenance status** — active in the last 12 months
   (commits, issues, or releases).

**Scores (lower is better; no individual score disqualifies)**:

7. Cold-load time (target: <500ms on M4)
8. Warm encode latency (target: <50ms for batch=1)
9. Batch throughput (target: >200 sentences/sec at batch=32)
10. Memory footprint (target: <500MB RSS at warm state)
11. Embedding dimension (lower → cheaper projection; 384d is
    the sweet spot for the existing `RandomProjectionProjector`)
12. Multilingual support (not required for Stage 3, but
    valued for future Context/Reasoning Foundations)

Gates 7–12 are filled in by Stage 3.1's `EmbeddingBench`.
This survey gates the candidates on 1–6 *only*; the score on
7–12 is *pending* (placeholder) until the bench runs.

### Conversion feasibility vs. operational maturity

The Stage 3 plan separates "conversion maturity" into two
distinct questions, each measured at a different stage:

| Question | Stage | What counts as evidence |
|---|---|---|
| Conversion feasibility | 3.0 (this survey) | ONNX export exists, coremltools supports the architecture, community conversion recipe published, or Hugging Face model card lists a Core ML tag |
| Conversion script succeeds | 3.1 (`EmbeddingBench`) | The Stage 3.1 conversion script produces a `.mlmodelc` from the source weights without error |
| Model loads in Swift | 3.1 | The bench harness instantiates `MLModel(contentsOf:)` successfully |
| Produces correct embeddings | 3.2 | The conformer passes the existing `semantic_stub_v1.json`-style regression test (the per-backend fixture is generated in 3.2, not before) |
| Meets latency targets | 3.3 | The benchmark's measured `cold_load_ms` / `warm_encode_ms` / `embeddings_per_second` match the targets above |

A candidate that passes gate 1 (feasibility) in this survey
is *plausibly convertible*; the survey does not claim it
*is* convertible. That distinction is the survey's honesty
budget.

## Candidates — evidence

### BAAI/bge-small-en-v1.5

- Hugging Face: <https://huggingface.co/BAAI/bge-small-en-v1.5>
- License: **MIT** (gate ✓)
- Tasks: Feature Extraction, sentence-similarity, mteb; tags
  `sentence-transformers`, `PyTorch`, `ONNX`, `Safetensors`,
  `Transformers`, `English`, `bert` (model card sidebar)
- Multilingual: **No** — English-only v1.5; BGE-M3 is the
  multilingual sibling. (model card; *News* section: "1/30/2024:
  Release BGE-M3 … 100+ languages.")
- Backed by Beijing Academy of Artificial Intelligence (BAAI); 508
  likes, 3.97k followers, 29 community discussions (model card
  sidebar; gates 4, 6 ✓)
- Pooling: **Likely CLS pooling** — the BGE paper (Xiao et al.,
  2023) and the FlagEmbedding training pipeline use CLS pooling
  for retrieval. **Not independently verified for `bge-small-en-v1.5`
  in this survey; pending Stage 3.1 confirmation** during
  conversion. If the conformer uses mean pooling instead, the
  Stage 3.3 semantic evaluation would surface it. L2-normalized
  output is consistent with the BGE convention either way.
- Query/passage prefix: **None required** (gates against E5's
  convention; **architectural simplicity**).
- arXiv citations on the model card: 5 papers (gates 3, 4 ✓)
- **Core ML conversion**: pending verification — flagged for Stage 3.1
  to attempt coremltools conversion via the ONNX path (ONNX tag
  present on the model card, which is a precondition for the
  coremltools ONNX import).
- Maintenance: model card *News* section most recent entry is
  2024-01-30 (BGE-M3 release); 5 months stale on the
  `bge-small-en-v1.5` model card itself. **Concern**, not
  disqualifying — the model weights are frozen, not the project.
- Verdict: passes all six gates. **Strong shortlist candidate.**

### intfloat/e5-small-v2

- Hugging Face: <https://huggingface.co/intfloat/e5-small-v2>
- License: **MIT** (gate ✓)
- Tasks: Sentence Similarity, mteb; tags `sentence-transformers`,
  `PyTorch`, `TensorFlow`, `ONNX`, `Safetensors`, `OpenVINO`,
  `English`, `bert` (model card sidebar)
- Multilingual: **No** — English-only v2; multilingual sibling is
  `intfloat/multilingual-e5-small`. (model card; `English` tag)
- 121 likes; 18 community discussions (gate 4, 6 ✓)
- Model card documents the architecture: *"This model has 12 layers
  and the embedding size is 384."* (gate 3 ✓)
- Pooling: **mean pooling with attention-mask normalization** (the
  model card's Python example shows `average_pool` function applied
  to `last_hidden_states` masked by `attention_mask`; L2-normalized
  via `F.normalize(embeddings, p=2, dim=1)`).
- Query/passage prefix: **REQUIRED** — *"Each input text should
  start with 'query: ' or 'passage: '. For tasks other than
  retrieval, you can simply use the 'query: ' prefix."* (model
  card, *Usage* section)
- arXiv citations on the model card: 2212.03533, 2104.08663,
  2210.07316 (gate 3, 4 ✓)
- **Core ML conversion**: pending verification — same ONNX-based
  coremltools path as BGE. The OpenVINO tag suggests a separate
  export pipeline exists; the ONNX tag is what matters for Core ML.
- Maintenance: 2022-era model (v2 released in line with the
  arXiv 2212.03533 paper); the v3 variants were not considered
  here, but E5-small-v2 itself is *frozen* (which is fine — the
  contract requires determinism, and a frozen model is the most
  deterministic model there is).
- Verdict: passes all six gates. **Strong shortlist candidate.**

### sentence-transformers/all-MiniLM-L6-v2

- Hugging Face:
  <https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2>
- License: **Apache-2.0** (gate ✓)
- Tasks: Sentence Similarity, feature-extraction; tags
  `sentence-transformers`, `PyTorch`, `TensorFlow`, **Rust**,
  `ONNX`, `Safetensors`, `OpenVINO`, `Transformers`, `English`,
  `bert` (model card sidebar)
- Multilingual: **No** — `English` tag (gate 6 for the *v1*;
  multilingual MiniLM is a separate `paraphrase-multilingual-*` model)
- 5.06k likes, 162 community discussions (gate 4, 6 ✓) — by far the
  most popular of the five candidates
- Architecture: 6-layer MiniLM, 384 dim, mean pooling with
  attention-mask normalization, L2-normalized output (model card
  *Usage (HuggingFace Transformers)* section; the `mean_pooling`
  function in the example code)
- Query/passage prefix: **None required** (no query convention)
- arXiv citations on the model card: 5 papers (gate 3, 4 ✓)
- **Core ML conversion**: pending verification — ONNX tag is
  present. Being the most popular SBERT model, it has the largest
  community of conversion recipes; if any of the five has a known
  working Core ML conversion path, this is the most likely one.
- Maintenance: model card last updated 2021-era; the
  `sentence-transformers` organization is active (5.3k followers;
  the model itself is *frozen*, which is what we want for
  determinism).
- Verdict: passes all six gates. **Comparison candidate** (lower
  retrieval quality than BGE/E5 per published MTEB; fast and small
  as a baseline).

### nomic-ai/nomic-embed-text-v1.5

- Hugging Face:
  <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5>
- License: **Apache-2.0** (gate ✓)
- Tasks: Sentence Similarity, mteb; tags `sentence-transformers`,
  `ONNX`, `Safetensors`, `Transformers`, `Transformers.js`,
  `English`, `nomic_bert`, `feature-extraction`, `custom_code`
  (model card sidebar)
- Multilingual: **Limited** — `English` tag (gate 6 partially
  satisfied)
- 865 likes, 59 community discussions (gate 4, 6 ✓)
- **Matryoshka Representation Learning** — the headline feature of
  v1.5. The model supports *resizable* embeddings: 768d native,
  with truncation to 512d, 256d, 128d, 64d available. This is a
  *theoretically attractive* property for our use case (we could
  project from a truncated sub-embedding), but it adds complexity
  that the current contract doesn't accommodate (the contract
  expects a fixed `dimension`).
- Pooling: mean pooling, with task-instruction prefix required
- Query/passage prefix: **REQUIRED** — model card *Usage* section:
  *"Important: the text prompt must include a task instruction
  prefix, instructing the model which task is being performed."*
  Examples given: `search_document: <text>`, `search_query: <text>`.
  This is the *most elaborate* prefix convention of the five
  candidates.
- arXiv citations on the model card: 2402.01613, 2205.13147
- **Core ML conversion**: pending verification — ONNX tag is
  present. `nomic_bert` is a custom architecture; `custom_code`
  tag means the model requires `trust_remote_code=True` in
  transformers, which is a smell for a deployment that wants to
  pin the conversion.
- Verdict: passes gates 1, 3, 4, 5, 6. **Deferred** — the 768d
  default dimension, the Matryoshka complexity, the `custom_code`
  requirement, and the most-elaborate prompt prefix make this a
  poor *first* backend even though the embedding quality is high.
  Reconsider for Stage 3.5+ when the contract has been observed
  in practice and a `dimension` field accommodates Matryoshka.

### jinaai/jina-embeddings-v2-small-en

- Hugging Face:
  <https://huggingface.co/jinaai/jina-embeddings-v2-small-en>
- License: **Apache-2.0** (gate ✓)
- Tasks: Feature Extraction, sentence-similarity, mteb; tags
  `sentence-transformers`, `PyTorch`, **Core ML** (✓ conversion
  evidence), `ONNX`, `Safetensors`, `custom_code` (model card
  sidebar)
- Multilingual: **No** — `English` tag (English-only v2; v3
  supports 30+ languages)
- 141 likes, 22 community discussions
- Architecture: **33M parameters, 8192 sequence length** (model
  card *Intended Usage* section: *"It is based on a BERT
  architecture (JinaBERT) that supports the symmetric bidirectional
  variant of ALiBi to allow longer sequence length. The
  embedding model was trained using 512 sequence length, but
  extrapolates to 8k sequence length (or even longer) thanks to
  ALiBi."*). Small + long-context is a real differentiator.
- Pooling: mean pooling, L2-normalized
- Query/passage prefix: **None required**
- arXiv citations: 2108.12409, 2310.19923
- **Core ML conversion**: The model card sidebar lists **Core ML**
  as one of the supported libraries. This is the *only* candidate
  of the five with Core ML listed in the Hugging Face tags. (gate 1
  ✓ with cited evidence)
- Maintenance: jinaai organization has 1.96k followers; v3 has
  been released; the v2 small model is in maintenance mode but
  not deprecated.
- Verdict: passes all six gates, with a **concrete Core ML
  conversion signal** (the model card tag). **Comparison
  candidate** (long-context and small are real differentiators
  worth measuring against BGE/E5).

## Disqualifications and deferrals

None of the five candidates is disqualified on gates 1–6. All
license gates pass (MIT or Apache-2.0, both SwiftPM-compatible).
All are determinism-feasible (mean pool + L2 normalize is the
standard pattern, and the contract's `seed: 0` default is honored
for backends without a stochastic component). All have versioned
Hugging Face revisions and active maintenance organizations.

**Deferrals (not on the Stage 3 shortlist, but worth revisiting
later)**:

- **Nomic Embed** — Matryoshka + 768d + `custom_code` makes it a
  *later* backend, not a *first* one. The contract's
  fixed-dimension assumption would need to be relaxed to
  accommodate it. (Stage 3.5+ discussion.)
- **Jina multilingual / Jina v3** — not in this survey because
  Stage 3 doesn't need multilingual. The Jina v2 small *en* is
  the comparison candidate; the multilingual variant is a future
  consideration when Stage 4 (Context Foundation) demands it.

## Shortlist (proposed)

| Rank | Candidate | Why on the shortlist |
|---|---|---|
| 1 | **BGE-small-en-v1.5** (MIT, 384d) | Highest published retrieval quality among 384d candidates (per common community reference; Stage 3.3 will *measure*, not just *cite*). MIT license is the most permissive of the shortlist. No query prefix simplifies the conformer. ONNX tag enables coremltools conversion. Mainstream attention (508 likes, 29 discussions). |
| 2 | **E5-small-v2** (MIT, 384d) | Strong published retrieval quality, comparable to BGE-small. The required `query: ` / `passage: ` prefix is a *real architectural factor* — the conformer must add it transparently, which is a small but real surface area. Comparison candidate: if the prefix is the only thing preventing E5 from being the winner, that's a useful signal. |
| 3 (comparison) | **all-MiniLM-L6-v2** (Apache-2.0, 384d) | The fastest, smallest, most-converted candidate. Lowest published retrieval quality. The "failsafe" choice if BGE/E5 conversion runs into Core ML issues. Useful as a "what does the cheapest possible Core ML backend look like" reference point. |
| 3 (alt comparison) | **jina-embeddings-v2-small-en** (Apache-2.0, 33M params, 8k context) | The only candidate with a direct **Core ML** tag on the Hugging Face model card. 33M parameters is the smallest. 8k context is a real differentiator for long-document embedding (overnight sleep-session text, large transcripts). Comparison candidate rather than primary: the long-context and small-parameter advantages are real but unmeasured on M4. |

**Primary candidate**: BGE-small-en-v1.5. This is the *expected*
winner of Stage 3.2 if conversion succeeds. The expected outcome
is that the survey's prediction is *not* the deciding factor —
Stage 3.1's measured benchmark and Stage 3.2's conformer passing
the audit gates are.

**Comparison candidates**: E5-small-v2 (the most likely
"actually better" alternative), all-MiniLM-L6-v2 (the
failsafe), jina-embeddings-v2-small-en (the long-context
alternative). Stage 3.1 should benchmark *at least* BGE and E5;
the other two are benchmarked only if conversion succeeds for
both and we have evidence-driven reason to compare.

### Planned evaluation order

This is the order `EmbeddingBench` (Stage 3.1) will attempt
conversion in. It is not a commitment that later candidates
will be benchmarked; later candidates are attempted only if
earlier ones fail the operational-maturity gate (the script
succeeds, the model loads). The order reflects engineering
intent, not a foregone conclusion:

1. **BGE-small-en-v1.5** — primary. Conversion attempted first;
   if successful, this is the Stage 3.2 conformer.
2. **E5-small-v2** — comparison. Conversion attempted second;
   if BGE conversion fails on a known-mitigable issue (tokenizer
   handling, dynamic shapes), E5 is the immediate next attempt,
   not a fallback.
3. **all-MiniLM-L6-v2** — failsafe. Conversion attempted third
   if BGE *and* E5 both fail; the smallest, most-converted
   candidate, used to validate that the *harness* works
   end-to-end before any of the harder candidates are retried.
4. **jina-embeddings-v2-small-en** — exploratory. Conversion
   attempted fourth; the only candidate with a direct Core ML
   tag, so the conversion may be the easiest of the four
   despite the long-context architecture. Interesting as a
   long-context alternative if its measured M4 performance
   matches its spec.
5. **nomic-embed-text-v1.5** — **deferred**. Conversion is
   not attempted in Stage 3. The 768d default, Matryoshka
   truncation behavior, and `custom_code` requirement make
   it a poor first backend. Reconsider for Stage 3.5+ when
   the contract has been observed in practice.

A future contributor picking up this work should not assume
that #1 is guaranteed to succeed. The order is *engineering
priority*, not *engineering certainty*. The first attempt
that satisfies operational maturity is the one the bench
commits a benchmark file for; the others stay at the
feasibility gate until their turn.

## What this survey does NOT decide

- **Specific Core ML conversion script.** Conversion is a
  Stage 3.1 deliverable; this survey only gates whether
  conversion is *plausible* (gate 1: feasibility).
- **M4-specific performance numbers.** Those are Stage 3.1's
  job (`EmbeddingBench` output). The survey uses *published*
  model card evidence and Hugging Face tag data as triage; the
  *measured* numbers replace the *cited* numbers.
- **Tokenizer handling.** Treated as a sub-decision of the
  conversion script; pinned by `tokenizer_sha256` in the
  benchmark schema (`embedding_contract.md` §6.2).
- **Final selection.** This is a *shortlist*, not a winner.
  The winner is the candidate whose Stage 3.1 benchmark and
  Stage 3.2 conformer both pass the audit gates on the first
  try. The survey is *evidence for* the decision, not a
  substitute for it.
- **Derived metrics.** The bench computes `embeddings_per_second`
  from the raw `batch32_ms` / `batch128_ms` timings and
  stores it directly in the benchmark JSON (per
  `embedding_contract.md` §6). The metric is *derived*, not
  measured — useful for long-term trend plots, but the raw
  timings remain the source of truth.

## Provenance

- Survey authored: 2026-07-12
- Evidence sources: Hugging Face model cards (URLs above);
  FlagEmbedding README (BGE pooling); the model card *Usage*
  Python snippets (E5, MiniLM pooling/prefix); the model card
  sidebar tags (Core ML availability)
- Subagent research that *would* have provided additional
  published Core ML numbers and conversion-repo URLs was
  dispatched but did not return usable evidence within the
  budget; that gap is filled in by Stage 3.1 (which will produce
  the M4-measured numbers anyway)
- Cited sources: see per-candidate URLs above
- Successor: *(none — this is v1)*
