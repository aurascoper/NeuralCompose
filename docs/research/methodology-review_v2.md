# Methodology Review v2: CKA/Procrustes Addendum + Verified Muse Clinical Literature

## Status

Review (this commit). Successor to
[methodology-review_v1.md](methodology-review_v1.md) — v1 is not
deprecated and stays as the record of the original three-pillar review;
this file adds one addendum and corrects one section based on new input
received after v1 shipped.

**What changed and why:** two things arrived after v1: a request to
contrast CKA against Orthogonal Procrustes for representation alignment,
and two specific clinical papers claimed to validate the Muse S against
polysomnography with precise statistics proposed as engineering
thresholds. Both papers turned out to be real — confirmed via `WebSearch`/
`WebFetch` in this session — but the statistics as presented needed
correcting, not just transcribing. That correction is the point of
keeping this a hostile peer review rather than a citation pass-through.

---

## Pillar A Addendum — CKA's Eigenvalue Dominance vs. Orthogonal Procrustes' Rigidity

### The math, stated correctly

Orthogonal Procrustes seeks the rotation (no scaling, no shearing) that
best aligns representation $A$ to representation $B$:

$$\min_{R^\top R = I} \|AR - B\|_F^2$$

with the closed-form solution from the SVD of the cross-covariance
matrix: $A^\top B = U\Sigma V^\top \implies R = UV^\top$ (Schönemann,
1966; see Gower & Dijksterhuis, *Procrustes Problems*, Oxford University
Press, 2004 — already cited in v1). This is correct as stated and is a
useful formula to add to `docs/Math.md` alongside the CKA formula v1
already proposed.

### Why this matters here: CKA and Procrustes answer different questions, and the codebase's Procrustes isn't actually the rigid one

