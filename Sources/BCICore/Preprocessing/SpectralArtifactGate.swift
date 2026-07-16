import Foundation

/// Swift mirror of `Scripts/eeg_spectral.py::window_is_clean`. Frontal
/// blinks/EOG saccades and movement/EMG twitches produce voltage swings far
/// larger than cortical rhythms. A blink is band-specific (a huge slow delta
/// transient), so it survives band-ratio normalization and would masquerade
/// as slow-wave/deep activity. Reject such windows on raw amplitude BEFORE
/// any spectral projection — band ratios cancel a broadband gain change
/// (impedance drift) but NOT a band-specific spike like a blink.
public enum SpectralArtifactGate {

    /// ~150 uV cleanly separates real EEG (tens of uV) from blink/movement
    /// artifacts (hundreds of uV), well under Muse ADC saturation. Matches
    /// `ARTIFACT_PEAK_UV` in `eeg_spectral.py` exactly.
    public static let defaultPeakThresholdMicrovolts: Float = 150.0

    /// True if no channel in `window` swings beyond `+/-thresholdMicrovolts`.
    public static func isClean(
        _ window: EEGWindow,
        thresholdMicrovolts: Float = defaultPeakThresholdMicrovolts
    ) -> Bool {
        guard !window.samples.isEmpty else { return false }
        for channel in window.samples {
            for value in channel where abs(value) > thresholdMicrovolts {
                return false
            }
        }
        return true
    }
}
