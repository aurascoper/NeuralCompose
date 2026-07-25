# NeuralCompose Android Dialectic MVP

## Architecture

The live dialectic session is a React Native screen (DialecticSessionScreen) that
orchestrates a multi-stage pipeline on the Pixel 8a:

```
microphone recording (expo-audio)
  -> local speech-to-text (STT service, when available)
  -> two local Qwen2.5-0.5B candidate generations (llama-server, 127.0.0.1:8081)
  -> deterministic semantic dialectical gates (TypeScript)
  -> one of: spoken candidate / legitimate silence / rare recalled synthesis
  -> Android text-to-speech (expo-speech) with competition-weighted prosody
  -> cooldown
  -> microphone may re-arm only after speech has completed
```

### Pure Dialectic Kernel (`src/dialectic/`)

The dialectical engine is pure TypeScript. No React, HTTP, storage, timers, or
randomness globals. Every function is deterministic and fully testable with fixed
embeddings and fixed random draws.

Files:
- `types.ts` — value types (Embedding, Energy, Weights, Candidate, Outcome, etc.)
- `dynamics.ts` — pure math: energy, tension, tau, softmax, compete, synthesisScore, centroid
- `profiles.ts` — focused/reflective/contemplative profile presets
- `semanticGraph.ts` — bounded graph of heard/reply nodes with edge threshold
- `memory.ts` — temporal rings + graph, synthesis candidate search
- `field.ts` — slow semantic clock (weight field with inertia)
- `spectralGloss.ts` — fast biological clock (EMA-smoothed gloss)
- `prosody.ts` — prosody presets + probability-weighted blend
- `prompts.ts` — runtime Qwen prompts (coherence 0.45 temp, displacement 1.0 temp)
- `engine.ts` — orchestrates one turn through the kernel
- `sessionReducer.ts` — authoritative session state machine

### Service Adapters (`src/services/`)

- `GenerationClient.ts` — Qwen chat-completions client (two temperatures)
- `EmbeddingClient.ts` — sentence embedding client + mock embedder
- `TranscriptionClient.ts` — STT seam (whisper.cpp when available)
- `SpeechOutput.ts` — expo-speech adapter with cancellation
- `ServiceHealth.ts` — health probes for all services
- `modelManifest.ts` — runtime model provenance

### Session Hook (`src/hooks/`)

- `useDialecticSession.ts` — ties the state machine, services, and engine together
  with epoch cancellation. Every async result checks that it still belongs to the
  active epoch.

### UI (`src/screens/`)

- `DialecticSessionScreen.tsx` — dedicated live session route
  - session on/off, push-to-talk, text injection
  - phase indicator with honest wording
  - transcript, spoken output, outcome badge
  - tension and margin indicators
  - profile selector (Focused/Reflective/Contemplative)
  - service chips (STT, Qwen, Embeddings, TTS)
  - model provenance badge (BASELINE/ADAPTER/MERGED/UNVERIFIED)
  - timing display
  - developer drawer (candidates, potentials, RNG draw)
  - privacy note

### Termux Orchestration (`scripts/termux/`)

- `start-neuralcompose-services.sh` — starts llama-server with PID/log management
- `stop-neuralcompose-services.sh` — cleanly stops owned processes
- `healthcheck-neuralcompose-services.sh` — checks all service health

### Tests (`src/dialectic/__tests__/`)

48 tests across 5 suites:
- `dynamics.test.ts` — energy, tension, tau, softmax, compete, synthesis (12 tests)
- `memory.test.ts` — graph, entropy/drift, synthesis gate (7 tests)
- `field.test.ts` — gloss EMA, weight field inertia (8 tests)
- `prosody.test.ts` — blend endpoints, interpolation, probability-weighting (4 tests)
- `sessionReducer.test.ts` — state transitions, mic/TTS non-overlap (18 tests)

### Privacy

All runtime processing is local. No audio, text, embeddings, or session logs are
sent to GLM-5.2:cloud or any cloud service. The EEG wind is labeled "neutral /
unavailable" — the app never claims Muse/EEG cognitive decoding.

## Model Provenance

- Base model: Qwen2.5-0.5B-Instruct Q4_K_M
- SHA256: 74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
- Status: BASELINE (no fine-tune artifact)
- llama.cpp build: 1 (0a50d99), Clang 21.1.8, Android aarch64

## Pixel Latency (measured)

30 scripted text-bypass turns, 5 warmups excluded:

| Stage | p50 | p95 | max |
|---|---|---|---|
| Coherence generate | 1111ms | 1938ms | 2228ms |
| Displacement generate | 897ms | 1301ms | 1551ms |
| Total per turn | 2000ms | 3066ms | 3210ms |

Failure rate: 0/30 (0%)

## Local Services (all running on Pixel 8a)

| Port | Service | Status | Model |
|---|---|---|---|
| 127.0.0.1:8081 | Qwen chat-completions | OK | Qwen2.5-0.5B-Instruct Q4_K_M |
| 127.0.0.1:8082 | BGE sentence embeddings | OK | bge-small-en-v1.5 Q8_0 (384-dim, mean pooling) |
| 127.0.0.1:8083 | Whisper STT | OK | whisper-tiny.en q5_1 |

All three services are real local processes on the Pixel. No cloud calls.

### Embedding Server

- Model: bge-small-en-v1.5 Q8_0 (same family as the Swift reference)
- SHA256: f046db1dc724cf4f6f0a0c5917e922823b73eb1d27b8f9a9c2797f7866974804
- Dimension: 384
- Pooling: mean
- llama-server `--embedding --pooling mean` on port 8082
- L2-normalized output (verified: norm = 1.000000)
- Gates: LIVE (no longer MOCK)

### STT Server

- Model: whisper-tiny.en-q5_1 (31MB)
- whisper.cpp 0.16.0, built from source with Clang 21.1.8
- Server: `whisper-server` on port 8083
- API: POST /inference with multipart form data (file, temperature, response_format)
- Health: GET /health returns {"status":"ok"}