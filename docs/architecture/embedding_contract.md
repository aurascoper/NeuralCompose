# Embedding Contract

The single reference for what the embedding pipeline guarantees, what it
intentionally does *not* guarantee, and what every future backend
substitution must satisfy.

This document is a **transcription** of decisions made across
`9487b09` (the seam), `b5dbcaa` (the golden fixture), and the test
suite that pins the contract. It is not a new design — if a claim here
disagrees with the code or tests, the code wins and the document gets
updated to match. Every claim is cited `path:line` for that reason.

The contract has three scopes:

| Scope | Lives in | Pinned by |
|---|---|---|
| **Producer** | `SentenceEmbedder` protocol + conformers | unit tests in `Tests/BCICoreTests/` |
| **Artifact** | `Embedding` value type | unit tests + golden fixture |
| **System** | replay + benchmark + audit gates | `Tests/BCICoreTests/SemanticReplayRegressionTests.swift`, future `Sources/EmbeddingBench/`, audit-gate enforcement at PR review |

These are checked in order: a backend must satisfy the producer
contract, the artifacts it produces must satisfy the artifact
contract, and the system-level properties (replay, benchmark,
substitution audit) follow from those.

This document is a *companion* to the ADRs, not a replacement:

- [PRINCIPLES §4](PRINCIPLES.md) — frozen public APIs evolve additively
- [PRINCIPLES §6](PRINCIPLES.md) — components communicate across protocol boundaries
- [ADR-002 — Deterministic replay as the validation backbone](decision-log/ADR-002-deterministic-replay.md) — the pattern this contract follows
- [ADR-003 — Runtime separation](decision-log/ADR-003-runtime-separation.md) — why MLX/ANNE stay out of `BCICore`
- [ADR-004 — SentenceEmbedder backend contract](decision-log/ADR-004-sentence-embedder-backend-contract.md) — the *short normative reference* for this document. The ADR is the right artifact to cite from a PR review (`ADR-004 §3.5 Gate 1`); this document is the long-form spec the ADR ratifies.

**Document vs. ADR**: When the ADR and this document disagree, the
ADR's §3 list is normative. The prose here explains the list, cites
the tests, and documents the non-guarantees; the list itself is the
binding form.

---

## 1. Producer contract — `SentenceEmbedder`

Source: `Sources/BCICore/Protocols/SentenceEmbedder.swift:24`.

A conformer of `SentenceEmbedder` **must** satisfy:

| # | Guarantee | Citation |
|---|---|---|
| 1.1 | Conforms to `Sendable` | `SentenceEmbedder.swift:24` |
| 1.2 | Exposes a stable `modelID: String` that uniquely identifies the backend (e.g. `"stub-hash-v1"`) | `SentenceEmbedder.swift:27` |
| 1.3 | Exposes a stable `dimension: Int` matching the length of every produced `values` array | `SentenceEmbedder.swift:30`, `Embedding.swift:33` |
| 1.4 | Exposes a stable `version: String` that is bumped only when the text→vector mapping changes in a way that invalidates stored vectors | `SentenceEmbedder.swift:33`, `Embedding.swift:38` |
| 1.5 | `encode(_ texts: [String]) async throws -> [Embedding]` returns results **in input order** (`result[i]` is the embedding of `texts[i]`) | `SentenceEmbedder.swift:40`, test `testBatchPreservesOrder` at `SentenceEmbedderTests.swift:93` |
| 1.6 | The returned array has exactly the same `count` as the input | `SentenceEmbedder.swift:40` |
| 1.7 | Every produced `Embedding.values` is **L2-normalized** (unit length) | `SentenceEmbedder.swift:38-40` doc comment, test `testOutputIsUnitNorm` at `SentenceEmbedderTests.swift:35` |
| 1.8 | `encode(_:)` is a *pure function* of the inputs and the conformer's own configuration — no hidden state, no cross-call side effects | test `testDuplicatesAreIdenticalNoHiddenState` at `SentenceEmbedderTests.swift:102` |
| 1.9 | The convenience `encode(_ text: String)` (default impl at `SentenceEmbedder.swift:46`) delegates to the batch `encode(_:)` and returns the first element | `SentenceEmbedder.swift:46-57` |
| 1.10 | The conformer does not import MLX, Core ML, or any third-party ML framework into `BCICore`. MLX isolation is load-bearing (per `ADR-003`). A `CoreMLSentenceEmbedder` lives in `Sources/BCIClassifier/` (the same target that already hosts `CoreMLIntentClassifier`); a future `MLXSentenceEmbedder` would live in `Sources/BCILLM/`. Both return plain-Swift `Embedding` values, never an `MLMultiArray` or `MLXArray`. | `SentenceEmbedder.swift:14-18` doc comment; `ADR-003` lines 28-46 |
| 1.11 | Empty and whitespace-only input produce a finite, deterministic, unit-norm vector (no NaN, no zero vector) | test `testEmptyStringIsSafeAndDeterministic` at `SentenceEmbedderTests.swift:110` |

