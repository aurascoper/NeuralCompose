# SVD for Four-Channel NeuralCompose EEG: Decision Memo v1

**Date:** 2026-07-23
**Status:** foundational study only
**Applies to:** proposed SVD studies adjacent to, but not part of,
[`EXP-NC-EEG-ENC-001`](../../NeuralComposeEEG/experiments/EXP-NC-EEG-ENC-001.md)

## Executive decision

Singular value decomposition (SVD) is justified in the NeuralCompose EEG
program as a numerical diagnostic and as a *controlled, train-only* method to
test a small number of explicitly different representations. It is not
justified as an automatic preprocessing stage, a replacement for direct signal
quality checks, a source-localization method, or a live/runtime dependency.

The immediate program remains at:

```yaml
status: pipeline_ready_for_first_capture
data_gate: D0
decision: insufficient_evidence
promotion_status: not_eligible
live_control: false
```

There are no eligible physical recordings at D0. Therefore this memo changes
no acquisition, labels, preprocessing, M0-M4 budget, or model architecture.
It creates four proposed studies only:

| Proposal | Earliest gate | Decision it can change | Current disposition |
| --- | --- | --- | --- |
| `EXP-NC-SVD-DIAG-001` | D1 for physical reporting; D0 for synthetic fixtures | whether singular-spectrum reports add capture/feature diagnosis beyond direct checks | eligible to preregister, not yet run |
| `EXP-NC-SVD-M0-001` | D2 | whether a train-only PCA/truncated-SVD feature path merits a separate M0 sensitivity result | deferred until an eligible grouped cohort exists |
| `EXP-NC-SVD-REP-001` | D3 | whether representation effective-rank diagnostics are stable across held-out sessions and controls | deferred |
| `EXP-NC-SVD-INV-001` | D3 and a separate forward-model hypothesis | whether a synthetic inverse problem benefits from a specified regularizer | deferred Pass 2 |

The primary conclusion is:

```yaml
status: foundational_study_only
```

In particular, `EXP-NC-EEG-ENC-001` remains the unchanged four-channel,
observable-label, complete-session benchmark. A low-rank plot is not encoder
generalization, and an SVD result cannot alter the application.

## Program boundary and data gates

This memo uses the following study-local meanings. They name evidence gates;
they do not authorize a change to the acquisition contract.

| Gate | Evidence available | Permitted SVD work |
| --- | --- | --- |
| D0 | frozen code/configuration and synthetic fixtures only | unit fixtures, numerical reconstruction checks, documentation, and benchmark design |
| D1 | one protocol-complete capture that passes integrity validation | read-only, per-capture diagnostic reports; no encoder training or physical-data model claim |
| D2 | multi-day, source-manifest-eligible pilot cohort | session-grouped, non-promotable controlled evaluations |
| D3 | confirmation-ready multi-session evidence sufficient for a separately registered follow-up | descriptive representation studies and a separately specified synthetic forward/inverse study |
| post_encoder | an encoder selected offline and exposed through a frozen structured-state contract | offline compression or computational tooling review only |

All activity remains subject to the source and evaluation contracts in
[`NeuralComposeEEG/README.md`](../../NeuralComposeEEG/README.md),
[`PROTOCOL.md`](../../NeuralComposeEEG/PROTOCOL.md), and
[`ADAPTER_CONTRACT.md`](../../NeuralComposeEEG/ADAPTER_CONTRACT.md). In
particular, `TP9`, `AF7`, `AF8`, and `TP10` at 256 Hz, four-second/1,024-sample
windows, one-second stride, calibration-only normalization, and complete
recording-session splits remain fixed.

## Mathematical primer tied to NeuralCompose matrices

### Core factorization

For a real or complex matrix `A` in `K^(m x n)`, where `K` is `R` or `C`, its
reduced SVD is

```text
A = U Sigma V^H
```

where `k = min(m, n)`, `U` has orthonormal columns, `V` has orthonormal
columns, `V^H` is the transpose for real matrices and conjugate transpose for
complex matrices, and

