# Math

This document gives the derivations behind the equations in the top-level
README. It is a reader-friendly supplement; the canonical type-level
specification is in `SLEEP_CYCLE_DESIGN.md`.

## 1. Multichannel EEG Representation

The Muse S provides 4 unipolar EEG channels referenced to the internal CMS/DRL
at Fpz:

$$X(t) = \begin{bmatrix} x_{\text{TP9}}(t) \\ x_{\text{AF7}}(t) \\ x_{\text{AF8}}(t) \\ x_{\text{TP10}}(t) \end{bmatrix} \in \mathbb{R}^{4 \times N}$$

- **TP9, TP10**: behind-the-ear reference electrodes (mastoids).
- **AF7, AF8**: forehead electrodes above the eyebrows.

The 12-bit ADC quantizes at $\approx 0.49 \,\mu\text{V}/\text{LSB}$ with a full-scale range of $\pm 1000 \,\mu\text{V}$, which is adequate for the EEG band up to $\sim 50 \,\text{Hz}$ (above 50 Hz the quantization noise dominates).

## 2. Windowed Epoch

A windowed epoch is a slice of the multichannel time series:

$$W_i = X[t_i : t_i + T_{\text{epoch}}]$$

For communication mode: $T_{\text{epoch}} = 2\,\text{s}$, stride $= 1\,\text{s}$ (50% overlap).
For sleep staging: $T_{\text{epoch}} = 30\,\text{s}$, stride $= 5\,\text{s}$ (matches the AASM 30-second epoch convention).

## 3. Band Power (Welch-Style)

For a windowed single-channel signal $w \in \mathbb{R}^N$ with sample rate $f_s$:

1. Detrend: $w' = w - \bar{w}$.
2. Apply Hann window: $w'' = w' \cdot h$, where $h_n = 0.5 - 0.5\cos(2\pi n / N)$.
3. Compute periodogram: $P(f) = \frac{1}{N} |\mathcal{F}\{w''\}(f)|^2$.
4. Integrate over a band $b$:

$$P_b = \sum_{f \in \text{band}_b} P(f) \cdot \Delta f$$

Standard bands:

| Band | Range (Hz) | Use |
|------|-----------|-----|
| Delta | 0.5 – 2 | N3 / slow-wave sleep |
| Theta | 4 – 8 | N1, REM proxy |
| Alpha | 8 – 13 | Wake (eyes-closed), relaxation |
| Beta | 13 – 30 | Active thinking, arousal |
| EMG proxy | > 20 | Muscle contamination, jaw clench |

## 4. Alpha-Dropout Ratio

The classic AASM N1 onset signature is *alpha dropout*: alpha power drops below
50% of the per-user eyes-closed baseline. We compute it as a ratio:

$$r_\alpha(t) = \frac{P_\alpha^{\text{baseline}}}{P_\alpha(t)}$$

- $r_\alpha = 1$: alpha power at the baseline level.
- $r_\alpha > 1$: alpha power *below* baseline (i.e., dropping out). $r_\alpha > 2$ is the canonical N1 threshold.
- $r_\alpha < 1$: alpha power *above* baseline (deep relaxation, possible meditation).

The baseline $P_\alpha^{\text{baseline}}$ is per-user, established from a 30-second eyes-closed calibration window at session start. Drift across nights is documented; we re-establish the baseline from the first eyes-closed window each session if a separate calibration is not run.

**Note on Muse S specifics.** The Muse S's 12-bit ADC and 256 Hz sample rate are
adequate for the alpha band. The 0.5–2 Hz delta band is the noise floor for
the device — per-channel noise RMS is ~0.5 µV in clean conditions, which is
near the 0.49 µV LSB. Slow-wave detection in N3 is therefore weaker than in
clinical PSG (which uses 16+ bit ADCs at 500 Hz).

## 5. Theta/Alpha Ratio (REM Proxy)

A common REM proxy when chin EMG is unavailable is the theta/alpha ratio:

$$\rho_{\theta\alpha}(t) = \frac{P_\theta(t)}{P_\alpha(t)}$$

