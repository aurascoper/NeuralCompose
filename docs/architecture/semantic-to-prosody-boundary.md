# Semantic-to-Prosody Boundary

> Status: Draft (2026-07-22). This document scopes the
> separation between generated semantic content and vocal
> realization. It is a research and architecture boundary, not a
> request to add a new runtime path.

## Thesis

NeuralCompose should keep semantic generation separate from vocal
realization.

The avoided mental model is:

```text
LLM -> speech
```

The intended model is:

```text
semantic generation
  -> sentence embedding
  -> dialogue state
  -> prosody model
  -> speech synthesizer
```

The language runtime decides what text is said. A separate prosody
layer decides how that text is spoken.

## Goal

```text
/goal
Predict cadence and prosody from semantic state without coupling
voice realization to the generation runtime.
```

This fits the three concerns:

- Science asks which prosody parameters improve perceived
  continuity, grounding, and conversational fit.
- Engineering records speech/prosody telemetry reproducibly and
  preserves the semantic/prosody boundary.
- Computation provides deterministic implementations behind stable
  interfaces once a model is validated.

## Existing Seams

The codebase already has a useful partial boundary:

- `GenerationRuntime` / `TextGenerating` produce text and metadata.
- `SentenceEmbedder` turns text into vectors.
- `SpeechProsody` carries rate, pitch, volume, and pre-utterance
  delay without importing AVFoundation into `BCICore`.
- `SpeechSynthesizing.speak(_:prosody:)` lets the speech backend
  realize text with prosody controls.
- `ProsodyWobble` is a provisional heuristic planner, not the final
  cadence model.
- `DialecticalRole.voiceProsody` and `SpeechProsody.blend` already
  make dialectical tension audible without changing the generated
  words.

These seams mean cadence prediction can be researched without
rewriting generation or speech synthesis.

## Future Prosody Vector

A future telemetry schema can record measured or requested prosody
features such as:

```text
speech_rate
pause_before
pause_after
mean_pitch
pitch_variance
energy
duration
syllables_per_second
emphasis
hesitation
cadence_class
```

The first research target should be cadence prediction, not voice
cloning. Voice identity belongs to the speech backend; cadence is the
learnable mapping from semantic/dialogue state to vocal realization.

## Research Flow

```text
generated text
  -> sentence embedding
  -> reconstructed dialogue state
  -> prosody target vector
  -> predicted prosody vector
  -> speech synthesizer
```

A Julia or Python reference model can estimate the mapping from
semantic state to prosody targets. A validated model can later be
promoted to a deterministic Rust kernel that emits
`ProsodyParameters` for Swift to pass into the active speech
synthesizer.

## Non-Goals

This boundary does not make a GPT model "become" a person. It does
not clone a voice, choose a TTS provider, add network egress, or
alter application state. It only defines the model boundary:

```text
Text
  -> ProsodyModel
  -> ProsodyParameters
  -> SpeechSynthesizer
```

Apple Personal Voice, another TTS provider, or a future local model
can sit behind `SpeechSynthesizing` without changing semantic
generation.