```text
sigma_1 >= sigma_2 >= ... >= sigma_k >= 0.
```

`rank(A)` is exactly the number of nonzero singular values in exact
arithmetic. `U` describes modes in the row-side space of `A`; `V` describes
modes in its column-side space. The singular values quantify the strength of
the paired modes. Singular-vector signs, and rotations inside a repeated
singular-value subspace, are not unique. A report may compare subspaces or
sign-invariant quantities, but must not treat the sign of one vector as a
scientific result.

For the current raw spatial window, use a channel-centered matrix

```text
X_window in R^(4 x 1024).
```

Its left singular vectors are four-channel spatial mixtures and its right
singular vectors are time-domain patterns *for that one window*. This does not
make `U` a source map, and it does not make `V` an oscillator model.

The spectral norm is `||A||_2 = sigma_1`. The Frobenius norm is

```text
||A||_F = sqrt(sum_i sigma_i^2).
```

For a full-column/full-row-rank rectangular matrix, the 2-norm condition
number is `kappa_2(A) = sigma_1 / sigma_k`; it is infinite when `A` is rank
deficient. These are exact definitions. Calling a finite singular value
"effectively zero" is a numerical decision, not an exact statement.

### Low rank, pseudoinverse, and stability

The rank-`r` truncated reconstruction is

```text
A_r = U[:, :r] Sigma[:r, :r] V[:, :r]^H.
```

The Eckart-Young-Mirsky theorem exactly states that `A_r` is a best rank-`r`
approximation under both the spectral and Frobenius norms. Its errors are

```text
||A - A_r||_2 = sigma_(r+1)
||A - A_r||_F^2 = sum_(i > r) sigma_i^2.
```

The theorem does *not* state that the retained components are physiological,
that a selected rank generalizes, or that a threshold represents signal rather
than artifact.

The Moore-Penrose pseudoinverse is

```text
A^+ = V diag(1 / sigma_i for sigma_i > 0) U^H.
```

It gives the minimum-norm least-squares solution `x = A^+ b`. Small singular
values make `1 / sigma_i` large, so a naively computed pseudoinverse can
amplify noise. That fact is exact. Whether a small value represents noise, a
redundant feature, a bad channel, or a real but weak mode depends on the
matrix construction and noise model.

For an additive perturbation `E`, singular values obey the exact Weyl bound

`|sigma_i(A + E) - sigma_i(A)| <= ||E||_2`. Singular *subspaces* can be much
less stable when neighboring singular values have a small gap. Wedin-style
subspace bounds formalize this dependency. Consequently, the program must
report spectra, gaps, precision, and threshold sensitivity rather than publish
one unstable singular vector as an interpretation.

### SVD, eigendecomposition, PCA, and whitening

For a centered data matrix `Z` with rows as observations,

```text
Z^T Z = V Sigma^2 V^T.
```

Thus the right singular vectors are covariance eigenvectors, after the
appropriate `1/(n-1)` scaling. Computing SVD of `Z` avoids explicitly forming
`Z^T Z`, which squares its condition number. For a symmetric covariance or
cross-spectral density matrix, a Hermitian eigendecomposition (`eigh`) is
usually the more direct operation. On a positive semidefinite covariance
matrix, singular values and eigenvalues coincide; using SVD there is not a new
method.

PCA projects onto leading right singular vectors. Whitening additionally
divides retained component scores by a singular-value-derived scale. Whitening
therefore magnifies low-variance directions unless an explicit floor is used.
PCA/whitening parameters are learned transformations: every mean, scale,
component, retained rank, and floor must be fit inside the training partition
only. A held-out session may only be transformed with the matching fold's
stored parameters.

### Regularization as singular-value filtering

For a linear inverse or least-squares problem `Ax approx b`, truncated SVD
uses filter factors

```text
f_i = 1 / sigma_i                 for i <= r
f_i = 0                           for i > r.
```

Tikhonov regularization with identity penalty solves

`min_x ||Ax - b||_2^2 + lambda ||x||_2^2` and uses smooth filters

