# An absent value given a numeric meaning that is also a legitimate value (2026-08-12)

**Status:** open. Found while porting `BCICore`'s dialectic to Rust
(`neuralcompose-client-native`, `crates/neuralcompose-hypnagogic`).

A recurring shape, not three accidents. In each case a value that is *missing*,
*unfindable* or *incomparable* is represented by a number that the same field
can legitimately hold — so the failure is indistinguishable from a real reading
and produces no symptom.

## Instances

### 1. `Embedding.cosineSimilarity(to:)` returns `0` for incomparable operands

`Sources/BCICore/Models/Embedding.swift:57`. **`0` is a legitimate cosine** —
orthogonal vectors from the same model return it. Covered in full, with its own
blast radius, in
[`embedding-comparability-unenforced-2026-08-12.md`](embedding-comparability-unenforced-2026-08-12.md).

### 2. `DialecticalDynamics.centroid(of:)` silently averages a subset

`Sources/BCICore/Dialectic/DialecticalDynamics.swift`. Members of a differing
dimension are skipped, and the result is returned as if complete. **A subset
centroid is a real vector**, and every similarity measured against it afterwards
is plausible. Nothing reports that anything was dropped.

### 3. `roleFulfillment: role?.objective(energy) ?? 0` — and this one is different in kind

`Sources/BCICore/Composition/HypnagogicDialecticLoop.swift:241`, and the sharpest
of the set. `roles.first { $0.id == roleID }` is a lookup that can miss; a miss
scores `0`.

`ScoredCandidate.roleFulfillment` is documented at
`DialecticalCompetition.swift:88-92` as existing so "a later stage [can] notice a
role that failed its own brief (e.g. a displacement-seeking pass that produced
something un-novel because the model refused to diverge)". **`0` is precisely
that signal.** So a lookup failure manufactures the exact reading the field
exists to detect, and the diagnostic reports a maximally-failed role instead of
an internal inconsistency.

**The distinction worth keeping, because it is the version of this argument that
should convince someone who finds the other four unremarkable:** instances 1, 2,
4 and 5 are a sentinel colliding with a *plausible number*. This one collides
with a *diagnostic*. The failure does not merely hide among legitimate values —
it **impersonates the specific signal a downstream stage is watching for**. A
role-lookup miss does not produce a suspicious zero; it produces a confident
report that the displacement pole utterly failed its brief. Anything built on
that field to detect degenerate generation will fire on an internal
inconsistency and point at the model.

Not currently reachable: `candidateTexts` is built from `roles`, so the id is
always present. It is one refactor away — a filtered role list, a duplicate id, a
role set swapped mid-turn — and the consequence is a wrong diagnostic rather than
a crash.

### 4. `FeatureExtractor` band energies — reachability checked, and it is *not* the live path

`Sources/BCICore/Preprocessing/FeatureExtractor.swift:122-126` —
`energies["delta"] ?? 0` and four siblings. **`0` is a legitimate band energy**
(a dead electrode), so a missing dictionary key and a flat channel are the same
number downstream.

This was worth checking rather than filing next to the others by proximity,
because electrode failure-without-saying-so is the project's active constraint.
Two questions, both answered:

**Does the Core ML classifier consume this? No.**
`CoreMLIntentClassifier.classify(window:)` builds its `MLMultiArray` directly
from the raw window (`multiArray(from:)`, :119) — channels × samples, zero-padded
— and never touches `FeatureExtractor`. There is no wrong-input path into the
shipped classifier. `FeatureExtractor`'s only callers are
`MockIntentClassifier.swift:46` (the stub path), `JEPATransition.swift:41`, and
one golden-recording regression test.

**Is the dictionary lookup actually breakable? Barely.** The band names are
written and read as hardcoded literals in the *same private function*, twenty
lines apart (`centers` at :103, the reads at :122-126), with a loop that always
writes all five. There is no config, no external band label, and no caller who
can influence the keys. The `?? 0` is dead defensive code. Its fuse is a rename
typo in one of the two lists — short, but local and immediately visible.

So: **lowest severity in this set, and reachable by neither of the routes that
made it look urgent.** Fix it as tidiness (destructure the tuple list, or build
`Bands` in the loop) rather than as a defect.

**The sharper sentinel in that same function is a different line.** At :117,
`let e = n > 0 ? Float(...) : 0` — a channel shorter than the lag is skipped
(`if ch.count <= lag { continue }`), and if *every* channel is too short the band
reports `0`. That is insufficient-data rendered as a real measurement, and unlike
the dictionary read it depends on runtime values: `lag = sampleRate / centerHz / 2`,
so delta at 256 Hz needs 51 samples. Comfortable for a 1–2 s window, but it is
the window length and sample rate — not a literal — that keep it safe.

**Where the wrong value would actually land:** `JEPATransition.init?(window:)`
takes `alphaEnergy`/`betaEnergy`/`thetaEnergy` straight from here into the
capture persisted for offline JEPA training (ADR-006). It guards `isFinite`,
which a spurious `0` passes. So the consequence is not a bad live decision but a
**poisoned training corpus** — silently, and discovered much later.

#### Checked: it has not happened, because the capture has never run

An exact `0.0` band energy out of a float computation over real EEG is a
measure-zero event — genuine delta power is small but never exactly zero — so
existing captures can be *scanned* for it rather than reasoned about. Any hit
would be either this bug or a dead channel, and both are worth finding.

