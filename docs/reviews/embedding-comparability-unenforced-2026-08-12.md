# Embedding comparability is documented but unenforced (2026-08-12)

**Status:** fixed on `fix/embedding-comparability` (2026-08-22), unverified on Linux (no Swift toolchain on the host); `swift test` on macOS pending. Originally: open defect, not yet fixed. Found while porting `DialecticalDynamics`
to Rust (`neuralcompose-client-native`, `crates/neuralcompose-hypnagogic`).

## The defect

`Embedding.cosineSimilarity(to:)` (`Sources/BCICore/Models/Embedding.swift`)
guards on dimension only:

```swift
public func cosineSimilarity(to other: Embedding) -> Float {
    guard values.count == other.values.count else { return 0 }
    var acc: Float = 0
    for i in 0..<values.count { acc += values[i] * other.values[i] }
    return acc
}
```

`modelID` is never consulted. But three places state that it must be:

| Source | Claim |
|---|---|
| `Embedding.swift:27-28` (doc comment) | "Two embeddings with different `modelID`s are not comparable even if their `dimension` matches" |
| `docs/architecture/embedding_contract.md` §2.7 | same rule — and cites *that doc comment* as its evidence |
| `docs/architecture/decision-log/ADR-010` | same rule |
| `docs/architecture/embedding_contract.md` §3.3 | "Embeddings from different `modelID`s are not comparable" |

So the contract's own evidence column points at a comment, and the comment is
the entire enforcement. Two embeddings of equal dimension from different
backends compare today and return a plausible number.

## Why it is worse than an unchecked precondition

The dimension guard returns `0` — and **`0` is a legitimate cosine
similarity.** Orthogonal vectors from the *same* model return `0` too. So the
sentinel makes "these are incomparable" indistinguishable from "these are
unrelated," which is the failure mode with no symptom:

- In `DialecticalDynamics.energy`, a mismatched candidate scores
  `normalized(0) = 0.5` on that axis — the same value the code deliberately
  uses to mean *neutral / no data*.
- It does not error. It scores low, loses the softmax, and the loop keeps
  producing fluent output indefinitely.

`DialecticalDynamics.centroid(of:)` has the same shape one level up: it takes
provenance from the first element and **silently skips** members of a differing
dimension. A centroid averaged over an unannounced subset is still a plausible
vector, and every similarity measured against it afterwards is plausible too.

## Reachability — latent, and checked rather than assumed

Not reachable in the shipped app: one embedder is constructed per session, so
every `Embedding` in a dialectic turn shares a `modelID`.

**`SemanticEval` was the obvious counterexample and it does not hold.** An
earlier draft of this note said it "compares across candidate models by design"
and was therefore the likely first caller to hit this. That is wrong, and the
distinction matters, because if it were true this would be a *history* — past
reports already containing cross-space numbers — rather than a risk.

`Sources/SemanticEval/main.swift` takes a single `--model` flag
(`parseModelFlag()`, :12), resolves exactly one conformer through a `switch`
(:59), populates one `embeddingByText` map from that one embedder (:101-103),
and writes its report to a directory stamped with `result.provenance.modelID`
(:217). Every `cosineSimilarity` call in it — `pairScores` (:33),
`meanPairwiseSimilarity` (:45), the corpus/query scans (:108, :123) — reads
from that single map.

So SemanticEval compares models **at the report level**, across runs, not by
taking a cosine between two spaces. Its past outputs are not suspect. The
exposure is genuinely latent and arrives with the first caller that holds two
embedders at once — which ADR-010 makes foreseeable, having named
bge-small-en-v1.5 as the candidate *over* all-MiniLM-L6-v2 and E5-base-v2.

## Blast radius

32 call sites of `cosineSimilarity(to:)` across `Sources/` and `Tests/`,
including `DialecticalDynamics`, `SemanticGraph`, `DialecticalMemory`,
`HypnagogicDialecticLoop`, `SemanticEval`, `GenerationEval`. Changing the
return type to `Float?` is a real migration, not a one-line edit — which is why
this is a note rather than a patch.

## Suggested shape

Mirror what the Rust port now does (`crates/neuralcompose-hypnagogic/src/embedding.rs`):