```text
f_i(lambda) = sigma_i / (sigma_i^2 + lambda).
```

Both reduce amplification of weak directions, but they encode different bias
assumptions. The useful rank or `lambda` must be chosen from training/synthetic
evidence specified before test evaluation. Neither belongs in the current
multiclass logistic M0 merely because the formulas exist: logistic regression
does not solve the ordinary least-squares system `Ax = b`.

### Randomized, incremental, block, weighted, and generalized variants

Randomized SVD approximates a target subspace using random test vectors and
power iterations. It is an algorithmic approximation, not a different
scientific representation. It is only interesting when a full decomposition
is a profiled bottleneck on a large matrix. The `4 x 1024` spatial window and
the current roughly 52-column M0 feature matrix are too small to justify it.
If later used, seed, oversampling, power iterations, normalizer, residual
error, and exact rank must be part of the artifact.

Incremental/streaming SVD trades exact batch results for update rules and
forgetting/ordering choices. NeuralCompose has no authorized online SVD path,
and a streaming decomposition would be a data-dependent stateful transform.
It is not justified for Pass 1.

Block/batched SVD simply applies the same operation to many independent
matrices, for example a batch of `4 x 1024` diagnostic windows. It is a
computational implementation detail, not an aggregation across sessions and
not a license to fit a global transform.

Weighted SVD is appropriate only after weights are identified with an explicit
measurement-noise covariance, reliability model, or loss. Per-channel contact
quality is not automatically such a covariance. A weight chosen after seeing
test performance would be leakage.

The generalized SVD can be useful for a pair such as a forward operator `G`
and a nonidentity regularization operator `L` in a future inverse problem.
There is no present two-operator NeuralCompose problem that needs it, so it is
not recommended now.

## Four-channel geometry: what can and cannot be learned

### Raw spatial window

`X_window` has at most four nonzero spatial singular values. That small bound
has practical consequences:

| Observation | What a spatial spectrum can show | Stronger or necessary companion |
| --- | --- | --- |
| flat/disconnected channel | a near-zero mode or reduced rank | channel variance, missing mask, amplitude range |
| duplicated/near-duplicated channel | a small fourth singular value | pairwise correlation and difference RMS |
| common-mode contamination | large first energy fraction `sigma_1^2 / sum sigma_i^2` | all pairwise correlations and amplitude/saturation checks |
| left/right frontal or temporal relationship | one particular four-channel mixture for a window | fixed channel-order provenance; no anatomical/source claim |
| contact degradation | a changed spectrum relative to calibration | signal-quality fields and a protocol-defined fault check |
| movement/saturation | sometimes a large shared mode or rank change | explicit amplitude, clipping, transport, and protocol artifact labels |

SVD contributes a compact *joint* redundancy measure. It does not contain
information that magically bypasses the direct checks, and, with only four
channels, it will often agree with variance and correlation. That is why
`EXP-NC-SVD-DIAG-001` must demonstrate incremental defect-detection value
before a spectrum is treated as a useful diagnostic.

Condition number depends on centering and scaling. A raw-amplitude condition
number and a calibration-z-scored condition number answer different questions.
Any diagnostic report must label which it computed and preserve the complete
four-value spectrum. It must not turn a heuristic numerical-rank threshold
into automatic capture rejection without a separately approved contract
change.

### Different matrices answer different questions

| Matrix | Example shape | Modes mean | Current disposition |
| --- | --- | --- | --- |
| raw spatial window | `4 x 1024` | channel mixtures and time patterns within one window | optional D1 diagnostic only |
| time-lag/Hankel window | `L x (1025-L)` per channel | delay-coordinate/SSA components | Pass 3 study only |
| M0 feature matrix | `n_train x 52` approximately | collinear deterministic-feature directions | optional D2 controlled experiment |
| spectrogram | `frequency x time` per channel or stacked channels | time-frequency patterns of a chosen transform | Pass 3 study only |
| cross-spectral density | `4 x 4` complex Hermitian per band | coherent spatial spectral modes | use Hermitian eigendecomposition; Pass 3 only |
| encoder activation matrix | `n_windows x embedding_dim` | variation in a named model layer | descriptive Pass 3 analysis |
| participant/session by feature matrix | `n_sessions x p` | between-session structure | requires enough sessions; never a window-level substitute |
| lead-field/forward matrix | `n_sensors x n_sources` | observable and poorly observable source directions | Pass 2 synthetic work only |

