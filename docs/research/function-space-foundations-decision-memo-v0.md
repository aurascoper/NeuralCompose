# Function-Space Foundations Decision Memo v0

**Status:** D0 foundational study only
**Experiment:** `EXP-FUNC-SYN-000`
**Decision:** `insufficient_evidence`
**Promotion status:** `not_eligible`
**Runtime change:** none

## Decision

NeuralCompose will treat curve fitting, integration, differentiation, and
representation learning as operators between function or representation
spaces, while preserving the different stability and evidence questions each
operator raises.

The shared conceptual objective is:

$$
J(\theta)
=
\int_T |y(t)-f_\theta(t)|^2\,d\mu(t)
+
\lambda\int_T |D f_\theta(t)|^2\,dt
+
\gamma\Phi(E_\theta).
$$

This equation organizes questions; it does not authorize one combined
algorithm:

- $\mu$ determines how observations are weighted.
- $D$ may be a classical or weak time derivative.
- automatic differentiation computes parameter derivatives of the
  implemented finite model.
- $\Phi(E_\theta)$ belongs to the existing JEPA representation and collapse
  contracts, not to a new trainer in this package.

`EXP-FUNC-SYN-000` demonstrates these distinctions with deterministic
synthetic fixtures. It consumes no EEG, dialogue, telemetry, fallback data, or
model output and cannot establish a physical-data method.

## Empirical Measures And Identifiability

For sampled observations $(t_i,y_i)$, define:

$$
\mu_n=\frac1n\sum_{i=1}^n\delta_{t_i}.
$$

Then empirical least squares is an integral:

$$
\int |y-f_\theta|^2\,d\mu_n
=
\frac1n\sum_i |y_i-f_\theta(t_i)|^2.
$$

The induced empirical pseudometric,

$$
d_{\mu_n}(f,g)
=
\left(\int |f-g|^2\,d\mu_n\right)^{1/2},
$$

cannot distinguish functions that agree at every sampled point but differ
between samples. The quotient by equality $\mu_n$-almost everywhere is the
space visible to the empirical loss. A smooth interpolant therefore is not
recovered continuous physiology.

Dirac masses represent atomic observations or events. They do not represent
inertia. `EXP-FUNC-SYN-000` uses them only as mathematical weights.

## Measurability And Integration

Borel measurability is background that makes continuous encoders and losses
legitimate random variables or integrands. It does not require a runtime
"Borel subsystem."

Lebesgue integration is the main language for expected loss, almost-everywhere
equivalence, noisy signals, and $L^p$ spaces. Continuous and atomic components
are represented together by:

$$
d\mu(t)=\rho(t)\,dt+\sum_k w_k\delta_{t_k},
$$

so:

$$
\int f\,d\mu
=
\int f(t)\rho(t)\,dt+\sum_k w_k f(t_k).
$$

The implementation calls this a Lebesgue-Stieltjes mixed measure. It avoids
depending on unstated endpoint conventions for Riemann-Stieltjes jumps.

## Three Derivative Questions

These operations must not be conflated:

```text
signal/time derivative
  change of a function with respect to time

weak derivative
  derivative defined by integration against test functions

numerical differentiation
  estimate of a signal derivative from sampled values

automatic differentiation
  exact chain-rule derivative of implemented operations with respect
  to model inputs or parameters
```

Differentiation is unstable under weak norms. For example:

$$
f_n(t)=\frac{\sin(nt)}n
\quad\Longrightarrow\quad
\|f_n\|_\infty\to0,
\qquad
\|f_n'\|_\infty=1.
$$

A fixed-step difference operator is bounded, but its norm grows approximately
as $1/h$. Decreasing the step can therefore amplify high-frequency
perturbations even while clean discretization error falls.

ForwardDiff verifies derivatives of the finite parametric computation. It
does not stabilize or recover the time derivative of noisy sampled data.

## Sobolev And Tikhonov Fitting

For a finite basis,

$$
f_c(t)=\sum_{j=1}^m c_j\phi_j(t),
$$

the synthetic package solves:

$$
J_\lambda(c)
=
\frac1n\sum_i |y_i-f_c(t_i)|^2
+
\lambda\int_a^b |f_c'(t)|^2\,dt.
$$

With a fixed Fourier basis and analytic derivative matrix, this is
deterministic penalized least squares. Regularization is selected using
training and inner-validation synthetic sessions only; held-out sessions are
untouched until evaluation. ForwardDiff verifies the analytic parameter
gradient but is not the primary solver.

Passing this fixture means only that the finite implementation behaves as
registered. A physical EEG comparison would require a separate experiment and
must not silently change preprocessing.

