# SRT interpretive-signal evaluation, v1

**Status:** `foundational_study_only`
**Data gate:** D0
**Promotion status:** `not_eligible`
**Runtime dependency authorized:** false
**Register entry:** `docs/scoping/srt-interpretive-signal-register-v0.json`

Adjudication of an externally-supplied proposal. Filing does not authorize work. No milestone identifier is
assigned; the identifier is the operator's to assign. Precedent for adjudicating rather than implementing a
pasted proposal: `ADR-005-local-interaction-logging.md`. Boundary between research artifact and runtime
component: `ADR-011-offline-eeg-encoder-artifact-boundary.md`.

---

## 1. The proposal

An external analysis proposed adopting SRT (Semiotic-Reflexive Transformer, `space-bacon/SRT`) as an
experimental side channel for three purposes:

1. **Dialectical fork detection** — a `SemanticForkObservation` carrying a divergence score that routes the
   dialectic loop: low divergence → ordinary response; high divergence → generate thesis and antithesis
   separately, preserve both through another turn, prohibit premature synthesis.
2. **A second discourse-aware retrieval index** — an "interpretive" embedding space stored beside, never
   mixed with, the primary semantic index.
3. **Cross-modal provenance** — image-to-text association via the Sunstone linear head.

The proposal's governance instincts were sound: no production dependency, no issue under the active M7-B
sequence, explicit claims boundaries, and a preregistered three-stage spike. Those are preserved. Its
technical premises did not survive verification, and the corrected experiment is cheaper than the one
proposed.

---

## 2. Findings

### 2.1 SRT's strongest published number is not its adapter

The repository's headline results on TruthfulQA-MC2 — Qwen-2.5-7B `0.8656 ± 0.011` AUC, Llama-3.2-3B
`0.8475 ± 0.013`, Gemma-2-2B `0.8563 ± 0.016` — are attributed to a **separate probe over the frozen
backbone, explicitly not an adapter capability**.

The adapter's own novel channels are disclaimed by its authors. The repository states that r̂, regime and
divergence are:

> "observational signals; they are **not** a validated hallucination detector, and on free-form generation
> they do not, on their own, separate hallucinated from faithful answers above chance."

So the component with evidence is a probe on hidden states, and the component that is novel is the one the
authors decline to stand behind. Any adoption argument that leans on the headline AUC is leaning on the
probe, not on SRT.

### 2.2 A cheaper, published, externally-replicated baseline was omitted

Semantic Entropy Probes (Kossen et al., 2024) are **linear** classifiers on hidden states — against SRT's
~14.6M trainable parameters — read from a **single forward pass**. Reported performance is 0.70–0.95 AUROC
in-distribution, with out-of-distribution gains over accuracy probes of 7.7–10.5 AUROC points on several
short-generation models. Public code exists. Lineage: Kuhn et al. (ICLR 2023) → Farquhar et al. (Nature 2024)
→ Kossen et al. (2024).

SEP is an arXiv/workshop baseline with public code, not a final authority. It is nonetheless a far better
null model than beginning with a vendor adapter. **Without this comparator, a positive SRT result cannot
demonstrate that SRT was needed.**

### 2.3 The literature's central warning lands on the proposed use case

The proposal's best use — fork detection — is where hidden-state methods are documented to be weakest.

- A **semantic fork** is *aleatoric* uncertainty: the input genuinely admits multiple readings. Holding the
  dialogue open is correct.
- **Model ignorance** is *epistemic*: holding open produces elaborate discourse where the system should
  clarify, retrieve evidence, or abstain.

*The Illusion of Certainty: Uncertainty quantification for LLMs fails under ambiguity* (arXiv 2511.04418)
reports that predictive-distribution, ensemble and hidden-state methods deteriorate toward near-random
behaviour under genuine ambiguity, because they conflate ambiguity with model confusion. It supplies MAQA*
and AmbigQA* as datasets with estimated answer distributions.