These factorizations are not interchangeable. In particular, a low rank in a
Hankel matrix is not evidence for a low rank in channel space, and an embedding
rank does not measure physical sensor rank.

## Direct use versus deferral

| SVD application | Classification | Earliest gate | Decision it could change | Why |
| --- | --- | --- | --- | --- |
| per-window spatial spectrum as a read-only diagnostic | B. Optional Pass 1 controlled experiment | D1 | retain or retire an additional report field, never current capture eligibility | only useful if it improves synthetic/known-defect detection beyond direct checks |
| M0 feature-matrix rank/conditioning report | B. Optional Pass 1 controlled experiment | D2 | whether an SVD-aware M0 sensitivity experiment is warranted | captures multi-feature collinearity that per-feature variance misses |
| train-only PCA / non-whitened truncated feature path | B. Optional Pass 1 controlled experiment | D2 | whether a separate M0 representation improves grouped calibration/generalization | must beat unchanged M0 and matched random projection |
| train-only whitening | B. Optional Pass 1 controlled experiment | D2 | whether scaling component scores adds value beyond PCA | likely to amplify weak directions; never a default |
| PCA followed by ICA | D. Pass 3 computational or analysis tooling | D3 | whether an explicitly registered artifact-inspection method adds value | independence and convergence assumptions need their own study |
| Hankel/SSA/DMD-style temporal study | D. Pass 3 computational or analysis tooling | D3 | whether a defined temporal diagnostic changes a later analysis decision | no existing short-horizon target or stationarity claim |
| spectrogram/CSD rank analysis | D. Pass 3 computational or analysis tooling | D3 | whether a defined artifact or frequency-structure report adds value | CSD should use `eigh`; phase must be preserved |
| SVD-stabilized pseudoinverse for current M0 logistic classifier | F. Not justified | none | none | pseudoinverse solves least squares, not the current logistic objective |
| EEGNet activation/kernel rank | D. Pass 3 computational or analysis tooling | D3 | whether representation collapse/stability warrants a later study | diagnostic only; cannot alter training from a plot |
| EEGPT/BENDR embedding effective rank | D. Pass 3 computational or analysis tooling | D3 | whether a descriptive representation follow-up is justified | not evidence of transfer without the existing controls/metrics |
| randomized SVD | F. Not justified now | post_encoder if profiled large matrix exists | computational implementation only | tiny matrices make exact reduced SVD cheaper and simpler |
| incremental/streaming SVD | F. Not justified | none | none | no authorized online adaptive transform |
| batched SVD | D. Pass 3 computational or analysis tooling | D1/D3 depending matrix | CPU implementation choice after a registered diagnostic exists | not a scientific method by itself |
| weighted SVD | C. Pass 2 inverse/forward-model method | D3 | stability of a specified noise-weighted synthetic inverse model | needs an explicit covariance/weight model |
| generalized SVD | F. Not justified now | future Pass 2 only if `G,L` are registered | none currently | no concrete paired-operator problem |
| low-rank deployment compression | D. Pass 3 computational or analysis tooling | post_encoder | whether a selected offline model can meet a stated resource budget within output tolerance | cannot precede model selection |
| TSVD/Tikhonov inverse regularization | C. Pass 2 inverse/forward-model method | D3 | a synthetic reconstruction decision only | no four-channel source-localization claim |

No application is classified A, Required Pass 1 diagnostic. Existing variance,
range, missing-mask, packet-loss, signal-quality, and pairwise-correlation
checks already satisfy the current integrity contract. An SVD report earns a
required status only after a registered study establishes that it changes an
integrity decision more accurately or more reproducibly.

## Leakage-safe use rules

These rules apply to every data-derived factorization, including a convenient
one-off notebook.

