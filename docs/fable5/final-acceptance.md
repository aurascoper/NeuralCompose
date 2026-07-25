# Final Acceptance — NeuralCompose Android Live Dialectic MVP

Reviewer: Claude Fable 5 (return pass), 2026-07-25.
Reviewed state: working tree on `feat/dialect-synthesis` (base `b68cbf1`,
Hermes work + Fable 5 repairs, uncommitted; Hermes original preserved in
`backup/hermes-before-fable-20260725-091005` and `.handoff/fable5/`).
Upstream refreshed same day: `main@611b07e` (default),
`docs/eeg-methods-scope@23c56ea`, PR #32 open draft (readiness/R18).

Method: independent re-run of defining checks this session — 70/70 unit tests
(`test-final.txt`), `tsc --noEmit` clean (`typecheck-final.txt`), live
two-service integration slice (`live-slice-evidence.txt`), privacy grep audit,
hash re-measurement. A commandless claim was not counted as evidence.

## A. Product regression — PASS (code level)

- Journal screen/storage/prompt untouched (tracked diff is additive: new tab,
  expo-speech dep, jest tooling, gitignore entries only).
- Viewer/mock screens untouched; navigation additive.
- Caveat: the app was not launched this session; regression is established by
  diff inspection and the passing suite, not by device interaction.

## B. Semantic correctness — PASS

- Two distinct local Qwen calls with role prompts and temperatures 0.45/1.0
  (live evidence: separate latencies/token counts per role).
- Real BGE embeddings (384-dim, batch, defensively L2-normalized) drove the
  live gate; dimension consistency enforced.
- Kernel equations verified against the specification exactly; tension is
  never added to potential; tau floor 0.12; stable softmax; single injectable
  draw; missing centroids neutral at 0.5.
- Legitimate silence and synthesis eligibility (prior machine replies only,
  recently-voiced excluded, min-similarity bridge, sustained-convergence bar)
  covered by deterministic tests.
- The fine-tune surface cannot own the gate: generation returns text only, and
  provenance is BASELINE.

## C. Runtime/readiness — PASS with one BLOCKED sub-item

- Prompt resources versioned + FNV-1a hashed (`android-live-dialectic/v1`);
  empty prompt is a typed readiness failure (tested).
- Fail-closed READY: positive Qwen model probe (verified live, including the
  `{models:[…]}` server shape), embedding/STT graded and labeled; no provider
  substitution anywhere (tested: embedding failure mid-turn errors the turn).
- One execution path: UI hook and integration test both run
  `src/session/turnPipeline.ts`; the legacy Hermes benchmark JSON predates
  this path (replacement is READY task R4).
- BLOCKED: installed/packaged-build behavior not exercised (Metro-only so
  far) — upstream PR #29's core lesson still needs a packaged run (B5).

## D. Lifecycle safety — PASS (unit level), device soak BLOCKED

- Reducer forbids mic+TTS overlap in every state including the new `cueing`;
  illegal transitions throw; text injection now has a legal path (the previous
  hook crashed on its only input path — repaired and regression-tested).
- Epoch checks at every async stage; stale work cannot dispatch or speak
  (tested); stop/unmount idempotent; real cooldown wait added.
- BLOCKED: ten consecutive live device turns with cancellation probes (B1).

## E. Provenance truthfulness — PASS

- BASELINE supported by on-device SHA-256 re-measurement matching the
  manifest; no adapter/merged artifact exists; no false fine-tuned badge.
- Runtime records model, embedder id, STT backend, TTS engine, prompt
  profile/hash; MOCK gates labeled and synthesis-disabled.

## F. Prosody — math PASS, perception BLOCKED

- Probability-weighted blend proven by unit tests and observed live
  (blended rate 1.0288 / pitch 1.0216 between the two presets).
- TTS completion/stop/error lifecycle unit-tested; volume now passed through.
- BLOCKED: audible distinction on the Pixel requires human ears (B2, after
  calibration panel R3).

## G. Privacy/network — PASS

- Only non-localhost URLs are the pre-existing M4 viewer endpoints; runtime
  path is 127.0.0.1 exclusively; no console text logging; benchmark/timing
  records carry no text; live sessions ephemeral (persistence unwired, opt-in
  design specified in R2); no cognitive-decoding claims — EEG wind fixed
  `neutral / unavailable`.
- Temp push-to-talk audio deletion not yet implemented (R1) — noted as the
  one open privacy item; audio never leaves the device regardless.

## H. Pixel evidence — PARTIAL

- Service/model readiness: PASS (live positive probes this session).
- One complete live turn through the real pipeline: PASS (3974 ms total;
  coherence 2698 ms, displacement 953 ms, embed 294 ms, gate 28 ms).
- Ten consecutive live turns: BLOCKED (B1). p50/p95 through the app path and
  evidence-derived timeouts: NOT DONE (R4; Hermes' 30-turn generation-only
  benchmark exists but bypassed the app path).

## Verdict

Software invariants — semantic correctness, fail-closed readiness, lifecycle
safety at unit level, provenance truthfulness, privacy — are verified with
commands. What remains is physical and packaging evidence, not design work.

**MVP CONDITIONALLY ACCEPTED — exact missing physical/artifact evidence:**

1. Ten consecutive live mic→STT→gate→TTS turns on the Pixel with cancellation
   probes and no stale speech / mic-TTS overlap (B1, B3).
2. Audible prosody distinction of the two role presets on the device (B2,
   after R3 calibration panel).
3. Packaged/installed-build readiness + one live turn (B5).
4. App-path benchmark with evidence-derived per-stage timeouts (R4) and temp
   audio deletion (R1).
5. Fine-tune remains BASELINE by design; a verified hashed artifact (B4) is
   an improvement path, not an acceptance condition.
