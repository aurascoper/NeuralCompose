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
\min_{R^\top R = I} \|XR - Y\|_F^2, \qquad
X^\top Y = U\Sigma V^\top \implies R = UV^\top
$$

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