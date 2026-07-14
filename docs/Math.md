# Math

This document is the single mathematical reference for the entire
NeuralCompose architecture — EEG signal processing, sleep-state
estimation, semantic embeddings, generation metrics, embedding
stability, joint-embedding fusion, and pipeline evaluation.

It is a reader-friendly supplement; the canonical type-level
specifications are in `SLEEP_CYCLE_DESIGN.md` and
`docs/architecture/embedding_contract.md`.

---

## 1. Multichannel EEG Representation

The Muse S provides 4 unipolar EEG channels referenced to the internal
CMS/DRL at Fpz:

$$
X(t)=
\begin{bmatrix}
x_{\mathrm{TP9}}(t)\\
x_{\mathrm{AF7}}(t)\\
x_{\mathrm{AF8}}(t)\\
x_{\mathrm{TP10}}(t)
\end{bmatrix}
\in\mathbb{R}^{4\times N}.
$$

- **TP9, TP10**: behind-the-ear reference electrodes (mastoids).
- **AF7, AF8**: forehead electrodes above the eyebrows.

The 12-bit ADC quantizes at $\approx 0.49\,\mu\text{V}/\text{LSB}$ with a
full-scale range of $\pm 1000\,\mu\text{V}$, which is adequate for the EEG
band up to $\sim 50\,\text{Hz}$ (above 50 Hz the quantization noise
dominates).

---

## 2. Windowed Epoch

A windowed epoch is a slice of the multichannel time series:

$$
W_i = X\bigl[t_i : t_i + T_{\text{epoch}}\bigr].
$$

For communication mode: $T_{\text{epoch}} = 2\,\text{s}$, stride $=
1\,\text{s}$ (50% overlap).  For sleep staging: $T_{\text{epoch}} =
30\,\text{s}$, stride $= 5\,\text{s}$ (matches the AASM 30-second epoch
convention).

---

## 3. Band Power (Welch's Method)

For a windowed single-channel signal $w \in \mathbb{R}^N$ with sample
rate $f_s$:

1. **Detrend:** $w' = w - \bar{w}$.
2. **Segment** $w'$ into $K$ overlapping segments of length $L$ with
   overlap $L/2$ (50%).
3. **Apply Hann window** to each segment $k$:
   $w_k'' = w_k' \cdot h$, where
   $h_n = 0.5 - 0.5\cos(2\pi n / L)$.
4. **Compute the Welch estimate** — the averaged, window-normalized
   periodogram across all $K$ segments:

$$
\hat{S}_{xx}(f)
=
\frac{1}{K\,U}
\sum_{k=1}^{K}
\left|
\mathcal{F}\{w_k''\}(f)
\right|^2,
$$

where $K$ is the number of segments, $h$ is the Hann window, and $U$ is
the window energy normalization:

$$
U = \sum_{n=0}^{L-1} h_n^2.
$$

5. **Integrate over a band** $b$:

$$
P_b
=
\int_{f \in \text{band}_b}
\hat{S}_{xx}(f)\,df
\;\approx\;
\sum_{f \in \text{band}_b}
\hat{S}_{xx}(f)\;\Delta f.
$$

The integral form is the standard continuous-domain definition; the
discrete summation is the numerical approximation used in code (Riemann
sum with bin width $\Delta f$).

Standard bands:

| Band | Range (Hz) | Use |
|------|-----------|-----|
| Delta | 0.5 – 2 | N3 / slow-wave sleep |
| Theta | 4 – 8 | N1, REM proxy |
| Alpha | 8 – 13 | Wake (eyes-closed), relaxation |
| Beta | 13 – 30 | Active thinking, arousal |
| EMG proxy | > 20 | Muscle contamination, jaw clench |

---

## 4. Alpha-Dropout Ratio

The classic AASM N1 onset signature is *alpha dropout*: alpha power
drops below 50% of the per-user eyes-closed baseline. We compute it as a
ratio:

$$
r_\alpha(t)
=
\frac{P_\alpha^{\mathrm{baseline}}}{P_\alpha(t)}.
$$

- $r_\alpha = 1$: alpha power at the baseline level.
- $r_\alpha > 1$: alpha power *below* baseline (i.e., dropping out).
  $r_\alpha > 2$ is the canonical N1 threshold.
- $r_\alpha < 1$: alpha power *above* baseline (deep relaxation,
  possible meditation).

Since clinicians often reason in decibels, we also define:

$$
r_\alpha^{\mathrm{dB}}(t) = 20\,\log_{10}\!\bigl(r_\alpha(t)\bigr).
$$

A 50% drop ($r_\alpha = 2$) corresponds to
$r_\alpha^{\mathrm{dB}} \approx 6\,\text{dB}$.

