import Foundation

public enum CalibrationLabel: String, Codable, CaseIterable, Sendable {
    case rest = "rest"
    case blink = "blink"
    case doubleBlink = "double_blink"
    case jawClench = "jaw_clench"
    case select = "select"
    case artifact = "artifact"

    public var keyboardCharacter: Character {
        switch self {
        case .rest:        return "r"
        case .blink:       return "b"
        case .doubleBlink: return "d"
        case .jawClench:   return "j"
        case .select:      return "s"
        case .artifact:    return "x"
        }
    }

    public var displayName: String {
        switch self {
        case .rest:        return "Rest"
        case .blink:       return "Blink"
        case .doubleBlink: return "Double Blink"
        case .jawClench:   return "Jaw Clench"
        case .select:      return "Select"
        case .artifact:    return "Artifact"
        }
    }

    public static func from(character: Character) -> CalibrationLabel? {
        Self.allCases.first { $0.keyboardCharacter == character.lowercased().first }
    }
}