Ran it, 2026-08-13. **There are no captures.** `~/Documents/NeuralCompose/` holds
`Calibration/`, `EEGIntegration/`, `InteractionLogs/`, `Recordings/`,
`health.json` and `voice-profile.json` — and no `JEPATransitions/` directory at
all, on either machine. `TransitionCaptureManager` writes
`~/Documents/NeuralCompose/JEPATransitions/jepa_transitions.jsonl`
(`TransitionCaptureManager.swift:58-60`) and that path has never been created,
which matches `CLAUDE.md`'s own statement that there are zero logged interaction
events because the capture is opt-in and off by default.

That is the good version of this finding rather than the disappointing one: the
corpus is empty, so the guard can land **before** the first capture run at zero
cleanup cost, and there is no archaeology to do. It also means the check is
better placed at capture time than after: reject a window whose band energies
come back exactly zero, rather than scanning for them later.

Pair it with making the implicit precondition explicit. The safety of :117
rests on window length ≥ lag — real, load-bearing, and currently unwritten.
Assert it (`window.sampleCount > lag` for the lowest-frequency band) instead of
relying on windows happening to be long enough.

### 5. `ProsodyWobble` substitutes concrete defaults for `nil`

`Sources/BCICore/Composition/ProsodyWobble.swift:49-52` — `base.rate ?? 0.5`,
`base.volume ?? 0.9`, `base.preUtteranceDelay ?? 0.1`. Here `nil` means "let the
engine choose", and the substitution silently converts that into a specific
number. Arguably deliberate — you cannot wobble an absent value — but it means a
prosody that deliberately abstained comes out of the wobble having decided.

## The codebase already contains the correct idiom

**`SpeechProsody.blend` gets this exactly right**
(`Sources/BCICore/Protocols/SpeechSynthesizing.swift:128-141`): each field is
averaged only over contributors that specify it, a `nil` field *abstains* rather
than voting zero, and the result is `nil` when nothing contributed. That is the
pattern the other five should follow.

Worth being precise about this, because an earlier verbal summary of mine
mistakenly listed the blend as a third instance of the defect. It is not — it is
the counter-example. The bug there was in the Rust *port*, which had reimplemented
it as a two-way lerp over non-optional fields; the Swift was right and the port
was wrong. Corrected in client-native `39c642a`.

So this is an inconsistency, not an unfamiliarity: the codebase knows how to do
this and does it in one place out of six.

## Why it is worth a pass rather than a note

The three ports that hit instances 1–3 all had to make the same decision
independently, which is the signal. In the Rust the resolution was uniform:

- `cosine_similarity -> Option<f32>`, propagated through `energy`, `tension` and
  `synthesis_score`, so **missing** (an early turn, legitimately neutral at 0.5)
  stays distinct from **incomparable** (a defect);
- `centroid` refuses a mixed set rather than averaging part of one;
- `Prosody::blend` abstains, matching the Swift.

Each is pinned by a test that asserts the two cases are *not equal* — e.g.
`Some(0.0) != None` for orthogonal-versus-incomparable — so reintroducing a
sentinel names itself.

## Suggested handling

Ranked by what the failure would actually cost, not by how alarming the line
looks:

1. **`roleFulfillment` (3)** — highest. It impersonates a diagnostic rather than
   hiding among plausible values, so anything built on that field to detect
   degenerate generation would misattribute an internal inconsistency to the
   model. Fix even though it is currently unreachable.
2. **`cosineSimilarity` (1)** and **`centroid` (2)** — fix together; they share a
   file and a caller, and the Rust port has already demonstrated the resolution.
3. **`FeatureExtractor`'s `n > 0 ? … : 0` (4, second line)** — insufficient data
   rendered as a measurement, on the path that feeds a *persisted* JEPA training
   corpus. Worth a guard that refuses rather than reports zero.
4. **`FeatureExtractor`'s dictionary reads (4, first lines)** — tidiness only.
   Not reachable; the keys are literals in one private function.
5. **`ProsodyWobble` (5)** — leave hedged. Substituting a default for "let the
   engine choose" is a real semantic loss, but it is plausibly what was meant,
   and it is the one case here where a fix would change *output* rather than only
   diagnostics. That asymmetry is the argument for leaving it alone until someone
   states the intent.

Nothing here should be fixed *only* in the Rust port. The dialectic's Rust half
is now checked against the Swift by a committed conformance fixture
(`Sources/DialecticFixture`), so a one-sided "improvement" shows up as a
conformance failure rather than as an improvement — which is the mechanism
working, but it means the Swift moves first.

## Related, found in the same pass

`HypnagogicDialogueLoop.chunk` emits lone-punctuation chunks for a punctuation
run: `"Wait... really?!"` → `["Wait.", ".", ".", "really?", "!"]`, because every
punctuation character closes the current chunk and only *empty* results are
dropped — `"."` is not empty.

This is a **latency** bug rather than a cosmetic one. Each lone `"."` is its own
`speak()` call, so a single ellipsis costs three utterances, three
`preUtteranceDelay`s and (in the Linux shell) three subprocess spawns — over a
second of dead air inside one spoken turn on the contemplative voices, where
`preUtteranceDelay` is longest and ellipses are most common. In a conversational
loop, turn latency is the product.

The Rust port pins the current behaviour rather than diverging, so this must be
fixed here first.
