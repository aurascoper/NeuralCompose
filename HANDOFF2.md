## Verdict

For the **macOS Apple Silicon build**, PR #32 is a strong A2 implementation. The three-commit sequence is coherent, independently buildable, and should **not** be rewritten. I would keep commits `1fdf48b`, `3067cd8`, and `14c8b6a` intact, then add narrowly scoped follow-up commits for the remaining gaps.

The original architecture makes `AppContainer` the composition root, preserves strict Swift concurrency, and treats MLX isolation as load-bearing. It also defines the Reflective Witness as a separate, non-voiced generator with its own prompt seam—not merely another label on the pole generator. PR #32 is fixing exactly the correct architectural boundary.  

As of the current GitHub state, PR #32 is still an **open, mergeable draft**, based on `docs/eeg-methods-scope@23c56ea`, with head `14c8b6a`, three commits, and 14 changed files.  Its CI run completed successfully, including the all-target build and deterministic test suites.

## What A2 now proves

The important parts are real:

* The app retains **requested and resolved** provider/model identities separately.
* Runtime identity exists on both success and failure paths.
* Ollama readiness checks the daemon and the exact requested model before enabling the loop.
* A missing Ollama model fails closed without substituting Claude.
* Claude is correctly classified as a **local broker to remote inference**, not on-device.
* Reflective resolves a separate Witness runtime with the actual Witness prompt.
* Focused and Contemplative do no unused Witness resolution or readiness work.
* The adapter’s dead prompt field is gone.
* Privacy presentation is derived from runtime identity rather than hard-coded provider strings.
* All 11 named mutations have regression coverage, even though the ad hoc mutation harness itself was correctly rejected as unreliable.

The report’s note that M2 belongs in Commit A is correct. The role-to-prompt binding is a factory invariant, so it naturally arrives with runtime identity and readiness rather than with the later AppViewModel Witness wiring.

## Five remaining gaps before I would mark it merge-ready

### 1. The structured failure identity is stored, but the UI hides it after fail-closed disablement

The implementation correctly stores the unavailable identity and then sets:

```swift
hypnagogicLoopEnabled = false
```

However, once that toggle is false, the expanded privacy view renders only:

```text
Disabled at runtime
```

rather than displaying the requested provider, requested model, locality, and readiness failure that the new identity was designed to preserve.

`lastError` still presents the sanitized message, so this is not a privacy failure. It is a mismatch between the PR’s architectural claim and the final UI.

I would add a persistent **Last runtime attempt** row:

```text
Runtime disabled
Last attempt: Ollama · qwen2.5:0.5b · On-device · Model unavailable
```

The active badge should remain hidden because the loop is not running, but the failure identity should remain visible in the expanded diagnostics panel.

### 2. Unknown provider locality is represented as a known cloud-broker locality

For an unsupported provider, the factory comment says:

> “there is nothing to classify”

but then assigns:

```swift
locality: .localBrokerToRemoteService
```

That is conservative about egress, but semantically inaccurate. An unknown provider is not known to be a local broker.

Add:

```swift
case unknown
```

or:

```swift
case unresolved
```

to `RuntimeLocality`, with:

```swift
involvesNetworkEgress == true
displayLabel == "Egress unverified"
```

That gives the Apple implementation the same honest conservative state now used by Android:

```text
unknown ≠ on-device
unknown ≠ known remote broker
unknown = egress unverified
```

### 3. “Ready” means different things on Claude and Ollama

Ollama readiness is relatively strong:

```text
endpoint answered
+ exact model present
+ prompt loaded
= ready
```

The probe uses exact model matching, allowing only the well-defined untagged-to-`:latest` canonicalization.

Claude readiness is weaker:

```text
claude executable found
+ prompt loaded
= ready
```

No authentication check, rate-limit check, account-status check, or real provider request occurs before the identity is marked `.ready`.   The PR also explicitly records that its added tests made no real provider generation requests.

There are two defensible solutions:

