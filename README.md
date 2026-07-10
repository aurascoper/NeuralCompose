# NeuralCompose

A privacy-first, fully on-device macOS prototype for **EEG-driven communication**
and **sleep-cycle EEG research**. A Muse headband streams brain signals through
BrainFlow, a Core ML classifier on the Apple Neural Engine detects intent
(jaw clench / blink / rest / select), and a local MLX LLM suggests the next
word. The same acquisition stack is being extended for sleep-stage estimation
and AI-assisted dream-incubation experiments. **No cloud APIs. No telemetry. No
network at runtime.**

## Project Status (July 2026)

| Status | Component |
|--------|-----------|
| ✅ | Native BrainFlow integration (BLE + BCIBridge) |
| ✅ | Live Muse S acquisition (256 Hz, 4 channels) |
| ✅ | Physiological validation (eyes-open/eyes-closed alpha response, 2026-07-10) |
| ✅ | Communication-mode architecture (intent → carousel → MLX LLM) |
| ✅ | Phase B Sleep Validation Toolkit — `EEGScalpPlotterView` (3D depth-stacked) |
| 🚧 | Sleep-stage classifier (4-class: Wake / N1 / N2_N3 / Uncertain_REM) |
| 🚧 | Dream-session controller + session FSM |
| 🚧 | LLM primer generation + dream-report analogy extraction |
| 🧪 | Cognitive-incubation experiments (planned, pre-registration pending) |
| 🧪 | D8 within-subject crossover pilot (planned, OSF pre-registration pending) |

## Current Features

**Communication mode (Phase 3, complete):**
- Live Muse S EEG acquisition through BrainFlow over native BLE on macOS.
- 4-channel recording at 256 Hz, channel order `[package_num, TP9, AF7, AF8, TP10, AUX, timestamp, aux_marker]`.
- 5-class intent classifier (rest, jawClench, singleBlink, doubleBlink, select) on the Apple Neural Engine via Core ML.
- Intent smoother (5-window ring buffer, activation thresholds, refractory period).
- Carousel of next-word candidates, MLX-LLM generated, locally inferred.
- Privacy indicator showing live source / classifier mode / predictor mode at all times.
- Synthetic, BrainFlow, and playback EEG stream paths selectable from a single env var.

**Sleep validation (Phase 4, in progress):**
- `EEGScalpPlotterView` — 3D depth-stacked time-series plotter with adjustable µV/px scale and z-depth spacing, 60 Hz display-link refresh.
- Phase B debug window (`Cmd+Shift+D`) with SwiftUI host.
- `validate-muse-physiology.py` — automated 5-condition protocol (eyes-open, eyes-closed, blinks, jaw clench, head turn) with pass/fail per signature.
- `SLEEP_CYCLE_DESIGN.md` — full architectural specification (D1–D8, hypothesis registry, risk register, safety requirements, integration checklist).

## Architecture

```
                    ┌──────────────────────────────────────────────────────┐
                    │                NeuralComposeApp                       │
                    │  (SwiftUI: comms window, Phase B debug, menu-bar UI)  │
                    └─────┬──────────────────────────┬──────────────────────┘
                          │                          │ Cmd+Shift+D
                          ▼                          ▼
                ┌──────────────────┐        ┌─────────────────────────┐
                │ TextComposition  │        │  SleepValidationView    │
                │ Controller       │        │  (Phase B debug)        │
                └────────┬─────────┘        │  → EEGScalpPlotterView  │
                         │                  └─────────────────────────┘
                         ▼
                ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
                │ IntentSmoother   │    │ SleepStageSmoother│    │ DreamAnalysis    │
                │ (BCICore actor)  │    │ (BCICore actor)  │    │ Predicting (LLM) │
                └────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘
                         ▼                       ▼                       ▼
                ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
                │ IntentState      │    │ SleepSessionFSM  │    │  MLX adapter     │
                │ Machine          │    │                  │    │  (BCILLM)        │
                └────────┬─────────┘    └──────────────────┘    └──────────────────┘
                         │
                         ▼
                ┌──────────────────┐    ┌──────────────────┐
                │ Core ML on ANE   │    │ EEGWindowing     │  (2s comms / 30s sleep)
                │ (BCIClassifier)  │    │ (BCICore actor)  │
                └────────┬─────────┘    └────────┬─────────┘
                         │                       │
                         └──────────┬────────────┘
                                    ▼
                          ┌──────────────────┐
                          │ EEGStreaming     │ ← BrainFlow / synthetic / playback
                          │  (BCIEEG)        │
                          └──────────────────┘
```

