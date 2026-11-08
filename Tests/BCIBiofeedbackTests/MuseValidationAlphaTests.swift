import XCTest
import BCICore
@testable import BCIBiofeedback

/// Physiology check for the egress's band powers: eyes-closed alpha must
/// rise on the posterior pair (TP9, TP10) and not on the frontal pair
/// (AF7, AF8) in the sessions whose QC sidecar says `alpha_pass: true`,
/// and the known bad session (013820, TP9 ratio 0.02 in the original QC)
/// must fail the same test. This is the first per-channel alpha figure in
/// physical units the project has; the lag-difference proxy in
/// `FeatureExtractor` could not provide one.
///
/// Two traps, both learned from the recordings on 2026-11-07:
///
/// 1. The validation CSVs are not continuous. `validate-muse-physiology.py`
///    sleeps ~3 s between segments, so `t_seconds` jumps 3.2 to 3.3 s at
///    every segment boundary. Replaying a whole file through
///    `PlaybackEEGStream(.normalized)` would interpolate ~820 fake samples
///    into each gap and misalign `segments.csv`. So this test reads
///    `<name>.eeg.csv` and `<name>.segments.csv` row for row, groups by
///    segment, and windows each segment on its own (512 samples at 256
///    stride: 29 windows per 30 s segment).
/// 2. The statistic is the **median** window Bels per segment, not the
///    mean. On 015723 one transient eyes-open window pulls TP10's mean rise
///    to 0.276 Bels, just under log10(2) = 0.301, while the median rise is
///    0.328; the mean would fail a session the QC passed for the wrong
///    reason.
///
/// The fixture `Fixtures/muse_validation_alpha_v1.json` records per-session,
/// per-channel medians and means for regression; hard pins below record the
/// three sessions with sidecars. Skips when `Recordings/` is absent.
///
///     NEURALCOMPOSE_REGENERATE_REFERENCE=1 swift test --filter MuseValidationAlphaTests
final class MuseValidationAlphaTests: XCTestCase {

    // MARK: - Fixture schema

    struct ChannelAlpha: Codable, Equatable {
        let openMedianBels: Float
        let closedMedianBels: Float
        let openMeanBels: Float
        let closedMeanBels: Float
        var medianRise: Float { closedMedianBels - openMedianBels }
        var meanRise: Float { closedMeanBels - openMeanBels }
    }

    struct SessionAlpha: Codable, Equatable {
        let session: String
        let alphaPass: Bool?
        let rowCount: Int
        let openWindows: Int
        let closedWindows: Int
        /// Largest gap between consecutive samples inside one segment (s).
        let maxIntraSegmentGap: Double
        /// Gap at the open to closed boundary (s); documents trap 1.
        let openClosedBoundaryGap: Double
        /// Channel label to alpha statistics.
        let channels: [String: ChannelAlpha]
    }

    struct AlphaReference: Codable, Equatable {
        let version: Int
        let windowSamples: Int
        let strideSamples: Int
        let sessions: [SessionAlpha]
    }

    // MARK: - Pins (measured 2026-11-07 on the M4, Swift 6.0)

    /// Median window Bels rise, closed minus open, per channel, for the
    /// three sessions that have a QC sidecar.
    static let medianRisePins: [String: [EEGChannel: Float]] = [
        "muse_validation_20260710-013820": [.tp9: 0.0616, .af7: -0.1217, .af8: -0.0906, .tp10: 0.2422],
        "muse_validation_20260710-014223": [.tp9: 0.4615, .af7: -0.1228, .af8: 0.2033, .tp10: 0.5651],
        "muse_validation_20260710-015723": [.tp9: 0.4277, .af7: -0.1500, .af8: -0.1019, .tp10: 0.3716],
    ]

    /// The physiological criterion: a doubling of alpha power on both
    /// posterior channels, and less than a doubling on both frontal ones.
    static let doubling = Float(log10(2.0))

    static let windowSamples = 512
    static let strideSamples = 256
    static let sampleRate = 256.0

    // MARK: - Paths

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var convertedRoot: URL {
        repoRoot.appendingPathComponent("Recordings/muse_validation_converted")
    }

    private var referenceFileURL: URL {
        repoRoot.appendingPathComponent("Tests/BCIBiofeedbackTests/Fixtures/muse_validation_alpha_v1.json")
    }

    // MARK: - Test

