# A2 Apple Silicon acceptance record — PR #32

Sanitized evidence for the packaged Apple Silicon acceptance of the A2
runtime-identity work (commits A/B/C `1fdf48b`/`3067cd8`/`14c8b6a` plus
follow-ups D/E/F). Records what was **directly observed**, on which head, in
which environment. Anything not run is listed as pending, not assumed.

## Environment

| | |
|---|---|
| Date | 2026-07-26 |
| Head under test | `4c5e275` (= C `14c8b6a` + D `d0d5dd7` + E `db01432` + F `4c5e275`) |
| Hardware / OS | Apple Silicon (arm64), macOS 26.5.2 (25F84) |
| Toolchain | Swift 6.3.3 (swiftlang-6.3.3.1.3) |
| Ollama daemon | running on `http://localhost:11434`, `qwen2.5:0.5b` pulled |
| Claude CLI | present on PATH |

## 1. Build, test, package, sign — PASS (observed)

```
swift build                      → Build complete
swift test                       → 616 tests, 0 failures, 10 skipped, exit 0 ¹
./Scripts/build.sh               → Build complete
./Scripts/package-app-bundle.sh  → Bundled .build/NeuralCompose.app
./Scripts/smoke-packaged-resources.sh
                                 → PASS — packaged prompt resources present,
                                   loadable, signed, and guarded
                                   (all 5 packaged-layout loads succeeded;
                                   packaging guard exits 1 with bundle removed)
codesign --verify --deep --strict .build/NeuralCompose.app
                                 → verified, exit 0
```

