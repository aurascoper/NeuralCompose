# Architectural Roadmap

Where the platform grows from here. Distinct from GitHub Issues (which
track discrete tasks): this document tracks *capabilities the
architecture grows toward*, grouped by the layer they extend.

Status icons: `✓` shipped · `□` planned · `~` in progress

---

## Current state

### External Systems
- `✓` Muse S over BrainFlow (native BLE and BLED112 dongle profiles)
- `✓` Muse S Athena (BrainFlow 5.22+, board ID 67)
- `✓` Synthetic EEG (deterministic, for development)
- `✓` CSV playback (regression fixtures)
- `✓` Remote Muse over OSC via Mind Monitor + Tailscale (`b2a6a2f`)

### Runtime
- `✓` Single-owner `EEGStreaming` fan-out via `AsyncMulticastChannel`
- `✓` Channel health provider (per-channel RMS, contact quality, clipping)
- `✓` Golden-recording deterministic playback
- `✓` Stall watchdog in supervisor (5s per-sample timeout, `a0a9e67`)
- `✓` Deployment validation artifacts (`Recordings/deployment/`)

### Intelligence
- `✓` Core ML intent classifier on ANE
- `✓` Band-power feature extraction
- `✓` Random-projection embedding projector (deterministic stub for 3D)
- `~` MLX next-word predictor (BCILLM stub shipped, real model pending)

### Interface
- `✓` SwiftUI app + menu-bar UI
- `✓` 2D depth-stacked EEG plotter
- `✓` 3D SceneKit neural workspace (electrode nodes + edges)
- `✓` Privacy indicator banner
- `✓` Channel-health badge with staleness indicator

---

## Next

Items in priority order. Each builds on a validated foundation from
the layer above. New work goes here when it's ready to spec; the
specific tasks (files, PRs, tests) live in GitHub Issues.

### Runtime
- `□` `StreamDiagnostics` integration with the privacy banner
  (bound port, interface name, heartbeat staleness) — *partially
  shipped in `a4d2ab8`; full UI integration pending*
- `□` Deployment checklist as a runnable validation script
  (currently a markdown document)
- `□` Reconnect-after-interruption integration test (Phase 3.6 follow-up,
  deferred from the OSC review)

### Intelligence
- `□` `SentenceEmbedding` protocol + stub + tests (per the proposed
  seven-section format; see also ADR-005 when it lands)
- `□` Core ML MiniLM-L6-v2 adapter (sentence embedder for 3D workspace,
  on ANE)
- `□` `EmbeddingProjector` integration: replace `RandomProjectionProjector`
  consumer with real `SentenceEmbedding` input, keeping the renderer
  source-agnostic

### Interface
- `□` Playback-driven 2D + 3D visualization (the canonical demo path;
  validates the Intelligence layer without live hardware)
- `□` Classifier confidence visualization over deterministic playback
  (proves the classifier composes correctly with the rest of the
  pipeline)

### Cross-cutting
- `□` Initial ADR set in `docs/architecture/decision-log/`
  (ADR-001 through ADR-004 cover the major decisions made to date)
- `□` `docs/architecture/PRINCIPLES.md` — engineering values that
  govern how new work is integrated
- `□` Layered architecture diagram in the main README

---

## Future

Capabilities the architecture is designed to support, but which are
not yet on the active development path. These belong here, not in
"Next," because the prerequisites (protocols, fixtures, deployment
validation) are still landing.

### Intelligence
- `□` Online adaptation: classifier that updates to a specific user
  over a calibration session, without losing the cross-user baseline
- `□` Cross-modal embeddings: combine EEG-derived features with
  external context (task description, prior session history) for
  richer semantic visualization
- `□` Multi-user collaboration: shared 3D workspace across multiple
  NeuralCompose instances, each running on its own Muse

### Interface
- `□` Local web dashboard for remote monitoring (deferred from the
  Phase 3.6 OSC review; the underlying `StreamDiagnostics` work is
  shipped, the HTTP layer is not)
- `□` LLM-assisted communication: the existing `BCILLM` slot
  populated with a real generative model, with the carousel UX
  refactored to consume it (currently stubbed)

### External Systems
- `□` Additional Muse profiles as BrainFlow adds them
- `□` Non-Muse EEG sources (OpenBCI, g.tec) via the same
  `EEGStreaming` protocol — the layer rename to *External Systems*
  is forward-compatible with this
- `□` Simulated streams for synthetic-bench experiments (the current
  `SyntheticEEGStream` is a development convenience; a separate
  *benchmark* stream with controlled noise models is a different
  capability)