    func testEyesClosedAlphaRisesOnPosteriorChannelsOnly() throws {
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(at: convertedRoot, includingPropertiesForKeys: nil),
              !sessionDirs.isEmpty else {
            throw XCTSkip("No Recordings/muse_validation_converted/ sessions; skipping.")
        }
        let regenerate = ProcessInfo.processInfo.environment["NEURALCOMPOSE_REGENERATE_REFERENCE"] == "1"

        var sessions: [SessionAlpha] = []
        for dir in sessionDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = dir.lastPathComponent
            let eeg = dir.appendingPathComponent("\(name).eeg.csv")
            let segments = dir.appendingPathComponent("\(name).segments.csv")
            guard FileManager.default.fileExists(atPath: eeg.path), FileManager.default.fileExists(atPath: segments.path) else {
                XCTFail("\(name): missing eeg.csv or segments.csv")
                continue
            }
            let session = try analyse(name: name, eegURL: eeg, segmentsURL: segments)
            sessions.append(session)

            // Physiology assertions, driven by the sidecar verdict.
            let rises = Dictionary(uniqueKeysWithValues: session.channels.map { ($0.key, $0.value.medianRise) })
            let posterior = [EEGChannel.tp9, .tp10].map { rises[$0.label] ?? -99 }
            let frontal = [EEGChannel.af7, .af8].map { rises[$0.label] ?? 99 }
            let passes = posterior.allSatisfy { $0 >= Self.doubling } && frontal.allSatisfy { $0 < Self.doubling }
            switch session.alphaPass {
            case .some(true):
                XCTAssertTrue(passes, "\(name) is alpha_pass: true but median rises were posterior \(posterior) frontal \(frontal)")
            case .some(false):
                XCTAssertFalse(posterior.allSatisfy { $0 >= Self.doubling }, "\(name) is the expected negative (alpha_pass: false) yet both posterior channels doubled: \(posterior)")
            case .none:
                break   // no verdict on file; recorded in the fixture only
            }

            // Trap 1 is visible in the data: the segment boundary gap is the
            // protocol's ~3.2 s inter-segment pause on the five valid sessions,
            // while 004345 has a -12.19 s backwards jump (overlapping segments
            // from a ring-buffer read-back, excluded from physiology claims).
            if name == "muse_validation_20260710-004345" {
                XCTAssertLessThan(session.openClosedBoundaryGap, -10.0, "\(name): expected the -12.19 s overlapping ring-buffer read-back jump")
            } else {
                XCTAssertGreaterThan(session.openClosedBoundaryGap, 1.0, "\(name): expected the ~3 s inter-segment pause at the open/closed boundary")
            }
            XCTAssertEqual(session.openWindows, 29, "\(name): 30 s at 256 Hz gives 29 windows of 512 at stride 256")
            XCTAssertEqual(session.closedWindows, 29, "\(name)")

            if let pins = Self.medianRisePins[name] {
                for (channel, pin) in pins {
                    XCTAssertEqual(rises[channel.label] ?? -99, pin, accuracy: 0.01, "\(name) \(channel.label) median rise")
                }
            }
        }
        XCTAssertFalse(sessions.isEmpty, "no sessions analysed")

        let reference = AlphaReference(version: 1, windowSamples: Self.windowSamples, strideSamples: Self.strideSamples, sessions: sessions)

        if regenerate {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: referenceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(reference).write(to: referenceFileURL)
            throw XCTSkip("Regenerated \(referenceFileURL.path); inspect the diff and commit if expected.")
        }

