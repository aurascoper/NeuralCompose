import BCICloudBridge
import Foundation

/// What the privacy banner says about the runtimes, as data.
///
/// Extracted from `PrivacyIndicatorView` so the claims are testable. The
/// strings this replaces — `"the claude CLI"` and `"Listening + Cloud"` — were
/// literals inside a SwiftUI `body`, which meant the app's most consequential
/// privacy assertion was the one part of the codebase no test could reach.
/// They had also been wrong since runtime selection landed: with
/// `NEURALCOMPOSE_RUNTIME=ollama` the loop ran entirely on-device while the
/// banner reported cloud egress to Anthropic.
///
/// Every field here is derived from `ResolvedRuntimeIdentity`. Nothing is
/// derived from the mode name, the provider spelling, or a default.
struct RuntimeIdentityPresentation: Equatable {
    let involvesEgress: Bool
    let headline: String
    let dialogueLine: String
    let witnessLine: String
    let caption: String
    let badgeLabel: String
    let badgeSystemImage: String

    /// - Parameters:
    ///   - dialogue: the dialogue runtime's identity, or `nil` before the first
    ///     resolution attempt.
    ///   - witness: the Witness identity, or `nil` when the active profile has
    ///     no Witness.
    ///   - isDialectical: whether the active mode runs the competing poles.
    ///     Used **only** for the per-turn call count, never for provider or
    ///     locality.
    init(
        dialogue: ResolvedRuntimeIdentity?,
        witness: ResolvedRuntimeIdentity?,
        isDialectical: Bool
    ) {
        let active = [dialogue, witness].compactMap { $0 }

        // Unknown counts as egress. Before the first resolution there is no
        // identity to read, and a privacy banner must not claim on-device
        // operation it cannot substantiate. The safe default is the alarming
        // one.
        let egress = active.isEmpty || active.contains { $0.locality.involvesNetworkEgress }
        self.involvesEgress = egress

        self.headline = active.isEmpty
            ? "Resolving runtime"
            : (egress ? "Network egress active" : "On-device only")

        self.dialogueLine = Self.line("Dialogue", dialogue, absent: "Resolving…")
        self.witnessLine = Self.line("Witness", witness, absent: "Disabled")

        if active.isEmpty {
            self.caption =
                "The runtime has not resolved yet — treated as potential egress until it does."
        } else {
            let calls: String = isDialectical
                ? (witness != nil
                   ? "three calls per turn (the third is the non-voiced Witness)"
                   : "two calls per turn")
                : "one call per turn"
            self.caption = egress
                ? "Transcript text (never audio) may leave this device — \(calls). "
                    + "Opt-in exception — see decision_registry entry 8."
                : "Transcript text (never audio) stays on this device — \(calls) to a local runtime."
        }

        self.badgeLabel = egress ? "Listening + Cloud" : "Listening · On-device"
        self.badgeSystemImage = egress
            ? "antenna.radiowaves.left.and.right"
            : "desktopcomputer"
    }

    /// `role: provider · model · locality · readiness`.
    private static func line(
        _ title: String,
        _ identity: ResolvedRuntimeIdentity?,
        absent: String
    ) -> String {
        guard let identity else { return "\(title): \(absent)" }
        return "\(title): \(identity.displayProvider) · \(identity.displayModel) · "
            + "\(identity.locality.displayLabel) · \(identity.displayReadiness)"
    }
}
