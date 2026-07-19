import Foundation

/// User-facing, load-bearing caveats for the experimental spoken-generation
/// loop. Mirrors `WorldModelDemoHonesty`: these strings are shown, not
/// decorative, and must not be softened.
enum SpokenGenerationHonesty {
    /// Always visible under the toggle. States exactly what drives the loop.
    static let headerCaveat =
        "Experimental. Generation parameters (temperature, word choice) adapt to EEG signal quality — electrode contact and hardware confidence — NOT any brain-state or cognitive read. No trained model and no MPPI drive this; it is a plain generate-then-speak cadence."

    /// Shown while the loop is active. Speaking aloud during any EEG capture
    /// contaminates the recording.
    static let captureContaminationCaveat =
        "Speaking aloud during an EEG recording can contaminate it with muscle/jaw (EMG) and auditory-response artifact. Do not run during calibration, imagined-speech, or overnight capture."
}
