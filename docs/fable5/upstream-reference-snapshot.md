# Upstream Reference Snapshot — aurascoper/NeuralCompose

Refreshed: **2026-07-25T09:27:27Z** via GitHub API (evidence:
`.handoff/fable5/upstream-refresh.txt`). Local Swift clone: `~/NeuralCompose`
at `main@611b07e` (read-only reference; not modified).

## Branch authority (verified this session)

| Ref | Head SHA (verified) | Authority |
|---|---|---|
| `main` (default) | `611b07e0b6a1030cc01f27b3cf80dfd24286931f` | Stable behavioral reference for the Swift dialectical loop. Unchanged since the digest snapshot. |
| `docs/eeg-methods-scope` | `23c56eae0a9a8d66a2ab42698dd20556516dced7` | Staging reference for GenerationRuntime/prompt-resource/fail-closed contracts (PRs #29, #31 merged here). **Not default main.** |
| PR #30 head | `1251b5baa7...` | Open draft, research base, boundary context only. |

## PR state (verified 2026-07-25)

| PR | State | Base | Relevance to Android |
|---|---|---|---|
| #32 | **open draft** (new since digest) | docs/eeg-methods-scope | "Role-specific runtime identity and readiness (R3+R8+R18)" — upstream is closing the same model-readiness gap. No authority until merged; direction confirms our fail-closed readiness work. |
| #31 | merged | docs/eeg-methods-scope | Fail-closed runtime selection, no provider substitution. Carried into Android readiness gate. R18 (Ollama model probe) was open at merge; #32 addresses it. |
| #29 | merged | docs/eeg-methods-scope | Prompt resources versioned/hashed; missing/empty prompt is typed readiness failure; test installed behavior. Carried into Android prompt-profile provenance. |
| #30 | open draft | research base | EEG encoder is an offline artifact boundary. Excluded from Android runtime. |
| #22–#28 | open/merged research & governance | various | Excluded from live Android control; PR #25 privacy precedent noted. |
| #21 | merged to main | main | Spectral demeaning; encoder discrimination still weak → Android claims no cognitive decoding; EEG wind neutral/unavailable. |

## Files used as reference

From `main@611b07e` (local clone): `Sources/BCICore/Dialectic/*`,
`Composition/HypnagogicDialecticLoop.swift`, `Protocols/SpeechSynthesizing.swift`,
`Tests/BCICoreTests/*` — behavioral contract for the TS kernel port (Hermes'
baseline doc records the same file list; math verified equation-by-equation
against the handoff spec this session).

From `docs/eeg-methods-scope@23c56ea` (principles only, no code copied):
`GenerationRuntime.swift`, `GenerationTransport.swift`, `LiveRuntimeFactory.swift`,
`PromptProfile.swift`, `ClaudeExecutableResolver.swift`, `Prompts/*.md`,
architecture docs.

## Deliberately excluded

- All EEG/WorldModel/fusion research paths (PRs #22, #24–#28, #30).
- Claude/Ollama LiveRuntimeFactory implementation details (Android uses
  llama-server directly; no Claude runtime on device).
- Any claim that staging-branch features are on default `main`.

## Android design position

Android follows `main` for dialectical behavior and follows the staging
contracts as *invariants* (fail-closed readiness, prompt hash provenance, no
substitution, one execution path) — an Android-specific adaptation, not a port
of staging Swift code.

## Unresolved upstream items that matter to Android

- R18 / PR #32: model readiness probing before READY — Android implements its
  own positive probe (llama-server `/v1/models`) rather than waiting.
- Live app vs harness execution-path split upstream — Android counters this by
  routing UI/tests/benchmark through one turn-controller path.
- Authorization-gated toggle coverage upstream — no Android analogue yet.

## Refresh 2026-07-25 (A2 delta session)

Verified live against the GitHub API this session:

- PR #32 `A2: role-specific runtime identity and readiness (R3 + R8 + R18)` —
  OPEN DRAFT, head `feat/resolved-runtime-identity@14c8b6a98df4b6a570ec17da84191fcfc94d3ae1`,
  base `docs/eeg-methods-scope@23c56eae0a9a8d66a2ab42698dd20556516dced7`, not merged.
- The cross-platform A2 addendum (operator-supplied) reports: runtime identity
  separate from generation object, Witness prompt-path repair (the headless
  harness had been transmitting the pole prompt while reporting a Witness
  identity), UI provider/locality derivation, 481 focused tests, CI green.
  Reported-by-addendum, not independently re-run here.

Authority note: PR #32 remains an OPEN DRAFT — its contracts are ported to
Android as invariants (requested-vs-resolved identity, locality classification,
derived presentation, role-consistency guard, alias≠exact model match), not as
merged upstream behavior. Apple-side Reflective evidence gathered through the
pre-#32 harness is historical/semantically suspect per the addendum; Android
carries no analogous defect because the Witness role resolves nothing here.