SRT emits one undifferentiated `divergence` scalar with no such decomposition. **A signal that scores well on
"contested versus neutral" while failing to separate ignorance from plurality is actively harmful here: it
would hold the dialogue open most eagerly exactly where the model is least entitled to speak.**

### 2.4 The repository already measures divergence — but not branch preservation

`DialecticalDynamics.tension(among:)` (`Sources/BCICore/Dialectic/DialecticalDynamics.swift:134`) is mean
pairwise `1 − normalizedCos` over candidate embeddings. It already drives prompt shaping
(`DialecticalRole.swift:92,149`), selection temperature (`:150`), the silence gate (`:249`), and the synthesis
convergence streak (`DialecticalMemory.swift:75`).

What exists is **post-generation divergence measurement plus scalar persistence.** What does *not* exist is
branch-preserving dialectical search. Each turn resolves to exactly one of speak / synthesize / stay silent,
and `standingTension` carries a scalar forward, not two live branches. The memory retains heard text and the
voiced reply.

It would therefore be wrong to say the proposal's branch preservation is already implemented. The accurate
and still-decisive statement is narrower: `FIELD_V2.md` §5 binds any future latent quantity to act **through
the field and `Tuning`** — modulating temperature, silence, synthesis thresholds and field targets — and
**never as a term added to a candidate's potential.** A `SemanticForkObservation` scoring candidates directly
would violate that contract.

The one genuine gap is timing, not semantics: `tension` is **post-generation** (both calls must be spent
before it can be measured), whereas a probe reads the prompt. That gap defines the experiment.

---

## 3. Resource dispositions

| Resource | Verified status | Disposition |
| --- | --- | --- |
| `space-bacon/SRT` | Apache-2.0. ~14.6M trainable params (≈0.17% of a 7B backbone); MAH ≈2.7M×3, RRM ≈2.2M, BEN ≈0.2M, community head ≈0.2M. FiLM correction `h ← h·(1+γ)+β`. Requires HuggingFace `output_hidden_states=True` | Conditional comparator arm, not the subject |
| Publication record | **Not on arXiv.** `sunstonenorth.com` itself states the program paper is "prepared for arXiv". Two SSRN records: *The Treachery of Signs* (SSRN 5987495) and *The SRT architecture* (SSRN 6349978). The SRT-Adapter (Stage 3) and SRT-NLA (Stage 4) manuscripts are repository-hosted | Self-published. SSRN is not peer review |
| Independent scrutiny | Searched; none located. The only public discussion found is a **2-point, 5-comment Hacker News thread** with no benchmark objections, no reproduction, and no adversarial engagement | Treat every claim as self-reported |
| `huggingface.co/RiverRider` | 16 models, 9 spaces, 6 datasets. The account glosses SRT as "Substrate-Readable Technology"; the repository and studio site say "Semiotic-Reflexive Transformer" | Artifact registry: pin revision, hash, inspect licence, reproduce. Never an authority source |
| `sunstonenorth.com` | Retrieved and corroborated — see §6. Commercial engineering and product studio behind SRT | Vendor. Raises the evidentiary bar; carries no architectural weight |
| Cross-modal (SRT-Sunstone) | Karpathy 5k i2t R@1 `0.416`; the studio frames it as "on par with fully trained dual encoders from roughly 3,000 times less pair data" | **Defer, not refute** — see §5 |
| llama.cpp / Vulkan runtime | `llama-server` serves final-layer embeddings including unpooled per-token output via `/embeddings --pooling none`. Exposing **intermediate activations is out of scope** upstream: no stable API for it under multi-sequence serving | Not drop-in. A custom instrumentation path, not a flag |

---

## 4. Corrections to the analysis as filed

1. **`AgentInference` does not exist in this program.** Zero occurrences across all repositories. The real
   ladders are `SupportStatus` (`crates/neuralcompose-mobile-core/src/runtime_target.rs:131`) and the
   proposed, deliberately separate `ModalityEvidenceStatus`.