1. `cosineSimilarity(to:) -> Float?`, `nil` for a different `modelID`, a
   different dimension, or a degenerate operand. `nil` is not a failed
   computation; it is the statement that no similarity exists to compute.
2. Propagate through `energy`, `tension`, `synthesisScore` as `Optional`, so
   **missing** (an early turn, legitimately neutral at `0.5`) stays distinct
   from **incomparable** (a defect).
3. `centroid(of:)` returns `nil` on any mismatch rather than averaging the
   comparable subset.
4. The contract table in `embedding_contract.md` §2.7 should then cite the
   type signature, not a doc comment.

The Rust side already carries this and pins it with a test asserting
`Some(0.0) != None` — orthogonal-and-comparable versus incomparable — so a
future reintroduction of the sentinel names itself.

## Not decided here — and the question is probably not "which failure mode"

The first two candidates were `nil` versus a `preconditionFailure`. Both assume
cross-model comparison is a *similarity* operation that should either return
nothing or crash.

**A third option says it is not a similarity operation at all**, and the
client-native workspace has already built the vocabulary for it:

- `crates/neuralcompose-mobile-core/src/property_law.rs:28-31` makes
  `IndexEntryKey` the pair *(content digest, embedding-space identity)* —
  "two records with different embedding identities are never the same entry,
  however similar the text."
- `property_law.rs:66-70`, `shares_index(a, b)`, is exactly this question as an
  executable law: entries belong in the same index **only** when
  `embedding_space_identity` matches, because "mixing spaces silently poisons
  retrieval."
- `model_pack.rs:305`, `embedding_space_identity()`, derives that identity from
  model family, revision, weight and tokenizer digests and dimensions — so the
  space has a name that cannot be forged, not just a `modelID` string.
- PR #30 treated cross-backend divergence as a **conformance measurement**
  (`tests/embedding_agreement.rs`, `vulkan_agreement.rs`, `composed_error.rs`),
  a different question with its own semantics and its own tolerances — not a
  similarity with a caveat.

So if a future caller genuinely needs to relate two spaces, it likely wants a
distinct, explicitly-declared operation that states what it means — a
conformance or agreement measurement between named spaces — rather than
borrowing `cosineSimilarity` and being handed a `nil` or a trap for its trouble.

That reframes the decision from *which failure mode* to *which operation*, and
it makes `nil` the cheap, honest default rather than a compromise: the primitive
declines to answer a question it was never the right operation for, and the
caller that actually needs an answer asks a differently-named one.

### Where the machinery actually lives

A correction to an earlier draft of this section, which said no
`EmbeddingProfileTerms` type existed. That was true of the two repos searched
(`neuralcompose-client-native/crates/` and `NeuralCompose/Sources/`) and **false
of the workspace**: it is in a third repo, `neural-memory-server`, at
`crates/neural-memory-domain/src/terms.rs:444`.

It is the richest form of the idea. Its own doc comment says the field set
"mirrors `neuralcompose-mobile-core`'s `embedding_space_identity`
(`model_pack.rs:305`)", and it seals:

```
model_family, model_revision, weight_sha256 (sorted), tokenizer_sha256 (sorted),
dimensions, pooling, normalization, task_instruction
```

— "change any of them and the vectors mean something else, however similar the
text." Digests are sorted before sealing because shard listing order is noise.

**And it settles the operation question outright**, in a passage worth quoting
rather than paraphrasing:

> **The backend is absent, and that is the point.** A CPU run and an NPU run of
> the same model produce vectors in the same space or they do not, and that is a
> question to be *measured*, not asserted by stamping a different identity on
> them. Putting the backend here would fork the space by declaration and make
> the measurement unaskable. Where the vector came from belongs on the runtime
> variant; whether the two may share an index is what conformance decides.

So the third option is not a proposal. It is the position this workspace already
took, deliberately, and wrote down: **identity declares the space; conformance
measures whether two things share one.** `cosineSimilarity` is neither, which is
why handing it a cross-space pair has no good answer — and why `nil` is the
honest one.

The gap is that all of this is Rust. Swift has no counterpart to
`EmbeddingProfileTerms`, `embedding_space_identity`, `IndexEntryKey` or
`shares_index`, and its `Embedding` carries a bare `modelID` string that nothing
checks. The enforcement machinery exists in the workspace, just not in the
language where the 32 call sites are.