The `modelID`/`version` fields are *backend* identity; the same-named
fields on `Embedding` are *artifact* identity. The duplication is
intentional — it lets you log which backend is live without having
encoded anything yet (`SentenceEmbedder.swift:20-23`).

---

## 2. Artifact contract — `Embedding`

Source: `Sources/BCICore/Models/Embedding.swift:19`.

An `Embedding` value **must** satisfy:

| # | Guarantee | Citation |
|---|---|---|
| 2.1 | `Sendable` and `Equatable` | `Embedding.swift:19` |
| 2.2 | `values.count == dimension` | `Embedding.swift:24`, test `testDimensionMatchesValuesCount` at `SentenceEmbedderTests.swift:42` |
| 2.3 | `values` is L2-normalized: `‖values‖₂ = 1.0` (within `1e-4`) | `Embedding.swift:20-23` doc comment, test `testOutputIsUnitNorm` at `SentenceEmbedderTests.swift:35` |
| 2.4 | `modelID` and `version` are non-empty and match the producer's `modelID`/`version` | `Embedding.swift:26-38`, test `testProvenanceIsPopulated` at `SentenceEmbedderTests.swift:48` |
| 2.5 | `cosineSimilarity(to:)` returns a value in `[-1, 1]` (within float error) and is a plain dot product (the L2-normalization invariant is what makes it one) | `Embedding.swift:54-63` |
| 2.6 | `cosineSimilarity(to:)` returns `0` when dimensions differ, rather than trapping — different spaces are incomparable, not broken | `Embedding.swift:58-59` |
| 2.7 | Two embeddings with different `modelID`s are not comparable, even if their `dimension` matches | `Embedding.swift:27-28` doc comment |

The struct carries *cheap* provenance (`modelID`/`version`/`seed`/
`dimension`) by design. Heavier provenance — model SHA256, tokenizer
SHA256, runtime, conversion-script revision — is **not** on the struct
because:

- It would couple every consumer of `Embedding` to ML-versioning
  concerns the workspace doesn't have today.
- It is *additive* metadata that can be added as fields when a second
  backend actually exists. The contract reserves the right to do so
  additively (per `PRINCIPLES §4`).

That reservation is the explicit deferral called out in
`Embedding.swift:11-13`: *"It is intentionally not the full
versioned-artifact machinery — those are metadata to add to this struct
when a second backend actually exists, not an architectural layer to
build now."*

---

## 3. What the system intentionally does NOT guarantee

These are not bugs or oversights. They are explicit non-goals, written
here so future work doesn't try to "fix" them and accidentally break
the load-bearing simplicity of the abstraction.

