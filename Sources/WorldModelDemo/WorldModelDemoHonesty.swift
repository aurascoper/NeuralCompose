import Foundation

/// Always-visible caption text for `WorldModelMPCDemoView`, in the style of
/// `SpectralState.honestyCaveat` and `ImaginedSpeechCalibrationView`'s
/// "Track B is experimental..." line. These are load-bearing strings, not
/// incidental copy — do not soften or remove them.
public enum WorldModelDemoHonesty {
    /// Header caption, always visible at the top of the demo view.
    public static let headerCaveat =
        "Synthetic-task demo, not a brain-state read — the Encoder/Predictor were trained only on simulated 2D particle-navigation trajectories (WorldModel/README.md), never on EEG."

    /// Caption directly above the illustrative generation panel.
    public static let illustrativeMappingCaveat =
        "Illustrative only: the words below are real output from the on-device predictor, but the maxCandidates/temperature values feeding it are a hand-picked function of this synthetic planner's own diagnostics — not trained, not validated, and not a demonstrated connection between this task and real generation quality."

    /// Fixed, arbitrary prompt used only to exercise the illustrative panel.
    public static let illustrativeContext = "I would like to"
}