2. **`NOT_AUTHORIZED` is not this program's vocabulary.** Terminal states are `ACHIEVED`,
   `BLOCKED_OPERATOR`, `BLOCKED_EXTERNAL`, `BLOCKED_EVIDENCE`. Research disposition is carried by
   `implementation_status`, `promotion_status` and the schema-pinned `runtime_dependency_authorized: false`.
3. **`sunstonenorth.com` is retrievable**, correcting the analysis's "could not retrieve / UNVERIFIED".
4. **The publication record is weaker than "pending reproduction" implies** — see §3.
5. **The proposal's branch preservation is not already implemented** — see §2.4. An earlier draft of this
   assessment overstated it; corrected here.

---

## 5. Why the cross-modal arm is deferred rather than refuted

SRT reports i2t R@1 `0.416` on Karpathy 5k. Current open dual-encoders report materially higher numbers on
COCO retrieval. **That comparison is not decisive on its own**: R@1 values are not comparable across reports
unless preprocessing, candidate pool size, retrieval direction, checkpoint selection and evaluation protocol
match, and the figures here come from different protocols.

What can be said without overreach: on the vendor's own framing the head is *on par with older dual-encoder
systems*, and this program has no provenance requirement that a purpose-built open dual-encoder would not
serve more cheaply.

Disposition: **not useful for the current roadmap.** Revisit only if a provenance-specific need emerges that
a standard dual encoder cannot meet. This is a roadmap judgement, not a scientific refutation.

---

## 6. Source-verification record

`sunstonenorth.com` was reported unretrievable by one reviewer and retrieved by another. Durable evidence was
therefore captured before this document asserted anything about it.

| Field | Value |
| --- | --- |
| URL | `https://sunstonenorth.com` |
| Retrieved (UTC) | 2026-08-01T21:18:52Z |
| Bytes | 11227 |
| SHA-256 of response body | `333a4d64610f8355895199783fa0d5d81b41ac98b96a5d93eab69924743664b3` |
| Retrievals | 2 independent successes (WebFetch, then curl); 1 reported failure by a third party |

Quoted verbatim from the whitespace-normalized text extraction:

> "Sunstone North is the engineering and product studio behind the SRT (Semiotic-Reflexive Transformer)
> research program."

> "We build small, auditable instruments that read semantics, discourse structure, and cross-modal
> understanding directly from frozen language models."

> "The SRT program paper : consolidated findings, prepared for arXiv. The Treachery of Signs (SSRN 5987495).
> The SRT architecture (SSRN 6349978). The SRT-Adapter manuscript (Stage 3). SRT-NLA: activation
> verbalization (Stage 4)."

Contact address published on the page: `burton@burtonlancaster.com`.

⚠️ **Method note.** Verify quotations against a whitespace-normalized text extraction, not against raw HTML
bytes. Line-based `grep` for "Semiotic-Reflexive Transformer" over the raw response returns zero matches
because the phrase spans a line break in the source, even though the rendered text contains it verbatim. An
initial check using raw-byte `grep` produced a false negative here.

⚠️ A single retrieval of a live page is weak evidence. The digest above pins *what was served at that
instant*, not what the site says now. Re-verify before relying on it.

---

## 7. Claims boundary

Binding on every artifact produced under this topic. Inherited from existing repository law, not reinvented.

`FIELD_V2.md` §3 enumerates the forbidden framings for a new latent scalar: *"not, and must never be presented
as: EEG / signal energy, neural activation, cognitive load, emotional intensity, sleep depth, meditation
depth, attention, arousal."* `HypnagogicDialecticHonesty.headerCaveat`: *"Any EEG reading only biases the
dialogue as a heuristic 'wind', never a cognitive decode."* Restated as the "wind, not steering wheel" rule at
`DialecticalField.swift:11-12`.

Such a signal is **model-state instrumentation**. It is never:

- a truth or hallucination verdict — the authors explicitly disclaim this;
- evidence that the model is conscious, or that it "thought" a decoded sentence;
- a claim that a user is confused, polarised, or ambiguous;
- **any statement about an EEG participant's mental state** — the hard line, inheriting the standing rule that
  the model must never declare a user anxious, relaxed, attentive or asleep;
