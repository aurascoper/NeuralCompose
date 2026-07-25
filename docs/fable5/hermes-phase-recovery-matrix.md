# Hermes Phase Recovery Matrix

Audited by Fable 5, 2026-07-25. Hermes base: `feat/dialect-synthesis@b68cbf1`,
all Hermes work uncommitted in the working tree (preserved in
`.handoff/fable5/hermes-working-tree.patch` + `hermes-untracked-files.tar.gz`
+ branch `backup/hermes-before-fable-20260725-091005`).

Statuses: VERIFIED / PRESENT_UNVERIFIED / PARTIAL / STUB / ABSENT / BLOCKED / REGRESSION.

## Phase 0 — repository/model/service census — **VERIFIED**

- `docs/android-dialectic-mvp-baseline.md` exists and is accurate where checkable.
- Model hashes independently re-measured and they match Hermes' claims:
  - Qwen2.5-0.5B q4_k_m `74a4da8c…a9db`, BGE q8_0 `f046db1d…4804`,
    whisper tiny.en q5_1 `c77c5766…7c2b` (`.handoff/fable5/model-hashes-before.txt`).
- No LoRA/merged artifact found anywhere on device → BASELINE is truthful.
- Service logs prove llama-server:8081, embedding:8082, whisper:8083 ran
  locally on 2026-07-25 (~12.5 min session) then exited; **not running at audit
  time**, PID files stale. Ollama runs but has zero models (irrelevant to this
  runtime; the client uses llama-server, not Ollama).

## Phase 1 — pure TS dialectic kernel + deterministic tests — **VERIFIED**

- `dynamics.ts` matches every required equation exactly (n(cos), energy with
  neutral 0.5 centroids, potential, mean-pairwise tension, tau =
  max(0.12, 0.5−0.35·tension), stable softmax, injected draw, min-similarity
  synthesis score). Tension is not added to potential. Precedence: synthesis →
  stalemate silence → sampled basin.
- Kernel files import no React/HTTP/storage/timers/global RNG (checked).
- 48/48 tests pass (`.handoff/fable5/test-before.txt`); `tsc --noEmit` clean;
  required invariant tests present (bifurcation, stalemate, synthesis
  precedence, recently-voiced rejection, mic/TTS reducer non-overlap).
- Minor: `memory.ts` duplicates `tension()` privately (cosmetic).

## Phase 2 — Qwen/embeddings/STT/TTS/provenance adapters — **PARTIAL**

- GenerationClient: two roles, two temperatures, post-processing, timeout,
  abort — present. Defects: pre-aborted `signal` not honored (listener added
  after the fact); health check is liveness (`/v1/models` ok) not a positive
  model probe.
- EmbeddingClient: batch, defensive L2, finite check — present. Defect:
  no cross-vector dimension-consistency check ('dimension mismatch' label
  actually checks count); mock embedder correctly labeled mock.
- TranscriptionClient: real whisper.cpp `/inference` client — present, and the
  service exists, but **nothing calls it** (see Phase 4).
- SpeechOutput: completion/cancel lifecycle present. Defects: `volume` from the
  prosody blend is dropped; error conflated with cancel.
- modelManifest: truthful BASELINE with real hash. No prompt profile/hash in
  provenance (upstream PR #29 invariant unmet).

## Phase 3 — authoritative cancellable session state machine — **PARTIAL** (P0 defects)

- Reducer itself is sound and tested; mic active only in `listening`, TTS only
  in `speaking`.
- **P0**: hook dispatches `TRANSCRIBED` from `ready` (text injection) — an
  illegal transition that throws inside a React state updater: the live app's
  only working input path crashes. The reducer has no injection path; Hermes'
  own benchmark bypassed the app (Python scripts in `~/.neuralcompose-runtime/`),
  so this was never exercised.
- **P0**: mid-turn embedding failure silently falls back to MOCK and still
  speaks a "semantic" selection (hidden fallback; forbidden).
- **P0**: no fail-closed readiness — session enters READY without probing Qwen
  model, embedding service, or prompt non-emptiness.
- **P0**: synthesis is not disabled under MOCK gates.
- **P0**: no unmount/background cleanup effect; `stopSession` throws if already
  stopped (non-idempotent).
- P1: cooldown never waits (`COOLDOWN_DONE` fired immediately; profile
  `interTurnCooldownMs` unused); `EMBEDDED` dispatched before embedding runs;
  silence cap static cue absent; `now()` is `Date.now()` labeled monotonic.

## Phase 4 — dedicated live-dialogue screen — **PARTIAL**

- Screen exists on its own tab; phase wording, outcome badge, tension/margin,
  service chips, provenance badge, `Gates: MOCK/LIVE`, dev drawer, privacy
  note, Reflective "Witness off" label — all present and honest.
- **Gap**: push-to-talk records audio but never calls STT (hardcoded "No local
  STT service available" alert) even though whisper:8083 exists and its client
  is implemented. `STOP_LISTENING` is never dispatched → state machine stuck in
  `listening`. Temp audio never deleted.
- Push-to-talk is disabled while TTS is active (good).

## Phase 5 — Termux service orchestration — **VERIFIED**

- start/stop/health scripts: absolute paths, PID/log files under gitignored
  runtime dir, duplicate-start rejection, health waits, hash printing, owned-
  process-only stop. Log evidence shows they worked. Embedding server uses
  `--embedding --pooling mean` as documented.

## Phase 6 — real Pixel validation and prosody calibration — **ABSENT / BLOCKED**

- No calibration panel; no evidence of audible A/B on the Pixel; no live
  mic→speaker turn evidence. Physical validation requires a human with the
  device. Blocked additionally on Phase 3/4 fixes (the app path crashes).

## Phase 7 — Pixel latency benchmark and timeout policy — **PARTIAL**

- `docs/pixel-benchmark-results.json`: real 30-turn generation benchmark
  (p50 2000ms, p95 3066ms, max 3210ms per turn; 0/30 failures) — but produced
  by Python harness (`full-e2e-test.py`), covers only the two generation
  stages, all outcomes "spoke", and does not use the app's execution path.
  No stt/embedding/gate/tts stages; timeout policy not derived from evidence
  (clients still use flat 30s/20s defaults).

## Phase 8 — fine-tune artifact verification — **VERIFIED (as BLOCKED-on-artifact)**

- Truthful `BASELINE — no fine-tune artifact found`; reproducible `training/`
  handoff with eval cases and non-negotiable gate boundaries. The artifact
  itself remains the single blocker; correctly not claimed.

## Phase 9 — final acceptance audit — **ABSENT**

- No ten-turn live soak, no acceptance checklist run. Blocked on Phases 3/4
  fixes and physical device interaction.

## Exact next actions (executed by Fable this session where unblocked)

1. Add a legal text-injection path to the reducer; fix event ordering. (P0)
2. Remove mid-turn mock fallback; embedding failure → error, no speech. (P0)
3. Fail-closed readiness gate before READY (Qwen positive model probe +
   embedding probe + prompt non-empty + STT probe for mic path). (P0)
4. Disable synthesis under MOCK gates. (P0)
5. Idempotent stop + unmount cleanup. (P0)
6. Real cooldown wait; correct EMBEDDED ordering; silence-cap static cue. (P1)
7. Wire mic → whisper STT → shared turn path; delete temp audio. (P2, code-ready)
8. Prompt profile + hash in turn provenance. (P1)
9. Prosody volume passthrough; pre-aborted signal handling; embedding dimension
   consistency. (P0/P1)
