# ADR-009: Generation runtime semantics and benchmark integrity

**Status**: Accepted
**Date**: 2026-07-28 (reconstructed; see Provenance)

## Context

This document is **reconstructed from the code that cites it**. Twenty-two
references across eleven files invoke "ADR-009 invariant #N" as normative
authority, each stating the invariant it relies on inline, but no ADR-009 file
has ever existed on any branch. The decision was made and enforced; only the
record was missing.

That is a provenance defect rather than a documentation gap. A citation reads as
an appeal to a review decision, and eleven files' worth of them appealed to
nothing a reader could open. `CONTRIBUTING.md` makes
`docs/architecture/decision-log/` the canonical location for exactly this, and
`Scripts/check_adr_references.py` now rejects a reference that resolves to no
file — so the runtime cannot land on `main` without this document.

The decision itself concerns the boundary between an application's *semantic*
intent and a runtime's *transport* responsibility, and what a benchmark
comparison across providers is allowed to assume.

## Decision

Five invariants. The wording is the wording its citations already carry; nothing
is added, generalised, or inferred beyond them.

### 1 · Prompt profiles are repository resources

The application owns semantic intent; a runtime owns transport and execution. A
prompt is a versioned resource in the repository, not runtime state assembled at
the call site.

### 2 · A runtime SHALL NOT modify semantic intent

The bytes a transport sends are the bytes the profile declares. No
re-instruction, no rewriting, no provider-specific reinterpretation, and no
appending of framing. A runtime and its transport are conduits.

### 3 · A new model behind an existing transport is configuration

Adding a model reachable by an existing transport is a configuration change, not
a new Swift type. New types are for new transports, not new endpoints.

### 4 · Optional behaviour is capability-advertised

Capabilities a runtime may or may not have — token counting, streaming, log
probabilities — are advertised and queried, never made method-mandatory on every
conformer. A runtime that cannot do a thing says so; it does not fabricate.

### 5 · Canonical benchmarks are immutable

Benchmark inputs and identities do not change. New provider or model results
attach to a canonical benchmark; they never rewrite it. This is what makes a
cross-provider comparison a comparison rather than two unrelated runs.

## Consequences

Invariant 2 is the load-bearing one and accounts for twelve of the twenty-two
citations: it is what allows a recorded `promptHash` to attest the bytes that
actually left the process. Invariants 1 and 5 make that hash meaningful over
time — a repository resource is diffable, and an immutable benchmark identity is
comparable. Invariant 4 is why a runtime reporting "no digest available" is
correct behaviour rather than a gap.

Together they mean a persisted turn is attributable to a specific
`(runtime, transport, provider, model, promptProfile, interactionStyle,
promptHash)` tuple without re-running the session.

### Not part of this decision

The `configured` / `ready` readiness split introduced by commit H (PR #32) is
**compatible with** these invariants but is a **later refinement**, not
reconstructed evidence about ADR-009's original scope. It is recorded in
`docs/evaluation/a2-apple-silicon-acceptance.md` §5, and nothing in this document
should be read as having anticipated it.

## Provenance

Reconstructed from the following citations at
`0dfae3ce35230b79deaee1da074f9313e63e55c8` (PR #32 head). **The locator is the
symbol**; line numbers are a snapshot at that commit and will move as the
runtime is integrated.

| # | file | symbol | line @0dfae3c |
|---|---|---|---|
| 1 | `Sources/BCICloudBridge/ClaudeCLIGenerator.swift` | `actor ClaudeCLIGenerator` | 27 |
| 1 | `Sources/BCICloudBridge/PromptProfile.swift` | file header · `enum PromptProfile` | 8 |
| 2 | `Sources/BCICloudBridge/LiveRuntimeFactory.swift` | file header · `enum LiveRuntimeFactory` | 38 |
| 2 | `Sources/BCICloudBridge/OllamaGenerationRuntime.swift` | file header · `struct OllamaGenerationRuntime` | 17 |
| 2 | `Sources/BCICloudBridge/OllamaHTTPTransport.swift` | file header · `struct OllamaHTTPTransport` | 18 |
| 2 | `Sources/BCICloudBridge/OllamaHTTPTransport.swift` | `let body` (request encoding) | 107 |
| 2 | `Sources/BCICloudBridge/OllamaHTTPTransport.swift` | `var body` (delimiter handling) | 139 |
| 2 | `Sources/BCICore/Protocols/GenerationRuntime.swift` | file header · `protocol GenerationRuntime` | 5 |
| 2 | `Sources/BCICore/Protocols/GenerationRuntime.swift` | `let generationParameters` | 72 |
| 2 | `Sources/BCICore/Protocols/GenerationTransport.swift` | file header · `protocol GenerationTransport` | 8 |
| 2 | `Sources/BCICore/Protocols/MetadataPublishingTextGenerating.swift` | file header | 26 |
| 2 | `Sources/BCICore/Protocols/MetadataPublishingTextGenerating.swift` | `protocol MetadataPublishingTextGenerating` | 39 |
| 2 | `Tests/BCICloudBridgeTests/ClaudeCLITransportTests.swift` | `func testBuildArgsPreservesPromptBytes` | 37 |
| 2 | `Tests/BCICloudBridgeTests/OllamaHTTPTransportTests.swift` | `func testEncodeRequestSystemPromptVerbatim` | 50 |
| 3 | `Sources/BCICloudBridge/OllamaGenerationRuntime.swift` | file header · `struct OllamaGenerationRuntime` | 10 |
| 3 | `Sources/BCICloudBridge/OllamaHTTPTransport.swift` | file header · `struct OllamaHTTPTransport` | 10 |
| 3 | `Sources/BCICore/Protocols/GenerationRuntime.swift` | `let logProbs` (`RuntimeCapabilities`) | 211 |
| 4 | `Sources/BCICloudBridge/OllamaGenerationRuntime.swift` | file header (Claude returns no digest) | 29 |
| 4 | `Sources/BCICloudBridge/OllamaGenerationRuntime.swift` | `let loaded` (capability query) | 66 |
| 4 | `Sources/BCICore/Protocols/GenerationRuntime.swift` | `let tokenCount` (`GenerationMetadata`) | 184 |
| 4 | `Tests/BCICloudBridgeTests/OllamaHTTPTransportTests.swift` | `func testRuntimeAdvertisesTokenCounting` | 164 |
| 5 | `Sources/BCICore/Telemetry/GeneratorFingerprint.swift` | file header · `struct GeneratorFingerprint` | 19 |

Distribution: #1 ×2 · #2 ×12 · #3 ×3 · #4 ×4 · #5 ×1 — twenty-two total.

None of these files is on `main` at the time of writing; they arrive with lane A.
`Scripts/check_adr_references.py` in hard mode rejects any intermediate tree that
carries the citations without this document, which is why D0-R was sequenced
before lane A rather than after it.
