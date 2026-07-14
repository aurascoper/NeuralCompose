# Methodology Review: Representation Alignment, Cascades, and Sparse EEG Sleep Staging

## Status

Review (this commit). Written as a hostile academic peer review of the
mathematical and clinical assumptions underpinning Stage 3.4 (interaction
science), Stage 3.5 (pipeline engineering, not yet implemented), and the
draft overnight EEG study (`SLEEP_CYCLE_DESIGN.md`, v1, not yet
implemented). Every claim below cites a real paper (arXiv ID given where
one exists) or a specific file/line in this repository. Scope note: two
assumptions in the originating brief for this review didn't survive
contact with the repo and were corrected before research began —
`docs/protocols/` does not exist (the real preflight material is in
`HARDWARE_SETUP.md` and `SLEEP_CYCLE_DESIGN.md` §6), and NeuralCompose's
Muse montage is TP9/AF7/AF8/TP10, not Fp1/Fp2 — see Pillar C.

---

## Pillar A — Representation Alignment Review

### What the code actually implements

`Evaluation/scripts/embedding_space_analysis.py` computes, for each pair of
embedding models, six metrics: linear CKA, SVCCA (top-4 singular
directions), Procrustes disparity (via `scipy.spatial.procrustes`),
neighborhood overlap (Jaccard), cluster purity (k-means), and intrinsic
dimensionality (participation ratio). `docs/Math.md` has no formulas for
any of these — it jumps from §8 Decoder Stability to §9 Statistical
Evaluation. The formulas below are what should be added, sourced
correctly, plus the specific implementation issues found by reading the
code line-by-line.

### CKA — linear, biased, run outside its stated valid range

