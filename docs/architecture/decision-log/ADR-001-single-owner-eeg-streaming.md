# ADR-001: Single-owner `EEGStreaming` with multicast fan-out

**Status**: Accepted
**Date**: 2026-07-10

## Context

A live Muse (or any other `EEGStreaming` source) is a shared resource:
the BLE handle, the BrainFlow session, the UDP socket. If two
downstream consumers each call `EEGStreaming.start()` independently,
they compete for the same resource. One wins; the other gets an error
or, worse, a stream that silently emits nothing because the underlying
hardware is already bound by the first consumer.

The pipeline has multiple consumers that all want the same samples
(2D plotter, 3D workspace, classifier, channel-health provider,
recorder). The naive design — each consumer opens its own stream —
produces the failure mode described above. A `for try await sample in
stream` consumer that opens a second stream is the most common bug in
this category.

## Decision

Exactly one component in a running process owns the live
`EEGStreaming`. Distribution to multiple consumers happens through
`AsyncMulticastChannel<EEGSample>` (see `BCICore/Buffers/`), not
through independent `start()` calls.

Playback and synthetic streams are exempt from this rule: they have no
shared hardware, are cheap to instantiate, and are designed to be
replayable per-consumer for testing.

## Alternatives Considered

**Each consumer opens its own `EEGStreaming`.** Simple, but produces
the resource-competition failure mode above. Rejected.

**A single global mutable sample buffer with locks.** Avoids the
competition, but loses the structured-concurrency benefits of
`AsyncStream` (cancellation, backpressure, terminal errors) and
introduces lock-contention as a new failure mode. Rejected.

**A callback-based broadcaster (one producer, N registered callbacks).**
Works, but inverts the dependency direction — consumers register
themselves with the producer, which makes the producer responsible
for consumer lifecycle. The `AsyncMulticastChannel` design keeps
consumers in charge of their own subscription lifecycle.

## What this prevents

Two consumers each calling `EEGStreaming.start()` independently and
competing for the same BLE handle, BrainFlow session, or UDP socket.
A consumer that needs samples subscribes; the existing single owner
emits once. The competition failure mode becomes impossible by
construction.

## When this rule does not apply

Playback (`PlaybackEEGStream`) and synthetic (`SyntheticEEGStream`)
sources are exempted. They have no shared hardware, are deterministic
and cheap to instantiate, and may legitimately be opened multiple
times in the same process (e.g., one stream per test case, or one
playback stream per visualization if the consumer wants to seek
independently).

Tests are also exempt. A test that needs to drive a `StallingEEGStream`
fake through the full pipeline may instantiate the fake and wrap it in
whatever supervision pattern the test requires.

## Related implementation

- `Sources/BCICore/Buffers/AsyncMulticastChannel.swift` — the
  multicast primitive
- `Sources/BCICore/Protocols/EEGStreaming.swift` — the protocol
  surface this rule constrains
- `Sources/NeuralComposeApp/AppViewModel.swift` — the supervisor
  that owns the single live stream and feeds the multicast channel
