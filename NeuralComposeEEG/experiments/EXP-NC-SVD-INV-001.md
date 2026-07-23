# EXP-NC-SVD-INV-001: Synthetic Inverse Regularization

**Status:** proposed, deferred Pass 2 study
**Classification:** C. Pass 2 inverse/forward-model method
**Earliest gate:** D3, with a separately approved forward-model hypothesis
**Promotion status:** not_eligible
**Physical Muse source-localization claim:** false
**Runtime dependency:** prohibited

## Question

> In a synthetic forward model with known source and noise structure, do TSVD
> or Tikhonov regularizers improve reconstruction error and stability relative
> to an unregularized pseudoinverse?

## Required Preregistration

Before execution, specify the discretized forward operator G, sensor and source
geometry, conductivity model, boundary assumptions, source target, noise
distribution/covariance, penalty operator L, generator seeds, regularization
selection rule, metrics, and held-out synthetic draws.

The proposal must explain why the synthetic system is not a claim that four
Muse channels locate human cortical sources. It uses no physical Muse inverse
target.

## Conditions

Compare the unregularized pseudoinverse with training/simulation-selected TSVD
and identity-Tikhonov. Use generalized SVD only when a real nonidentity penalty
operator L exists and is justified. Evaluate on unseen synthetic source/noise
draws, with a fixed noise-level and geometry-perturbation sensitivity grid.

## Outcomes and Falsification

Report source error, forward residual, stability under noise and geometry
perturbation, resolution/null-space summaries, regularization parameter,
precision, and complete singular-value filter. Retire a regularizer when it
does not improve preregistered metrics over pseudoinverse across unseen draws,
works only at a hand-picked noise level, or has no geometry robustness.

## Artifact

Emit nc-eeg-svd-inverse-synthetic-v0 with operator and generator hashes,
geometry/noise/penalty contract, numerical provenance, and
physical_muse_claim: false. A result does not authorize app input, live
control, production code, or a physical source-localization claim.

See the [SVD experiment roadmap](../../docs/scoping/svd-eeg-experiment-roadmap.md)
for broader scope and controls.
