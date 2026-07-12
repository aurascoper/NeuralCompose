# ADR-004: SentenceEmbedder backend contract

**Status**: Accepted
**Date**: 2026-07-12

## Context

The embedding pipeline has crossed from "single conformer
(DeterministicSentenceEmbedder)" to "frozen seam, multiple possible
conformers to come." Stage 2 (commit `9487b09`) defined the
`SentenceEmbedder` protocol; Stage 2.5 (commit `b5dbcaa`) added the
golden-fixture and regression infrastructure that pins the *behavior*
of any conformer. The architecture contract document
(`embedding_contract.md`, commit `4059dac`) is the long-form
specification of the invariants a conformer must satisfy.

The contract document is the *right* artifact for someone implementing
a new backend, because it has the citations, the tolerance values, the
edge cases, and the explicit non-guarantees. It is the *wrong* artifact
for a reviewer of a pull request, because it is 315 lines long and
organized by scope (producer/artifact/system) rather than by invariant.

Reviewers and future contributors need a short, normative reference
that can be cited as `ADR-004 §3.5` from a PR comment, an audit, or a
code-review note. The contract document is the specification the ADR
points at; the ADR is the document you cite.

## Decision

This ADR ratifies the architecture contract
(`docs/architecture/embedding_contract.md`) as the binding specification
for any conformer of `SentenceEmbedder`. The invariants in §3 below
are normative; the contract document is the long-form explanation of
each.

A conformer is accepted only if **all** of the following hold. Numbers
in `§N.M` reference the contract document.

### §3.1 Producer invariants (`contract §1`)

A conformer:

- Conforms to `Sendable` and exposes a stable `modelID`, `dimension`,
  and `version` (`§1.1`–`§1.4`).
- Returns batched results **in input order**, with `count` equal to
  the input, and **L2-normalized** `values` on every output
  (`§1.5`–`§1.7`).
- Is a *pure function* of inputs and its own configuration — no hidden
  state, no cross-call side effects (`§1.8`).
- Does not import MLX, Core ML, or any third-party ML framework into
  `BCICore`. A `CoreMLSentenceEmbedder` lives in `BCIClassifier`; a
  future `MLXSentenceEmbedder` would live in `BCILLM`; both return
  plain-Swift `Embedding` values (`§1.10`).
- Produces a finite, deterministic, unit-norm vector for empty and
  whitespace-only input — no NaN, no zero vector (`§1.11`).

### §3.2 Artifact invariants (`contract §2`)

An `Embedding` value:

- Is `Sendable` and `Equatable`; `values.count == dimension`; `‖values‖₂ = 1.0`
  within `1e-4` (`§2.1`–`§2.3`).
- Carries non-empty `modelID` and `version` matching the producer
  (`§2.4`).
- `cosineSimilarity(to:)` returns a value in `[-1, 1]` and is a plain
  dot product (the L2-normalization invariant is what makes it one).
  Returns `0` on dimension mismatch, not a trap (`§2.5`, `§2.6`).
- Two embeddings with different `modelID`s are not comparable, even
  when `dimension` matches (`§2.7`).

### §3.3 Determinism requirements (`contract §4`)

A backend is *fully specified* by
`(modelID, version, model_weights_SHA256, tokenizer_SHA256, seed)`.
Two runs with the same tuple produce the same vectors within float
tolerance. A change to *any* element of the tuple is a new embedding
space, not a new version of the old one — bumping `version` is the
correct response.

### §3.4 Replay invariants (`contract §5`)

- A backend's golden fixture is `Tests/Fixtures/semantic_<modelID-with-dashes>_v<version>.json`.
  Per-backend filenames prevent a backend swap from overwriting the
  previous backend's recorded truth.
- The fixture records the embedding, the projected 3D coordinate, the
  full `n×n` cosine matrix, and a SHA-256 projection fingerprint.
  The cosine matrix is the *semantic* contract; the raw vectors are
  the *deterministic* contract.
- Provenance fields are asserted **exactly**, not within tolerance.
- Regeneration is gated on a backend-specific env var
  (`NEURALCOMPOSE_REGENERATE_<BACKEND>_REFERENCE=1`); the regenerate
  path *skips* after writing, so CI cannot accidentally commit a
  stale fixture.
- The semantic-relationship sanity test is a separate test from
  value-equality, and must survive an intentional regenerate.

### §3.5 Substitution audit gates (`contract §7`)

A new conformer PR passes audit only if **both** of the following hold.

**Gate 1 — Bounded production diff.** The production diff is
approximately:

```
+ <New conformer>.swift
+ <New conformer>Tests.swift
+ Tests/Fixtures/semantic_<model>_v<version>.json
~ AppContainer.swift   (one-line binding change)
```

If the diff touches `NeuralWorkspaceView.swift`,
`EmbeddingProjecting.swift` or its conformers, replay infrastructure,
the regression harness, the SceneKit / projection layer, or the
command / dispatcher system, the substitution has leaked through the
seam.

**Gate 2 — Existing tests unchanged.** All tests in the existing test
suite (`BCICoreTests`, `BCIEEGTests`, `BCIClassifierTests`, `BCILLMTests`,
`BCIVoiceTests`, `NeuralComposeAppTests`) continue to pass unchanged.
No existing test is modified to accommodate the new backend. If an
existing test starts needing backend-specific branching, the seam is
leaking *behavior*, not just structure.