- a manufacturing, quality, feasibility or clinical determination.

A verbalized hidden state is described as *a candidate reconstruction of an internal representation, with
measured round-trip fidelity* — never as what the model was thinking.

Because a text-derived interpretive scalar sits **outside** the `SpectralState` caveat chain, the two must be
kept strictly separate. An interpretive scalar must never be narrated as though it were physiological.

---

## 8. Prerequisite: embedding-space comparability currently fails open

Independent of SRT, and blocking for any second index.

Program law is unambiguous. `nc-goal.rtf` §6 (M7-D): *"vectors from different embedding-space identities never
share one index"*, over a ten-element identity tuple. Restated at client-native `ADR-001:42` and at
`docs/architecture/embedding_contract.md` §4.2 / §3.3. **Executable behaviour contradicts the documentation:**

- `Embedding.cosineSimilarity(to:)` (`Embedding.swift:58-63`) checks vector length only. Two unrelated 384-d
  spaces produce a plausible number instead of failing.
- `DialecticalDynamics.centroid(of:)` (`:264-274`) inherits the first element's provenance and merely *skips*
  dimension mismatches; it does not reject same-dimensional vectors from another model, version, seed,
  pooling policy or semantic role.
- `NeuralWorkspaceView.ingestSpokenNode` (`:546-567`) retains provenance (`:173-176`) but admits and projects
  nodes without checking space membership.
- `SentenceEmbedder` carries **no space or role discriminator** — `modelID` does double duty, so an
  interpretive space produced by the *same* BGE model is indistinguishable from the semantic one.

The remedy is a full identity rather than a `role` string, with mismatch **failing or throwing — never
returning `0`**, since zero is a legitimate similarity. `centroid` must reject a mixed set rather than
silently drop members. The pattern to copy already exists: `SpectralStateEstimator`'s construction-time
honesty gate (`Sources/BCILLM/SpectralStateEstimator.swift:33-40`) throws rather than warns, and names the
failure mode — projecting against a mismatched space yields "a plausible-looking but content-free argmax."

Per `embedding_contract.md` §10, adding this guarantee requires a pinning test, a §9 citation entry, and a §3
update; §8 already reserves the additive path.

---

## 9. Registered experiment (summary)

Full staging is in the register entry and the plan of record. In outline:

- **1A — retrospective predictability.** Can heard text plus frozen turn context predict the divergence the
  loop later produces? Target is `observed_candidate_tension` — a **proxy**, never
  `semantic_ambiguity_ground_truth`. It is conditioned on generator and model identity, two role-specific
  prompts, role temperatures, sampling configuration, the previous turn's standing tension, and one embedding
  backend; all are retained as covariates. Splits are session-level, never per-turn (adjacent turns share
  context and would leak). Baselines ascend: session mean → lexical features → sentence embedding + ridge →
  raw hidden-state linear probe.
- **1B — diagnostic validity.** Requires a **separately sealed, human-labelled corpus**; the existing turn
  records contain no authoritative labels. Strata, not a binary: `ClearSingleInterpretation`,
  `InterpretivePlurality`, `ClarificationRequired`, `KnowledgeInsufficient`, `FalsePremise`,
  `NormativeConflict`, with the intended action defined independently. **Primary safety gate:**
  `KnowledgeInsufficient` and `FalsePremise` must not route to dialectical elaboration above a preregistered
  error ceiling.
- **1C — conditional SRT comparator.** Only if 1A shows signal, 1B shows a safe target, and headroom remains.
  Same backbone, split and extraction inputs; incremental rather than absolute performance; latency and memory
  recorded. A non-strict loader may be used **only** if the receipt lists every expected, loaded, missing and
  unexpected key — `strict=False` succeeding is not proof the intended adapter executed. No FiLM injection.
- **2 — retrieval ablation.** Only after §8 is enforceable. Reuse
  `Evaluation/scripts/embedding_space_analysis.py` (`cka`, `svcca`, Procrustes variants,
  `neighborhood_overlap`) — machinery for comparing two spaces *without merging them*.