| # | Non-guarantee | Why |
|---|---|---|
| 3.1 | **Cross-run determinism without recorded backend identity.** A `SentenceEmbedder` conformer is not required to produce the same vector across processes unless the *full* backend identity is preserved (model weights, tokenizer, OS, hardware). The deterministic stub does this trivially; a Core ML backend does not, and the benchmark captures the conditions under which it does (see §6). | ML runtimes are not required to be bit-exact across macOS releases. The contract freezes *what the system can detect* (via benchmark provenance) rather than *what the runtime must do*. |
| 3.2 | **Output stability across macOS releases or hardware generations.** A Core ML backend's output may change when Apple ships a new ANE compiler, a new OS, or a new chip. The benchmark's `macos` and `device` fields are how the system detects this, not how it prevents it. | Out of scope. The contract is about making drift *visible* (via the benchmark), not eliminating it. |
| 3.3 | **Cross-backend comparability.** Embeddings from different `modelID`s are not comparable. `cosineSimilarity` returns 0 for dimension mismatches; a backend-vs-backend comparison is a *separate test* (Stage 3.3) operating on a shared reference set, not a property of `cosineSimilarity` itself. | `Embedding.swift:27-28` — different backends are different spaces. |
| 3.4 | **Semantic meaningfulness in the stub.** `DeterministicSentenceEmbedder` is compositional (shared tokens pull vectors closer) but is *not* a linguistic model. Spatial proximity under the stub is decorative; under a real encoder it is meaningful. The contract does not promise the former will look like the latter. | `DeterministicSentenceEmbedder.swift:21-25` — *"still not semantically meaningful in any linguistic sense; treat spatial proximity as decorative until a real backend replaces this."* |
| 3.5 | **Caching, batching policy, or throughput guarantees.** A conformer is free to cache, batch, or single-shot internally. The protocol *requires* one async call (`encode(_ texts: [String]) async throws -> [Embedding]`); an extension at `SentenceEmbedder.swift:43-58` adds a single-string convenience that delegates to the batch form. The conformer decides how to serve either. | Protocol minimality. Adding policy to the protocol would push it into the wrong layer. |
| 3.6 | **Cross-platform determinism.** A backend that runs on Apple Silicon and on Intel will produce different vectors. The contract is silent on non-Apple-Silicon targets until there is one. | The current deployment target is Apple Silicon only. |

---

## 4. Determinism requirements

For replay to work, every backend must satisfy the following in
addition to §1 and §2. The fixture-based replay pattern is established
by `b5dbcaa` and `Tests/BCICoreTests/SemanticReplayRegressionTests.swift`.

| # | Requirement | Citation |
|---|---|---|
| 4.1 | A backend is *fully specified* by the tuple `(modelID, version, model_weights_SHA256, tokenizer_SHA256, seed)`. Two runs with the same tuple produce the same vectors (within float tolerance). | `SemanticReplayRegressionTests.swift:117-125` (the exact-match provenance block, `// 3a. Provenance — exact match.`) |
| 4.2 | A change to *any* element of the tuple is a new embedding space, not a new version of the old one. Bumping `version` is the correct response; bumping only the SHA while keeping `modelID` is not. | `Embedding.swift:35-37` (version-bump rule) |
| 4.3 | The deterministic stub satisfies 4.1 by construction — FNV-1a over UTF-8 bytes is execution-independent (`DeterministicSentenceEmbedder.swift:11-13, 119-129`), and the canonicalization step (`precomposedStringWithCanonicalMapping` → locale-independent lowercase → whitespace split) makes invisible input differences irrelevant. | `DeterministicSentenceEmbedder.swift:88-96`, tests `testCasingAndWhitespaceAreCanonicalized` (line 78) and `testUnicodeNormalizationMakesAccentsEqual` (line 84) |
| 4.4 | A Core ML backend satisfies 4.1 *iff* the conversion script, the input PyTorch weights, the tokenizer version, and the macOS release are all pinned. The benchmark (§6) is the artifact that records the conditions. | Implied by `Sources/BCICore/Models/Embedding.swift:11-13` and §3.1 above. |

---

## 5. Replay invariants