**Module boundaries** (MLX isolation is load-bearing):

- `BCICore` — pure-Swift models, protocols, FSMs, buffers. **No third-party deps.**
- `BCIBridge` — Obj-C++ shim for BrainFlow (stub by default, real BrainFlow gated by `BCI_BRAINFLOW_AVAILABLE`).
- `BCIEEG` — `BrainFlowService`, `SyntheticEEGStream`, `PlaybackEEGStream`, `EEGScalpPlotterView`.
- `BCIClassifier` — Core ML wrapper + mock.
- `BCILLM` — **MLX-Swift linked only here.** Adapter + stub + tokenizer.
- `NeuralComposeApp` — SwiftUI views, the Phase B debug window, the menu-bar UI.

The app talks to `BCILLM` through `NextWordPredicting`, so there is exactly **one** MLX runtime copy in the linked binary. No duplicate-symbol risk. New sleep-cycle code follows the same isolation: types in `BCICore`, audio in a future `BCIAudio` target, MLX stays in `BCILLM`.

## Scientific Motivation

This is a platform, not a clinical or productivity tool. The aim is to build
the on-device infrastructure that lets a small research team:

1. **Validate consumer-grade EEG against physiological expectations** (alpha rise on eyes-closed, blink transients, jaw-clench EMG contamination, motion artifacts).
2. **Estimate sleep stage from 4 frontal channels** (Muse S provides TP9, AF7, AF8, TP10 — no chin EMG, no EOG). A 4-class output is the honest upper bound: `Wake / N1 / N2_N3 / Uncertain_REM`.
3. **Test whether TMR cues during N2/SWS paired with LLM-generated dream analysis improve creative problem solving.** Pre-registration required before claiming any effect.
4. **Ship the platform regardless of (3) — the validation toolkit, the architectural specification, and the open-source codebase are independently useful contributions.**

The established neuroscience in this stack (alpha dropout, AASM staging, TMR for declarative memory) is treated as established. The novel claims (LLM analogy extraction, engineering-insight improvement) are treated as unproven. Every claim is annotated with a confidence rating in `SLEEP_CYCLE_DESIGN.md`.

## Engineering & Mathematical Foundations

This section summarizes the math that motivates the pipeline. Detailed derivations are in [`docs/Math.md`](docs/Math.md).

**Multichannel EEG as discrete time series:**

$$X(t) \in \mathbb{R}^{4 \times N}, \quad X(t) = \begin{bmatrix} x_{\text{TP9}}(t) \\ x_{\text{AF7}}(t) \\ x_{\text{AF8}}(t) \\ x_{\text{TP10}}(t) \end{bmatrix}$$

**Windowed epoch** (sleep staging uses 30s windows with 5s stride; comms uses 2s windows with 1s stride):

$$W_i = X[t_i : t_i + T_{\text{epoch}}]$$

**Band power** (Welch-style periodogram, summed within band):

$$P_b = \sum_{f \in \text{band}_b} |\mathcal{F}\{x\}_{f}|^2 \cdot \frac{1}{N_{\text{bin}}}$$

**Alpha-dropout ratio** (per-epoch, relative to a per-user eyes-closed baseline):

$$r_\alpha(t) = \frac{P_\alpha^{\text{baseline}}}{P_\alpha(t)}$$

A value $r_\alpha > 1$ means the current alpha is *lower* than the baseline — the canonical N1 onset signature.

**Theta/alpha ratio** (REM proxy; weak without chin EMG):

$$\rho_{\theta\alpha}(t) = \frac{P_\theta(t)}{P_\alpha(t)}$$

**Softmax classifier** (Core ML on ANE):

