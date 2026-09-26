import Foundation
import BCICore

/// The runtime choices exposed by the packaged app. These are reference
/// generators only; neither choice changes the production composition runtime.
public enum HypnagogicRuntimePreference: String, CaseIterable, Sendable, Identifiable {
    case ollama
    case claude

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ollama: return "Ollama"
        case .claude: return "Claude CLI"
        }
    }

    fileprivate var defaultModel: String {
        switch self {
        case .ollama: return "qwen2.5:0.5b"
        case .claude: return "claude-sonnet-5"
        }
    }
}

public enum HypnagogicRuntimeSource: Sendable, Equatable {
    case savedPreference
    case environment

    var label: String {
        switch self {
        case .savedPreference: return "Saved app setting"
        case .environment: return "Launch environment override"
        }
    }
}

/// Resolves the app-facing runtime configuration. Shell variables always win
/// for repeatable harnesses; Finder and DMG launches use a persisted app choice.
public struct HypnagogicRuntimeConfiguration: Sendable, Equatable {
    public static let preferenceKey = "hypnagogicRuntimePreference"

    public let runtimeName: String
    public let model: String
    public let source: HypnagogicRuntimeSource

    public static func resolve(
        environment: [String: String],
        preference: HypnagogicRuntimePreference
    ) -> Self {
        let environmentRuntime = environment["NEURALCOMPOSE_RUNTIME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentModel = environment["NEURALCOMPOSE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRuntimeOverride = !(environmentRuntime?.isEmpty ?? true)
        let hasModelOverride = !(environmentModel?.isEmpty ?? true)
        let runtimeName = hasRuntimeOverride ? environmentRuntime! : preference.rawValue
        let defaultModel = HypnagogicRuntimePreference(rawValue: runtimeName.lowercased())?.defaultModel
            ?? preference.defaultModel

        return Self(
            runtimeName: runtimeName,
            model: hasModelOverride ? environmentModel! : defaultModel,
            source: hasRuntimeOverride || hasModelOverride ? .environment : .savedPreference
        )
    }

    public var providerLabel: String {
        switch runtimeName.lowercased() {
        case "ollama": return "Ollama"
        case "claude": return "Claude CLI"
        default: return runtimeName
        }
    }

    public var transportLabel: String {
        switch runtimeName.lowercased() {
        case "ollama": return "local HTTP"
        case "claude": return "CLI"
        default: return "unresolved"
        }
    }

    public var isEnvironmentControlled: Bool { source == .environment }
}

/// UI-ready diagnostics for the selected reference runtime and current loop.
/// This records no dialogue text and is not part of interaction telemetry.
public struct HypnagogicRuntimeDiagnostics: Sendable, Equatable {
    public let configuration: HypnagogicRuntimeConfiguration
    public let promptProfile: String
    public let interactionStyle: String
    public let phase: HypnagogicLoopPhase
    public let turnCount: Int
    public let lastTurnAt: Date?
    public let lastFailure: String?

    public init(
        configuration: HypnagogicRuntimeConfiguration,
        promptProfile: String,
        interactionStyle: String,
        phase: HypnagogicLoopPhase = .stopped,
        turnCount: Int = 0,
        lastTurnAt: Date? = nil,
        lastFailure: String? = nil
    ) {
        self.configuration = configuration
        self.promptProfile = promptProfile
        self.interactionStyle = interactionStyle
        self.phase = phase
        self.turnCount = turnCount
        self.lastTurnAt = lastTurnAt
        self.lastFailure = lastFailure
    }

    public func updating(with status: HypnagogicLoopStatus) -> Self {
        Self(
            configuration: configuration,
            promptProfile: promptProfile,
            interactionStyle: interactionStyle,
            phase: status.phase,
            turnCount: status.turnIndex,
            lastTurnAt: status.lastTurnAt,
            lastFailure: status.lastFailure
        )
    }

    public func stopped() -> Self {
        Self(
            configuration: configuration,
            promptProfile: promptProfile,
            interactionStyle: interactionStyle,
            phase: .stopped,
            turnCount: turnCount,
            lastTurnAt: lastTurnAt,
            lastFailure: lastFailure
        )
    }
}

extension HypnagogicLoopPhase {
    var displayLabel: String {
        switch self {
        case .stopped: return "Stopped"
        case .listening: return "Listening"
        case .generating: return "Generating"
        case .speaking: return "Speaking"
        case .retrying: return "Retrying"
        }
    }
}
