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

### 3. `roleFulfillment: role?.objective(energy) ?? 0`

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

Not currently reachable: `candidateTexts` is built from `roles`, so the id is
always present. It is one refactor away — a filtered role list, a duplicate id, a
role set swapped mid-turn — and the consequence is a wrong diagnostic rather than
a crash.

### 4. `FeatureExtractor` band energies

`Sources/BCICore/Preprocessing/FeatureExtractor.swift:122-126` —
`energies["delta"] ?? 0` and four siblings. **`0` is a legitimate band energy**
(a dead electrode). A missing dictionary key and a flat channel are the same
number downstream. Lower severity than the others, since the dictionary is built
immediately above, but the same shape.

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

Instances 1 and 3 are worth fixing; 2 is worth fixing with them since it is in
the same file as 1's main caller. 4 and 5 are worth a comment stating the
substitution is deliberate, or a fix, but neither is urgent.

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