$$p(c \mid W_i) = \frac{\exp(z_c(W_i))}{\sum_{c'} \exp(z_{c'}(W_i))}, \quad c \in \{\text{Wake}, \text{N1}, \text{N2\_N3}, \text{Uncertain\_REM}\}$$

**Temporal smoother** (AASM-aware, value-typed):

$$S_t = f\big(\{p(\cdot \mid W_{t-k}), \ldots, p(\cdot \mid W_t)\}\big), \quad k = 60 \text{ epochs default}$$

The smoother enforces AASM transition rules (no `Wake → N2_N3` skip) with a confidence-based override at $p > 0.9$ for 3+ consecutive epochs.

**State-transition function** (session FSM, §10 of `SLEEP_CYCLE_DESIGN.md`):

$$\text{phase}_{t+1} = g(\text{phase}_t, S_t, \text{budget})$$

where `budget` is the `TMRBudget` (5 cues/night max, 15-min min interval, 2 wake attempts). Budget exhaustion is enforced in code, not documentation.

## Current Validation Results

**Live Muse S through BrainFlow** — 2026-07-10, single participant, 80-second protocol. Three runs captured; the 01:42 session is the canonical reference (cleanest signal, all four conditions within the expected envelope on 3 of 4 channels):

| Condition | Signature | Result |
|-----------|-----------|--------|
| Eyes-closed alpha (TP9) | $P_\alpha^{\text{closed}} / P_\alpha^{\text{open}}$ | **2.98×** (PASS ≥1.5×) |
| Eyes-closed alpha (TP10) | ratio | **3.88×** (PASS) |
| Eyes-closed alpha (AF8) | ratio | 1.20× (borderline; AF7 saturated) |
| Eyes-closed alpha (AF7) | ratio | 1.03× (saturated pad; ratio not meaningful) |
| Blink transient (AF8) | $\max \lvert x(t) \rvert$ | **64.9 µV** (PASS ≥40 µV) |
| Jaw clench broadband (TP9) | $P_{\text{30-100 Hz}}^{\text{clench}} / P^{\text{open}}$ | **2.62×** (PASS ≥1.5×) |
| Jaw clench broadband (TP10) | ratio | **3.18×** (PASS) |
| Contact quality (RMS, healthy channels) | per channel | 10–20 µV (PASS, physiological) |
| Contact quality (AF7) | RMS | 912 µV (saturated; pad needs repositioning) |

This is a **calibration observation**, not a normative threshold. The pipeline (Muse S → BrainFlow → Python bindings → ring buffer) is the validation result; the alpha ratios are properties of the data. Reproducing this on a different participant, a different day, and with all 4 channels in skin contact is required before generalizing.

The full protocol, raw CSV, and per-signature pass criteria are in `Scripts/validate-muse-physiology.py` and `Recordings/muse_validation_20260710-014223.csv`.

## Repository Layout

```
NeuralCompose/
├── Sources/
│   ├── BCIBridge/        Obj-C++ shim for BrainFlow (stub by default)
│   ├── BCICore/          pure-Swift models, protocols, FSMs, buffers
│   ├── BCIEEG/           EEG streams + EEGScalpPlotterView (Phase B)
│   ├── BCIClassifier/    Core ML wrapper + mock
│   ├── BCILLM/           MLX adapter + stub + tokenizer  ← only MLX target
│   └── NeuralComposeApp/ SwiftUI views, Phase B debug window
├── Tests/                unit tests, runnable in synthetic mode
├── Scripts/              build / run / validate / train helpers
│   ├── build.sh
│   ├── run-synthetic.sh
│   ├── run-muse-s.sh
│   ├── run-calibration.sh
│   ├── train-intent-classifier.py
│   └── validate-muse-physiology.py    # Phase B physiological validation
├── Recordings/           per-session EEG + events (gitignored)
├── docs/                 long-form documentation (see below)
├── paper/                LaTeX manuscript (planned)
├── SLEEP_CYCLE_DESIGN.md full D1–D8 sleep architecture spec
├── HARDWARE_SETUP.md     Muse + BrainFlow + BLE transport
├── MODEL_SETUP.md        Core ML and MLX model files
├── CALIBRATION.md        recording labeled EEG for classifier training
└── TROUBLESHOOTING.md    common build / runtime issues
```