        guard let expectedData = try? Data(contentsOf: referenceFileURL) else {
            throw XCTSkip("No committed reference at \(referenceFileURL.path). Run with NEURALCOMPOSE_REGENERATE_REFERENCE=1 to generate it.")
        }
        let expected = try JSONDecoder().decode(AlphaReference.self, from: expectedData)
        XCTAssertEqual(reference.version, expected.version)
        XCTAssertEqual(reference.windowSamples, expected.windowSamples)
        XCTAssertEqual(reference.sessions.map(\.session), expected.sessions.map(\.session), "session set changed")
        for (actual, stored) in zip(reference.sessions, expected.sessions) {
            XCTAssertEqual(actual.alphaPass, stored.alphaPass, "\(actual.session) sidecar verdict changed")
            XCTAssertEqual(actual.rowCount, stored.rowCount, "\(actual.session) row count")
            XCTAssertEqual(actual.openWindows, stored.openWindows)
            XCTAssertEqual(actual.closedWindows, stored.closedWindows)
            for (label, storedChannel) in stored.channels {
                guard let got = actual.channels[label] else {
                    XCTFail("\(actual.session) \(label) missing")
                    continue
                }
                XCTAssertEqual(got.openMedianBels, storedChannel.openMedianBels, accuracy: 1e-3, "\(actual.session) \(label) open median")
                XCTAssertEqual(got.closedMedianBels, storedChannel.closedMedianBels, accuracy: 1e-3, "\(actual.session) \(label) closed median")
                XCTAssertEqual(got.openMeanBels, storedChannel.openMeanBels, accuracy: 1e-3, "\(actual.session) \(label) open mean")
                XCTAssertEqual(got.closedMeanBels, storedChannel.closedMeanBels, accuracy: 1e-3, "\(actual.session) \(label) closed mean")
            }
        }
    }

    // MARK: - Analysis

    private func analyse(name: String, eegURL: URL, segmentsURL: URL) throws -> SessionAlpha {
        let (times, rows) = try Self.readEEG(eegURL)
        let labels = try Self.readSegments(segmentsURL)
        XCTAssertEqual(labels.count, rows.count, "\(name): segments.csv and eeg.csv row counts differ")
        let count = min(labels.count, rows.count)
        guard count > 0 else {
            throw XCTSkip("\(name): empty recording")
        }

        // Group contiguous rows by segment label, preserving order.
        var groups: [(label: String, range: Range<Int>)] = []
        var start = 0
        for i in 1...count {
            if i == count || labels[i] != labels[start] {
                groups.append((labels[start], start..<i))
                start = i
            }
        }

        var maxIntraGap = 0.0
        for group in groups where group.range.count > 1 {
            for i in (group.range.lowerBound + 1)..<group.range.upperBound {
                maxIntraGap = max(maxIntraGap, times[i] - times[i - 1])
            }
        }
        var boundaryGap = 0.0
        if let closed = groups.first(where: { $0.label == "closed" }), closed.range.lowerBound > 0 {
            boundaryGap = times[closed.range.lowerBound] - times[closed.range.lowerBound - 1]
        }

        let estimator = BandPowerEstimator(bands: [.alpha])
        func alphaBelsPerWindow(_ range: Range<Int>) -> [EEGChannel: [Float]] {
            var out: [EEGChannel: [Float]] = Dictionary(uniqueKeysWithValues: EEGChannel.allCases.map { ($0, []) })
            var startIndex = range.lowerBound
            while startIndex + Self.windowSamples <= range.upperBound {
                for (c, channel) in EEGChannel.allCases.enumerated() {
                    let slice = (startIndex..<(startIndex + Self.windowSamples)).map { rows[$0][c] }
                    out[channel, default: []].append(estimator.powers(for: slice, sampleRate: Self.sampleRate).bels(.alpha))
                }
                startIndex += Self.strideSamples
            }
            return out
        }

        let openRange = groups.first(where: { $0.label == "open" })?.range ?? 0..<0
        let closedRange = groups.first(where: { $0.label == "closed" })?.range ?? 0..<0
        let openBels = alphaBelsPerWindow(openRange)
        let closedBels = alphaBelsPerWindow(closedRange)

        var channels: [String: ChannelAlpha] = [:]
        for channel in EEGChannel.allCases {
            let o = openBels[channel] ?? []
            let c = closedBels[channel] ?? []
            channels[channel.label] = ChannelAlpha(
                openMedianBels: Self.median(o),
                closedMedianBels: Self.median(c),
                openMeanBels: Self.mean(o),
                closedMeanBels: Self.mean(c)
            )
        }

        return SessionAlpha(
            session: name,
            alphaPass: Self.sidecarAlphaPass(for: name),
            rowCount: count,
            openWindows: openBels[.tp9]?.count ?? 0,
            closedWindows: closedBels[.tp9]?.count ?? 0,
            maxIntraSegmentGap: maxIntraGap,
            openClosedBoundaryGap: boundaryGap,
            channels: channels
        )
    }

    /// `t_seconds,TP9,AF7,AF8,TP10` to parallel arrays.
    private static func readEEG(_ url: URL) throws -> (times: [Double], rows: [[Float]]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var times: [Double] = []
        var rows: [[Float]] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            if index == 0 { continue }   // header
            let parts = line.split(separator: ",")
            guard parts.count >= 5, let t = Double(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let values = parts[1...4].map { Float($0.trimmingCharacters(in: .whitespaces)) ?? .nan }
            times.append(t)
            rows.append(values)
        }
        return (times, rows)
    }

    /// `t_seconds,segment` to the segment column.
    private static func readSegments(_ url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var labels: [String] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            if index == 0 { continue }
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { continue }
            labels.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return labels
    }

    /// `Recordings/<name>.json`, key `alpha_pass` at any depth; nil when the
    /// sidecar is absent or has no verdict.
    private static func sidecarAlphaPass(for name: String) -> Bool? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Recordings/\(name).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findBool(key: "alpha_pass", in: json)
    }

    private static func findBool(key: String, in object: Any) -> Bool? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] as? Bool { return value }
            if let number = dict[key] as? NSNumber { return number.boolValue }
            for (_, child) in dict {
                if let found = findBool(key: key, in: child) { return found }
            }
        } else if let array = object as? [Any] {
            for child in array {
                if let found = findBool(key: key, in: child) { return found }
            }
        }
        return nil
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Float(values.count)
    }
}
