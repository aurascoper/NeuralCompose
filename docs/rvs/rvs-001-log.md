# Runtime Validation Session 001 — observations

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators
**Goal:** Validate the complete dialectical loop using the new
runtime abstraction. Compare Qwen 0.5B (local) against
DeepSeek-v4-flash:cloud (Ollama-routed cloud) across the three
implemented profiles.

---

## Setup

- 3 profiles × 2 models = 6 runs.
- 3 scripted lines per run (the same lines per profile across
  both models, so the only variable that changes between
  model runs is the model itself).
- 18 dialectic turns total.
- Claude path not exercised (rate-limited until 2026-07-24 6am).

## Bug surfaced during RVS-001

While running the matrix, every DeepSeek run hung at turn 1
(0/3 turns). After instrumentation (debug request-body logging
in `OllamaHTTPTransport.send(...)`) and curl reproduction, the
root cause turned out to be **inside the dialectic loop, not
the HTTP transport**:

- The cloud-routed model uses all 60 `num_predict` tokens on
  its `thinking` field and produces `response: ""` (empty
  text).
- The loop's `runTurn(heard:)` had a `guard !candidateTexts.isEmpty
  else { return }` early-exit at line 211, which returned
  *without incrementing `turnIndex`*.
- The main loop's progress check (`while await loop.turnIndex <
  heardLines.count`) then waited forever for a turn to land;
  the 90-second watchdog killed the harness with "0/N turns
  run" and no telemetry explaining why.

The URLSession is fine. Curl reproduces the empty response in
1-2 seconds. Ollama is fine.

### Fix

`Sources/BCICore/Composition/HypnagogicDialecticLoop.swift`:
the early-exit now logs a `.silent` turn with empty candidates
before returning, and `turnIndex` advances. A persistently-silent
run is now visible in the rollup as N `silent` outcomes, not
as a hang.

`Sources/BCICloudBridge/OllamaHTTPTransport.swift`: the session
was also changed from `URLSession.shared` (and `.default`) to
`URLSessionConfiguration.ephemeral` with explicit
`timeoutIntervalForRequest = 30`. This is a defensive change to
eliminate the keep-alive bug class on cloud-routed models; not
the root cause but removes a related failure mode.

`OllamaHTTPTransport.send(...)` debug print was added during
diagnosis and then removed before commit.

---

## Results — Qwen 2.5:0.5B (local)

### F_qwen (focused, 3 lines)

- Turn 0: outcome=`spoke:displacement-seeking`. Both voices
  produced text; displacement won. Coherence: "To understand a
  concept means to grasp its essence, meaning, and implications;
  t..." (pot 1.41). Displacement: "What does it mean to
  understand a concept? Understanding often involves not just..."
  (pot 1.56).
- Turn 1: outcome=`spoke:coherence-seeking`. Coherence: "Sure,
  I'll do my best to provide a clear example that aligns with
  the constraint..." (pot 1.40). Displacement: "Certainly! Can
  you give me an example?" (pot 1.74).
- Turn 2: outcome=`spoke:coherence-seeking`. Coherence: "That
  helps, thanks." (pot 1.77). Displacement: "That's just another
  way of saying 'helps'. Let's think about something else
  inst..." (pot 1.16).
- Witness: off (focused).
- Total: 3/3 turns, 3 lines written, exit 0.
- Observation: Qwen's tiny model produces coherent two-line
  answers in the dialectic style. Focused profile is functioning
  as expected (resolves readily, both voices land in expected
  ranges).

### R_qwen (reflective, 3 lines)

- Turn 0: outcome=`spoke:displacement-seeking`. Witness ON.
  Witness finding: "Understanding." (1 word).
- Turn 1: outcome=`spoke:displacement-seeking`. Witness finding:
  "Both voices avoided noticing the tension and uncer..."
- Turn 2: outcome=`spoke:coherence-seeking`. Witness finding:
  "Understanding is a process that requires effort an..."
- Total: 3/3 turns, 3 lines written, exit 0.
- Observation: Reflective profile correctly enables the Witness
  on every turn. Witness output is short (1-9 words) and reads
  as the *observing* stance the prompt asks for ("what both
  poles avoided"). The Witness itself is the cloud model, so
  the same empty-text issue would apply, but the small Witness
  prompt template (just the heard line + the two candidates)
  doesn't blow the 60-token budget the way the full dialectic
  template does. This is a real observation: the Witness
  prompt fits; the dialectic template doesn't.

### C_qwen (contemplative, 3 lines)

- Turn 0: outcome=`spoke:displacement-seeking`. Both voices
  produced text.
- Turn 1: outcome=`spoke:displacement-seeking`. Coherence: "Sometimes
  the question matters more than the answer." (pot 1.36).
  Displacement: "In humanistic perspectives, understanding
  questions is just as important as find..." (pot 0.96).
- Turn 2 (heard="..."): outcome=`silent` with 2 candidates
  *generated* (pot 0.94 and 1.05) but the loop resolved to
  silence. The contemplative profile's reluctance to synthesize
  is visible: both candidates exist but neither reaches the
  high synthesis bar; the turn is logged as silent.
- Total: 3/3 turns, 3 lines written, exit 0.
- Observation: contemplative's "less, not more" behavior is
  visible — turn 2 generates text but the loop *chooses* to be
  silent. The Witness is off for contemplative (only reflective
  has it). The high-bar synthesis gate is doing its job.

---

## Results — DeepSeek-v4-flash:cloud (Ollama-routed)

All three runs (focused, reflective, contemplative) produced
**3/3 silent turns** with **0 candidates per turn**.

- The HTTP requests succeed (1-2s each via curl).
- The model returns `response: ""` with `eval_count: 60`,
  using all 60 tokens on the `thinking` field.
- The dialectic template's prompt ("Output only the spoken
  words. At most three sentences.") is enough to make the
  model use its budget on reasoning instead of speaking.

**This is a real finding**, not a bug in the harness. The
cloud model is too "thinking-heavy" for the 60-token cap on
the dialectic template, given the size of the system prompt.
A future fix would be to either:

1. Raise `num_predict` to 256+ for cloud-routed models
   (matches the loop's intent of "three sentences"), OR
2. Use a smaller / more compressed dialectic prompt for
   cloud-routed models (a prompt-preset config knob), OR
3. Use the `/api/chat` endpoint with a `system` role instead
   of `/api/generate` (so the system prompt is shorter).

None of those is a refactor — they're config. The
`OllamaGenerationRuntime` already accepts `maxTokens` and the
`GenerationTransportRequest` already carries the parameter.
The fix is "set a higher `num_predict` per-turn when the
runtime is cloud-routed." That's a one-line change in
`RuntimeFactory.makeOllama` (or in the `OllamaHTTPTransport`
default).

---

## What this session did NOT do

- Did not run Claude (rate-limited; not testable this session).
- Did not exercise Wittgenstein / Schopenhauer / Suzuki
  modes — those are *philosophical framings* the user named
  in their essay, not code paths in the codebase. The modes
  that exist are `focused` / `reflective` / `contemplative`,
  plus the Witness on the reflective profile. All three were
  exercised.
- Did not exercise `hypnagogic` (the `PromptProfile` enum
  case is reserved for a future sleep mode; the waking
  harness loads `wakingDialectical` by design).
- Did not relaunch the full app with the dialectic engine
  enabled (would require UI interaction to start the engine
  from the menu bar; the harness exercises the engine
  directly and the app's other subsystems were verified by
  relaunching it under synthetic EEG and confirming the
  MLX probe, classifier stub, voice, and embedding all
  initialize cleanly).
- Did not implement the metadata-threading commit (deferred
  to next session per the user's "use the remaining time to
  exercise the system" guidance).

## Commits this session produced

1. `fix(loop): log a silent turn when both voices return empty
   text` — the bug fix that makes the harness usable on
   cloud-routed models. Without it, the validation session
   was unable to compare DeepSeek against Qwen.

## Recommended next milestone

The metadata-threading commit (so the live turn event records
the `GeneratorFingerprint`), then the benchmark harness on
`benchmark-001-grounding.txt` × 3 profiles × 2 models × 3
seeds. With the silent-turn fix in place, the benchmark will
produce honest data: a DeepSeek run will show 3 silent outcomes,
not a hang with 0 written.