1. Build complete-session folds before any fit. Windows from one recording
   never cross a train/test boundary.
2. For a learned transform, fit means, scales, component vectors, whiteners,
   rank thresholds, and selection rules using training windows only. Store a
   fold-specific artifact hash.
3. A held-out session may be transformed with that fold's stored transform.
   It may not fit components, normalization, rank, numerical threshold, or a
   global visualization geometry.
4. The current causal calibration normalization remains a fixed input
   contract. An SVD study must not reuse held-out task windows to fit a new
   normalizer or treat calibration-derived session normalization as permission
   to fit a held-out PCA/whitener.
5. Rank selection cannot use final held-out performance. A training-only rule
   must be fixed in the experiment contract and recorded per fold.
6. Bind each transform to the canonical `dataset_sha256`, preprocessing hash,
   feature-extractor hash, split-manifest hash, train-window-hash digest,
   retained rank, numerical threshold, dtype, library version, and seed where
   randomness exists.
7. Full-corpus PCA and plots are exploratory only. They cannot tune labels,
   rank, quality thresholds, or a confirmatory conclusion.
8. Preserve label shuffles, channel-map shuffles, no-SVD, and matched-rank
   random-projection controls. An SVD benefit that vanishes under grouped
   evaluation is retired.

## Candidate matrix-specific analyses

### Acquisition integrity

For `X_window`, calculate a read-only tuple after direct integrity checks:

```text
singular_values[4]
energy_fraction[4]
stable_rank_entropy = exp(-sum p_i log p_i), p_i = sigma_i^2 / sum sigma_j^2
condition_number_if_sigma_4_above_pinned_floor
```

This tuple is *not* a label, rejection rule, or M0 feature in the first
study. The baseline is the currently available deterministic check set:
channel variance, amplitude range, pairwise correlation, packet loss,
signal-quality fields, and missing-channel mask. Synthetic fixtures create
known flat, duplicated, common-mode, and full-rank/noisy cases. A physical
capture report may only state agreement or disagreement with those checks; it
cannot infer an unobserved fault.

### PCA and whitening

The only justified near-term PCA matrix is the standardized deterministic M0
feature matrix `Z_train` of a fold. The current feature extractor produces
per-channel variance/amplitude/spectral features, six correlations,
line-noise ratio, quality fields, and channel-observed flags. A PCA condition
would be evaluated only in a new study under the same grouped splits and
unchanged labels.

The preregistered rank rule should be: smallest `r` whose *training-only*
explained-variance ratio reaches 0.95, bounded by `1 <= r <= min(p,
n_train - 1)`. The threshold is a heuristic design choice, not a theorem; its
0.90 and 0.99 sensitivity results must be reported without selecting the best
test result. A matched random orthogonal projection uses the same `r` for each
fold. Whitening uses the same training components plus a pinned singular-value
floor and is reported separately.

`PCA -> ICA` may be compared only later with the identical folds and outputs.
It adds independence and convergence assumptions and must not be used to
relabel a protocol block or to repair artifact windows. It is not a current
preprocessing recommendation.

### Temporal low-rank structure

For one channel `x[0:1023]`, a Hankel embedding might have

`H[i, j] = x[i + j]`, with an explicitly pinned lag `L`. SVD of `H` supports
singular spectrum analysis (SSA); reconstructed components require a stated
anti-diagonal averaging rule. Dynamic mode decomposition and subspace
identification require time-shifted state matrices and make stronger dynamical
and stationarity assumptions. Autoregressive modeling is often a simpler,
direct prediction baseline.

None of these currently has a registered target or decision. A narrowband
looking singular spectrum is not enough to add a temporal denoiser, claim an
attractor, or infer a short-horizon state transition. Treat them as Pass 3
study material only.

### Spectral and time-frequency matrices

SVD may summarize a real channel-by-frequency magnitude matrix or a
time-frequency spectrogram. It can show that a fixed transform is dominated by
a few modes, but cannot itself distinguish artifact from neural activity.
Broadband movement, stable rhythms, and line contamination must be tested
against known/protocol-observable artifact contexts and direct spectral
baselines.