¹ The 616/0 result requires
`--skip MindMonitorOSCStreamTests/testTruncatedSampleAddressCountsAsDroppedNotIgnored`
**on this machine**: that UDP test kills the test process silently
(exit 1, no failure output, every suite alphabetically after it never
runs). Reproduced identically at the untouched base `14c8b6a`, so it is
pre-existing and environmental (macOS 26 local-network TCC against an
unbundled test binary is the suspected mechanism, consistent with this
machine's cdhash-pinned Local Network grants), not introduced by D/E/F.
PR CI is green including this test. **Caveat for local runs:** a plain
`swift test` on this machine silently under-reports — check the exit
code, not the absence of failure lines.

The packaged-app MLX caveat from `package-app-bundle.sh` was observed:
no `mlx-swift_Cmlx.bundle` metallib in this SwiftPM build, so the
spectral estimator runs as STUB in the packaged app (known limitation,
`Scripts/build-xcode-mlx.sh` is the documented remedy). Does not affect
runtime-identity behavior.

## 2. Headless runtime acceptance (real daemon, no generation) — observed

Via `dialectic-session` (`--dry-run` initializes + verifies + reports and
makes **no** LLM call).

**Ollama, exact model present — PASS.**
`--dry-run --runtime ollama --model qwen2.5:0.5b` → exit 0; fingerprint
`runtime=ollama transport=ollama-http provider=ollama model=qwen2.5:0.5b
promptProfile=wakingDialectical promptHash=094ec537…`; verification
`prompt loaded: yes / transport reachable: yes / model available: yes`;
"No LLM call was made."

**Ollama, missing model, daemon alive — PASS (fails closed).**
`--dry-run --runtime ollama --model a2-definitely-absent` → exit 1,
"is not installed" diagnostic, no generation, no Claude substitution.

**Ollama, untagged request with `:latest` stored — DIVERGENCE (harness only).**
Fixture: `ollama cp qwen2.5:0.5b a2-accept:latest`, request `a2-accept`,
fixture removed afterwards. The **harness** (`DialecticSession/RuntimeFactory`)
rejected the untagged request (exit 1) even though `a2-accept:latest` was
installed. The **app** path (`LiveRuntimeFactory` → `OllamaReadinessProbe`)
canonicalizes untagged → `:latest` and, since commit D, reports it as the
same model in `isSubstitution` (regression-tested). Follow-up: align the
harness probe with the app's canonicalization or document the stricter
harness matching as intended.

**Claude, resolution only — PASS (no request made).**
`--runtime-report --runtime claude --model claude-sonnet-5` → exit 0;
executable resolved; `provider=anthropic model=claude-sonnet-5
promptProfile=wakingDialectical promptHash=094ec537…` (same hash as the
Ollama dialectic profile — same transmitted prompt bytes, as intended).
Per the A2 report this proves **configured**, not operationally proven:
no authentication, rate-limit, or generation check occurred.

**Not observable headlessly here** (no endpoint override in the harness
CLI): non-loopback Ollama endpoint and endpoint-unavailable. Both remain
covered by mocked regression tests at the app factory
(`testLoopbackOllamaIsOnDeviceAndNonLoopbackIsNot`,
`testUnreachableEndpointIsUnavailableNotModelMissing`).

Note on sanitization: the harness's missing-model stderr enumerates the
user's locally pulled models. The app deliberately does not (see
`LiveRuntimeFactory`'s `.modelMissing` path). Acceptable for a developer
CLI on stderr; this record does not reproduce the enumeration.

## 3. What D/E/F add to the A2 keep-bar (regression-tested, this head)

- Unknown provider → `RuntimeLocality.unresolved`: egress-conservative,
  displayed "Egress unverified", never "On-device", never a claimed broker
  topology (D).
- `qwen2.5` → `qwen2.5:latest` is canonical resolution, not a substitution
  alarm; any other difference still discloses (D).
- `DialecticalTurnEvent.witnessGeneratorFingerprint` persists the Witness's
  provider/model/prompt profile/prompt hash separately from the pole
  fingerprint; pole and Witness prompt hashes proven distinct on the same
  logged event; pre-field logs decode unchanged (E).
  `analyze_dialectic.py` reports witness-fingerprint counts and a
  witness/pole prompt-hash collision count (collision = the old
  wrong-prompt bug's signature; must be 0).
- Failed runtime identity stays visible in the expanded privacy panel after
  fail-closed disablement ("Last attempt — …"); active badge stays hidden
  while disabled (F).

## 4. Pending — requires an operator (not run in this record)

Per the A2 report's acceptance plan; none of the below is claimed.

1. **Packaged GUI matrix**: launch `.build/NeuralCompose.app` (binary
   directly, not `open`, so `NEURALCOMPOSE_RUNTIME`/`NEURALCOMPOSE_MODEL`
   reach it), grant mic/speech, and drive one turn or one deliberate
   readiness failure per combination: {Mirror, Focused, Reflective,
   Contemplative} × {Claude, Ollama}. Observe requested/resolved identity,
   locality, readiness, prompt profile/hash, toggle state, UI wording, and
   on failure: no Claude process, "Last attempt" diagnostics retained.
2. **Real Claude operational acceptance**: authenticated CLI, one real
   Mirror turn, one Focused turn, one Reflective turn with separate Witness
   fingerprint present in the logged turn (now recordable via E); CLI
   missing and rate-limited/unavailable cases where safely reproducible.
   This decides whether `RuntimeReadiness` needs a distinct
   `configured` state, per the A2 report.
3. **Cancellation / mode-change**: while resolution is pending — switch
   mode, disable the loop, quit the app, interrupt an Ollama probe, deny
   mic permission; verify the reconcile seam prevents stale resolutions
   from enabling or reporting the wrong runtime.
4. **Reflective reference rerun**: after this PR merges, mark the affected
   pre-B Reflective runs `status: superseded` (dead-prompt-field defect,
   `fixed_by: 3067cd8`) and rerun the Focused-vs-Reflective fixture so the
   replacement captures dialogue + Witness fingerprints.

## 5. Commit J — app-side Claude provenance (correction, not a rewrite)

Sections 1–4 stand as written. They record what was observed at the heads they
name, and nothing below revises them.

### What the log audit found

A read-only review of the `71c5c02` session logs
(`NeuralCompose-a2-handoff/a2-final/sonnet5-dialectic-log-review.md`) found the
day-file's twelve dialectical turns carried **no `generatorFingerprint` and no
`witnessGeneratorFingerprint`**, while the harness runs of the same head carried
both. The cause was an app-path asymmetry, established from source rather than
inferred:

- `ClaudeCLIGenerator` conforms only to `TextGenerating`;
- `GenerationRuntimeTextGeneratingAdapter` is the sole
  `MetadataPublishingTextGenerating` conformer;
- `LiveRuntimeFactory.makeClaude` returned the raw generator, while
  `makeOllama` returned the adapter;
- `HypnagogicDialecticLoop` populates `generatorFingerprint` *only* from a
  metadata-publishing generator (`HypnagogicDialecticLoop.swift:86`).

So the packaged app could not durably attribute a Claude turn to its provider,
model, or prompt hash, and the same gap hid the Claude Witness's identity. The
absence was self-concealing: with no fingerprint there is no record of which
provider produced the record. Pre-existing rather than introduced by this PR —
the Ollama adapter work made it visible.

### The correction

Commit J routes `makeClaude` through the bridge the repository already had:
`ClaudeCLIGenerationRuntime` wrapped in `GenerationRuntimeTextGeneratingAdapter`,
matching the Ollama path. No second provenance mechanism was introduced.

Prompt bytes are unchanged. The `promptProfile:` initializer re-loads the
profile so metadata records the real profile rather than `custom`; that load is
a cache hit on the entry the factory has already populated
(`PromptProfile.load()` caches on `cacheKey`), so it returns the identical
`String`. The adapter carries no prompt of its own by construction.

Readiness semantics are untouched: Claude still resolves `.configured`, not
`.ready`, and a successful call does not mutate `ResolvedRuntimeIdentity`.

Failed calls publish nothing. Metadata is built inside
`ClaudeCLIGenerationRuntime.generate` only after `transport.send` returns, and
the adapter fires `onMetadata` only after `generate` returns, so a throw
short-circuits both.

### Evidence status

- The `71c5c02` bundle hashes in §1 remain **historical evidence for that head**.
  Commit J necessarily produces a new bundle and new hashes.
- New final-head hashes and the targeted rerun below are appended after packaging.
- Admissible from the prior record: harness provider/model/prompt provenance;
  Reflective-only Witness operation; zero pole/Witness prompt-hash collisions;
  a failed Claude generation writing zero records; and `spectralState: null`
  disambiguating the stub `glossScalar` from a real reading.
- **Not claimed:** Focused, Contemplative, or Mirror behavioural fidelity. The
  available sessions were one turn per profile, and every knob distinguishing
  those profiles governs sustained behaviour.

### Recorded limitations (unchanged by this commit)

1. **Mirror has no durable telemetry.** `HypnagogicDialogueLoop` emits no
   `DialecticalTurnEvent`, which is architecturally correct — Mirror is not a
   `ContextProfile` — but leaves it observable only through an operator.
2. **No event-to-build self-attribution.** `DialecticalTurnEvent` carries no
   timestamp and no build identifier, so a log cannot independently attest which
   bundle produced it; attribution rests on filesystem metadata.
