import Foundation

/// Launch-environment configuration for the two-machine hypnagogic dialectic
/// bridge (`decision_registry.md` entry 9). `NEURALCOMPOSE_BRIDGE_PEER` and
/// `NEURALCOMPOSE_BRIDGE_SESSION` must both be present for the bridge to
/// activate; otherwise `AppViewModel.ensureHypnagogicLoopRunning()` builds
/// the original mic/speaker pair unchanged. Mirrors
/// `HypnagogicRuntimeConfiguration`'s env-var-only resolution — Finder/DMG
/// launches don't inherit shell variables, so this is a scripted-harness
/// affordance, not a UI toggle.
public struct PeerBridgeConfiguration: Sendable, Equatable {
    public let peerHost: String
    public let peerPort: UInt16
    public let session: String
    /// Sent once, verbatim, before the loop starts listening — this side is
    /// always the dialer, which per the fixed protocol sends the seed
    /// utterance. `nil` skips the seed (e.g. a peer already primed by
    /// another tool, or manual testing).
    public let seedText: String?

    /// Resolves from `NEURALCOMPOSE_BRIDGE_PEER` ("host:port"),
    /// `NEURALCOMPOSE_BRIDGE_SESSION`, and the optional
    /// `NEURALCOMPOSE_BRIDGE_SEED`. `nil` if the required pair is absent or
    /// `NEURALCOMPOSE_BRIDGE_PEER` isn't a well-formed "host:port".
    public static func resolve(environment: [String: String]) -> Self? {
        guard let peerRaw = environment["NEURALCOMPOSE_BRIDGE_PEER"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !peerRaw.isEmpty,
              let sessionRaw = environment["NEURALCOMPOSE_BRIDGE_SESSION"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sessionRaw.isEmpty
        else { return nil }

        let parts = peerRaw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }

        let seedRaw = environment["NEURALCOMPOSE_BRIDGE_SEED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            peerHost: String(parts[0]),
            peerPort: port,
            session: sessionRaw,
            seedText: (seedRaw?.isEmpty ?? true) ? nil : seedRaw
        )
    }
}