For a complex cross-spectral density `C(f)`, use a Hermitian eigendecomposition
because `C = C^H`; phase is in its complex off-diagonal terms. If an SVD API is
used, it must use the conjugate transpose and complex dtype, and report why an
eigendecomposition was not sufficient. `complex128` is the default for
condition/rank diagnostics; `complex64` is acceptable only after a recorded
agreement check on the decision statistic.

### M0 numerical stability

The present M0 is already an L2-regularized logistic regression with `C = 1.0`
and a training-fold `StandardScaler`; it is not an unregularized least-squares
model. SVD can diagnose the standardized `n_train x p` feature matrix and can
define a separate truncated-feature sensitivity condition. It should not be
introduced as a disguised replacement for the registered M0.

A matched future comparison has four roles:

| Condition | Mathematical role | Status |
| --- | --- | --- |
| unchanged M0 logistic regression | primary benchmark baseline | required baseline |
| unregularized logistic regression | conditioning stress diagnostic, if separability permits | secondary only |
| existing L2 logistic regression | ridge-like regularized discriminative baseline | unchanged M0 |
| train-only truncated-SVD/PCA features then same L2 logistic head | data-adaptive feature-reduction test | proposed condition |
| SVD/QR least-squares one-vs-rest score | numerical teaching/control only | not a replacement for calibrated logistic M0 |

An SVD pseudoinverse may solve a continuous least-squares control problem or
verify a linear algebra implementation. It cannot claim mathematical
equivalence to the current multiclass logistic classifier, and must not be
selected by held-out accuracy.

### Encoder and pretrained representation diagnostics

For EEGNet, a study may collect named layer activations and learned weights
from each already-trained fold. For EEGPT/BENDR it may collect only the
contract-permitted, fold-scoped adapter outputs or frozen representation
outputs tied to the canonical split. Candidate summaries are singular spectrum,
energy rank, entropy effective rank, and reconstruction error at a
preregistered rank.

The analysis must be descriptive. Activation matrices from held-out windows can
be summarized after scoring, but no global transform fit across held-out
sessions may steer model selection. Per-session comparisons need fixed sample
counts or a stated weighted estimator so a long session does not dominate. A
pretrained representation with a desirable rank profile has not transferred
unless it passes the existing M0, M1, random-init, shuffled-map, zero-fill,
calibration, and grouped-metric controls.

## Adjacent-method comparison

| Method | Overlap with SVD | Assumptions and robustness | Four-channel disposition |
| --- | --- | --- | --- |
| QR | stable least-squares and rank-revealing variants | no low-rank optimum by itself; usually cheaper for a full-rank solve | prefer for an explicitly full-rank least-squares solve; no M0 change |
| Cholesky | ridge/normal-equation solve | requires positive-definite system; normal equations worsen conditioning when unregularized | implementation choice for a well-regularized linear study, not diagnostic |
| eigendecomposition | PCA/covariance/CSD modes | square symmetric/Hermitian matrix; covariance formation squares conditioning | use for CSD/covariance where appropriate |
| NMF | low-rank components | requires nonnegative representation and nonnegative additive interpretation | raw signed EEG: not justified; spectral-power study later only |
| ICA | unmixing/artifact inspection | independence/non-Gaussianity, convergence, component ambiguity | Pass 3 only, after PCA if a registered question demands it |
| robust PCA | low-rank plus sparse decomposition | sparse-outlier model and optimization choices | not justified without synthetic artifact test and a decision target |
| tensor decompositions | multiway low-rank structure | enough independent modes/sessions and rank choices | deferred; not needed for `4 x 1024` windows |
| autoencoders | learned nonlinear compression | training data, architecture, optimization, and leakage risk | not justified for Pass 1 |
| random projections | dimension-reduction control | preserves distances probabilistically, not data-adaptive modes | required matched-rank control for PCA studies |
| ridge regression | smooth spectral shrinkage in a linear solve | loss/objective must match target | current M0 already uses L2 logistic regularization |
| CCA | paired-view correlation | requires a legitimate paired continuous view and grouped fitting | no current paired target; dialogue is prohibited |