The baseline $P_\alpha^{\mathrm{baseline}}$ is per-user, established from
a 30-second eyes-closed calibration window at session start. Drift
across nights is documented; we re-establish the baseline from the first
eyes-closed window each session if a separate calibration is not run.

**Note on Muse S specifics.** The Muse S's 12-bit ADC and 256 Hz sample
rate are adequate for the alpha band. The 0.5–2 Hz delta band is the
noise floor for the device — per-channel noise RMS is ~0.5 µV in clean
conditions, which is near the 0.49 µV LSB. Slow-wave detection in N3 is
therefore weaker than in clinical PSG (which uses 16+ bit ADCs at
500 Hz).

---

## 5. Theta/Alpha Ratio (REM Proxy)

A common REM proxy when chin EMG is unavailable is the theta/alpha ratio:

$$
\rho_{\theta/\alpha}(t)
=
\frac{P_\theta(t)}{P_\alpha(t)}.
$$

In REM, alpha drops out and theta rises, so $\rho_{\theta/\alpha}$
increases. We do **not** treat this as a REM detection; we treat it as a
*flag* that the system labels as `.uncertain_rem` when
$\rho_{\theta/\alpha} > \tau$ and alpha is low and EMG proxy is low. The
output is `Uncertain_REM`, not `REM`, precisely because Muse S cannot
measure atonia.

A reasonable threshold: $\tau \approx 1.5$ (theta power > 1.5× alpha
power). This is empirical; the literature is mixed on the exact value.

---

## 6. Softmax Classifier

The Core ML classifier is a small CNN on a 30s × 4ch × 128-bin
log-magnitude spectrogram (see `SLEEP_CYCLE_DESIGN.md` §16.3 for the
architecture). Its output is a 4-class softmax:

