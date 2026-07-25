# Post-Fable Handoff — remaining tasks

The architecture is adjudicated (see ADR). Do not redesign it. Work READY tasks
in order; BLOCKED tasks stay blocked until their named clearing condition.

Run checks with the direct binaries (`./node_modules/.bin/jest`,
`./node_modules/.bin/tsc --noEmit`) — `npx`/`npm` startup can stall for many
minutes on this device.

Invariants that every task must preserve:
- turn execution goes through `src/session/turnPipeline.ts` only;
- readiness fails closed (`src/session/readiness.ts`); no provider substitution;
- embedding failure mid-turn = error, never mock, never speech;
- MOCK gates are labeled and disable synthesis;
- mic active only in `listening`; TTS active only in `speaking`/`cueing`;
- every async continuation checks the session epoch;
- no runtime text/audio/embeddings to any cloud endpoint;
- BASELINE provenance label until an artifact hash proves otherwise.

## READY

### R1 — Delete temp push-to-talk audio after transcription
- Files: `src/screens/DialecticSessionScreen.tsx`, `package.json`.
- Do: `npx expo install expo-file-system` (network was available at handoff);
  after `processRecording` resolves (success or failure), delete `recorder.uri`
  unless a user opt-in to retain audio exists (none does today).
- Check: unit-level is impractical; verify on device that the cache file is
  gone after a turn; grep that no other code retains the URI.

### R2 — Wire session-summary opt-in persistence
- Files: `src/storage/dialecticSessionStore.ts` (exists, unwired),
  `DialecticSessionScreen.tsx`, `useDialecticSession.ts`.
- Do: add an explicit "Save session summary" switch (default OFF) and a
  separate "Include text" switch (default OFF); on stopSession, persist via
  `saveSessionSummary` with provenance labels (model hash, embedder id, STT
  backend, TTS voice, prompt profile `PROMPT_PROFILE`).
- Check: jest test for the summary shape; manual: toggle off → nothing stored.

### R3 — In-app prosody calibration panel
- Files: `DialecticSessionScreen.tsx`, `src/services/SpeechOutput.ts`
  (`getVoices` exists).
- Do: a small panel that speaks one neutral sentence with the coherence preset,
  then the displacement preset, and records/displays the selected Android voice
  identifier.
- Check: renders; both presets audibly played in sequence on device (human).

### R4 — App-path benchmark through the single execution path
- Files: new `scripts/benchmark-live-turns.ts` (drive `runLiveTurn` exactly as
  `livePipeline.integration.test.ts` does), `docs/pixel-benchmark-results.json`.
- Do: 5 warm-ups + 30 scripted turns with varied short inputs; record every
  `TurnTiming` stage; include embedding and gate stages this time; compute
  p50/p95/max; then set per-stage timeouts in a config from warm p95 + explicit
  headroom (replacing the flat 30 s/20 s defaults in the clients).
- Check: JSON committed; timeouts referenced from code, not literals.

### R5 — Reflective/contemplative profile pass through the live slice
- Files: `livePipeline.integration.test.ts` or the R4 benchmark.
- Do: run turns under each profile; confirm silence appears under
  contemplative tuning on near-tie inputs and is labeled `Tension held`.
- Check: recorded outcomes include at least one legitimate `silent`.

### R6 — Fix expo-doctor jest version mismatch
- Files: `package.json`.
- Do: either pin jest 29.7 / @types/jest 29.5 (expo SDK 57 expectation) or add
  `expo.install.exclude`. Re-run `expo-doctor`; re-run full jest suite after.

## BLOCKED (with clearing conditions)

### B1 — Microphone-to-speaker acceptance (ten consecutive live turns)
- Blocked on: physical human interaction with the Pixel.
- Clearing: run the app (`npx expo start --android` or a dev build), speak ten
  turns in a quiet room; verify no stale speech, no frozen control, no mic/TTS
  overlap, Stop works during every stage. Text injection does NOT clear this.

### B2 — Audible prosody distinction
- Blocked on: human ears on device (after R3).
- Clearing: the same neutral sentence under both presets is audibly
  distinguishable without being theatrical; note the voice identifier used.

### B3 — Whisper end-to-end from the app
- Blocked on: B1 (needs a real spoken clip; the RN FormData file shape cannot
  be driven from node).
- Clearing: one recorded utterance returns a non-empty transcript through
  `processRecording` and the turn completes.

### B4 — Fine-tuned artifact integration
- Blocked on: existence of a verified LoRA adapter or merged GGUF (none found
  on device; hash search evidence in `.handoff/fable5/model-artifacts-before.txt`).
- Clearing: artifact + SHA-256 + `training/README.md` manifest requirements
  met; adapter-on/off eval on `training/eval_cases.jsonl`; only then may the
  badge change from BASELINE.

### B5 — Installed/packaged-build verification (upstream PR #29 lesson)
- Blocked on: building an APK/dev-client (Metro-only so far).
- Clearing: the packaged app passes readiness and one live turn; prompt
  resources load in the packaged bundle.

## Acceptance pointer

When B1–B3 clear and R1–R4 land, run the Fable return acceptance
(`docs/fable5/final-acceptance.md` will be produced by the reviewer — see the
handoff packet §6).

## A2 delta addendum (2026-07-25, Apple PR #32 parity) — DONE except device UI pass

Implemented and verified this session (see `docs/fable5/a2-delta.md`):
requested-vs-resolved `RuntimeIdentity` on success and failure paths
(`src/runtime/identity.ts`, wired in `src/session/readiness.ts` and the hook's
generate call site), locality classification with conservative loopback rule,
alias ≠ exact model match (alias → UNVERIFIED, not READY), per-role SHA-256
prompt manifests, role-consistency guard, derived UI presentation and derived
privacy wording (no hard-coded locality claims), Witness flag honesty
(`witnessEnabled: false` everywhere until a real Witness runtime exists),
sanitized public errors. Live evidence: `.handoff/fable5/a2-evidence.json`.

New READY task:
### R7 — Confirm derived identity UI on device
- The SERVICES card and dev drawer now render identity-derived egress/
  locality/readiness and requested-vs-resolved fields; render them once on the
  Pixel (Metro is fine) and confirm the failure wording by stopping the Qwen
  server before Start Session (expect NOT READY + EGRESS UNVERIFIED, no crash).

B1–B5 unchanged.