The golden fixture pattern, established for EEG recordings by ADR-002
and extended to embeddings by `b5dbcaa`, has these invariants:

| # | Invariant | Citation |
|---|---|---|
| 5.1 | A backend's golden fixture is named `semantic_<modelID-with-dashes>_v<version>.json` and lives at `Tests/Fixtures/`. Per-backend filenames prevent a backend swap from overwriting the previous backend's recorded truth. | `Tests/Fixtures/semantic_stub_v1.json` (existing); plan for `semantic_bge_small_v1.json` (Stage 3.2) |
| 5.2 | The fixture records the embedding, the projected 3D coordinate, and the full `n×n` cosine matrix for a fixed sentence set. The cosine matrix is the *semantic* contract; the raw vectors are the *deterministic* contract. | `SemanticReplayRegressionTests.swift:41-55` (schema), `:260-269` (fixture construction) |
| 5.3 | A SHA-256 fingerprint over the concatenated projection coordinates is recorded alongside the JSON. The fingerprint is a one-value drift check; the full JSON is for debugging when the fingerprint changes. | `SemanticReplayRegressionTests.swift:55` (struct field), `fingerprint(projections:)` at `SemanticReplayRegressionTests.swift:280-292` |
| 5.4 | Regeneration is gated on an env var (`NEURALCOMPOSE_REGENERATE_SEMANTIC_REFERENCE=1` for the stub, the equivalent for any future backend). The regenerate path *skips* after writing, so CI cannot accidentally commit a stale fixture. | `SemanticReplayRegressionTests.swift:95-106` |
| 5.5 | The fixture's provenance block (`model`, `version`, `seed`, `projectionSeed`, `dimension`) is asserted **exactly**, not within tolerance. A provenance drift is a different kind of error than a value drift and deserves its own failure message. | `SemanticReplayRegressionTests.swift:119-128` |
| 5.6 | The semantic-relationship sanity test (`cos(sleep, deep sleep) > cos(sleep, banana)`) is a separate test from the value-equality test, because it must survive an intentional regenerate of the fixture. | `SemanticReplayRegressionTests.swift:191-201` (test `testCompositionalClusteringHolds`) |

---

## 6. Benchmark provenance (Stage 3.1 — *not yet built*)

A real encoder's runtime behavior is captured by `Sources/EmbeddingBench/`
(proposed), a standalone SwiftPM executable. Its output is a dated
`Benchmarks/<date>-<model>.json` file with **frozen schema**:

```json
{
  "schema_version": 1,
  "model_id": "bge-small-en-v1.5",
  "runtime": "coreml",
  "device": "Apple M4",
  "macos": "15.x",
  "build_sha": "<commit>",
  "coreml_sha256": "...",
  "tokenizer_sha256": "...",
  "dimension": 384,
  "cold_load_ms": 0,
  "warm_encode_ms": 0,
  "batch_sizes": {
    "1": 0,
    "8": 0,
    "32": 0,
    "128": 0
  },
  "rss_mb": 0,
  "embeddings_per_second": 0
}
```

| # | Field | Why it's required |
|---|---|---|
| 6.1 | `coreml_sha256` | Pinning the compiled model. Without it, a regenerated `.mlmodelc` would silently move embeddings. |
| 6.2 | `tokenizer_sha256` | A tokenizer swap can move embeddings even when the model weights stay identical. Recording only the model SHA would let this slip through. |
| 6.3 | `build_sha` | Pins the `Swift` toolchain and the project revision. Compiler version affects code generation; project revision affects what's being measured. |
| 6.4 | `macos` + `device` | Out of the system's control, but required to interpret a benchmark that looks different from a prior one. Drift in `warm_encode_ms` between two macOS releases is *informational*, not *regressive*. |
| 6.5 | `schema_version` | The benchmark schema will evolve (new fields, deprecated fields). Versioning makes old benchmark files self-describing. |