In REM, alpha drops out and theta rises, so $\rho_{\theta\alpha}$ increases. We do **not** treat this as a REM detection; we treat it as a *flag* that the system labels as `.uncertain_rem` when $\rho_{\theta\alpha} > \tau$ and alpha is low and EMG proxy is low. The output is `Uncertain_REM`, not `REM`, precisely because Muse S cannot measure atonia.

A reasonable threshold: $\tau \approx 1.5$ (theta power > 1.5x alpha power). This is empirical; the literature is mixed on the exact value.

## 6. Softmax Classifier

The Core ML classifier is a small CNN on a 30s × 4ch × 128-bin log-magnitude spectrogram (see `SLEEP_CYCLE_DESIGN.md` §16.3 for the architecture). Its output is a 4-class softmax:

$$p(c \mid W_i) = \frac{\exp(z_c(W_i))}{\sum_{c'} \exp(z_{c'}(W_i))}, \quad c \in \{\text{Wake}, \text{N1}, \text{N2\_N3}, \text{Uncertain\_REM}\}$$

where $z_c(W_i)$ is the pre-softmax logit for class $c$. The classifier is trained on a labeled dataset (Sleep-EDFx with channel-mapping transfer, or per-user labeled data when available) and quantized to FP16 for ANE.

## 7. Temporal Smoother

Single-epoch predictions are noisy. The smoother aggregates the last $k$ predictions (default $k = 60$ epochs = 30 minutes at 30s epochs) and applies AASM transition rules.

AASM rule: sleep stages do not skip. The transition graph is:

$$\text{Wake} \leftrightarrow \text{N1} \leftrightarrow \text{N2\_N3}$$
$$\text{N2\_N3} \leftrightarrow \text{Uncertain\_REM}$$

(Direct Wake ↔ N2_N3 is forbidden; the smoother will not emit such a transition regardless of classifier confidence.)

The smoother maintains a per-stage count over the window. The output `SmoothedSleepStage` is the stage with the highest count, gated by:

- If a stage has $p > 0.9$ confidence for 3+ consecutive epochs, allow it even if the AASM rules would block the transition.
- If 5+ consecutive Wake epochs occur after a TMR cue, abort the cue budget (passive recording only).

This is a heuristic; the override thresholds are tuned on per-user data. The
smoother is a value type, so it is testable in isolation.

## 8. State-Transition Function (FSM)

The session FSM is a value type with a pure-function `step(_:current:)` method. Given the current phase and an input (a `SmoothedSleepStage`, a timer tick, an event), it returns a single action.

Concretely:

$$\text{phase}_{t+1} = g(\text{phase}_t, S_t, B_t)$$

where $S_t$ is the smoothed stage and $B_t$ is the `TMRBudget` (5 cues/night max, 15-min min interval, 2 wake attempts). Budget exhaustion is enforced in code by the `DreamSessionController` actor, which calls `g` and refuses to emit `playTMRcue` or `initiateWake` actions when the budget is exhausted.

The transition table is in `SLEEP_CYCLE_DESIGN.md` §3.3.

## 9. Event-Driven Controller

The `DreamSessionController` actor subscribes to the EEG stream, the smoother, the FSM, and the LLM. It publishes a `DreamSessionSnapshot` via a `BoundedAsyncChannel` for the SwiftUI view to consume.

The channel is the only way the UI sees the session state. The UI is read-only; the controller is the single source of truth. This is the same pattern as `TextCompositionController` in the communication-mode pipeline.

## 10. Validation: Eyes-Closed Alpha Rise

The validation session on 2026-07-10 measured $P_\alpha^{\text{closed}} / P_\alpha^{\text{open}}$ at 3.08× on TP9, 2.07× on AF7, 2.78× on TP10. This is a calibration observation on a single participant, not a normative threshold. The pipeline produces the data; the ratio is a property of the data.

For a population estimate, repeat the protocol across $N \geq 5$ participants, compute the per-participant ratio, and report the median and 95% CI. The literature consensus is 2-3× alpha rise on eyes-closed for frontal derivations; the calibration observation is consistent with that range.