## Quick Start

**Synthetic mode — no hardware, no models:**

```bash
git clone https://github.com/aurascoper/NeuralCompose.git
cd NeuralCompose
./Scripts/build.sh        # swift build
./Scripts/run-synthetic.sh
```

The app launches, generates a synthetic EEG stream, exercises the full pipeline through the mock Core ML classifier and the stub next-word predictor. Carousel cycles and commits work out of the box.

**Live Muse S (after BrainFlow is installed at `~/Developer/brainflow/`):**

```bash
./Scripts/build.sh --with-brainflow
./Scripts/run-muse-s.sh
```

**Phase B Sleep Validation Toolkit** (live signal debugger):

```bash
./Scripts/build.sh --with-brainflow
DYLD_LIBRARY_PATH=~/Developer/NeuralCompose/.build/debug \
    ~/Developer/brainflow/compiled \
  /tmp/nc-bf-py/bin/python3 \
  Scripts/validate-muse-physiology.py
```

Or open the Phase B debug window in the running app with `Cmd+Shift+D`. The window has the live `EEGScalpPlotterView` with adjustable Y-scale and 3D depth-spacing sliders.

## Experimental Status & Limitations

| Claim | Status | Evidence |
|-------|--------|----------|
| Live Muse S EEG acquisition through BrainFlow is reproducible on macOS | **Established** | 2026-07-10 validation session; see `Recordings/muse_validation_20260710-004400.csv`. |
| Per-channel RMS, alpha power, and blink detection are observable on consumer Muse hardware | **Established** | Toolkit §21.4 acceptance criteria; multiple sessions. |
| 4-class sleep staging from Muse S is achievable at clinical-research accuracy | **Plausible** | Domain shift from PSG to Muse S is the largest expected error source. Per-user fine-tuning required. |
| TMR cues during N2/SWS paired with LLM dream analysis improves engineering insight | **Unproven** | D8 within-subject crossover, OSF pre-registration pending. |
| LLM analogy extraction from dream reports agrees with human raters (Cohen's κ > 0.4) | **Unproven** | Novel; D8 evaluates. |
| 5-class AASM sleep staging on Muse S | **Hardware-limited** | Muse S has no chin EMG; atonia is the defining REM criterion. |

The platform ships regardless of the unproven claims. The validation toolkit, the architectural spec, and the open-source codebase are useful contributions on their own.

## Documentation

- [`HARDWARE_SETUP.md`](HARDWARE_SETUP.md) — Muse + BrainFlow + BLE transport details.
- [`MODEL_SETUP.md`](MODEL_SETUP.md) — Core ML and MLX model setup.
- [`CALIBRATION.md`](CALIBRATION.md) — recording labeled EEG for classifier training.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — common build / runtime issues.
- [`SLEEP_CYCLE_DESIGN.md`](SLEEP_CYCLE_DESIGN.md) — full D1–D8 sleep architecture spec (1,500 lines).
- [`docs/Architecture.md`](docs/Architecture.md) — module structure and design rationale.
- [`docs/Math.md`](docs/Math.md) — derivations of the equations in this README.
- [`docs/Validation.md`](docs/Validation.md) — physiological validation protocol and results.
- [`docs/Research.md`](docs/Research.md) — research methodology and D8 pre-registration plan.
- [`docs/SleepCycleDesign.md`](docs/SleepCycleDesign.md) — reader-friendly summary of `SLEEP_CYCLE_DESIGN.md`.

## Citation

A paper draft is in `paper/`. Suggested citation when published:

> Kinder, H. (2026). *An open-source, privacy-preserving platform for EEG-guided
> cognitive incubation and dream-report analysis using consumer-grade
> hardware.* In preparation.

## License

This is research prototype code. **Do not use NeuralCompose to make clinical
or safety-critical decisions.** License terms: see `LICENSE`.

## Acknowledgements

- **BrainFlow** for the unified biosensor acquisition API.
- **MLX-Swift** for the local on-device LLM runtime.
- **Apple Neural Engine** for low-power Core ML inference.
- The Muse headband community for open BLE protocol documentation.
- The sleep-staging research community for the AASM standard.