The benchmark is **permanent infrastructure**, not a one-off. Every
future backend is measured the same way, on the same machine, and the
JSON output is the historical record.

---

## 7. Audit gates for backend substitution

A new `SentenceEmbedder` conformer (Stage 3.2 and beyond) is merged
only if **both** of the following hold:

### Gate 1 — Bounded production diff

The production-code diff is approximately:

```
+ <New conformer>.swift
+ <New conformer>Tests.swift
+ Tests/Fixtures/semantic_<model>_v<version>.json
~ AppContainer.swift   (one-line binding change)
```

If the diff touches any of:

- `Sources/BCIEEG/NeuralWorkspaceView.swift`
- `Sources/BCICore/Protocols/EmbeddingProjecting.swift` or its conformers
- replay infrastructure (`Tests/BCIEEGTests/SemanticWorkspaceReplayTests.swift`, etc.)
- the regression harness (`Tests/BCICoreTests/SemanticReplayRegressionTests.swift`)
- the SceneKit / projection layer
- the command / dispatcher system

…**the substitution has leaked through the seam**. Stop and ask why.
The expected answer to "why did this file need to change?" is
*"because adding a `SentenceEmbedder` conformer requires it"*; any
other answer is a smell. (This is the gate stated in the post-2.5
review of Stage 3.)

### Gate 2 — Existing tests unchanged

All 239 tests in the existing test suite (across `BCICoreTests`,
`BCIEEGTests`, `BCIClassifierTests`, `BCILLMTests`, `BCIVoiceTests`,
`NeuralComposeAppTests`, and the package-level tests) **continue to
pass unchanged**. No test in those targets is modified to accommodate
the new backend.

If an existing test starts needing backend-specific branching (a
`#if coreml` block, a different `accuracy:` value, a conditional
assert), the seam is leaking *behavior*, not just structure. Stop and
ask why.

The Stage 2.5 test suite (`SemanticReplayRegressionTests`,
`SemanticWorkspaceReplayTests`) is the *behavioral* part of the
contract. The new backend's `semantic_<model>_v<version>.json`
fixture is the new backend's claim that it satisfies the same
behavioral properties. If a Stage 2.5 test needs a backend-specific
branch, the new backend has not actually demonstrated the same
behavioral property.

### Why both gates

Gate 1 is about *structure*: the production code didn't grow sideways.
Gate 2 is about *behavior*: the existing tests didn't gain
backend-specific paths. A substitution that passes Gate 1 but fails
Gate 2 has added a new conformer that *happens* to satisfy the
structural shape but *coincidentally* has different semantics. A
substitution that passes Gate 2 but fails Gate 1 has the right
semantics but has leaked implementation details into the rest of the
app. Both must pass.

---

## 8. Open evolution paths (deliberately deferred)

These are fields and capabilities the contract reserves the right to
add but does *not* require today. They are listed here so a future
contributor knows they are intentional omissions, not oversights.

| # | Deferral | When it would be added |
|---|---|---|
| 8.1 | Model SHA256, tokenizer SHA256, and runtime identifier as fields on `Embedding` | When a second `SentenceEmbedder` conformer actually exists. The metadata is *additive* to the existing struct. |
| 8.2 | `Embedding.modelSHA256`, `Embedding.tokenizerSHA256`, `Embedding.runtime` | Same trigger. |
| 8.3 | A `MLXSentenceEmbedder` conformer | When the MLX runtime in `BCILLM` is no longer load-bearing for the LLM, or when an embedding-only MLX model becomes a meaningfully better choice than the ANE-preferred Core ML option. The current Core ML preference is documented at `CLAUDE.md` ("MLX isolation is load-bearing"). |
| 8.4 | A `MultilingualSentenceEmbedder` conformer (e.g. `bge-m3`) | When cross-lingual support is needed. Would add a `language` field or `crossLingualCompatible: Bool` to `Embedding` as an additive change. |
| 8.5 | A fitted projector (`PCAProjector`, `UMAPProjector`) | When an embedding corpus exists to fit on. The `EmbeddingProjecting` protocol already anticipates this (`EmbeddingProjecting.swift:14-16`). The fitted projector would replace `RandomProjectionProjector` as the *display* layer, behind the same protocol, with no changes to `SentenceEmbedder` or `Embedding`. |
| 8.6 | Per-backend `SentenceEmbedder` registry or runtime selection | Stage 4+ at the earliest, and only if a concrete user need emerges. Today the binding lives in `AppContainer.swift` and the user changes it by editing that line. |
| 8.7 | Embedding cache hierarchy, semantic databases, graph memories | Explicitly deferred per the closed roadmap (memory). These are Stage 4+ concerns gated on observed need, not speculation. |