```text
Option A:
configured
available
generationVerified
```

or:

```text
Option B:
keep RuntimeReadiness.ready
but define it narrowly as "local prerequisites resolved"
and require a separate live acceptance result
```

I prefer the first:

```swift
enum RuntimeReadiness {
    case configured
    case ready
    case unavailable(RuntimeReadinessFailure)
}
```

For Claude:

```text
executable + prompt = configured
successful bounded operator smoke = ready
```

For Ollama:

```text
/api/tags exact model probe = ready
```

At minimum, avoid presenting Claude as operationally proven before one real provider call succeeds.

### 4. `:latest` canonicalization conflicts with `isSubstitution`

The Ollama probe deliberately treats:

```text
qwen2.5
qwen2.5:latest
```

as the same model.

But `ResolvedRuntimeIdentity.isSubstitution` compares the raw requested and resolved model strings:

```swift
resolvedModel != requestedModel
```

Therefore:

```text
requested: qwen2.5
resolved:  qwen2.5:latest
```

can be simultaneously:

```text
accepted as the same model by readiness
reported as a provider/model substitution by identity
```

Normalize before substitution comparison, or preserve a canonical requested model alongside the literal request:

```swift
requestedModelLiteral
requestedModelCanonical
resolvedModelCanonical
```

A canonical `:latest` resolution should not trigger a substitution alarm.

### 5. The pole runtime is fingerprinted per turn; the Witness runtime is not

`DialecticalTurnEvent` contains:

* Witness finding
* Witness distance
* Witness attempted
* one `generatorFingerprint`

But that single fingerprint is documented as the generator that produced the **candidates**. There is no separately persisted Witness fingerprint.

This matters because the bug being fixed was precisely:

```text
reported Witness prompt
≠
prompt actually transmitted
```

PR #32 proves the wiring statically and in focused tests, but a future persisted Reflective turn still cannot independently prove:

```text
Witness provider
Witness model
Witness prompt profile
Witness prompt hash
Witness generation parameters
```

Add an optional:

```swift
public let witnessGeneratorFingerprint: GeneratorFingerprint?
```

to:

* `DialecticalCompetition`
* `DialecticalTurnEvent`
* the JSONL codec
* analysis scripts and rollups

The Witness adapter needs its own metadata callback box, parallel to the pole generator’s metadata capture.

Without this, rerunning `seed-002` would prove that a Witness ran and produced a finding, but the saved turn record would not fully attest which runtime/prompt produced it.

## The old Reflective evidence should be explicitly superseded

The report’s conclusion is right:

> Every affected Reflective harness run using the dead prompt field should be treated as suspect.

Do not delete or rewrite those old runs. Mark them:

```yaml
status: superseded
reason: witness adapter carried a non-operative prompt field
actual_runtime_prompt: waking-dialectical pole prompt
intended_runtime_prompt: witness prompt
fixed_by: 3067cd8
```

Then rerun the same Focused-versus-Reflective fixture after the Witness fingerprint field exists.

That rerun should capture:

```text
dialogue fingerprint
Witness fingerprint
Witness attempted
Witness finding
witnessDistance
selfSimilarity
candidate outputs
tension
outcome
seed
profile
```

This gives you a clean replacement rather than an incomparable new experiment.

## Required Apple Silicon acceptance runs

The current 481 focused tests and CI are strong engineering evidence, but not the complete runtime acceptance.

### Packaged application test at the PR head

Build and package from `14c8b6a` or its follow-up head:

```bash
./Scripts/build.sh
./Scripts/package-app-bundle.sh
./Scripts/smoke-packaged-resources.sh
codesign --verify --deep --strict .build/NeuralCompose.app
```

Then launch the packaged app, not only `swift run`.

Verify:

```text
Mirror + Claude
Focused + Claude
Reflective + Claude
Contemplative + Claude

Mirror + Ollama
Focused + Ollama
Reflective + Ollama
Contemplative + Ollama
```

