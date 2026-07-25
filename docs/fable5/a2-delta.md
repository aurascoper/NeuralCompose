# A2 Delta — Runtime Identity, Locality, Derived Presentation

Session: 2026-07-25 (Fable 5, follow-on to the conditional acceptance).
Upstream reference: Apple PR #32 `A2: role-specific runtime identity and
readiness (R3 + R8 + R18)`, open draft,
head `feat/resolved-runtime-identity@14c8b6a`, base `docs/eeg-methods-scope@23c56ea`
(verified live against the GitHub API this session).

This ports the PR #32 contracts into the Android client as invariants. It does
not copy Swift types; it extends the existing readiness/provenance layer.

## What was already present (verified in the audit, not re-implemented)

- Fail-closed READY with a positive `/v1/models` probe (PR #31/R18 invariant).
- Versioned prompt profile with content hash; empty prompt = typed failure (PR #29).
- No provider substitution anywhere; embedding failure mid-turn errors the turn.
- One execution path (`src/session/turnPipeline.ts`) for UI, tests, benchmark.
- Epoch cancellation, private AbortController, idempotent stop.
- BASELINE provenance from an on-device hashed manifest.

## Gaps found and closed

1. **No requested-vs-resolved identity.** Probe results collapsed into
   `{ready, detail}`; nothing structured survived on failure paths.
   → `src/runtime/identity.ts`: immutable `RuntimeIdentity`
   (`requested` + `resolved` + sanitized `failure`), built on success AND
   failure by `resolveRuntimeIdentity()`; wired through
   `src/session/readiness.ts` (`identities.{coherence,displacement,witness}`).

2. **No locality classification.** Localhost was assumed, never classified.
   → `RuntimeLocality` with the conservative rule: a loopback endpoint proves
   `localhost_local_inference` only after an exact configured-model match
   (a local executable may broker remote inference); loopback without that
   proof stays `unknown` → displayed as `EGRESS UNVERIFIED`.

3. **Alias-as-ready.** The model probe accepted substring/alias overlap as
   READY. → `classifyModelMatch` distinguishes `exact` / `alias` / `none`;
   alias resolves to readiness `unverified` (never READY, provenance
   `unverified`).

4. **Hard-coded privacy claim.** The screen asserted "All processing is local.
   No audio, text, or embeddings are sent to any cloud service." regardless of
   evidence. → Privacy wording, egress/locality/readiness/provenance badges all
   derive from `deriveRuntimePresentation(identity)`. Unknown locality reads
   `EGRESS UNVERIFIED`, never on-device.

5. **Decorative Witness flag.** `profiles.ts` set `witnessEnabled: true` on
   Reflective while the screen said "Witness off" and no Witness runtime
   exists — the exact defect class PR #32 found in the Apple harness.
   → Flag set to `false` with an explanatory comment; readiness returns
   `witness: null` meaning zero resolution/probe/prompt work was performed.

6. **No per-role prompt hashes.** One FNV-1a profile hash covered all
   templates. → `rolePromptManifest(role)` hashes each role's actually
   transmitted templates with pure-TS SHA-256 (`src/runtime/sha256.ts`);
   the two poles share one server but carry distinct role identities,
   prompts, temperatures, and prompt hashes.

7. **No role-consistency guard at the call site.** → `assertRoleConsistency`
   enforced inside the hook's `generate` wrapper (the production path): a
   runtime resolved for one role supplied to another fails the turn closed.

8. **Public error sanitation.** Failure messages could carry absolute
   filesystem paths. → `sanitizePublicMessage` strips paths to basenames and
   redacts token-shaped values; regression-tested.

## New tests

- `src/runtime/__tests__/identity.test.ts` — SHA-256 vectors; exact/alias/none
  model match; locality classification (loopback without proof ≠ local);
  identity on every failure path; role guard; derived presentation defaults
  (EGRESS UNVERIFIED / NOT READY / UNVERIFIED); remote endpoint cannot claim
  on-device.
- `src/session/__tests__/readinessIdentity.test.ts` — at the real readiness
  call site with a routing fetch mock: exact model → READY with per-role
  identities and distinct prompt hashes; missing model → not READY, identity
  with sanitized failure, every contacted endpoint loopback (no alternate
  provider); unreachable endpoint → fail-closed identities; alias → UNVERIFIED.
- `src/session/__tests__/a2Evidence.integration.test.ts` — LIVE-gated
  (`NEURALCOMPOSE_LIVE=1`): captures `.handoff/fable5/a2-evidence.json`
  (per-role requested/resolved record, gate record, missing-model fail-closed
  proof against the real server). Metadata only; no user/prompt text.

## Evidence

See `docs/fable5/verification-evidence.md` (A2 section) and
`.handoff/fable5/a2-evidence.json` after a live run.

## Operational note (this device, this session)

The Pixel rebooted mid-session; Android's phantom-process limits appear to have
reverted, and jest child processes were repeatedly killed (exit 144) until run
in-band with a capped heap. Use:

    NODE_OPTIONS='--max-old-space-size=768' ./node_modules/.bin/jest --runInBand

and re-apply the phantom-process fix over ADB after any reboot
(see `~/phantom-fix.sh` and the handoff packet).
