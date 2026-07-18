import XCTest
@testable import BCICore

final class TelemetryEventTests: XCTestCase {

    private func makeEvent() -> TelemetryEvent {
        TelemetryEvent(
            eventId: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_752_000_000),
            composedContextBeforeCommit: "the quick brown",
            committedWord: "fox",
            signalQuality: "healthy",
            detectedSpectralState: "Engaged/focused",
            appliedMaxCandidates: 3,
            appliedTemperature: 0.7,
            appliedStyleInstruction: "",
            adaptiveComplexityEnabled: true
        )
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let original = makeEvent()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TelemetryEvent.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testEncodesAsSingleFlatJSONObject() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(makeEvent())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(object, "must decode as a single flat JSON object, not an array or nested structure")
        XCTAssertEqual(object?["committedWord"] as? String, "fox")
        XCTAssertEqual(object?["detectedSpectralState"] as? String, "Engaged/focused")
    }

    func testNilOptionalFieldsRoundTrip() throws {
        // Fixed whole-second timestamp, not `Date()`: `.iso8601` encoding
        // truncates sub-second precision, so a `Date()` timestamp would
        // fail equality after round-tripping even though nothing is
        // actually broken — this feature only needs commit-granularity
        // timestamps, not sub-second precision.
        let original = TelemetryEvent(
            timestamp: Date(timeIntervalSince1970: 1_752_000_000),
            composedContextBeforeCommit: "",
            committedWord: "hello",
            signalQuality: nil,
            detectedSpectralState: nil,
            appliedMaxCandidates: 3,
            appliedTemperature: 0.7,
            appliedStyleInstruction: "",
            adaptiveComplexityEnabled: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TelemetryEvent.self, from: data)

        XCTAssertNil(decoded.signalQuality)
        XCTAssertNil(decoded.detectedSpectralState)
        XCTAssertEqual(decoded, original)
    }
}