A substitution that passes Gate 1 but fails Gate 2 has added a new
conformer that *happens* to satisfy the structural shape but
*coincidentally* has different semantics. A substitution that passes
Gate 2 but fails Gate 1 has the right semantics but has leaked
implementation details into the rest of the app. Both must pass.

## Alternatives Considered

**Treat the contract document itself as the ADR.** The contract
document is 315 lines, organized by scope, and is the right artifact
for someone *implementing* a backend. It is the wrong artifact for
*citing* in a PR review ("violates §7.1" is more useful as "violates
ADR-004 §3.5 Gate 1"). Splitting them keeps the ADR short and stable
(the ADR's §3 list changes only when an invariant changes; the
contract's prose can be edited to clarify without re-ratifying the
invariants).

**No ADR; rely on the contract document and tests alone.** Rejected
because the contract is long, the tests are buried in `Tests/`, and a
reviewer of a 4-file PR doesn't want to read either one to know
whether the PR is correct. An ADR is the discoverable, citable,
durable form of the contract.

**Defer this ADR until Stage 3.2 lands.** Rejected because the
contract document was committed in `4059dac` *before* any conformer
that satisfies it, which means the contract is currently self-asserted
(its only conformer is the stub, which is what the contract was
written to describe). Ratifying it now means the *first* real
conformer is measured against an ADR that existed when it was
written, not one written after the fact to justify it.

## What this prevents

A future contributor adding a `SentenceEmbedder` conformer that:

- Touches `NeuralWorkspaceView`, projection, or the dispatcher to
  accommodate a backend-specific behavior.
- Modifies an existing test to assert different things for different
  backends.
- Returns a non-unit-norm vector, a NaN, or a non-`Sendable` value.
- Produces vectors that can't be reproduced given the recorded
  provenance.
- Stores embeddings from different backends in the same comparison
  without going through a per-backend reference set.

Each of those is a smell. The ADR's §3 list is the *checklist* the PR
is judged against. "Violates ADR-004 §3.5 Gate 2" is a complete code-
review note.

## When this rule does not apply

The contract describes what *every* conformer must satisfy. The
contract does *not* describe:

- Performance targets. A conformer can be arbitrarily slow at
  `encode(_:)` and still satisfy the contract. Performance is
  measured by `EmbeddingBench` (`§6` of the contract document), not
  by the contract itself.
- Cross-backend comparability. Embeddings from different `modelID`s
  are not comparable (`§3.3` of the contract). Comparing them is a
  *test* concern (Stage 3.3), not a `SentenceEmbedder` concern.
- Backing-store, caching, or batching policy. A conformer is free to
  cache, batch, or single-shot internally. The protocol requires one
  async call (`encode(_ texts: [String]) async throws -> [Embedding]`);
  the conformer decides how to serve it (`§3.5` of the contract).

The contract is also not a *design* document. The contract describes
what the system already does (or will, when a real conformer lands);
it does not propose new architecture. Architectural changes are ADRs
under the existing `docs/architecture/decision-log/` convention.

## Related implementation

- `docs/architecture/embedding_contract.md` — the long-form
  specification this ADR ratifies
- `Sources/BCICore/Protocols/SentenceEmbedder.swift` — the protocol
- `Sources/BCICore/Models/Embedding.swift` — the artifact type
- `Sources/BCICore/Embedding/DeterministicSentenceEmbedder.swift` —
  the reference conformer (satisfies the contract by construction)
- `Tests/BCICoreTests/SentenceEmbedderTests.swift` — protocol tests
  (per-conformer)
- `Tests/BCICoreTests/SemanticReplayRegressionTests.swift` —
  replay-fidelity tests (per-backend fixtures)
- `Tests/BCIEEGTests/SemanticWorkspaceReplayTests.swift` — workspace
  consumption tests (verifies the seam)
- `Sources/BCIClassifier/` — the future home of `CoreMLSentenceEmbedder`
  (per `ADR-003` runtime-separation rules)
- `Sources/EmbeddingBench/` (planned) — the benchmark executable
  whose output schema is `contract §6`
- `Benchmarks/<date>-<model>.json` (planned) — historical benchmark
  records
- `Tests/Fixtures/semantic_<model>_v<version>.json` — the per-backend
  golden fixture pattern (current: `semantic_stub_v1.json`)

## Change protocol for this ADR

This ADR is **load-bearing**. Editing it has the same review gravity
as editing the protocol it ratifies.

- **Adding or weakening an invariant in §3**: requires (a) updating
  the contract document, (b) a test that pins the new invariant, (c)
  explicit user sign-off.
- **Removing an invariant**: requires (a) a deliberate decision
  recorded as a follow-up ADR, (b) explicit user sign-off.
- **Adding a §3 subsection for a new invariant class** (e.g. a future
  "Provenance" subsection if SHA256 fields are added to `Embedding`):
  requires (a) updating the contract document's §1/§2/§8, (b) a
  follow-up ADR if the new invariant conflicts with an existing one.

If a future commit violates this ADR without a corresponding update
here, that commit is a regression. Revert it.
