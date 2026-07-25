# ADR: Android Live Dialectic Runtime

Status: **RATIFIED** (Fable 5, 2026-07-25)
Decision: The Pixel owns a complete local live-dialectic MVP. The Journal remains behaviorally unchanged.

## Context

### Historical thin-client boundary

The Android client was built as a thin React Native/Expo viewer for the M4 Swift
pipeline (Overview/EEG/Health/Classifier tabs over HTTP/WS, `USE_MOCK=true` by
default) plus a durable local Dream Journal. The Journal's only model use is
`LLMClient.synthesizeDream()` — a single fire-and-forget local rewrite. Nothing
in the original client was designed as a continuous voice runtime.

### Current target

The product request adds a full Pixel-local live dialectic loop:

    mic → local STT → two local Qwen2.5-0.5B generations (coherence 0.45 / displacement 1.0)
      → real local sentence embeddings → deterministic TS dialectical gates
      → spoken candidate / legitimate silence / rare recalled synthesis
      → Android TTS with probability-blended prosody → cooldown → re-arm

## Decision

The **Android Live Dialectic Runtime** is a new bounded context added *beside*
the Journal and viewer, not a transformation of them. Ratified on evidence: all
required local artifacts and services exist on this Pixel 8a (Qwen2.5-0.5B GGUF,
bge-small-en-v1.5 GGUF, whisper-tiny.en, llama.cpp + whisper.cpp builds; service
logs show all three servers ran locally on 8081/8082/8083). No hard blocker
justifies deviation.

### Module boundaries and dependency direction

    src/dialectic/*        pure TS kernel (math, memory, field, prosody, prompts,
                           reducer, engine) — depends on nothing outside itself
    src/services/*         adapters (Qwen HTTP, embeddings HTTP, whisper HTTP,
                           expo-speech, health, manifest) — depend on config + kernel types
    src/hooks/useDialecticSession.ts   orchestration — depends on kernel + services
    src/screens/DialecticSessionScreen.tsx  UI — depends on hook + theme

Dependencies point inward: UI → hook → (kernel | services). The kernel imports
no React, HTTP, storage, timer, native-module, or global-random dependency.
The Journal path (`DreamJournalScreen`, `LLMClient`, `DreamJournal` storage) is
untouched; the live runtime shares only the read-only theme tokens and the
llama-server port with it.

### Shared behavior with Swift

The kernel ports the *contracts and math* of `main@611b07e`
(`DialecticalDynamics/Competition/Memory/SemanticGraph/Field/SpectralGloss/
ContextProfile`), not Swift UI or AVSpeech values. The runtime principles
(fail-closed readiness, prompt identity as provenance, no provider
substitution, one execution path) follow the staging contracts at
`docs/eeg-methods-scope@23c56ea` (PRs #29/#31) as principles, not as code.

### Android-specific adapters

- `expo-audio` push-to-talk recording; `expo-speech` TTS (rate 1.0 = normal, so
  prosody presets are Android-calibrated, not copied AVSpeech rates).
- llama-server OpenAI-compatible endpoints on 127.0.0.1:8081 (Qwen) and
  :8082 (BGE, `--embedding --pooling mean`); whisper.cpp server on :8083.
- Termux start/stop/health scripts own service lifecycle (PID/log files under
  gitignored `~/.neuralcompose-runtime/`).

### Fallback behavior (all fail closed, all labeled)

- Qwen service/model not positively probed → session cannot enter READY.
- Embedding service down at session start → `Gates: MOCK`, semantic synthesis
  disabled, UI never claims a live semantic decision.
- Embedding failure mid-turn → the turn errors; no semantic selection is spoken.
  (Hermes' silent mid-turn mock fallback is removed as a P0 defect.)
- One role generation fails → degraded turn, not a dialectical decision.
- STT down → push-to-talk disabled for processing; text injection remains,
  labeled as STT bypass; never counted as microphone acceptance.
- No implicit provider substitution anywhere; cloud runtimes are never dialogue
  providers.

### Runtime/cloud privacy boundary

Runtime audio, transcripts, candidates, embeddings, and session records stay on
device (127.0.0.1 services only). Cloud agents (Fable/Hermes/GLM) assist
development only. The M4 viewer path (`SERVER_URL`/Tailscale) is a separate,
pre-existing, user-visible boundary and is unchanged. Live sessions are
ephemeral by default; summary persistence is opt-in and text persistence is a
separate opt-in.

### Non-goals

- No EEG encoder port, no cognitive-decoding claims; EEG wind stays
  `neutral / unavailable` (PR #30/#21 boundaries).
- No Witness third-generation call for Reflective (labeled "Witness off").
- No fine-tuning on the Pixel; BASELINE label until a hashed artifact exists.
- No always-on listening; no auto re-arm before strict alternation is proven.
- No Journal schema/prompt changes.

## Three control surfaces (invariant)

1. Qwen (fine-tunable) owns verbal register/role adherence/brevity only.
2. Pure TypeScript owns energies, tension, weights, memory, synthesis
   eligibility, silence, probabilities, outcome.
3. Android TTS adapter owns acoustic prosody and speech lifecycle.

Qwen is never asked for a winner, tension, synthesis decision, probabilities,
prosody, or hidden reasoning.