## Numerical implementation and reproducibility

### Python

No new Python dependency is justified. The benchmark already has NumPy, SciPy,
scikit-learn, and PyTorch.

| Need | Recommendation | Reproducibility rule |
| --- | --- | --- |
| tiny diagnostics | `numpy.linalg.svdvals` or reduced `numpy.linalg.svd` | record NumPy/LAPACK version, dtype, matrix shape, threshold |
| explicit LAPACK driver or `compute_uv=False` | `scipy.linalg.svd` / `svdvals` | retain `lapack_driver`, finite-input policy, and library version |
| M0 PCA | `sklearn.decomposition.PCA(svd_solver="full")` | fit in fold pipeline only; artifact contains mean/components/rank hashes |
| randomized comparison, only if later profiled | `sklearn.utils.extmath.randomized_svd` | pin seed, rank, oversamples, power iterations, normalizer, residual error |
| neural activation spectra | `torch.linalg.svdvals` after a fixed model run | use values/subspaces, not signs; record device/dtype and copy timing |

NumPy documents reduced and stacked SVD behavior; SciPy exposes the
`gesdd`/`gesvd` driver choice; scikit-learn documents full and randomized PCA
solvers; and PyTorch warns that singular vectors are nonunique and gradients
through close/repeated singular values can be unstable. See the linked
[NumPy](https://numpy.org/doc/stable/reference/generated/numpy.linalg.svd.html),
[SciPy](https://docs.scipy.org/doc/scipy/reference/generated/scipy.linalg.svd.html),
[scikit-learn PCA](https://scikit-learn.org/stable/modules/generated/sklearn.decomposition.PCA.html),
[randomized SVD](https://scikit-learn.org/stable/modules/generated/sklearn.utils.extmath.randomized_svd.html),
and [PyTorch](https://docs.pytorch.org/docs/stable/generated/torch.linalg.svd)
references.

### Julia

Julia is a reference environment, not a benchmark/runtime dependency. For a
separate scientific workspace, use `LinearAlgebra.svd(X; full=false)` and
`svdvals(X)` for exact reduced decompositions. Record `VERSION`, the active
BLAS/LAPACK backend, `Project.toml`/`Manifest.toml` hashes, dtype, and matrix
layout. `MultivariateStats.jl` is reasonable only for a separately registered
PCA/ICA study; its observation-orientation convention must be checked before
comparing it to Python. Do not introduce an incremental or randomized package
without a maintained implementation and a measured full-SVD bottleneck.

`Optim.jl` is unnecessary for ordinary PCA, TSVD, or identity-Tikhonov
calculations; closed-form linear algebra is more transparent. JuMP with
MathOptInterface is appropriate only after a future study writes down an
actual constrained optimization problem. MathProgBase is not to be used.
The [Julia LinearAlgebra documentation](https://docs.julialang.org/en/v1/stdlib/LinearAlgebra/)
is the authoritative API reference.

### Apple Silicon and cloud compute

| Workload | Default executor | Why | Cloud/MPS rule |
| --- | --- | --- | --- |
| one/batched `4 x 1024` spatial diagnostics | local CPU through NumPy/SciPy or Julia BLAS/LAPACK | CPU launch and transfer overhead dominate | do not move to GPU merely for SVD |
| M0 `n_train x about-52` feature analysis | local CPU | small dense factorization and exact full SVD are cheap | no randomized/GPU SVD |
| activation/embedding matrix inspection | same executor that produced artifact, then profile local CPU | avoid transfer/copy and preserve provenance | MPS/GPU only after batch size and transfer measurement justify it |
| large, already-authorized public/external embedding matrix | profile CPU and GPU honestly | may become throughput-bound | cloud is never a reason to upload local EEG; follow existing data/provenance policy |
| Julia reference notebook | local Julia BLAS/LAPACK | reproducible small-matrix science | inspect actual BLAS backend; do not assume Accelerate |

Apple's Accelerate framework supplies BLAS/LAPACK routines, but it does not
make every small decomposition GPU work. PyTorch's documented SVD driver
selection is CUDA-specific; an MPS request must be benchmarked rather than
assumed equivalent. A benchmark record must include matrix dimensions, batch
size, dtype, warm-up count, host/device transfer time, compute time, peak
memory, reconstruction error, algorithm/library versions, and determinism
status. Apple's [Accelerate](https://developer.apple.com/documentation/accelerate)
documentation is the relevant local CPU API reference.

### Precision guide

| Quantity | Default dtype | Escalate when | Do not do |
| --- | --- | --- | --- |
| raw/window diagnostic spectrum | float64 | small singular values or condition estimates affect a decision | report a float32 rank threshold as physical truth |
| M0 PCA transform | float64 fit; transform may be checked in float32 | fold rank/metrics disagree across dtype | fit or choose rank with held-out data |
| neural activation spectrum | float32 acceptable for descriptive scale | rank/condition conclusion changes against float64 | backpropagate through singular vectors as a stability feature |
| CSD/eigen diagnostic | complex128 | phase/near-null modes matter | drop conjugation or phase silently |
| deployment compression | selected model's native dtype plus float64 audit | output tolerance is near boundary | introduce float16 only for nominal speed |

Machine epsilon is part of numerical-rank behavior. A conventional numerical
threshold such as `tau = eps(dtype) * max(m,n) * sigma_1` is a library-scale
heuristic, not a physiological cutoff. Record the full spectrum and report
sensitivity to a small preregistered threshold set. FP32 is usually sufficient
for ordinary activation summaries; FP64 is warranted for condition numbers,
weak modes, reconstruction audits, and any conclusion that depends on small
singular values. FP16 is not justified for condition/rank estimates.

## Falsification and retirement rules

Retire SVD from an active role in the relevant study when any registered
criterion is met:

- direct variance/correlation/range/mask/transport checks match defect
  detection and have equal or lower false-positive rate;
- a training-only retained-rank rule varies materially across grouped folds or
  its apparent gain disappears under complete-session evaluation;
- a matched-rank random projection performs equivalently;
- a feature reduction helps only by reducing dimension, with no advantage over
  a non-SVD matched control;
- calibration, artifact recognition, or abstention behavior worsens;
- a result depends on a held-out fit, selected threshold, or a global PCA;
- effective-rank conclusions reverse under reasonable dtype/threshold choices;
- a purported benefit is confined to one session, one configuration, or one
  model condition;
- compute/memory complexity exceeds its independently measured benefit.

## Glossary

| Term | Meaning here |
| --- | --- |
| SVD | factorization `A = U Sigma V^H` for a real or complex matrix |
| PCA | training-data projection onto leading covariance eigenvectors/right singular vectors |
| ICA | model-based attempt to find statistically independent components; not equivalent to PCA or SVD |
| pseudoinverse | `A^+`, the minimum-norm least-squares operator; not a logistic classifier |
| truncated SVD | retain a fixed first `r` singular components and discard the rest |
| Tikhonov regularization | smooth least-squares regularization using factors `sigma/(sigma^2 + lambda)` for identity penalty |
| effective rank | a threshold- or entropy-derived summary of a spectrum, not exact algebraic rank |
| condition number | `sigma_1/sigma_min` in the 2-norm; measures sensitivity of a linear solve and depends on scaling |

## References

- G. H. Golub and C. F. Van Loan, *Matrix Computations*, 4th ed. (SVD,
  conditioning, least squares, and perturbation foundations).
- P. C. Hansen, *Rank-Deficient and Discrete Ill-Posed Problems* (TSVD and
  Tikhonov filter-factor interpretation).
- N. Halko, P.-G. Martinsson, and J. A. Tropp, "Finding structure with
  randomness," *SIAM Review* 53(2), 2011,
  [doi:10.1137/090771806](https://doi.org/10.1137/090771806).
- The current NeuralCompose four-channel scope and experimental contracts cited
  above are authoritative over this educational primer.
