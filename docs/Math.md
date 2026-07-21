# Math

## Purpose

This document provides mathematically consistent derivations for the
NeuralCompose pipeline.

## 1. EEG Signal

$$
\mathbf{X}(t) \in \mathbb{R}^{4 \times N}
$$

with TP9, AF7, AF8, TP10 channels.

## 2. Welch Spectral Density

$$
\hat{S}_{xx}(f) = \frac{1}{K\,U} \sum_{k=1}^{K} \left| \mathcal{F}\{w_k h\}(f) \right|^2
$$

Band power:

$$
P_b = \int_{f_1}^{f_2} \hat{S}_{xx}(f)\,df \approx \sum_i \hat{S}_{xx}(f_i)\,\Delta f
$$

## 3. Alpha Dropout

$$
r_\alpha = \frac{P_\alpha^{\mathrm{baseline}}}{P_\alpha}, \qquad r_\alpha^{\mathrm{dB}} = 20\,\log_{10}(r_\alpha)
$$

## 4. Softmax

$$
p(c \mid W) = \frac{e^{z_c(W)}}{\sum_{c' \in \mathcal{C}} e^{z_{c'}(W)}}
$$

## 5. Embeddings

Unit normalization:

$$
\hat{\mathbf{v}} = \frac{\mathbf{v}}{\|\mathbf{v}\|_2}
$$

Cosine similarity:

$$
\cos(\hat{\mathbf{v}}_1, \hat{\mathbf{v}}_2) = \hat{\mathbf{v}}_1^\top \hat{\mathbf{v}}_2
$$

## 6. Random Projection

$$
\mathbf{y} = R\,\mathbf{v}, \qquad R \in \left\{\pm\frac{1}{\sqrt{d}}\right\}^{3 \times d}
$$

## 7. Joint Embeddings

*(Definition only — joint/fused representations are RQ5, deferred to
Stage 3.4-B/F; no fusion has been evaluated as of the 2026-07-14
Stage 3.4 freeze.)*

$$
\mathbf{z} = \frac{\operatorname{concat}(w_i\,\mathbf{v}_i)}{\left\|\operatorname{concat}(w_i\,\mathbf{v}_i)\right\|_2}
$$

## 8. Decoder Stability

Define

$$
D = \max_n r_n
$$

where $r_n$ is the repeat count of an immediately repeated period-$n$
token sequence.

Recommended metrics:

- decoder loop period
- decoder loop repeat count
- prompt echo detection
- stop reason
- generation length

## 9. Representation Alignment (Stage 3.4-C)

Metrics computed pairwise between embedding models in
`Evaluation/scripts/embedding_space_analysis.py`. See
`docs/research/methodology-review_v1.md`/`v2.md` Pillar A for the
literature review these formulas and caveats are drawn from.

### 9.1 CKA (Centered Kernel Alignment)

Kornblith, Norouzi, Lee, and Hinton, *"Similarity of Neural Network
Representations Revisited"* ([1905.00414](https://arxiv.org/abs/1905.00414),
2019).

$$
\mathrm{CKA}(X,Y) = \frac{\mathrm{HSIC}(X,Y)}{\sqrt{\mathrm{HSIC}(X,X)\,\mathrm{HSIC}(Y,Y)}},
\qquad
\mathrm{HSIC}(X,Y) = \frac{1}{(n-1)^2}\operatorname{tr}(KHLH)
$$

