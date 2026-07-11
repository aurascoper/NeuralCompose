import Foundation

/// Marker for anything that can supply text into composition alongside EEG.
/// Lets the composition layer eventually accept new modalities (keyboard,
/// accessibility switch, gaze keyboard, external AAC devices) without further
/// changes, by giving each a stable identifier rather than baking modality
/// specifics into `TextCompositionController`.
public protocol TextInputSource: Sendable {
    var identifier: String { get }
}
