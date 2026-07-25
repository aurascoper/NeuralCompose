# Architecture After Hermes (+ Fable 5 repairs)

State of `~/neuralcompose-client` on `feat/dialect-synthesis` (base `b68cbf1`)
after the Hermes implementation pass and the Fable 5 recovery pass, 2026-07-25.

## Module map (actual files)

    App.tsx                                  six-tab navigator (+ "Dialectic" tab, additive)
    src/config.ts                            USE_MOCK, SERVER_URL (M4 viewer), LLM_URL=127.0.0.1:8081

    src/dialectic/          PURE KERNEL — no React/HTTP/storage/timers/global RNG
      types.ts              value types (Embedding, Energy, Tuning, Manifest, Timing…)
      dynamics.ts           n(cos), energy, potential, tension, tau, softmax, sample,
                            synthesisScore, compete, centroid
      profiles.ts           focused / reflective / contemplative tuning as data
      semanticGraph.ts      bounded node/edge graph, nearest-prior lookup
      memory.ts             heard/reply rings, centroids, entropy/drift,
                            low-tension streak, synthesis candidate search
      field.ts              slow weight field (inertia + wind)
      spectralGloss.ts      EMA gloss; absent → neutral 0.5
      prosody.ts            Android-calibrated presets + probability blend
      prompts.ts            role prompts, post-processing, PROMPT_PROFILE
                            (id/version/FNV-1a hash), promptResourcesReady()
      engine.ts             runTurn(): score → clocks → synthesis (gated by
                            allowSynthesis) → compete → record; pure
      sessionReducer.ts     15-state machine incl. 'cueing'; INJECT_TEXT path;
                            idempotent stop; isMicActive/isTTSActive

    src/session/            ORCHESTRATION SEAM (Fable 5)
      turnPipeline.ts       runLiveTurn(): THE single execution path
                            (UI, tests, benchmarks). All I/O injected.
      readiness.ts          fail-closed READY gate: prompts + positive Qwen
                            model probe required; embedding/STT graded

    src/services/           ADAPTERS
      GenerationClient.ts   two-temperature Qwen calls; generationModelReady()
      EmbeddingClient.ts    batch embed, defensive L2, validateEmbeddingBatch();
                            mockEmbed clearly separate
      TranscriptionClient.ts whisper.cpp /inference client
      SpeechOutput.ts       expo-speech; rate/pitch/volume; cancel vs error
      ServiceHealth.ts      liveness chips
      modelManifest.ts      BASELINE manifest with real SHA-256

    src/hooks/useDialecticSession.ts  epoch cancellation, readiness gate,
                            cooldown timer, unmount cleanup; delegates the turn
                            to runLiveTurn
    src/screens/DialecticSessionScreen.tsx  dedicated tab; push-to-talk → STT;
                            text injection (labeled bypass); truthful badges
    src/storage/dialecticSessionStore.ts  opt-in summaries only (not yet wired)
    src/telemetry/turnTiming.ts  monotonic now(), percentiles

    scripts/termux/*.sh     start/stop/health for llama-server:8081 (Qwen),
                            llama-server:8082 (BGE --embedding --pooling mean),
                            whisper-server:8083

## Data flow (one live turn)

    [screen] push-to-talk → recorder.stop() → processRecording(uri)
      → STOP_LISTENING → transcribeAudio (whisper:8083)
      → runLiveTurn (src/session/turnPipeline.ts):
          TRANSCRIBED
          → generate coherence (Qwen:8081, T=0.45)      COHERENCE_GENERATED
          → generate displacement (Qwen:8081, T=1.0)    DISPLACEMENT_GENERATED
          → embedBatch [heard, coh, disp] (BGE:8082)    EMBEDDED
            (live failure → ERROR; never mock mid-turn)
          → runTurn (pure gate; allowSynthesis = gates live)  GATED
          → speak(blended prosody) | silence | cue      SPEAKING_DONE /
                                                        SILENCE_DONE / CUE_DONE
      → cooldown timer (profile interTurnCooldownMs) → COOLDOWN_DONE → ready

Text injection enters the same path via INJECT_TEXT → runLiveTurn.

## Dependency direction

    screen → hook → { session (pipeline, readiness) → services, kernel }
    kernel depends on nothing outside src/dialectic.
    services depend on config + kernel types only.
    Journal/viewer never import from dialectic/session; dialectic never imports
    Journal/LLMClient/storage.

## State machine and cancellation ownership

- One reducer; illegal transitions throw. Mic active only in `listening`; TTS
  active in `speaking`/`cueing`; no state has both.
- One `AbortController` per session + one integer epoch. The hook owns both.
  Every async continuation (pipeline dispatch, STT return, cooldown timer)
  checks the epoch; stale work cannot update state or speak.
- `stopSession` and unmount: bump epoch → abort → `Speech.stop()` →
  STOP_SESSION (legal from every state; idempotent from `stopped`).

## Service boundary and persistence boundary

- All runtime model traffic is 127.0.0.1 (8081/8082/8083). TTS is the Android
  system engine. The M4 viewer (`SERVER_URL`, Tailscale) is a separate,
  pre-existing boundary, untouched.
- Live sessions are ephemeral. `dialecticSessionStore` exists for opt-in
  summaries and is not yet wired to any UI (no accidental persistence).
  Journal storage schema unchanged.

## Runtime/cloud boundary

Cloud agents assist development only. No runtime audio/transcript/candidate/
embedding leaves the device; grep audit of `src/` shows the only non-localhost
URLs are the pre-existing M4 viewer endpoints in `config.ts`.

## Fine-tune / kernel / TTS split

- Qwen (BASELINE, hash `74a4da8c…a9db`) proposes role-shaped text only.
- The kernel owns every semantic decision; RNG is injected; MOCK gates disable
  synthesis and are labeled.
- SpeechOutput renders blended prosody; it never chooses outcomes.