You do not need long conversations for every combination. One successful turn or one deliberate readiness failure per meaningful path is enough for A2.

### Real Ollama acceptance

Test:

1. Correct exact model present.
2. Missing model while daemon remains alive.
3. Untagged model resolved to `:latest`.
4. Non-loopback Ollama endpoint.
5. Endpoint unavailable.

Observe:

```text
requested identity
resolved identity
locality
readiness
prompt profile/hash
toggle state
no Claude process or request on failure
UI wording
```

### Real Claude acceptance

Test:

1. CLI present and authenticated.
2. CLI missing.
3. CLI present but provider unavailable or rate-limited, where safely reproducible.
4. One real Mirror turn.
5. One real Focused turn.
6. One real Reflective turn with separate Witness metadata.

This is where you learn whether “configured” is enough or whether the readiness enum needs another state.

### Cancellation and mode-change test

While resolution is pending:

* switch mode;
* disable the loop;
* close the app;
* interrupt an Ollama probe;
* deny microphone permission.

Verify that the internal reconcile seam prevents stale resolution results from enabling or reporting the wrong runtime.

## Recommended commit sequence

Do **not** rewrite A/B/C.

Add:

```text
Commit D
fix(runtime): distinguish unresolved locality and canonical model identity
```

Include:

* `.unknown` or `.unresolved` locality;
* conservative egress presentation;
* canonical model comparison;
* regression tests.

Then:

```text
Commit E
fix(telemetry): persist Witness runtime fingerprint
```

Include:

* separate Witness metadata capture;
* optional Witness fingerprint in the turn event;
* backward-compatible decoding;
* analysis/rollup updates;
* regression tests proving the pole and Witness prompt hashes differ.

Then:

```text
Commit F
fix(ui): retain failed runtime identity after loop disablement
```

Include:

* Last runtime attempt diagnostics;
* no active-listening badge while disabled;
* sanitized failure identity;
* tests.

Finally:

```text
Commit G
test(runtime): record packaged Apple Silicon A2 acceptance
```

Include only sanitized evidence and documentation—not private transcripts.

## Merge strategy

PR #32 currently targets `docs/eeg-methods-scope`, not `main`.  Therefore even after PR #32 merges, A2 is still a **staging-branch capability**, not a shipped `main` capability.

I would use this sequence:

```text
1. Add D/E/F to PR #32.
2. Run packaged Apple Silicon acceptance.
3. Mark PR #32 ready for review.
4. Merge PR #32 into docs/eeg-methods-scope.
5. Add the ADR-011 ShadowPolicyEvaluating governance amendment separately.
6. Rerun the invalidated Reflective fixture.
7. Open an explicit integration PR from the stabilized runtime train to main.
8. Only then update README/release documentation to describe A2 as shipped.
```

Do not merge PR #30 merely because PR #32 is ready; PR #30 remains a separate planning-and-contract branch with its own disposition.

## Current status

```yaml
apple_silicon_a2:
  identity_and_readiness: PASS
  exact_ollama_model_probe: PASS
  no_provider_substitution: PASS
  witness_prompt_separation: PASS
  disabled_witness_zero_resolution: PASS
  privacy_ui_provider_derivation: PASS
  mutation_regression_coverage: PASS
  ci: PASS

remaining:
  failed_identity_visible_after_disable: PARTIAL
  unknown_locality_representation: NEEDS_FIX
  claude_operational_readiness: UNPROVEN
  latest_tag_substitution_normalization: NEEDS_FIX
  witness_per_turn_provenance: MISSING
  packaged_head_acceptance: UNPROVEN
  reflective_reference_rerun: REQUIRED
  mainline_promotion: NOT_YET
```

So the Apple build is ahead of Android in its Swift runtime abstraction and Witness implementation, while Android is ahead in its explicit per-role prompt hashes and device-local end-to-end evidence. The best next move is to close those small Apple provenance/UI gaps, rerun Reflective honestly, and then converge the two platforms around the same evidence contract.


