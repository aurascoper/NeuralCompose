# Verification Evidence — Fable 5 pass, 2026-07-25

All raw outputs live under `.handoff/fable5/` (gitignored). Commands were run
from `~/neuralcompose-client` on the Pixel 8a in Termux.

## Baseline (before any Fable edit)

| Check | Command | Result | Evidence file |
|---|---|---|---|
| Tests | `npm test` | 5 suites, 48/48 pass, 8.7 s | `test-before.txt` |
| Typecheck | `npx tsc --noEmit` | clean, exit 0 | `typecheck-before.txt` |
| Expo doctor | `npx expo-doctor` | 3 checks failed: jest/@types/jest major-version mismatch (29 expected, 30 installed — introduced with Hermes' test stack; pre-existing) | `expo-doctor-before.txt` |
| Services | `ss`, `ps`, port probes | 8081/8082/8083 all down at audit start; logs prove a ~12.5 min run earlier on 2026-07-25; Ollama running with zero models | `services-before.txt`, `service-probes-before.txt` |
| Model hashes | `sha256sum ~/models/*` | Qwen `74a4da8c…a9db`, BGE `f046db1d…4804`, whisper-tiny.en `c77c5766…7c2b` — all match Hermes' manifest claims | `model-hashes-before.txt` |
| Preservation | branch + patch + tar | `backup/hermes-before-fable-20260725-091005`; `hermes-working-tree.patch`; `hermes-untracked-files.tar.gz` | `.handoff/fable5/` |

## Upstream refresh

`GET api.github.com` 2026-07-25T09:27Z: `main@611b07e` (default, unchanged),
`docs/eeg-methods-scope@23c56ea` (unchanged), PR #32 newly open (draft,
readiness/R18) — `upstream-refresh.txt`.

## After Fable repairs

| Check | Command | Result | Evidence file |
|---|---|---|---|
| Tests | `./node_modules/.bin/jest --ci --runInBand` | 9 suites, 70/70 pass (48 Hermes + 22 Fable), 5.7 s | `test-after.txt`, `test-final.txt` |
| Typecheck | `./node_modules/.bin/tsc --noEmit` | clean, exit 0 | `typecheck-after.txt`, `typecheck-final.txt` |
| Live P1 slice | `NEURALCOMPOSE_LIVE=1 ./node_modules/.bin/jest livePipeline` | 2/2 pass against REAL services | `live-slice-evidence.txt` |

### Live P1 slice detail (real Qwen:8081 + real BGE:8082, single execution path)

- Fail-closed readiness passed: prompts non-empty
  (`android-live-dialectic/v1#<hash>`), positive Qwen model probe, live
  embedding mode.
- One full turn through `runLiveTurn` (same path the UI uses):
  coherence 2698 ms, displacement 953 ms, embeddings 294 ms (384-dim BGE),
  gate 28 ms, turn total 3974 ms; outcome `spoke`; tension 0.205; margin 0.246;
  prosody probability-blended between role presets
  (rate 1.0288, pitch 1.0216, volume 0.9, preDelay 82 ms);
  event sequence `TRANSCRIBED → COHERENCE_GENERATED → DISPLACEMENT_GENERATED →
  EMBEDDED → GATED → SPEAKING_DONE`, every event replayed through the real
  reducer, end state `cooldown`.
- TTS was a recorded no-op in node; audible speech remains device-only evidence.
- Discovered and fixed during this run: this llama-server build returns
  `{models:[…]}` from `/v1/models` (not OpenAI `{data:[…]}`); the positive
  probe now accepts both shapes.

### New unit tests (all deterministic, fake services)

- `turnPipeline.test.ts` (8): legal event ordering replayed through the real
  reducer; coherence failure → error with nothing spoken; **live embedding
  failure fails closed with no mock fallback and no speech**; dimension
  inconsistency rejected; **MOCK gates disable synthesis** even with a seeded
  perfect bridge; stale epoch stops silently; TTS error settles as
  SPEAKING_FAILED; silence-cap cue via `cueing` state.
- `sessionReducerAdditions.test.ts` (7): INJECT_TEXT legal only from ready;
  cueing is TTS-active/never mic-active; idempotent STOP_SESSION.
- `engineSynthesisGate.test.ts` (2): allowSynthesis default fires; false never.
- `promptProfile.test.ts` (5): stable content-sensitive hash; non-empty
  resources; readiness detail carries profile identity.

## Privacy/network audit

- `grep -rn 'https?://|ws://' src/` → only the pre-existing M4 viewer endpoints
  in `src/config.ts` (Tailscale placeholder); everything else 127.0.0.1.
- No `console.*` in dialectic/session/services/hook/screen runtime code.
- Benchmarks/timing records contain no transcript/candidate text.
- `.handoff/` and `.neuralcompose-runtime/` gitignored; no weights/secrets/
  audio committed.

## Not verified (honest gaps)

- No live mic → whisper → turn on this pass (needs physical push-to-talk).
- No audible prosody check (needs human ears on the Pixel).
- Whisper client exercised only via `/health` (its `/inference` FormData shape
  is RN-specific and cannot be driven from node).
- Ten-turn soak not run; benchmark still generation-stage-only.

## A2 delta session (2026-07-25, later same day)

Commands run with direct binaries after the device reboot:

- `node ./node_modules/jest/bin/jest.js --runInBand --no-coverage --watchman=false`
  → 11 suites passed, 2 skipped (live-gated); 95 tests passed, 3 skipped.
- `./node_modules/.bin/tsc --noEmit` → clean.
- `NEURALCOMPOSE_LIVE=1 … jest a2Evidence livePipeline` against real services
  → 2 suites / 3 tests passed; wrote `.handoff/fable5/a2-evidence.json`.

Live A2 evidence highlights (full record in `.handoff/fable5/a2-evidence.json`):

- coherence + displacement both resolved `exact` on llama-server:8081;
  locality `localhost_local_inference`; provenance `baseline`; readiness `ready`.
- Distinct per-role prompt SHA-256 (`5c67b975…` vs `4aae4d03…`),
  profile `android-live-dialectic/v1`.
- Witness: null — zero resolution/probe/prompt work.
- One real turn: total 3807 ms (coherence 2738, displacement 948, embed 108,
  gate 9); outcome `spoke` under live BGE gates.
- Missing-model proof: probing a deliberately unserved model returns
  `ready:false` with the server responding — the model, not the port, gates.
- New regression caught during this pass: readiness `reasons` leaked the
  served model's absolute path; now routed through `sanitizePublicMessage`
  (test: `readinessIdentity.test.ts` "missing exact model…").

Device note: after the mid-session reboot, Android's phantom-process cap
killed jest crawler workers (exit 144). Fixed by `roots: ['<rootDir>/src']`,
`maxWorkers: 1`, and transpile-only ts-jest in `jest.config.js`; typecheck is
owned by `tsc --noEmit`.
