import Foundation

/// Track B vocabulary — the *experimental* closed-vocabulary imagined-speech
/// classifier. Kept entirely separate from `IntentClass` (motor/ocular Track A)
/// and `CalibrationLabel` (keyboard-driven gesture labels) so a stray retrain
/// of the production Track A model can't pick up these classes.
///
/// Binary Yes/No was chosen for the first cut because:
///  - Chance = 50%, so above-chance is easy to characterize statistically.
///  - Semantic separation (affirm vs reject) drives frontal asymmetry, which
///    is the only axis the Muse's AF7/AF8 frontal pair can plausibly resolve.
///  - "Yes/No" remains communicatively useful at modest accuracy when paired
///    with the LLM prompt loop.
///
/// `wordRest` is the silent-baseline class collected during the rest phase
/// of the cue/active/rest cadence; it is NOT the same physiological state as
/// Track A's `IntentClass.rest`, which captures gesture-rest, not cognitive
/// rest.
public enum ImaginedWordClass: Int, Sendable, Codable, CaseIterable, Hashable {
    case wordRest = 0
    case wordYes  = 1
    case wordNo   = 2

    /// Stable string used in the CSV events file. The Python evaluator reads
    /// this exact string; do not rename without updating
    /// `Scripts/evaluate-imagined-signal.py`.
    public var rawString: String {
        switch self {
        case .wordRest: return "rest"
        case .wordYes:  return "yes"
        case .wordNo:   return "no"
        }
    }

    /// Short label shown during the cue phase ("Prepare: YES").
    public var cueText: String {
        switch self {
        case .wordRest: return "REST"
        case .wordYes:  return "YES"
        case .wordNo:   return "NO"
        }
    }

    public var displayName: String {
        switch self {
        case .wordRest: return "Rest"
        case .wordYes:  return "Yes"
        case .wordNo:   return "No"
        }
    }

    /// Classes recorded during the *active* imagination phase. `.wordRest`
    /// is collected from the rest phase implicitly and is not part of the
    /// cued target set the protocol cycles through.
    public static let activeTargets: [ImaginedWordClass] = [.wordYes, .wordNo]
}