## Bounded Operators And Cauchy-Schwarz

For a bounded linear operator $T$:

$$
\|Tx\|\le\|T\|\|x\|.
$$

Composition satisfies $\|ST\|\le\|S\|\|T\|$. Cauchy-Schwarz similarly bounds
inner products:

$$
|\langle f,g\rangle|\le\|f\|_2\|g\|_2.
$$

The D0 fixture measures induced L2 matrix norms for discrete derivative,
integration, and identity operators, then checks observed perturbation
amplification against those bounds. Undefined or infinite condition numbers
are recorded as such rather than replaced by finite values.

## Convergence And Approximation Cautions

### Egorov

The canonical fixture is $f_n(x)=x^n$ on $[0,1]$. It converges almost
everywhere to zero except at $x=1$, but not uniformly on the full interval.
After removing:

$$
A_\varepsilon=[1-\varepsilon,1],
$$

the remaining uniform error is:

$$
\sup_{x\in[0,1-\varepsilon]}x^n=(1-\varepsilon)^n.
$$

This is a theorem illustration. It is not an early-stopping rule, anomaly
filter, exceptional-window remover, or physical threshold.

### Riesz

Riesz's lemma warns that finite-dimensional approximation success does not
show that an infinite-dimensional unit ball has been exhausted. A compact
feature set may approximate observed samples without capturing every possible
function-space direction. The omitted directions are not automatically
physiological.

## Deferred Material

Hamiltonian and symplectic dynamics remain Pass 4 possibilities for a
separately justified synthetic latent-dynamics or control experiment. There is
no current evidence that four-channel EEG or NeuralCompose dialogue follows a
conserved Hamiltonian.

The source notation $R_0(f;(a,b))$ and the proposition that it is open remain
unresolved. The available material does not establish the definition, and no
definition, theorem connection, or implementation consequence is inferred.

## Brown-Pearcy Study Checklist

No proposition numbers are asserted.

### Normed Linear Spaces

- norm and induced metric;
- Cauchy sequences, completeness, and Banach spaces;
- finite-dimensional norm equivalence and closed subspaces;
- quotient spaces and quotient norms;
- $C[a,b]$, $\ell^p$, and $L^p$;
- distance to a closed subspace;
- Riesz's lemma;
- noncompactness of infinite-dimensional unit balls.

### Bounded Linear Transformations

- linear continuity if and only if boundedness;
- continuity at zero;
- operator norm and $\|Tx\|\le\|T\|\|x\|$;
- composition and $\|ST\|\le\|S\|\|T\|$;
- completeness of $\mathcal B(X,Y)$ when $Y$ is Banach;
- closed kernels and extension to completions;
- induced maps through $X/\ker T$;
- lower bounds and stable inversion;
- transition to open-mapping and bounded-inverse results.

These are mathematical foundations, not runtime requirements.

## Source Provenance

All sources below are background evidence only. They do not define acceptance
criteria for `EXP-FUNC-SYN-000`.

| Source | Version or page | Retrieved | Claim scope |
| --- | --- | --- | --- |
| [Encyclopedia of Mathematics: Delta-function](https://encyclopediaofmath.org/wiki/Dirac_delta-function) | web reference | 2026-07-24 | background evidence only |
| [MIT 18.125 Measure and Integration](https://ocw.mit.edu/courses/18-125-measure-and-integration-fall-2003/pages/lecture-notes/) | Fall 2003 notes | 2026-07-24 | background evidence only |
| [MIT 18.125 Egorov lecture](https://ocw.mit.edu/courses/18-125-measure-and-integration-fall-2003/resources/18125_lec13/) | Lecture 13 | 2026-07-24 | background evidence only |
| [ForwardDiff documentation](https://juliadiff.org/ForwardDiff.jl/) | package documentation; project pins 1.4.1 | 2026-07-24 | background evidence only |
| [Brown and Pearcy, Introduction to Operator Theory I](https://link.springer.com/book/10.1007/978-1-4612-9926-4) | public book metadata | 2026-07-24 | background evidence only |
| [MIT 18.102 Introduction to Functional Analysis](https://www.ocw.mit.edu/courses/18-102-introduction-to-functional-analysis-spring-2009/pages/lecture-notes/) | Spring 2009 notes | 2026-07-24 | background evidence only |

## Fixed Disposition

```yaml
experiment_id: EXP-FUNC-SYN-000
status: foundational_study_only
data_gate: D0
decision: insufficient_evidence
promotion_status: not_eligible
runtime_change: none
physical_eeg_used: false
dialogue_logs_used: false
fallback_capture_used: false
scientific_claim_allowed: false
```