Every addition on this list is governed by `PRINCIPLES §4` (frozen
public APIs evolve additively) — the contract never shrinks, it only
gains fields, methods, or conformers.

---

## 9. Per-claim evidence

| Claim | File:line | Test |
|---|---|---|
| `SentenceEmbedder` is `Sendable` | `Sources/BCICore/Protocols/SentenceEmbedder.swift:24` | (compiler-enforced) |
| Batch order is preserved | `Sources/BCICore/Protocols/SentenceEmbedder.swift:36-40` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:93` |
| `values` is L2-normalized | `Sources/BCICore/Models/Embedding.swift:20-23` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:35` |
| `cosineSimilarity` is a plain dot product | `Sources/BCICore/Models/Embedding.swift:58-63` | (implied by 2.3) |
| `cosineSimilarity` returns 0 on dim mismatch | `Sources/BCICore/Models/Embedding.swift:58-59` | (docstring) |
| Provenance is populated | `Sources/BCICore/Models/Embedding.swift:26-44` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:48` |
| Casing/whitespace canonicalized | `Sources/BCICore/Embedding/DeterministicSentenceEmbedder.swift:88-96` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:78` |
| Unicode canonicalized (NFC) | `Sources/BCICore/Embedding/DeterministicSentenceEmbedder.swift:91-96` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:84` |
| Empty input is safe & deterministic | `Sources/BCICore/Embedding/DeterministicSentenceEmbedder.swift:56-65, 113-117` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:110` |
| Pure function (no hidden state) | `Sources/BCICore/Embedding/DeterministicSentenceEmbedder.swift:38-42` | `Tests/BCICoreTests/SentenceEmbedderTests.swift:102` |
| Various dimensions all normalize | `Tests/BCICoreTests/SentenceEmbedderTests.swift:120-126` | (self) |
| Golden fixture is the canonical reference | `Tests/Fixtures/semantic_stub_v1.json` | `Tests/BCICoreTests/SemanticReplayRegressionTests.swift:108-180` |
| SHA-256 projection fingerprint | `Tests/BCICoreTests/SemanticReplayRegressionTests.swift:55, 280-292` | (within the same file's golden test) |
| Workspace consumes the contract, not the conformer | `Sources/BCIEEG/NeuralWorkspaceView.swift:467` | `Tests/BCIEEGTests/SemanticWorkspaceReplayTests.swift` |

---

## 10. Change protocol for this document

This document is **load-bearing**. Editing it has the same review
gravity as editing the protocol it describes.

- **Adding a guarantee**: requires (a) a test that pins it, (b) a
  citation in §9, (c) a corresponding addition to §3 if the new
  guarantee changes what the system previously did *not* guarantee.
- **Removing or weakening a guarantee**: requires (a) a deliberate
  decision recorded as an ADR, (b) regeneration of any fixture that
  relied on the removed guarantee, (c) explicit user sign-off.
- **Adding to the §8 deferral list**: free. The list is the
  *intentional* backlog.
- **Promoting a §8 deferral to a real field**: requires going through
  the "adding a guarantee" path, with the field cited in both §1/§2
  and §9.

If a future commit violates this document without a corresponding
update here, that commit is a regression. Revert it.