CKA (Kornblith et al. 2019, [1905.00414](https://arxiv.org/abs/1905.00414), cited in v1) is invariant to orthogonal transformation **and** isotropic scaling, and is dominated by the top eigenvalues of the representation's covariance structure — two representations can have high CKA while differing substantially in fine-grained, low-variance directions. Davari, Horoi, Natik, Lajoie, Wolf, and Belilovsky,
["Reliability of CKA as a Similarity Measure in Deep Learning"](https://arxiv.org/abs/2210.16156)
(2210.16156, already cited in v1) formally shows CKA can be manipulated by
specific classes of transformation without a corresponding change in a
model's functional behavior — general support for treating a high CKA
score as necessary but not sufficient evidence of "these two models
represent things the same way." Orthogonal Procrustes, by construction,
does **not** tolerate scaling — it measures rotation-only alignment, so a
low Procrustes disparity is a stronger (more literal) claim about shared
geometry than a high CKA score is.

One illustrative extension worth naming explicitly as **speculative, not
cited**: it's plausible that aggressive weight quantization (e.g. 4-bit)
could damage a model's fine-grained representational geometry in ways
that leave the top-eigenvalue structure — and therefore CKA — largely
unaffected, while a rigid Procrustes fit would degrade visibly. No paper
found in this review studies that specific scenario; it follows from
Davari et al.'s general point about CKA's tolerance for certain
transformation classes, but should be labeled as an extrapolation if used
in any design doc, not attributed to a specific empirical result.

**This directly sharpens a finding already in v1, rather than adding a
new one.** `Evaluation/scripts/embedding_space_analysis.py`'s
`procrustes_alignment()` calls `scipy.spatial.procrustes(X, Y)`, which
performs **scaled** Procrustes (translate to origin, rescale both to unit
Frobenius norm, then rotate) — not the rotation-only orthogonal Procrustes
described above. v1 flagged this as a terminology mismatch against
`STAGE_3_4_3_5_DESIGN.md`'s "orthogonal Procrustes" label. Given this
addendum's premise — that Procrustes is valuable specifically *because* it
refuses to compromise on scale/shear the way CKA does — that mismatch
matters more than v1's original framing suggested: **the codebase
currently isn't computing the metric whose main selling point is exactly
what would make it useful here.** If geometric rigidity checking (e.g. a
"does this lightweight model's latent space rotate cleanly onto the
target's" signal) becomes a real requirement, `procrustes_alignment()`
needs a rotation-only variant (Procrustes without the rescaling step,
i.e. skip scipy's normalization and solve $R=UV^\top$ directly on the
raw — at most mean-centered — data) as a distinct metric from what's
computed today, not a relabeling of the existing one.

### Scope note

Whether and how to use a Procrustes-distance threshold as a routing
"abort" signal is Stage 3.5 pipeline-engineering design work, out of this
review's scope (`docs/research/` is literature grounding, not routing
logic). This addendum supplies the citation and the code-level finding;
the routing mechanism itself belongs in the Stage 3.5 design document.

---

## Pillar C Correction — Verified Muse-S Clinical Validation Literature

v1 searched arXiv only and found nothing Muse-specific, explicitly noting
that clinical/HCI venues were the more likely home for such validation
and recommending a non-arXiv search "if needed." That turned out to be
needed. Two real papers were found and verified via `WebFetch` in this
session — the numbers below are taken directly from the fetched abstracts/
full text, not from the secondhand description that prompted this search.

### Paper 1: Muse-S vs. level-1 polysomnography

*"Assessing the performance of a portable electroencephalographic sleep
monitor against level 1 polysomnography,"* *SLEEP Advances*, December
2025 ([PMC12782022](https://pmc.ncbi.nlm.nih.gov/articles/PMC12782022/)).
56 adults, one night of simultaneous Muse-S + level-1 PSG recording, PSG
scored blind to the Muse-S automated output.

**Verified numbers:**

| Metric | Value |
|---|---|
| Full-night Cohen's Kappa | 0.76 (substantial agreement) |
| Kappa — Wake | 0.84 |
| Kappa — NREM1 | 0.41 (fair) |
| Kappa — NREM2 | 0.75 |
| Kappa — NREM3 (deep sleep) | 0.77 |
| Kappa — REM | 0.85 |
| NREM3 accuracy / sensitivity / specificity | 93.8% / 88.3% / 94.3% |
| Overall accuracy range across stages | 88–96% |

**Two corrections to how these numbers were proposed for use:**

1. **The 84%/16% figure is per-participant, not per-night.** 47 of 56
   participants (84%) had usable whole-night data; 9 (16%) were excluded.
   This is a *study-inclusion rate*, not a *within-night signal-retention
   budget* — treating "≥84% retained" as a per-night epoch-quality gate
   for a new study misapplies the statistic. If an overnight protocol
   wants a retention target, it should define its own epoch-level metric
   and validate it empirically rather than borrow this number's units.
2. **The exclusion cause was device wear, not just motion.** The paper
   attributes exclusions to "poor electrode contact with the skin or...
   wear and tear of the Muse-S device after 14 to 20 nights of use" — a
   degradation effect from repeated use over weeks, distinct from
   within-night motion artifacts. A multi-night study design should budget
   for this as its own risk (electrode/headband condition monitoring over
   the study's duration), separate from `SLEEP_CYCLE_DESIGN.md`'s existing
   single-night motion-artifact handling (R3).

The paper does **not** specify artifact-rejection thresholds or frequency-
band filtering rules ("automated algorithms developed by InteraXon," no
technical detail given) — any specific frequency-band heuristic (e.g. a
>20–30 Hz EMG-contamination band, 0.5–4 Hz delta band for N3) is standard
EEG convention, not something sourced from this paper, and should not be
cited to it.

**Montage discrepancy, resolved:** this paper states Muse-S channels as
Fp1, Fp2, TP9, TP10 — apparently conflicting with v1's claim (TP9, AF7,
AF8, TP10, sourced from `Sources/BCICore/Models/EEGSample.swift` and
`BrainFlowService.swift`). Checked against BrainFlow's own board
documentation
(`brainflow.readthedocs.io/en/stable/SupportedBoards.html`): both Muse S
and Muse 2 expose **TP9, AF7, AF8, TP10** as EEG channel names in the
actual SDK NeuralCompose links against. The clinical paper is using
"Fp1/Fp2" as an approximate clinical-convention relabeling of the same
physical anterior-frontal electrodes for a medical readership — not a
different device or montage. v1's montage claim stands; this paper's
findings do transfer to NeuralCompose's actual hardware.

**Still an open gap:** this paper validates InteraXon's proprietary
combined 4-channel scorer as a black box — it does not isolate the
contribution of TP9/TP10 (temporal-parietal) versus AF7/AF8
(anterior-frontal) individually. v1's finding that no paper separately
characterizes TP9/TP10 signal quality for sleep staging still holds.

### Paper 2: Single-channel EEG headband + actigraphy validation

Melo, Vallim, Garbuio, et al., *"Validation of a sleep staging
classification model for healthy adults based on 2 combinations of a
single-channel EEG headband and wrist actigraphy,"* *Journal of Clinical
Sleep Medicine*, 2024, 20(6):983-990, NCT04943562
([jcsm.aasm.org/doi/10.5664/jcsm.11082](https://jcsm.aasm.org/doi/10.5664/jcsm.11082)).
23 healthy adults, full-night type-I PSG reference, two device
combinations (flexible headband, n=12; rigid headband, n=11), 18
frequency/time features, ensemble classifier.

**Verified numbers — two distinct devices, not one blended range:**

| Combination | EEG alone | EEG + actigraphy |
|---|---|---|
| Flexible single-channel headband | 97.7% F1 | 98.4% F1 |
| Rigid single-channel headband | 95.3% F1 | 96.9% F1 |

**Most useful finding for NeuralCompose, stated by the authors
explicitly:** *"actigraphy was not an important feature of the model"* —
single-channel EEG alone performs nearly as well as EEG plus actigraphy
for both devices. This is directly relevant independent of how it was
originally framed: it supports NeuralCompose's existing no-actigraphy
design (per `SLEEP_CYCLE_DESIGN.md`, only BrainFlow EEG is assumed) rather
than motivating a hardware addition.

**Caveat:** the abstract does not specify which electrode site either
single channel was placed at, so this paper's numbers cannot be assumed
to transfer to the TP9/AF7/AF8/TP10 montage specifically — cite it for
the "actigraphy isn't necessary" finding and the general single-channel-
viability precedent, not as a montage-matched accuracy benchmark.

### Updated search-coverage note (supersedes v1's)

v1 stated: *"a direct search for 'Muse headband EEG validation' returned
no relevant results here [on arXiv]... If Muse-specific validation
literature is needed, it should be sought outside arXiv."* That
recommendation was correct and, followed up in this session, found both
papers above via general web search. Clinical/HCI validation literature
for consumer EEG remains thin on arXiv specifically — non-arXiv search
(PubMed, journal sites) is the right tool for this category of claim, and
should be the default next step rather than a fallback, for any future
Muse- or PSG-specific literature question in this project.

---

## Updated Recommendation to the Overnight EEG Study

1. Define a study-specific, within-night epoch-retention metric if a
   retention gate is wanted — do not reuse the 84% participant-inclusion
   figure from Paper 1 as if it measured the same thing.
2. If the protocol involves repeated multi-night use of the same
   headband, treat electrode/device-wear degradation (per Paper 1, onset
   around 14–20 nights) as a distinct risk from single-night motion
   artifacts, with its own monitoring approach (e.g. periodic signal-
   quality spot checks across the study's duration).
3. Treat EMG-band (>20–30 Hz) and delta-band (0.5–4 Hz) heuristics as
   standard EEG convention available to propose as a starting filter, not
   as findings sourced from either paper cited here.
4. No actigraphy addition is supported by Paper 2's own conclusion that it
   didn't meaningfully help — consistent with, and further supporting,
   the project's existing EEG-only design.
5. TP9/TP10 contribution to sleep-relevant signal remains unvalidated in
   the literature found so far; recommend an explicit ablation (compare
   AF7/AF8-only vs. TP9/TP10-only vs. all-4 classification performance)
   as part of `SLEEP_CYCLE_DESIGN.md` §21's Sleep Validation Toolkit gate,
   since no published source does this for this montage.

---

## Annotated Bibliography Additions

| Citation | Why it matters here |
|---|---|
| [Assessing the performance of a portable electroencephalographic sleep monitor against level 1 polysomnography](https://pmc.ncbi.nlm.nih.gov/articles/PMC12782022/), *SLEEP Advances*, 2025 | First verified Muse-S-vs-PSG validation directly applicable to NeuralCompose's exact hardware (montage discrepancy resolved via BrainFlow docs); real Kappa/accuracy numbers per sleep stage; exclusion-rate statistic is per-participant, not per-night — a common unit-of-analysis trap worth flagging generally |
| Melo, Vallim, Garbuio, et al., [Validation of a sleep staging classification model for healthy adults based on 2 combinations of a single-channel EEG headband and wrist actigraphy](https://jcsm.aasm.org/doi/10.5664/jcsm.11082), *J Clin Sleep Med*, 2024, 20(6):983-990 | Real single-channel EEG viability precedent; explicit finding that actigraphy doesn't meaningfully improve accuracy, supporting NeuralCompose's EEG-only design; electrode site unspecified, so montage-match is not assumed |
