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

## 9. Statistical Evaluation

Recommended evaluation reports include:

- bootstrap confidence intervals
- Mann–Whitney U
- Cohen's d
- Pareto frontier
- effect sizes
- hypothesis preregistration

These sections align with the Stage 3.4 and Stage 3.5 evaluation
framework.