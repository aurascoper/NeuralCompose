import Foundation
import BCICore

/// Local-only sink for the window/action/window tuples used by the offline
/// JEPA trainer. `AppViewModel` gates every call behind its explicit,
/// off-by-default `jepaTransitionCaptureEnabled` toggle.
public protocol JEPATransitionCapturing: Sendable {
    func ingest(_ state: JEPASpectralState)

    /// Starts one non-blocking capture sequence. Returns `nil` while the
    /// pre-action ring is warming up; callers intentionally do not retry that
    /// interaction because partial windows must never enter the data set.
    @discardableResult
    func recordTransition(actionVector: [Float]) -> Task<Void, Never>?
}

/// Default for previews and tests that do not explicitly ask to write a
/// JEPA data set. Mirrors `NullInteractionLogger`'s stub-safe posture.
public struct NullJEPATransitionCapture: JEPATransitionCapturing {
    public init() {}
    public func ingest(_ state: JEPASpectralState) {}
    public func recordTransition(actionVector: [Float]) -> Task<Void, Never>? { nil }
}

/// Captures aligned `(W_t, a_t, W_t+1)` examples without blocking the UI or
/// the EEG ingestion path. Disk writes are serialized so overlapping user
/// commits remain valid JSON Lines records.
public final class TransitionCaptureManager: JEPATransitionCapturing, @unchecked Sendable {
    public let predictionHorizon: TimeInterval
    public let fileURL: URL

    private let eegBuffer: JEPASpectralStateRingBuffer
    private let writeQueue = DispatchQueue(label: "com.neuralcompose.jepa-transition-writer")

    public init(
        eegBuffer: JEPASpectralStateRingBuffer,
        predictionHorizon: TimeInterval = 5.0,
        fileURL: URL = TransitionCaptureManager.defaultFileURL()
    ) {
        precondition(predictionHorizon.isFinite && predictionHorizon >= 0,
                     "predictionHorizon must be finite and non-negative")
        self.eegBuffer = eegBuffer
        self.predictionHorizon = predictionHorizon
        self.fileURL = fileURL
    }

    /// Kept separate from the existing interaction-log directory because this
    /// schema contains measured signal features, not word-commit telemetry.
    public static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralCompose")
            .appendingPathComponent("JEPATransitions")
            .appendingPathComponent("jepa_transitions.jsonl")
    }

    public func ingest(_ state: JEPASpectralState) {
        eegBuffer.append(state)
    }

    @discardableResult
    public func recordTransition(actionVector: [Float]) -> Task<Void, Never>? {
        guard actionVector.allSatisfy(\.isFinite) else {
            BCILog.telemetry.error("JEPA transition skipped: non-finite action vector")
            return nil
        }
        guard let preActionWindow = eegBuffer.snapshot() else {
            BCILog.telemetry.debug("JEPA transition skipped: feature buffer warming up")
            return nil
        }

        let timestamp = Date().timeIntervalSince1970
        let horizonNanoseconds = UInt64(predictionHorizon * 1_000_000_000)

        return Task.detached(priority: .utility) { [weak self, preActionWindow, actionVector] in
            do {
                try await Task.sleep(nanoseconds: horizonNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self else { return }
            guard let postActionWindow = self.eegBuffer.snapshot() else {
                BCILog.telemetry.debug("JEPA transition skipped: no complete post-action window")
                return
            }

            let transition = JEPATransition(
                timestamp: timestamp,
                preActionWindow: preActionWindow,
                actionVector: actionVector,
                postActionWindow: postActionWindow
            )
            do {
                try self.appendToJSONL(transition)
                BCILog.telemetry.debug("JEPA transition persisted: \(transition.id.uuidString, privacy: .public)")
            } catch {
                BCILog.telemetry.error("JEPA transition write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func appendToJSONL(_ transition: JEPATransition) throws {
        try writeQueue.sync {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            var data = try encoder.encode(transition)
            data.append(0x0A)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
