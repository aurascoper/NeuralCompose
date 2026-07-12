import XCTest
@testable import BCICore
@testable import BCIEEG

/// Verifies the Phase 2 signal -> material mappings in `NeuralWorkspaceView`
/// directly, rather than relying on visual screenshot comparison — which
/// can't reliably catch subtle emission-intensity/color regressions in a
/// native SceneKit view the way it can for web content (no pixel-inspection
/// tool exists for native rendering the way it does for a browser preview).
@MainActor
final class NeuralWorkspaceViewTests: XCTestCase {

    private func makeSample(_ value: Float) -> EEGSample {
        EEGSample(timestamp: 0, channels: [value, value, value, value])
    }

    private func makeView() -> NeuralWorkspaceView {
        NeuralWorkspaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    }

    private static func throwingStream<Element: Sendable>(
        from stream: AsyncStream<Element>
    ) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream<Element, any Error> { continuation in
            let task = Task {
                for await element in stream {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Node brightness <- broadband RMS

    func testBrightnessTracksBroadbandRMS() {
        let view = makeView()
        for _ in 0..<64 { view.ingest(makeSample(0.1)) }
        view.testableTriggerRecompute()
        let low = view.testableEmissionIntensity(for: "TP9") ?? -1

        for _ in 0..<64 { view.ingest(makeSample(200.0)) }
        view.testableTriggerRecompute()
        let high = view.testableEmissionIntensity(for: "TP9") ?? -1

        XCTAssertGreaterThan(high, low, "higher broadband RMS should mean brighter node emission")
    }

    // MARK: - Edge tint <- classifier intent

    func testEdgeColorTracksClassifierIntent() async throws {
        let view = makeView()
        let (stream, continuation) = AsyncStream<IntentPrediction>.makeStream()
        view.subscribeClassifier(to: Self.throwingStream(from: stream))

        continuation.yield(IntentPrediction(
            intent: .select, confidence: 0.9, distribution: [:],
            windowSequence: 0, endTimestamp: 0
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Keep samples "fresh" so the staleness guard doesn't dim the color.
        for _ in 0..<8 { view.ingest(makeSample(10.0)) }
        view.testableTriggerRecompute()

        let color = view.testableEdgeTintColor()
        let converted = color?.usingColorSpace(.deviceRGB)
        XCTAssertNotNil(converted, "expected an edge tint color once a classifier prediction has arrived")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted?.getRed(&r, green: &g, blue: &b, alpha: &a)
        // intentColor(.select) = (1.0, 0.85, 0.2).
        XCTAssertEqual(Float(r), 1.0, accuracy: 0.01)
        XCTAssertEqual(Float(b), 0.2, accuracy: 0.01)

        continuation.finish()
    }

    // MARK: - Edge pulse <- classifier confidence

    func testEdgePulseTracksConfidence() async throws {
        let view = makeView()
        let (stream, continuation) = AsyncStream<IntentPrediction>.makeStream()
        view.subscribeClassifier(to: Self.throwingStream(from: stream))

        continuation.yield(IntentPrediction(
            intent: .rest, confidence: 0.1, distribution: [:], windowSequence: 0, endTimestamp: 0
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<8 { view.ingest(makeSample(10.0)) }
        // Several ticks so the confidence EMA has time to settle.
        for _ in 0..<40 { view.testableTriggerRecompute() }
        let lowIntensity = view.testableEdgeEmissionIntensity() ?? -1

        continuation.yield(IntentPrediction(
            intent: .select, confidence: 0.95, distribution: [:], windowSequence: 1, endTimestamp: 0
        ))
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<8 { view.ingest(makeSample(10.0)) }
        for _ in 0..<40 { view.testableTriggerRecompute() }
        let highIntensity = view.testableEdgeEmissionIntensity() ?? -1

        XCTAssertGreaterThan(highIntensity, lowIntensity, "higher confidence should mean a more intense edge pulse")
        continuation.finish()
    }

    // MARK: - Synchronization: stale classifier dims rather than lies

    func testStaleClassifierDimsEdgeIntensity() async throws {
        let view = makeView()
        // Shrink the threshold so the test doesn't need to sleep 3+ real
        // seconds; the mechanism being exercised doesn't care about the
        // specific duration, just "past threshold while samples flow". Keep
        // a wide margin between the "fresh" sleep and the threshold, and
        // between the threshold and the "stale" sleep — sleep() isn't
        // precise enough to cut it close without flaking.
        view.classifierStaleThreshold = 0.15
        let (stream, continuation) = AsyncStream<IntentPrediction>.makeStream()
        view.subscribeClassifier(to: Self.throwingStream(from: stream))

        continuation.yield(IntentPrediction(
            intent: .select, confidence: 0.95, distribution: [:], windowSequence: 0, endTimestamp: 0
        ))
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms, well under the 150ms threshold
        for _ in 0..<8 { view.ingest(makeSample(10.0)) }
        for _ in 0..<40 { view.testableTriggerRecompute() }
        let fresh = view.testableEdgeEmissionIntensity() ?? -1

        // Let the prediction go stale while samples keep flowing, so
        // staleness is attributable specifically to the classifier stream.
        try? await Task.sleep(nanoseconds: 400_000_000) // total elapsed >> 150ms threshold
        for _ in 0..<8 { view.ingest(makeSample(10.0)) }
        for _ in 0..<40 { view.testableTriggerRecompute() }
        let stale = view.testableEdgeEmissionIntensity() ?? -1

        XCTAssertLessThan(
            stale, fresh,
            "a stalled classifier stream should dim edge intensity rather than keep showing old confidence"
        )
        continuation.finish()
    }

    // MARK: - Graceful fallback with no classifier bound

    func testFallsBackToFSMColorWithNoClassifierBound() {
        let view = makeView()
        for _ in 0..<8 { view.ingest(makeSample(10.0)) }
        view.testableTriggerRecompute()

        // No crash, and some tint is still rendered (the FSMState fallback),
        // even though no classifier was ever subscribed.
        XCTAssertNotNil(view.testableEdgeTintColor())
    }

    // MARK: - Embedding source <- SentenceEmbedder

    func testStoresSentenceEmbedderVectorForContext() async throws {
        let view = makeView()
        let embedder = DeterministicSentenceEmbedder()
        view.subscribeEmbeddings(provider: embedder, contextProvider: { "hello world" })

        // The polling loop encodes immediately on its first iteration, before
        // sleeping — a short wait is enough to capture that first embedding.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let expected = try await embedder.encode("hello world")
        let stored = try XCTUnwrap(view.latestEmbedding, "an embedding should be stored after subscribing")
        XCTAssertEqual(stored.values, expected.values)
        XCTAssertEqual(stored.modelID, "stub-hash-v1")

        view.cancelEmbeddingSubscription()
    }
}
