# Embedding comparability is documented but unenforced (2026-08-12)

**Status:** open defect, not yet fixed. Found while porting `DialecticalDynamics`
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

## Reachability

Not currently reachable in the shipped app, as far as this review can tell: one
embedder is constructed per session, so every `Embedding` in a dialectic turn
shares a `modelID`. The exposure is real but latent, and it grows the moment a
second backend exists — which ADR-010 is explicitly about, having named
bge-small-en-v1.5 as the candidate *over* all-MiniLM-L6-v2 and E5-base-v2.

`Sources/SemanticEval/` compares across candidate models by design and is the
most likely first caller to hit it.

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

## Not decided here

Whether `nil` should be a trap instead. A `preconditionFailure` would be louder
and is defensible for what is arguably a programming error, but it would make a
mixed-corpus `SemanticEval` run crash rather than report, and that tool exists
precisely to compare across models. `Optional` leaves the choice with the
caller; the trap does not.
