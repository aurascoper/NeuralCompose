import XCTest
import Network
@testable import NeuralComposeApp
@testable import BCIEEG
@testable import BCICore
@testable import BCIClassifier
@testable import BCILLM

/// End-to-end smoke test: does `AppViewModel`'s consumption loop actually
/// receive and record samples when the live source is `MindMonitorOSCStream`?
///
/// This exists because a live deployment session found a real gap: the OSC
/// transport was provably healthy (packets arriving, zero decode errors,
/// `samplesYielded` incrementing) while `CalibrationRecorder` logged
/// "0 windows, 0 samples" for a full ~6-minute session. `MindMonitorOSCStream`
/// and `MuseOSCDecoder` both have solid unit/integration coverage in
/// isolation (see `MindMonitorOSCStreamTests`, `MuseOSCDecoderTests`) — what
/// was never tested is the *app-level wiring* between "the transport yields
/// an `EEGSample`" and "the recorder writes it," end to end, through a real
/// `AppViewModel`. That gap is exactly what this test closes.
@MainActor
final class AppViewModelOSCSmokeTests: XCTestCase {

    private let testPort: UInt16 = 57_282

    private func oscString(_ s: String) -> Data {
        var data = Data(s.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    /// Wraps a `/muse/eeg` message in an OSC bundle — matching Mind
    /// Monitor's real wire format (see `MuseOSCDecoderTests`'s captured-bytes
    /// fixture), not the bare-message shape that would mask a bundle-related
    /// regression.
    private func makeBundledEEGPacket(_ floats: [Float]) -> Data {
        var message = oscString("/muse/eeg")
        message.append(oscString("," + String(repeating: "f", count: floats.count)))
        for f in floats {
            var bits = f.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { message.append(contentsOf: $0) }
        }

        var bundle = oscString("#bundle")
        bundle.append(contentsOf: [UInt8](repeating: 0, count: 8)) // timetag, unused
        var sizeBits = UInt32(message.count).bigEndian
        withUnsafeBytes(of: &sizeBits) { bundle.append(contentsOf: $0) }
        bundle.append(message)
        return bundle
    }

    private func sendUDP(_ data: Data, port: UInt16) async {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp
        )
        connection.start(queue: .global())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
        connection.cancel()
    }

    func testCalibrationRecorderReceivesSamplesFromLiveOSCStream() async throws {
        let stream = MindMonitorOSCStream(port: testPort)
        let resolved = EEGStreamFactory.Resolved(stream: stream, source: .oscRemote, profile: .oscRemote)
        let classifierResolved = ClassifierFactory.live()
        let predictorResolved = await PredictorFactory.live()
        let windowingConfig = EEGWindowingConfig(
            windowSeconds: 2.0, strideSeconds: 1.0,
            sampleRate: stream.effectiveSampleRate, channelCount: stream.channelCount
        )
        let container = AppContainer(
            streamResolved: resolved,
            classifierResolved: classifierResolved,
            predictorResolved: predictorResolved,
            metrics: MetricsCollector(),
            windowingConfig: windowingConfig
        )
        let viewModel = AppViewModel(container: container)

        await viewModel.start()
        // Let the supervisor's streamTask reach `current.stream.start()` and
        // bind the listener before we send anything.
        try? await Task.sleep(nanoseconds: 300_000_000)

        await viewModel.startCalibrationRecording()
        XCTAssertTrue(viewModel.isCalibrating, "startCalibrationRecording() should flip isCalibrating")

        // ~1.3s of bundled EEG packets at a realistic cadence — enough for
        // calibrationSampleRate's 1-second averaging window to update at
        // least once, without needing a full 2s window to complete.
        for i in 0..<16 {
            await sendUDP(makeBundledEEGPacket([Float(i), Float(i), Float(i), Float(i)]), port: testPort)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        await viewModel.stopCalibrationRecording()
        await viewModel.stop()

        XCTAssertGreaterThan(
            viewModel.calibrationSampleRate, 0,
            "calibrationSampleRate stayed 0 — recorder received no samples from the live OSC stream"
        )
    }
}
