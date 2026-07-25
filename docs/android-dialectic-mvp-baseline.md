# NeuralCompose Android Dialectic MVP — Baseline

Date: 2026-07-25
Agent: GLM-5.2:cloud (development agent)
Device: Pixel 8a, Android 16, Termux

## Repository

- Path: `~/neuralcompose-client`
- Branch: `feat/dialect-synthesis` (4 commits)
- Remote: `neuralcompose/feat/dialect-synthesis [gone]` (no remote currently)
- Stack: Expo SDK 57, React Native 0.86, React 19.2.3, TypeScript 6.0.3

## Current App Structure

Five tab screens: Overview, EEG, Health, Classifier, Journal.
Navigation: bottom-tab navigator in App.tsx.
Theme: dark palette (`src/theme.ts`), consistent tokens.

### Existing Files

```
App.tsx                         — tab navigator
src/config.ts                   — USE_MOCK=true, SERVER_URL (M4 Tailscale placeholder), LLM_URL=127.0.0.1:8081
src/api/ApiClient.ts            — interface
src/api/LiveApiClient.ts        — real HTTP/WS client
src/api/MockApiClient.ts        — mock
src/api/LLMClient.ts            — synthesizeDream() fire-and-forget for journal
src/prompts/dialect.ts          — philosopher-of-science-adversarial prompt
src/hooks/                      — useClassifier, useDiagnostics, useEEGStream, useHealth, useNow, usePipelineMode
src/screens/                    — Overview, EEG, Health, Classifier, DreamJournal
src/storage/DreamJournal.ts     — AsyncStorage CRUD
src/types/api.ts
src/components/                 — ChannelBadge, ConfidenceBar, EEGTrace, PrivacyBadge, StaleIndicator
src/mock/fixtures.ts
```

### Journal (must not be disrupted)

DreamJournalScreen uses `expo-audio` for recording, AsyncStorage for persistence,
`synthesizeDream()` from LLMClient for fire-and-forget dialect synthesis.
Entry shape: `{ id, createdAt, text, audioUri?, audioDurationMs?, synthesized?, synthesisStatus? }`.

## Model Artifacts

| Artifact | Path | SHA256 | Status |
|---|---|---|---|
| Qwen2.5-0.5B-Instruct Q4_K_M | `~/models/qwen2.5-0.5b-instruct-q4_k_m.gguf` | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` | **BASELINE** (no adapter) |
| LoRA adapter | — | — | NOT FOUND |
| Merged weights | — | — | NOT FOUND |
| Embedding model (BGE/other) | — | — | NOT FOUND |
| Whisper model | — | — | NOT FOUND |

## Local Services

### llama.cpp

- Build: `~/llama.cpp/build/bin/llama-server` (version 1, 0a50d99, Clang 21.1.8, Android aarch64)
- `llama-embedding` binary also available
- **Not currently running**. Must be started for the MVP.
- Existing config in memory: `-c 512 -t 2` on `127.0.0.1:8081`
- No embedding model GGUF installed (only vocab test files in `~/llama.cpp/models/`)
- No whisper.cpp build or model installed

### Port Plan

| Port | Service | Status |
|---|---|---|
| 127.0.0.1:8081 | Qwen chat-completions (existing) | Must start |
| 127.0.0.1:8082 | Sentence embedding server | **BLOCKED** — no embedding model |
| 127.0.0.1:8083 | STT (whisper.cpp) | **BLOCKED** — no whisper build/model |

## Swift Reference

- Path: `~/NeuralCompose` (cloned, not modified)
- Key dialectic files read:
  - `DialecticalDynamics.swift` — pure math: energy, tension, tau, softmax, compete, synthesisScore, centroid
  - `DialecticalCompetition.swift` — value types: Weights, Energy, Candidate, ScoredCandidate, Outcome, Competition
  - `DialecticalRole.swift` — coherence-seeking (temp 0.45) + displacement-seeking (temp 1.0), waking variants
  - `DialecticalMemory.swift` — SemanticGraph wrapper, history/reply rings, synthesis candidate search
  - `SemanticGraph.swift` — bounded graph with edge threshold, nearest-prior lookup
  - `DialecticalField.swift` — slow semantic clock, inertia, target policy
  - `SpectralGloss.swift` — fast EMA gloss from SpectralState
  - `ContextProfile.swift` — focused/reflective/contemplative profiles with tuning presets
  - `SpeechSynthesizing.swift` — prosody types, blend function
  - `HypnagogicDialecticLoop.swift` — full loop orchestration
  - `Embedding.swift` — L2-normalized vector with modelID/dimension/version/seed

## Divergences from Prompt Assumptions

1. **No embedding model**: The prompt assumes a local sentence-embedding service. No BGE or other embedding GGUF is installed. The `llama-embedding` binary exists but needs a model. For the MVP, we will:
   - Implement the embedding client seam with a real HTTP interface
   - Provide a deterministic mock embedder for testing
   - Download a small BGE model if possible, or proceed with mock embedder clearly labeled `Gates: MOCK`

2. **No whisper.cpp**: No STT service is available. We will:
   - Implement the TranscriptionClient seam
   - For MVP testing, use text injection (manual transcription)
   - Clearly label the STT chip as UNAVAILABLE

3. **expo-speech**: Not currently in package.json. Must be added for TTS.

4. **No test framework configured**: package.json has only start/android/ios/web scripts. Must add jest + ts-jest.

5. **Existing LLMClient**: Used by Journal. Must not be replaced — extend or wrap behind a new generation interface.

## Pre-existing Failures

- No tests, no lint, no TypeScript check has been run yet. Baseline tsc result will be recorded.
- `expo-doctor` will be run.

## Privacy

- No runtime audio/text will be sent to GLM-5.2:cloud or any cloud service.
- All local services on 127.0.0.1.
- Existing USE_MOCK=true means the app currently runs on mock fixtures.