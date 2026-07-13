# Review: refinement generation repetition-loop fix — ablation

Fix: `Sources/BCILLM/MLXNextWordPredictor.swift`'s `generate` (chat-
template-aware prompt framing, `<|im_end|>` registered as an extra EOS
token, a repetition penalty). Regression coverage:
`Tests/BCILLMTests/MLXGenerationRegressionTests.swift`.

The implementation intentionally lands all three correctness
improvements — chat templating, EOS registration, repetition penalty —
together. The ablation below exists to understand their relative
contribution, not to determine whether they should be shipped
independently.

**Partially filled in** using `Sources/MLXProbe/main.swift` (a
standalone diagnostic executable added alongside this fix — `swift run
MLXProbe <model-directory> [prompt]`) with temporary env-var ablation
toggles, run directly against the real model. Only prompt 1 got the
full four-way matrix (plus 3 extra baseline trials); prompts 2-3 were
only run at the final (on/on) configuration. Prompts 4-5 and the
remaining cells are genuinely untested — left blank, not fabricated.

**Verdict:** all-three-on (the shipped configuration) produced clean,
coherent, non-repetitive output on every trial across all three tested
prompts. **Which single change is responsible is not established** —
see "Surprises" below. Not claiming this "solves" the repetition bug;
the regression tests guard against the specific decoder-looping and
instruction-framing failure modes observed, and the shipped
configuration held up under real generation, but the failure is
probabilistic and a small number of samples can't attribute causality
to one change over another.

---

## The matrix

Toggle chat templating and the repetition penalty independently by
temporarily commenting out each piece in `generate` (EOS registration
is cheap enough to leave on throughout, but note in your observations
if you also tried disabling it). Run all six regression prompts at
each combination:

1. "Say the word no"
2. "I will not say the words 'a' or 'and' again in this or any future sentences transcribed"
3. "Rewrite this more politely: \"Close the window.\""
4. "Rewrite this sentence in a clearer way: The experiment was successful although several calibration steps were required."
5. "Continue the sequence: 1 2 3 4"

Ran via `MLXProbe` with `MLXPROBE_DISABLE_CHAT_TEMPLATE`/
`MLXPROBE_DISABLE_REPETITION_PENALTY` env toggles (temporary, not
shipped). `temperature: 0.7` throughout (matches `DialecticEngine`'s
default), so single-trial cells are one stochastic sample, not a
reliable failure rate.

| chat framing | repetition penalty | prompt | short-period decoding loop? | notes |
|---|---|---|---|---|
| off | off | 1 (baseline), trial 1 | no | ", you will only have a single choice." |
| off | off | 1 (baseline), trial 2 | no | "What can you say with that? Write the word on the side." |
| off | off | 1 (baseline), trial 3 | no | 'Sure, I will respond "no" with the word "no" but I will still do it.' |
| off | on  | 1 | no | 'Sorry, I didn\'t understand your command. Please provide another word to repeat.' (0.54s) |
| on  | off | 1 | no | ", and I will make it into a question." |
| on  | on  | 1 (final) | no | "no" (0.73s) |
| on  | on  | 2 (final) | no | coherent multi-sentence response, no "and a and a" loop |
| on  | on  | 3 (final) | no | "Please close your windows." (0.28s, clean rewrite not an echo) |
| off | off | 4, 5 | untested | |
| off | on  | 2-5 | untested | |
| on  | off | 2-5 | untested | |
| on  | on  | 4, 5 | untested | |

## Does prompt 5 (pure sequence continuation) ever fail on its own?

Prompts 1-2 conflate instruction-following and decoder stability;
prompts 3-4 test instruction-following specifically. Prompt 5 requires
almost no reasoning, so if it fails under any configuration above, that
isolates a decoder-stability issue independent of instruction content —
worth calling out explicitly here since it's the cleanest signal for
comparing this backend against a second one (Gemma, Phi, ...) later.

## Surprises

**The original bug is stochastic, not deterministic.** Three fresh
baseline (off/off) trials on prompt 1 — the exact configuration that
produced "Say the word no more and a and a" in the original manual
repro — did *not* reproduce a short-period decoding loop in any of the
three runs. This means a handful of samples per configuration cannot
cleanly attribute which of chat-framing/repetition-penalty is
responsible for suppressing the loop; the real metric is a failure
*rate* (`P(loop | prompt, temperature)`) over many trials per cell, not
single samples. The full 20-cell matrix with enough trials per cell to
estimate that rate is left as follow-up work, not blocking this fix.

**Also unexpected:** `MLXNextWordPredictor.init()` and `.generate()`
work fine and quickly (~2.7s init) when run in complete isolation via
`MLXProbe`, outside `PredictorFactory`'s subprocess/semaphore
machinery — the ~120s probe-subprocess timeout some launches hit is an
infrastructure issue in that surrounding architecture, not evidence
that MLX loading itself is slow or broken. Tracked as a separate
follow-up, not part of this fix.