- **3 — observational integration only.** Log and visualise; no injection.

⚠️ **A call-skipping router is outside the current field contract.** `FIELD_V2.md` §5 permits a latent
quantity to modulate temperature, silence, synthesis thresholds and field targets — not to gate generation.
The experiment may *estimate* potential call savings; it cannot authorize the router. Moving from observation
to routing requires a separate ADR with fail-closed behaviour and explicit `FIELD_V2` reconciliation.

### 9.1 Confounder scope, stated precisely

Gloss is **not** a same-turn confounder for candidate tension. Verified by reading
`Sources/BCICore/Composition/HypnagogicDialecticLoop.swift`: generation occurs at `:298-299`;
`glossProvider()` is not called until `:335`; `field.advance` at `:337`; and `tension` at `:356` is computed
from candidate embeddings produced before the gloss was read. Gloss enters only *lagged*, through field
weights → outcome → `standingTension` → the next turn's `role.promptShaper(heard, standingTension)`, and
`standingTension` is already a covariate.

Therefore: segment by real-versus-absent gloss when predicting **selection, silence, synthesis or field
evolution**; do **not** present that segmentation as necessary for predicting raw candidate tension. The
underlying defect (§10.2) is real but is not a Gate 1A confounder.

---

## 10. Defects surfaced, to be handled independently of SRT

1. **Embedding comparison fails open** — §8. The most serious; blocks any second index.
2. **Missing and neutral gloss collapse.** `SpectralGloss.scalar` maps both `nil` and `.neutralBaseline` to
   `0.5` (`SpectralGloss.swift:24-33`), acknowledged at `DialecticalCompetition.swift:139-144` but mitigated
   only in telemetry — the dynamics still cannot distinguish them. `update(nil, …)` actively drags the EMA
   toward neutral each turn, and `logSilentTurn` (`HypnagogicDialecticLoop.swift:487`) writes a hardcoded
   `glossScalar: 0.5, spectralState: nil`. Represent `Unavailable | NeutralBaseline | Observed(state)` rather
   than collapsing absence into a number.
3. **Synthesis policy is collapsed into a Boolean.** `forceSynthesis: true` *forces* synthesis —
   `if let synthesis, forceSynthesis { return result(.synthesized(synthesis)) }`
   (`DialecticalDynamics.swift:240`) short-circuits **before** the stalemate/silence check. It is therefore
   the opposite of a hold-open control. It is not dead across the public API or its tests; it is **redundant
   at the only production call site**, which passes `forceSynthesis: synthesis != nil`
   (`HypnagogicDialecticLoop.swift:369`), so any memory-proposed synthesis preempts metastable silence. Open
   question: should the API become `synthesisPolicy: prohibited | eligible | required`, or should memory
   remain authoritative and the Boolean disappear?

---

## 11. Disposition

| Item | Disposition |
| --- | --- |
| Research-only adjudication | **Approve** |
| SRT-first reproduction | **Reject** |
| Linear hidden-state baseline first | **Approve** |
| Existing tension as a useful label | **Approve as proxy** |
| Existing tension as ground truth | **Reject** |
| Aleatoric/epistemic safety gate | **Requires a separately labelled corpus** |
| Multi-space embedding fix | **Blocking prerequisite** |
| Direct call-skipping router | **Outside the current field contract** |
| SRT read-only comparator | **Conditional** |
| SRT FiLM injection | **Out of scope** |
| Cross-modal arm | **Defer** |

---

## 12. Sources

- SRT repository — https://github.com/space-bacon/SRT
- RiverRider artifacts — https://huggingface.co/RiverRider
- Sunstone North — https://sunstonenorth.com (digest in §6)
- Semantic Entropy Probes — https://arxiv.org/abs/2406.15927; code https://github.com/OATML/semantic-entropy-probes
- The Illusion of Certainty — https://arxiv.org/abs/2511.04418
- SSRN 6349978 — https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6349978
- llama.cpp server documentation — https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- Hacker News discussion — https://news.ycombinator.com/item?id=47263653