$$
p(c \mid W_i)
=
\frac{
\exp\!\bigl(z_c(W_i)\bigr)
}{
\sum_{c'}
\exp\!\bigl(z_{c'}(W_i)\bigr)
},
\qquad
c \in \{\mathrm{Wake},\;\mathrm{N1},\;\mathrm{N2\_N3},\;\mathrm{Uncertain\_REM}\}.
$$

where $z_c(W_i)$ is the pre-softmax logit for class $c$. The classifier
is trained on a labeled dataset (Sleep-EDFx with channel-mapping
transfer, or per-user labeled data when available) and quantized to
FP16 for ANE.

---

## 7. Temporal Smoother

Single-epoch predictions are noisy. The smoother aggregates the last
$k$ predictions (default $k = 60$ epochs = 30 minutes at 30s epochs) and
applies AASM transition rules.

**Majority-vote estimate.** Let $y_i \in \mathcal{C}$ be the classifier
output for epoch $i$. The smoothed label at time $t$ is:

$$
\hat{y}_t
=
\arg\max_{c \in \mathcal{C}}
\sum_{i=t-k+1}^{t}
\mathbf{1}[y_i = c].
$$

**AASM transition rules.** Sleep stages do not skip. The transition
graph is:

$$
\mathrm{Wake} \leftrightarrow \mathrm{N1} \leftrightarrow \mathrm{N2\_N3}
$$
$$
\mathrm{N2\_N3} \leftrightarrow \mathrm{Uncertain\_REM}
$$

(Direct Wake ↔ N2_N3 is forbidden; the smoother will not emit such a
transition regardless of classifier confidence.)

**Override rules:**

- If a stage has $p > 0.9$ confidence for 3+ consecutive epochs, allow
  it even if the AASM rules would block the transition.
- If 5+ consecutive Wake epochs occur after a TMR cue, abort the cue
  budget (passive recording only).

This is a heuristic; the override thresholds are tuned on per-user data.
The smoother is a value type, so it is testable in isolation.

---

## 8. State-Transition Function (FSM)

The session FSM is a value type with a pure-function
`step(_:current:)` method. Using the conventional $s$ for state:

$$
s_{t+1} = g(s_t,\;o_t,\;b_t),
$$

where $s_t$ is the current session state (phase), $o_t$ is the
observation (a `SmoothedSleepStage`, a timer tick, or an event), and
$b_t$ is the `TMRBudget` (5 cues/night max, 15-min min interval, 2 wake
attempts). Budget exhaustion is enforced in code by the
`DreamSessionController` actor, which calls $g$ and refuses to emit
`playTMRcue` or `initiateWake` actions when the budget is exhausted.

The transition table is in `SLEEP_CYCLE_DESIGN.md` §3.3.

---

## 9. Event-Driven Controller

The `DreamSessionController` actor subscribes to the EEG stream, the
smoother, the FSM, and the LLM. It publishes a `DreamSessionSnapshot`
via a `BoundedAsyncChannel` for the SwiftUI view to consume.

The channel is the only way the UI sees the session state. The UI is
read-only; the controller is the single source of truth. This is the
same pattern as `TextCompositionController` in the communication-mode
pipeline.

---

## 10. Validation: Eyes-Closed Alpha Rise

The validation session on 2026-07-10 measured
$P_\alpha^{\text{closed}} / P_\alpha^{\text{open}}$ at 3.08× on TP9,
2.07× on AF7, 2.78× on TP10. This is a calibration observation on a
single participant, not a normative threshold. The pipeline produces the
data; the ratio is a property of the data.

For a population estimate, repeat the protocol across $N \geq 5$
participants, compute the per-participant ratio, and report the median
and 95% CI. The literature consensus is 2–3× alpha rise on eyes-closed
for frontal derivations; the calibration observation is consistent with
that range.

---

## 11. Semantic Embedding Pipeline

The 3D workspace's semantic layer (`SentenceEmbedder` → `Embedding` →
`EmbeddingProjecting`) is a separate pipeline from the sleep/EEG math
above — it turns composed text into a 3D point, not a signal into a sleep
stage. Full invariants are in
[`docs/architecture/embedding_contract.md`](architecture/embedding_contract.md);
this is the reader-friendly derivation of the two pieces of actual math
involved.

**L2 normalization and cosine similarity.** Every `SentenceEmbedder`
conformer (the deterministic stub, `CoreMLSentenceEmbedder`) returns a
unit-norm vector:

$$
\hat{\mathbf{v}}
=
\frac{\mathbf{v}}{\|\mathbf{v}\|_2},
\qquad
\|\mathbf{v}\|_2 = \sqrt{\textstyle\sum_i v_i^2}.
$$

Because both operands are already unit-norm, similarity between two
embeddings is a plain dot product rather than the general cosine
formula's division by both magnitudes:

$$
\cos(\hat{\mathbf{v}}_1,\;\hat{\mathbf{v}}_2)
=
\hat{\mathbf{v}}_1 \cdot \hat{\mathbf{v}}_2
=
\sum_i \hat{v}_{1,i}\,\hat{v}_{2,i}
\;\in [-1,\,1].
$$

This is what `Embedding.cosineSimilarity(to:)` computes, and it's the
semantic contract the golden replay fixtures (`semantic_stub_v1.json`,
`semantic_bge_small_v1.json`) pin per-backend: e.g. under the real
BGE-small conversion,
$\cos(\text{"sleep"},\;\text{"light sleep"}) \approx 0.86$ versus
$\cos(\text{"sleep"},\;\text{"banana"}) \approx 0.54$ — genuine
semantic clustering, unlike the deterministic stub's token-overlap
structure, which is decorative by design (see the contract's §3.4
non-guarantee).

**Random projection (display only).** `RandomProjectionProjector`
reduces an arbitrary-dimension embedding
$\mathbf{v} \in \mathbb{R}^d$ (32 for the stub, 384 for BGE-small) to
the 3D point the SceneKit workspace actually renders, via a fixed,
seeded Rademacher matrix
$R \in \{+\tfrac{1}{\sqrt{d}},\;-\tfrac{1}{\sqrt{d}}\}^{3 \times d}$:

$$
R_{ij} \in \left\{+\frac{1}{\sqrt{d}},\;-\frac{1}{\sqrt{d}}\right\},
\qquad
\mathbf{y} = R\,\mathbf{v},
\qquad
\mathbf{y} \in \mathbb{R}^3.
$$

Each entry $R_{ij}$ is drawn uniformly from
$\{+1/\sqrt{d},\;-1/\sqrt{d}\}$ (the $\pm 1/\sqrt{d}$ Rademacher
construction), which is the variance-preserving variant. This makes the
matrix explicit rather than appearing from nowhere.

This is a Johnson–Lindenstrauss-style projection: it approximately
preserves *relative distances* between points, which is a much weaker
property than "nearby points are semantically similar." Spatial proximity
in the workspace is therefore a display convenience, not evidence of
semantic similarity on its own — the cosine similarity above is the
actual semantic signal; the projection is only how it gets drawn. A
fitted projector (PCA, once an embedding corpus exists to fit on) is
the anticipated replacement, behind the same `EmbeddingProjecting`
protocol, with no change to `SentenceEmbedder` or `Embedding`.

---

## 12. Joint Embedding Fusion

Stage 3.4 evaluates whether combining embeddings from multiple models
improves retrieval quality. Given $n$ embedding models producing
embeddings $\mathbf{v}_1, \mathbf{v}_2, \dots, \mathbf{v}_n$ for the
same input text, two fusion strategies are evaluated:

**Concatenation fusion:**

$$
\mathbf{z}
=
\operatorname{concat}\bigl(w_1\,\mathbf{v}_1,\;
w_2\,\mathbf{v}_2,\;\dots,\;
w_n\,\mathbf{v}_n\bigr),
$$

where $w_i$ are scalar weights (uniform or learned).

**Projected fusion (shared latent space):**

$$
\mathbf{z}
=
\sum_{i=1}^{n}
w_i\,P_i\,\mathbf{v}_i,
$$

where $P_i$ projects model $i$'s embedding into a shared latent space
(via PCA, CCA, or a learned projection), and $w_i$ are learned or
policy weights.

**Late fusion (rank aggregation):** Rather than fusing in embedding
space, late fusion aggregates the top-$k$ retrieval rankings from each
model independently:

$$
\text{rank}_{\text{fused}}(j)
=
\sum_{i=1}^{n}
w_i \cdot \text{rank}_i(j),
$$

where $\text{rank}_i(j)$ is the rank of item $j$ under model $i$.

The metric for evaluating fusion is the **separation ratio** (intra-group
mean cosine / cross-group mean cosine) and **retrieval top-1 accuracy**.
See Stage 3.4 hypothesis registry for success criteria.

---

## 13. Generation Metrics

The generation benchmark evaluates LLM rewrite quality on the
NeuralCompose prompt corpus.

**Latency** (time to first token):

$$
L = t_{\text{first token}} - t_{\text{request}}.
$$

**Throughput** (tokens per second):

$$
T = \frac{N_{\text{tokens}}}{\Delta t}.
$$

**Prompt echo rate** (fraction of prompt tokens that leaked into the
output):

$$
E = \frac{|P \cap O|}{|P|},
$$

where $P$ is the set of prompt tokens and $O$ is the set of output
tokens. $E = 0$ is ideal (no echo); $E > 0$ indicates the model is
repeating the input.

**Decoder loop score** (maximum repeated $n$-gram count):

$$
D = \max_n r_n,
$$

where $r_n$ is the count of the most frequently repeated $n$-gram in
the output. High $D$ indicates the model is stuck in a repetition loop.

**Cosine similarity to reference** (semantic quality):

$$
\text{sim} = \cos\bigl(\hat{\mathbf{v}}_{\text{output}},\;
\hat{\mathbf{v}}_{\text{reference}}\bigr),
$$

where both vectors are L2-normalized embeddings of the model's output
and the expected rewrite, respectively.

---

## 14. Embedding Stability

The embedding benchmark evaluates robustness of embedding models to
ASR errors, typos, hesitations, fillers, punctuation changes, and
capitalization variants.

**Per-sample stability** under perturbation $\delta$:

$$
S(x,\;\delta)
=
\cos\!\bigl(\hat{\mathbf{v}}_{e(x)},\;
\hat{\mathbf{v}}_{e(\delta(x))}\bigr),
$$

where:

- $x$ is the original utterance,
- $\delta$ is a perturbation function (e.g., ASR error, typo insertion,
  hesitation/filler injection, punctuation removal, case change),
- $e(\cdot)$ is the embedding function,
- $\hat{\mathbf{v}}_{e(\cdot)}$ is the L2-normalized embedding.

**Aggregate stability** across $N$ test samples:

$$
\bar{S}
=
\frac{1}{N}
\sum_{i=1}^{N}
S(x_i,\;\delta(x_i)).
$$

$\bar{S} \to 1$ means the model is perfectly robust to the perturbation
class; $\bar{S} < 0.9$ indicates meaningful semantic drift. The
benchmark evaluates six perturbation classes: ASR errors, typos,
hesitations, fillers, punctuation, and capitalization.

---

## 15. Pipeline Evaluation Metrics

Stage 3.5 evaluates complete embedding → retrieval → generation
pipelines.

**Pipeline score** (weighted composite):

$$
\text{score}_{\text{pipeline}}
=
\alpha \cdot \text{sim}_{\text{rewrite}}
+
\beta \cdot \text{acc}_{\text{retrieval}}
-
\gamma \cdot \text{latency}_{\text{total}},
$$

where $\alpha$, $\beta$, $\gamma$ are policy-dependent weights (see
Stage 3.5 policy registry: Fast, Balanced, Quality, Adaptive).

**Pareto frontier.** A pipeline $P_a$ dominates $P_b$ if
$P_a$ is at least as good on every axis (quality, latency, memory) and
strictly better on at least one. The Pareto-optimal set is:

$$
\mathcal{P}
=
\{P \mid \nexists P' : P' \succeq P \;\text{on all axes}\}.
$$

**Adaptive routing gain.** When routing queries to different embedding
models by input type, the improvement over the best fixed model is:

$$
\Delta_{\text{adaptive}}
=
\frac{\text{acc}_{\text{adaptive}} - \text{acc}_{\text{best\_fixed}}}
{\text{acc}_{\text{best\_fixed}}}.
$$

Stage 3.5 pre-registers the hypothesis that
$\Delta_{\text{adaptive}} \geq 3\%$.