The canonical reference is Kornblith, Norouzi, Lee, and Hinton,
**"Similarity of Neural Network Representations Revisited"**
([1905.00414](https://arxiv.org/abs/1905.00414), 2019). Its abstract makes
a claim that is directly load-bearing for this codebase: *"neither CCA nor
any other statistic that is invariant to invertible linear transformation
can measure meaningful similarities between representations of higher
dimension than the number of data points."* NeuralCompose's Stage 3.4-C
pilot compares embeddings at **N=10 stored samples** against **d=384
dimensions** — roughly 38× more dimensions than data points, deep inside
the exact regime the foundational paper flags as unreliable for
CCA-family statistics. CKA (which the paper introduces specifically to be
more robust than CCA in the high-dimension/low-N regime) is less brittle
here than CCA would be, but "less brittle than CCA" is not the same claim
as "reliable at N=10," and `embedding_space_analysis.py`'s `cka()`
implements the **biased** linear-kernel HSIC estimator (no debiasing
term — `Evaluation/scripts/embedding_space_analysis.py:35-49`). Davari,
Horoi, Natik, Lajoie, Wolf, and Belilovsky, **"Reliability of CKA as a
Similarity Measure in Deep Learning"**
([2210.16156](https://arxiv.org/abs/2210.16156), 2022) formally
characterizes CKA's sensitivity to simple transformations and outliers,
and shows CKA values can be manipulated substantially without any
corresponding change in a model's actual functional behavior — direct
support for treating `stage_3_4_audit.md`'s CKA=0.957–0.966 pilot numbers
as unreliable rather than merely "preliminary."

- **Recommendation to the Stage 3.4 audit:** don't just note "N=10 is
  small" — state the actual mismatch (N should exceed the embedding
  dimensionality by a comfortable margin for CKA/SVCCA to be meaningful;
  N=10 vs d=384 is roughly 40× in the wrong direction) and treat the
  reported CKA values as **not yet evidence** for hypothesis 3.4-C until
  re-run against the full stored corpus, not the first-10-texts sample.
- **Math.md formula to add** (linear CKA, HSIC-based):
  $$\mathrm{CKA}(X,Y) = \frac{\mathrm{HSIC}(X,Y)}{\sqrt{\mathrm{HSIC}(X,X)\,\mathrm{HSIC}(Y,Y)}}, \quad \mathrm{HSIC}(X,Y) = \frac{1}{(n-1)^2}\operatorname{tr}(KHLH)$$
  with $K = XX^\top$, $L = YY^\top$, $H$ the centering matrix — matching
  what the code computes (X, Y are pre-centered before the trace, which is
  algebraically equivalent to the $H$-centered form).

### SVCCA — fixed-k truncation, not the original method's adaptive threshold

Raghu, Gilmer, Yosinski, and Sohl-Dickstein, **"SVCCA: Singular Vector
Canonical Correlation Analysis for Deep Learning Dynamics and
Interpretability"** ([1706.05806](https://arxiv.org/abs/1706.05806),
2017) truncates each representation's SVD to the directions accounting
for a target fraction of variance (they use 99% in the paper) before
running CCA on the truncated subspaces — the whole point of the
"SV" in SVCCA is to discard low-variance noise directions adaptively.
`embedding_space_analysis.py:52-64`'s `svcca()` instead truncates to a
**fixed `n_directions=4`** regardless of how much variance those 4
directions explain for a given model pair. At N=10 samples this
additionally means the SVD has at most 10 singular values to begin with,
so a fixed k=4 is a large, unexamined fraction of the available
directions — this is a real, citable deviation from the cited method, not
an implementation detail. Recommend switching to variance-threshold
truncation (e.g., smallest k such that cumulative explained variance
≥ 0.99, capped by `min(n_samples, n_features)`).

### Procrustes — code computes *scaled* Procrustes, design doc says *orthogonal*

`STAGE_3_4_3_5_DESIGN.md` (RQ2 description) calls this metric "orthogonal
Procrustes." `embedding_space_analysis.py:67-75` calls
`scipy.spatial.procrustes(X, Y)`, which performs the **full Procrustes
superimposition**: translate both to the origin, **rescale both to unit
Frobenius norm**, then find the optimal rotation — i.e., it removes scale
differences before measuring disparity. Orthogonal Procrustes in the
classical sense (Schönemann, 1966; see Gower & Dijksterhuis, *Procrustes
Problems*, Oxford University Press, 2004 — not on arXiv) finds only the
optimal **rotation**, preserving whatever scale difference exists between
X and Y. These give different disparity values whenever the two embedding
spaces have different overall vector norms, which 384-dim sentence
embeddings from different training runs generally do. This is a
terminology/implementation mismatch worth fixing in the design doc's
wording (call it "scaled Procrustes" or "Procrustes superimposition"),
not a bug in the code — scipy's default is a defensible choice, it's just
not what "orthogonal Procrustes" names.

### Neighborhood overlap, cluster purity, intrinsic dimensionality — correctly implemented

No issues found. `neighborhood_overlap()` is a standard Jaccard-of-top-k
computation; `cluster_purity()` is a standard majority-label purity over
independently-fit k-means partitions; `intrinsic_dimensionality()`
implements the participation ratio,
$\mathrm{PR} = (\sum_i \lambda_i)^2 / \sum_i \lambda_i^2$ over the
covariance eigenspectrum, which matches the standard definition used in
Jazayeri and Ostojic, **"Interpreting neural computations by examining
intrinsic and embedding dimensionality of neural activity"**
([2107.04084](https://arxiv.org/abs/2107.04084), 2021) — a useful review
for `Math.md` to cite, since it also explains *why* participation ratio at
N=10 is dominated by the sample-to-dimension ratio rather than true
geometry (the same point `stage_3_4_audit.md`'s Observation 3 already
makes empirically without naming the mechanism: PR is bounded above by
N−1, so PR≈7 at N=10 is close to the ceiling, not necessarily a real
low-dimensional signal).

---

## Pillar B — Cascade & Routing Literature

### Established practice: LLM cascades as a cost-accuracy tradeoff

Chen, Zaharia, and Zou, **"FrugalGPT: How to Use Large Language Models
While Reducing Cost and Improving Performance"**
([2305.05176](https://arxiv.org/abs/2305.05176), 2023) is the canonical
reference for exactly what `hypothesis_registry.json`'s `3.5-D-cascaded-
generation` and the `policy_registry`'s Fast/Balanced/Quality/Adaptive
tiers are describing: a **learned cascade** that routes each query through
increasingly expensive models only as needed, matching best-single-model
accuracy at a fraction of the cost (their reported result: up to 98% cost
reduction at matched accuracy, or +4% accuracy at matched cost). This
directly supports treating cascades as established, not speculative,
practice for NeuralCompose's Stage 3.5 — the open question is *how* to
decide when to escalate, which is where the entropy/confidence literature
below matters.

### The confidence-signal gap: what the literature assumes vs. what `MLXNextWordPredictor` has

Nearly all cascade/routing literature assumes access to either full
per-token logprobs, an entropy measure over the vocabulary distribution,
or a separate learned router. `Sources/BCILLM/MLXNextWordPredictor.swift`
currently exposes neither — the carousel path returns a `[PredictedWord]`
array with a per-candidate `probability: Float` (softmax over a
top-N-of-vocab pool, not the full vocabulary), and the file's own doc
comment on `logGenerationDiagnostics` explicitly states that per-step
entropy and top-1 probability are "not currently logged, and not trivial
to add" because it requires bypassing `MLXLMCommon.generate`'s high-level
wrapper for the lower-level `TokenIterator` API. Two papers found in this
review map closely onto exactly this constrained signal:

- Agrawal, Jeon, and Lee, **"AdaEDL: Early Draft Stopping for Speculative
  Decoding of Large Language Models via an Entropy-based Lower Bound on
  Token Acceptance Probability"**
  ([2410.18351](https://arxiv.org/abs/2410.18351), 2024) — uses the
  entropy of the *currently observed drafted logits* (not a full
  sequence-level score) as a training-free stopping criterion. This is
  architecturally close to what's achievable from `MLXNextWordPredictor`'s
  existing per-step softmax without a rewrite, and is a better template
  for a first confidence signal than assuming full logprob access.
- Chen, Ju, and Qi, **"How Confident Is the First Token? An
  Uncertainty-Calibrated Prompt Optimization Framework..."**
  ([2603.18009](https://arxiv.org/abs/2603.18009), 2026) — uses **only the
  first generated token's** confidence to decide whether to trigger a more
  expensive retrieval step, reporting a 50.66% reduction in retrieval
  triggers with maintained accuracy. This is a near-exact structural
  analog of `hypothesis_registry.json`'s `3.5-E-confidence-consensus`
  (confidence-gated second-model invocation) — same pattern (first-token
  confidence → gate an expensive fallback), different domain (RAG
  retrieval vs. generation escalation).

**Recommendation to the Stage 3.5 design agent:** scope "expose a richer
confidence signal from `MLXNextWordPredictor`" as an explicit,
prerequisite Swift engineering task (bypassing `MLXLMCommon.generate` for
`TokenIterator` access), not a detail folded into the routing design. Until
that lands, design the first version of `3.5-E` around the **existing**
signal (top-1 candidate probability, or the margin between top-1 and
top-2 candidate probabilities in the current `[PredictedWord]` array) —
this is directly compatible with the AdaEDL-style approach above and
requires no MLX-side changes.

### Emerging practice: conformal prediction for threshold-setting

Van der Laan and Alaa, **"Self-Calibrating Conformal Prediction"**
([2402.07307](https://arxiv.org/abs/2402.07307), 2024) and Xi, Huang, Liu,
Feng, and Wei, **"Does confidence calibration improve conformal
prediction?"** ([2402.04344](https://arxiv.org/abs/2402.04344), 2024) are
representative of an active but not-yet-standardized area: using conformal
prediction to set data-driven, coverage-guaranteed confidence thresholds
rather than hand-tuned cutoffs. This is directly relevant to setting the
`latency_budget_s` / confidence-gating thresholds in
`hypothesis_registry.json`'s `policy_registry`, but nobody has published
this specifically for a 3-candidate, brain-signal-committed carousel like
NeuralCompose's — applying conformal prediction to guarantee a coverage
bound on "is the top-1 carousel candidate good enough to commit" would be
a genuine novel contribution for this project, not an established
recipe to just adopt. Flag it to the Stage 3.5 design agent as a
**speculative, worth-scoping experiment**, not a load-bearing design
assumption.

---

## Pillar C — Sparse EEG Sleep Staging Validation

### The montage correction (stated up front because it changes which literature applies)

NeuralCompose's Muse channel layout is **TP9, AF7, AF8, TP10**
(`Sources/BCICore/Models/EEGSample.swift`, `BrainFlowService.swift`
channel-layout comment) — AF7/AF8 are anterior-frontal (adjacent to but
not the same site as prefrontal-midline Fp1/Fp2), and TP9/TP10 are
temporal-parietal, near the mastoids, typically used as reference/ground
or artifact-detection channels rather than primary signal channels in
clinical montages. This matters for sleep staging specifically because
slow-wave (delta) activity and sleep spindles are classically strongest at
frontal/central sites, and eye-movement (EOG) artifact — the dominant
contaminant during sleep-onset and REM — couples most strongly into
frontal electrodes. AF7/AF8 get *some* of both signals; TP9/TP10 get
comparatively little of either and are dominated by different artifact
sources (temporalis muscle tension, mastoid-adjacent placement, possible
cardiac pulse propagation). **No paper found in this search separately
characterizes signal quality at the TP9/TP10 position for sleep staging**
— this is a genuine, uncited gap, not just an under-researched footnote,
and should be treated as an open validation question before committing to
`SLEEP_CYCLE_DESIGN.md`'s 4-class `SleepStage` design.

### Established practice: sparse/single-channel wearable EEG sleep staging is viable, with caveats about ground truth

- Koushik, Amores, and Maes, **"Real-Time Sleep Staging using Deep
  Learning on a Smartphone for a Wearable EEG"**
  ([1811.10111](https://arxiv.org/abs/1811.10111), 2018) — single-channel,
  smartphone-only inference, 83.5% 5-class accuracy on the public
  Sleep-EDF dataset (PSG ground truth). Demonstrates the general viability
  of the sparse-channel approach `SLEEP_CYCLE_DESIGN.md` assumes.
- Estevan, Sierra-Torralba, López-Larraz, and Montesano, **"A Systematic
  Evaluation of Self-Supervised Learning for Label-Efficient Sleep Staging
  with Wearable EEG"** ([2510.07960](https://arxiv.org/abs/2510.07960),
  2025) — a **PSG-validated** wearable-headband benchmark (Ikon Sleep
  device, BOAS dataset has consensus PSG labels), reaching >80% clinical-
  grade accuracy using only 5–10% labeled data via self-supervised
  pretraining. This is the closest published methodology template for how
  NeuralCompose could bootstrap a sleep classifier without collecting a
  large hand-labeled corpus — directly relevant to `SLEEP_CYCLE_DESIGN.md`
  §21's "Sleep Validation Toolkit" gate.
- Lepold, Leichtle, Röddiger, and Beigl, **"Feasibility of In-Ear
  Single-Channel ExG for Wearable Sleep Monitoring in Real-World
  Settings"** ([2509.07896](https://arxiv.org/abs/2509.07896), 2025) — a
  cautionary comparator: single dry electrode, 4-class staging
  (Awake/REM/Core/Deep), only **65.1%** accuracy, and critically, **ground
  truth was an Apple Watch, not PSG**. This is the closest published
  system to NeuralCompose's own 4-class `wake/n1/n2_n3/uncertain_rem`
  proposal in terms of channel sparsity, and its accuracy ceiling (and
  weak ground truth) is a realistic expectation-setter, not the
  optimistic 83.5%/>80% numbers above.

**Recommendation:** `SLEEP_CYCLE_DESIGN.md` doesn't currently specify what
ground truth the classifier would be validated against. Recommend it
explicitly add a same-night reference signal — even a consumer actigraphy/
sleep-tracker comparison (as in 2509.07896) is better than no external
check — before treating any accuracy number from the eventual classifier
as meaningful, and recommend running the §21 "Sleep Validation Toolkit"
gate with an explicit TP9/TP10-vs-AF7/AF8 signal-quality comparison as a
first sub-experiment, given the literature gap noted above.

### Artifact taxonomy for this specific montage

Han, Zhang, Lei, Han, Du, Wang, Bai, and Zhang, **"Cepstral Analysis Based
Artifact Detection, Recognition and Removal for Prefrontal EEG"**
([2404.08199](https://arxiv.org/abs/2404.08199), 2024) is the best-matched
paper found: it targets **prefrontal** EEG specifically (closest available
literature to AF7/AF8), reports 99.62% artifact-detection accuracy for
eye-movement contamination with low enough compute cost (0.66M
multiplications per 5s segment) to be plausible for real-time use, and is
a much finer-grained approach than `SLEEP_CYCLE_DESIGN.md`'s current R3
motion-artifact handling (amplitude/saturation-threshold rejection only).
General EOG-removal literature (LSTM+ICA: 2308.13371; U-Net denoising:
2009.08809, 2111.10026; BiLSTM+wavelet: 2209.11980) mostly assumes either
a dedicated simultaneous EOG reference channel or multi-channel ICA
source separation — **neither is available on this 4-channel montage with
no reference EOG channel**, so these methods don't transfer directly; the
cepstral/SVM approach in 2404.08199 is the more realistic template since
it works from the contaminated signal alone.

| Artifact source | Spectral signature | Applicability to TP9/AF7/AF8/TP10 |
|---|---|---|
| Eye movement (EOG) | Low-frequency (<4 Hz), high amplitude, strongest frontally | AF7/AF8 most affected; matches 2404.08199's target site |
| Muscle tension (EMG) | Broadband, >20 Hz | Temporalis near TP9/TP10; can mimic beta/gamma |
| 60 Hz line noise | Narrowband spike at 60 Hz (US) | All channels; standard notch filtering applies, not montage-specific |
| Cardiac pulse propagation | Quasi-periodic, ~1 Hz | Possible at TP9/TP10 (mastoid-adjacent); not separately characterized in literature found |
| Sweat/motion baseline drift | Very low frequency (<0.5 Hz), slow | All channels; matches `SLEEP_CYCLE_DESIGN.md` R3's amplitude-drift heuristic |

---

## Implications for NeuralCompose

**Established practice** (safe to build on directly): linear CKA and
SVCCA as similarity tools (used within their valid N-vs-dimension range);
LLM cascades as a cost-accuracy strategy (FrugalGPT); sparse/single-
channel wearable EEG sleep staging as a viable approach in general.

**Emerging practice** (promising, not yet a settled recipe): conformal
prediction for confidence-threshold calibration; self-supervised
pretraining to reduce labeled-data requirements for wearable sleep
staging (directly actionable for `SLEEP_CYCLE_DESIGN.md` §21).

**Speculative** (would be a novel contribution, not literature to cite and
apply): conformal-prediction coverage guarantees for a 3-candidate,
brain-signal-committed carousel specifically; any claim about TP9/TP10
mastoid-adjacent signal quality for sleep staging, since no paper found
here characterizes that electrode position for this purpose.

**To the Stage 3.4 audit:** treat the RQ2 (geometry) pilot numbers as
methodologically out-of-range per CKA/SVCCA's own literature (N=10 vs
d=384), not just "small-sample, revisit later"; flag the SVCCA fixed-k=4
truncation and the Procrustes "orthogonal" vs. "scaled" terminology
mismatch as concrete, fixable implementation issues.

**To the Stage 3.5 design:** ground `3.5-E` (confidence-based selection)
in the existing top-1/top-N candidate-probability signal and the AdaEDL/
first-token-confidence literature, not an assumed full-logprob API; treat
"expose richer confidence signal from `MLXNextWordPredictor`" as a
prerequisite engineering task; frame `3.5-D` (cascades) explicitly as
FrugalGPT-style sequential escalation.

**To the overnight EEG study:** add an explicit ground-truth reference
signal to the protocol design, and validate TP9/TP10 signal usefulness
before committing further design effort to the 4-class `SleepStage`
scheme.

---

## Annotated Bibliography

| Citation | Why it matters here |
|---|---|
| Kornblith, Norouzi, Lee, Hinton, "Similarity of Neural Network Representations Revisited," [1905.00414](https://arxiv.org/abs/1905.00414), 2019 | Canonical CKA paper; states the exact N-vs-dimension failure mode NeuralCompose's Stage 3.4-C pilot runs into |
| Raghu, Gilmer, Yosinski, Sohl-Dickstein, "SVCCA," [1706.05806](https://arxiv.org/abs/1706.05806), 2017 | Canonical SVCCA paper; defines the adaptive variance-threshold truncation the code's fixed k=4 deviates from |
| Davari, Horoi, Natik, Lajoie, Wolf, Belilovsky, "Reliability of CKA as a Similarity Measure in Deep Learning," [2210.16156](https://arxiv.org/abs/2210.16156), 2022 | Empirical critique of CKA's sensitivity to transformations/outliers; supports treating small-N CKA values as unreliable |
| Jazayeri, Ostojic, "Interpreting neural computations by examining intrinsic and embedding dimensionality of neural activity," [2107.04084](https://arxiv.org/abs/2107.04084), 2021 | Review explaining why participation-ratio dimensionality estimates are sample-size-bound at small N |
| Gower, Dijksterhuis, *Procrustes Problems*, Oxford University Press, 2004 (book, no arXiv ID) | Classical taxonomy distinguishing orthogonal (rotation-only) from scaled Procrustes — grounds the terminology fix |
| Chen, Zaharia, Zou, "FrugalGPT," [2305.05176](https://arxiv.org/abs/2305.05176), 2023 | Canonical LLM-cascade paper; direct template for hypothesis 3.5-D |
| Agrawal, Jeon, Lee, "AdaEDL," [2410.18351](https://arxiv.org/abs/2410.18351), 2024 | Entropy-of-drafted-logits stopping rule; closest architectural match to what `MLXNextWordPredictor` can expose without a rewrite |
| Chen, Ju, Qi, "How Confident Is the First Token?," [2603.18009](https://arxiv.org/abs/2603.18009), 2026 | First-token-confidence gating of an expensive fallback step; structural analog of hypothesis 3.5-E |
| Van der Laan, Alaa, "Self-Calibrating Conformal Prediction," [2402.07307](https://arxiv.org/abs/2402.07307), 2024 | Data-driven confidence-threshold calibration with coverage guarantees; emerging practice for policy thresholds |
| Xi, Huang, Liu, Feng, Wei, "Does confidence calibration improve conformal prediction?," [2402.04344](https://arxiv.org/abs/2402.04344), 2024 | Companion critique — calibration and CP efficiency don't automatically align; caution for naive threshold-setting |
| Koushik, Amores, Maes, "Real-Time Sleep Staging using Deep Learning on a Smartphone for a Wearable EEG," [1811.10111](https://arxiv.org/abs/1811.10111), 2018 | Establishes viability of single-channel, on-device sleep staging (PSG-validated) |
| Estevan, Sierra-Torralba, López-Larraz, Montesano, "SSL for Label-Efficient Sleep Staging with Wearable EEG," [2510.07960](https://arxiv.org/abs/2510.07960), 2025 | PSG-validated wearable-headband benchmark; template for bootstrapping with little labeled data |
| Lepold, Leichtle, Röddiger, Beigl, "Feasibility of In-Ear Single-Channel ExG for Wearable Sleep Monitoring," [2509.07896](https://arxiv.org/abs/2509.07896), 2025 | Closest channel-sparsity analog to NeuralCompose's proposal; realistic (lower) accuracy ceiling and weak (non-PSG) ground truth as cautionary comparator |
| Han, Zhang, Lei, Han, Du, Wang, Bai, Zhang, "Cepstral Analysis Based Artifact Detection... for Prefrontal EEG," [2404.08199](https://arxiv.org/abs/2404.08199), 2024 | Best-matched artifact-detection method for the AF7/AF8 site specifically; doesn't require a reference EOG channel |

*Search coverage note:* this review used arXiv only. Muse-specific
consumer-EEG validation studies against PSG most likely exist in clinical/
HCI venues (e.g. *Sleep*, *Sleep Medicine Reviews*, JMIR, IEEE
Transactions on Biomedical Engineering) with weaker arXiv preprint
coverage than ML venues — a direct search for "Muse headband EEG
validation" returned no relevant results here (only unrelated astronomy
papers sharing the "MUSE" acronym). If Muse-specific validation literature
is needed, it should be sought outside arXiv.