with $K = XX^\top$, $L = YY^\top$, $H$ the centering matrix. The code
mean-centers $X,Y$ before the trace, which is algebraically equivalent to
the $H$-centered form, and computes the **biased**, linear-kernel HSIC
estimator (no debiasing term). Valid only when $n \gg d$; at $n$ close to
or below $d$, CKA (and CCA-family statistics generally) cannot reliably
measure representational similarity — see Kornblith et al.'s own stated
limitation, and Davari, Horoi, Natik, Lajoie, Wolf, and Belilovsky,
*"Reliability of CKA as a Similarity Measure in Deep Learning"*
([2210.16156](https://arxiv.org/abs/2210.16156), 2022) for further
characterization of CKA's sensitivity to outliers and certain
transformation classes.

### 9.2 SVCCA (Singular Vector CCA)

Raghu, Gilmer, Yosinski, and Sohl-Dickstein, *"SVCCA: Singular Vector
Canonical Correlation Analysis for Deep Learning Dynamics and
Interpretability"* ([1706.05806](https://arxiv.org/abs/1706.05806), 2017).

Truncate each representation's SVD to the smallest $k$ whose top-$k$
singular directions explain a target fraction $\tau$ (default
$\tau = 0.99$) of that representation's variance — an adaptive threshold,
not a fixed direction count, per the original method:

$$
k_X = \min\left\{k : \frac{\sum_{i=1}^{k}\sigma_i^2}{\sum_i \sigma_i^2} \ge \tau\right\}
$$

computed independently for $X$ (giving $k_X$) and $Y$ (giving $k_Y$).
Project onto the retained left-singular directions
$U_X^{(k_X)}, U_Y^{(k_Y)}$, then take the mean canonical correlation
between the two projected subspaces (singular values of the cross
product):

$$
\mathrm{SVCCA}(X,Y) = \frac{1}{\min(k_X,k_Y)}\sum_i \mathrm{svd}\!\left(U_X^{(k_X)\top} U_Y^{(k_Y)}\right)_i
$$

### 9.3 Procrustes alignment — two distinct metrics

**Scaled (superimposition).** `scipy.spatial.procrustes`: translate both
$X,Y$ to the origin, rescale both to unit Frobenius norm, then find the
optimal rotation. Tolerant of scale differences between the two spaces —
answers "are these the same shape, ignoring size."

**Orthogonal (rotation-only).** Schönemann (1966); Gower & Dijksterhuis,
*Procrustes Problems* (Oxford University Press, 2004). No rescaling —
finds only the rotation minimizing residual error, so a scale mismatch
between $X$ and $Y$ shows up as disparity rather than being silently
absorbed:

$$
\mathrm{disparity} = \frac{\min_{R^\top R = I} \|XR - Y\|_F^2}{\|Y\|_F^2},
\qquad X^\top Y = U\Sigma V^\top \implies R = UV^\top
$$

reported as a relative residual (normalized by $\|Y\|_F^2$) rather than
the raw squared norm, so that values are comparable across pairs with
different sample counts or embedding magnitudes — scaled Procrustes gets
this normalization for free from its unit-norm rescale; the rotation-only
variant has to normalize explicitly since it deliberately skips that
rescale.

These answer different questions and are not interchangeable: a pair of
embedding spaces can have near-zero scaled-Procrustes disparity (same
shape) while having large orthogonal-Procrustes disparity (badly
misaligned once scale isn't corrected for). Report both; do not treat one
as a relabeling of the other.

### 9.4 Intrinsic dimensionality (participation ratio)

Jazayeri and Ostojic, *"Interpreting neural computations by examining
intrinsic and embedding dimensionality of neural activity"*
([2107.04084](https://arxiv.org/abs/2107.04084), 2021).

$$
\mathrm{PR} = \frac{\left(\sum_i \lambda_i\right)^2}{\sum_i \lambda_i^2}
$$

over the eigenspectrum $\{\lambda_i\}$ of the representation's covariance
matrix. Bounded above by $n-1$ samples, not by the true geometric
dimensionality — at small $n$ (e.g. $n=10$), $\mathrm{PR}$ close to $n-1$
reflects the sample-to-dimension ratio, not necessarily a genuine
low-dimensional signal.

## 10. Statistical Evaluation

Recommended evaluation reports include:

- bootstrap confidence intervals
- Mann–Whitney U
- Cohen's d
- Pareto frontier
- effect sizes
- hypothesis preregistration

These sections align with the Stage 3.4 and Stage 3.5 evaluation
framework.

## 11. Cross-Project Measurement Primitives

Companion to §2–3, §8, and §9 above and to `Research.md`, drawing on the
representation-geometry / spectral-preprocessing review.

**Scope rule.** This section unifies *instruments*, not *theories*. Every
definition below must change a reported number in at least one project; nothing
here justifies an algorithm change on its own (cf. "philosophy is documentation,
never justification"; "no speculative abstraction unless ≥2 call sites exist").
No shared latent space is asserted — heterogeneous embeddings remain coupled,
not fused (§7 stays deferred).

### 11.1 Eigenspectrum descriptors — (PR, α) as a pair

Given a representation matrix $Z \in \mathbb{R}^{n \times d}$ with centered
covariance eigenvalues $\lambda_1 \ge \dots \ge \lambda_d \ge 0$:

- **Participation ratio (second-moment effective dim; = §9.4):**
$$\mathrm{PR}(Z) = \frac{\left(\sum_i \lambda_i\right)^2}{\sum_i \lambda_i^2}$$

- **RankMe (entropy effective dim):** with singular values $\sigma_k$ of $Z$ and
$p_k = \sigma_k / \sum_j \sigma_j + \varepsilon$,
$$\mathrm{RankMe}(Z) = \exp\!\Big(-\sum_k p_k \log p_k\Big)$$

- **α-ReQ (eigenspectrum decay slope):** fit $\lambda_i \sim i^{-\alpha}$ by OLS
of $\log\lambda_i$ on $\log i$.

**PR and RankMe are the same family** (Simpson vs. Shannon summaries of the same
spectrum); **α is orthogonal** to both — it measures *shape*, not magnitude. Two
representations can share PR while differing in α.

**Use.** Report every representation in the stack — per-user EEG latent, each
embedding model in `embedding_space_analysis.py`, the synthetic JEPA latent — as
the pair $(\mathrm{PR}, \alpha)$. The generalization-favorable regime is near
$\alpha \approx 1$ (α-ReQ; verify the exact interval before citing a number — it
rests on companion benign-overfitting theory, not a single sentence in the
source).

**Caveat (inherited).** PR/RankMe are bounded by $\min(n-1, d)$; at $n \approx d$
(e.g. $n=10$) both reflect the sample-to-dimension ratio, not geometry. See §9.4.

### 11.2 Aperiodic-adjusted spectral features (specparam)

Replace/augment the raw band power of §2 and the alpha ratio of §3. Fit the
log-power spectrum as an aperiodic component plus periodic peaks (specparam /
FOOOF, "fixed" aperiodic mode):
$$\log_{10}\hat S(f) \approx \underbrace{b - \chi\,\log_{10} f}_{\text{aperiodic } \hat L(f)} \;+\; \sum_j \mathcal{G}_j(f)$$
so in linear power $\hat L(f) = 10^{b} f^{-\chi}$.

- **Aperiodic exponent $\chi$ is a first-class feature** (this is the "1/f slope"
the whole preprocessing question turns on) — not a nuisance to be log-compressed
away.
- **Aperiodic-adjusted band power** (the oscillatory signal, aperiodic removed):
$$P_b^{\mathrm{osc}} = \int_{f_1}^{f_2} \big[\hat S(f) - \hat L(f)\big]_+ \, df$$
- **Corrected alpha dropout (§3 upgrade):** compute $r_\alpha$ from
$P_\alpha^{\mathrm{osc}}$ (aperiodic-removed alpha), so a broadband aperiodic shift
no longer masquerades as an alpha change:
$$r_\alpha^{\mathrm{corr}} = P_\alpha^{\mathrm{osc}} / P_{\alpha,\text{baseline}}^{\mathrm{osc}}, \qquad r_{\alpha,\mathrm{dB}}^{\mathrm{corr}} = 20\log_{10} r_\alpha^{\mathrm{corr}}$$

**Serves both stacks.** Same front-end for the awake NeuralCompose pipeline and
the sleep study's EEG. **`Research.md` upgrade:** the exploratory hypothesis
"theta power ↔ dream relevance" becomes "aperiodic exponent $\chi$ during N2/SWS
↔ insight quality" — literature-backed (aperiodic slope indexes E/I balance and
varies across sleep stages), hence pre-registerable rather than post-hoc.

**Decision (transform choice), most→least information-preserving:** (1) specparam
channels $\{\chi, b, P_b^{\mathrm{osc}}\}$; (2) learned/affine normalization or
symlog for scale-robustness; (3) log band power (current — conflates periodic +
aperiodic; keep only if a forward benchmark beats 1–2); (4) aggressive 1/f
flattening (only if a forward benchmark shows the aperiodic component is nuisance
for the task). Never default to (4).

### 11.3 Trajectory novelty / collapse functional

Unifies §8 (decoder loop count $D$), JEPA representation collapse, and the
`Research.md` novelty outcome. For a trajectory of states
$\tau = (\tau_1,\dots,\tau_T)$ with centered covariance eigenvalues $\lambda_i$:
$$N_{\mathrm{PR}}(\tau) = \frac{\left(\sum_i \lambda_i\right)^2}{\sum_i \lambda_i^2}$$
Low $N_{\mathrm{PR}}$ ⇒ the generative/predictive rollout occupied a
low-dimensional subspace (collapse / looping). Three instantiations:

| Project | Trajectory states $\tau_t$ | Interpretation |
|---|---|---|
| WorldModel (JEPA) | rolled-out latent states | low $N_{\mathrm{PR}}$ = degenerate dynamics; soft companion to VICReg variance floor |
| NeuralCompose decode (§8) | emitted-token embeddings | $D$ is the exact-repeat corner; $N_{\mathrm{PR}}$ also catches paraphrastic near-loops ($D{=}1$ but $N_{\mathrm{PR}}\!\approx\!2$–3). $N_{\mathrm{PR}} \supseteq D$ in coverage |
| Sleep study (D8) | LLM-extracted analogy embeddings | effective count of *distinct* analogical directions |

**`Research.md` contribution (pre-register before D8):**
- Report $N_{\mathrm{PR}}$ over the analogy set as an **automated novelty score**,
secondary to the blind human Likert (H1).
- Pre-register **Spearman $\rho(N_{\mathrm{PR}}\text{-novelty}, \text{mean blind
human novelty})$** and report it beside the LLM–human agreement of H4.
- Optionally: does $N_{\mathrm{PR}}$ separate Active vs. Control? (automated
companion to H1.)

Passes the "must change a measured number" bar in all three projects
simultaneously.

### 11.4 Cross-representation alignment — pilot-scale caveat

The §9 metrics (CKA, SVCCA, scaled/orthogonal Procrustes) answer the review's
"are the EEG latent and the language/solution latent *coupled* spaces?" question
directly. **Do not run this at pilot N.**

With $n \approx 20$–$30$ matched (EEG-state, solution-embedding) pairs and $d$ in
the hundreds, we are in the $n \not\gg d$ regime where §9's own caveat (and
Kornblith et al.; Davari et al.) says CKA/SVCCA cannot be trusted. Required
before any alignment claim:
1. Reduce each space to $k \ll n$ dimensions first (the SVCCA $\tau$-truncation
of §9.2), then compare; **or**
2. Defer the EEG↔language coupling analysis to the definitive trial.

Report **both** Procrustes variants (scaled = shape-only; orthogonal =
rotation-only, scale-sensitive) — they are not interchangeable (§9.3).

### 11.5 Boundaries (what these primitives do NOT claim)

- **No shared latent** for EEG + language + world-state + memory. Coupled via
learned cross-attention/alignment; §7 concatenation remains deferred and is the
wrong fusion.
- **No cross-validation between the two research programs.** The D8 sleep study
does not validate the JEPA architecture, nor vice versa — orthogonal questions,
no logical dependency.
- **No label-free metric is an oracle.** $(\mathrm{PR},\alpha)$, $N_{\mathrm{PR}}$,
RankMe can all fail (RankMe shows no correlation with some downstream tasks; all
break under collapse). Anchor promotion to a downstream number — MPC success
(WorldModel) or blind human novelty (D8) — never to a geometry statistic alone.