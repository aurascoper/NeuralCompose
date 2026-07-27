import Foundation

/// **A resolved runtime object is not a resolved runtime identity.**
///
/// The runtime performs generation. The identity is an immutable, sanitized
/// *description* of what actually resolved — consumed by telemetry, readiness
/// logic, health reporting, and the privacy UI, none of which should hold a
/// live generator to answer "what is running?".
///
/// The separation is load-bearing for two reasons.
///
/// 1. **Failure still has an identity.** When resolution fails there is no
///    runtime object at all, but the UI must still be able to say
///    *"Requested: Ollama / qwen2.5:0.5b — model unavailable — on-device"*.
///    A description that only exists on success cannot do that.
/// 2. **Requested ≠ resolved.** Keeping both pairs makes substitution
///    *visible* rather than inferable. A UI that renders only the resolved
///    provider cannot distinguish "you asked for Ollama and got it" from
///    "you asked for Ollama and something silently handed you Claude".
public struct ResolvedRuntimeIdentity: Codable, Sendable, Equatable {
    public let role: RuntimeRole
    public let requestedProvider: String
    public let requestedModel: String
    public let resolvedProvider: String
    public let resolvedModel: String
    /// Provider-reported content digest, when the provider exposes one.
    /// Ollama reports a digest per model; the Claude CLI does not, so this is
    /// `nil` on that path rather than a fabricated value.
    public let modelDigest: String?
    public let locality: RuntimeLocality
    public let readiness: RuntimeReadiness
    public let promptProfile: String
    /// sha256 of the bytes that will actually be transmitted — not of the
    /// profile on disk. On the system-prompt-override path those differ, and
    /// hashing the profile would attest to bytes never sent.
    public let promptHash: String
    public let systemPromptSource: String

    public init(
        role: RuntimeRole,
        requestedProvider: String,
        requestedModel: String,
        resolvedProvider: String,
        resolvedModel: String,
        modelDigest: String? = nil,
        locality: RuntimeLocality,
        readiness: RuntimeReadiness,
        promptProfile: String,
        promptHash: String,
        systemPromptSource: String
    ) {
        self.role = role
        self.requestedProvider = requestedProvider
        self.requestedModel = requestedModel
        self.resolvedProvider = resolvedProvider
        self.resolvedModel = resolvedModel
        self.modelDigest = modelDigest
        self.locality = locality
        self.readiness = readiness
        self.promptProfile = promptProfile
        self.promptHash = promptHash
        self.systemPromptSource = systemPromptSource
    }

    /// True when the resolved provider/model differ from what was requested.
    /// The privacy UI treats this as a disclosure condition: a substitution the
    /// user did not choose must never be silent.
    ///
    /// Models are compared *canonically*: `OllamaReadinessProbe` deliberately
    /// accepts a stored `name:latest` for an untagged request — the daemon
    /// stores an untagged pull under `:latest`, so they are the same model —
    /// and the identity records the stored name. Comparing the raw strings
    /// here made the same resolution simultaneously "accepted as the same
    /// model by readiness" and "reported as a substitution by identity". A
    /// canonical `:latest` resolution is not a substitution alarm; any other
    /// difference still is.
    public var isSubstitution: Bool {
        resolvedProvider != requestedProvider
            || Self.canonicalModelName(resolvedModel) != Self.canonicalModelName(requestedModel)
    }

    /// An untagged model name canonicalizes to `name:latest`, mirroring the
    /// probe's one allowed equivalence. Empty stays empty (the failure-path
    /// identity, where nothing resolved) so no phantom tag is fabricated.
    static func canonicalModelName(_ name: String) -> String {
        name.isEmpty || name.contains(":") ? name : name + ":latest"
    }

    /// The *strict* predicate: the endpoint and exact model were verified.
    /// Deliberately false for a `configured` Claude runtime, which is usable
    /// but unproven — see `canAttemptGeneration` for the usability question.
    public var isReady: Bool { readiness == .ready }

    /// The *usability* predicate: generation may be attempted. True for both
    /// `configured` and `ready`.
    public var canAttemptGeneration: Bool { readiness.canAttemptGeneration }

    /// Human-readable provider name for display. Falls back to the *requested*
    /// provider when nothing resolved, so a failed identity still names what
    /// the user asked for instead of rendering an empty cell.
    public var displayProvider: String {
        Self.providerDisplayName(resolvedProvider.isEmpty ? requestedProvider : resolvedProvider)
    }

    public var displayModel: String {
        resolvedModel.isEmpty ? requestedModel : resolvedModel
    }

    /// What resolution actually proved, or the specific reason it failed.
    ///
    /// `ready` names its evidence rather than saying "Ready", because the whole
    /// point of the `configured` split is that the user can tell the two apart.
    public var displayReadiness: String {
        switch readiness {
        case .configured:               return "Configured"
        case .ready:                    return "Endpoint + model verified"
        case .unavailable(let failure): return failure.displayLabel
        }
    }

    private static func providerDisplayName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude CLI"
        case "ollama": return "Ollama"
        case "":       return "—"
        default:       return id
        }
    }
}

/// The role a runtime plays. Roles are *not* interchangeable even when they
/// resolve to the same provider and model, because they carry different prompts
/// — which is exactly the confusion this type exists to make impossible.
public enum RuntimeRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// The dialectical poles. Waking-dialectical prompt.
    case dialectic
    /// The non-voiced post-compete observer. Witness prompt.
    case witness
    /// The plain non-competing reply loop (`HypnagogicDialogueLoop`).
    ///
    /// Not in the original A2 sketch, which named only `dialectic` and
    /// `witness`. Added because the mirror loop resolves its own runtime with a
    /// *third* prompt profile, and filing it under `.dialectic` would make the
    /// identity assert a role and prompt the runtime does not have.
    case mirror
}

/// Where inference actually happens.
///
/// **A local executable does not imply local inference.** The Claude CLI is a
/// local binary that brokers to a remote service; labelling it `onDevice`
/// because the process is local is the single most consequential lie this
/// enum prevents, since it is the app's one deliberate network-egress path.
public enum RuntimeLocality: String, Codable, Sendable, Equatable, CaseIterable {
    /// Inference runs on this machine. Ollama bound to a loopback address.
    case onDevice
    /// A local process or endpoint that forwards to a remote service.
    /// The Claude CLI. Text leaves the device.
    case localBrokerToRemoteService
    /// A non-loopback endpoint. Ollama on another host. Text leaves the device.
    case remoteEndpoint
    /// No locality could be established — an unsupported provider name, so
    /// there is no endpoint or executable to classify. Distinct from the three
    /// known localities because an unknown provider is *not known* to be a
    /// local broker (the previous classification), any more than it is known
    /// to be on-device: unknown ≠ on-device, unknown ≠ known remote broker,
    /// unknown = egress unverified. Egress is still assumed (the safe
    /// direction) while the label says it is unverified (the honest one).
    case unresolved

    /// Whether text leaves the machine on this locality. The privacy UI reads
    /// this rather than pattern-matching provider names. `unresolved` counts
    /// as egress: a banner must not claim on-device operation it cannot
    /// substantiate.
    public var involvesNetworkEgress: Bool { self != .onDevice }

    public var displayLabel: String {
        switch self {
        case .onDevice:                  return "On-device"
        case .localBrokerToRemoteService: return "Local broker → remote service"
        case .remoteEndpoint:            return "Remote endpoint"
        case .unresolved:                return "Egress unverified"
        }
    }
}

/// Whether a runtime may be used, and *on what evidence*. `unavailable` is a
/// *pre-generation* verdict: the loop must not start, and no alternate provider
/// is attempted.
///
/// The success side is split because the two resolution paths prove different
/// things and used to report the same word for both.
///
/// - Ollama contacts `/api/tags` and requires the exact requested model before
///   enablement, so its success is a *positively observed* fact about the
///   endpoint: the daemon answered and holds that model.
/// - Claude resolves an executable and loads a prompt. Nothing contacts the
///   provider. An expired `claude login`, an unreachable network, or a model
///   name the account cannot use all still resolve.
///
/// Collapsing those into one `ready` made the failure side of this type strictly
/// more precise than the success side: six distinct reasons a runtime cannot be
/// used, one undifferentiated reason it can. `configured` closes that gap.
public enum RuntimeReadiness: Codable, Sendable, Equatable {
    /// Local construction prerequisites resolved, but no real provider or
    /// exact-model round trip has been observed.
    case configured

    /// The configured endpoint/provider and exact requested model were
    /// positively verified before enablement.
    case ready

    /// The runtime must not be used.
    case unavailable(RuntimeReadinessFailure)

    /// Whether generation may be attempted at all. Both success cases qualify:
    /// `configured` is unverified, not broken, and a UI that painted it as a
    /// fault would trade one false claim for its mirror image.
    ///
    /// Read this for *usability*; read `isReady` for *verified* usability. The
    /// two are deliberately different questions.
    public var canAttemptGeneration: Bool {
        switch self {
        case .configured, .ready: return true
        case .unavailable:        return false
        }
    }

    public var failure: RuntimeReadinessFailure? {
        if case .unavailable(let f) = self { return f }
        return nil
    }
}

/// Why a runtime is unavailable.
///
/// These are *infrastructure* verdicts. They are deliberately not expressible
/// as a policy outcome: a missing model is a broken configuration, not a
/// considered decision to abstain, and collapsing the two would let an
/// infrastructure failure masquerade as a reasoned result.
public enum RuntimeReadinessFailure: String, Codable, Sendable, Equatable, CaseIterable {
    /// No executable named `claude` resolved.
    case executableNotFound
    /// An executable resolved but failed validation.
    case executableInvalid
    /// The prompt resource was missing, empty, or unreadable.
    case promptResourceUnavailable
    /// The endpoint did not answer within the bounded probe timeout.
    case endpointUnreachable
    /// The endpoint answered but does not have the exact requested model.
    case modelMissing
    /// The requested provider name is not one this factory supports.
    case unknownProvider

    public var displayLabel: String {
        switch self {
        case .executableNotFound:        return "CLI not found"
        case .executableInvalid:         return "CLI not usable"
        case .promptResourceUnavailable: return "Prompt resource unavailable"
        case .endpointUnreachable:       return "Endpoint unreachable"
        case .modelMissing:              return "Model unavailable"
        case .unknownProvider:           return "Unknown provider"
        }
    }
}

/// A resolution failure that still carries a displayable identity.
///
/// `publicMessage` is safe to render in the UI and to write to `lastError`.
/// `internalDetail` is for the log only and may contain paths or transport
/// text; it is never interpolated into `publicMessage`.
///
/// The sanitization boundary is enforced at construction rather than at the
/// display site, because a display site that has to remember to sanitize will
/// eventually forget, and the value it forgets to sanitize here is the user's
/// full environment `PATH`.
public struct RuntimeResolutionFailure: Error, Sendable, CustomStringConvertible {
    public let identity: ResolvedRuntimeIdentity
    public let code: RuntimeReadinessFailure
    public let publicMessage: String
    public let internalDetail: String?

    public init(
        identity: ResolvedRuntimeIdentity,
        code: RuntimeReadinessFailure,
        publicMessage: String,
        internalDetail: String? = nil
    ) {
        self.identity = identity
        self.code = code
        self.publicMessage = publicMessage
        self.internalDetail = internalDetail
    }

    /// `description` is the *public* message. `String(describing:)` is what
    /// call sites reach for by reflex, so the reflex must be the safe one.
    public var description: String { publicMessage }
}

/// Redaction helpers for values that reach the UI or `lastError`.
public enum RuntimeIdentityRedaction {

    /// An endpoint reduced to scheme, host, and port.
    ///
    /// Drops user-info (credentials), path, query, and fragment. Ollama's base
    /// URL is operator-configurable, so it can carry a token in a query string
    /// or basic-auth credentials in the authority — neither belongs in a
    /// privacy banner.
    public static func endpoint(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<endpoint>"
        }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? "<endpoint>"
    }

    /// Whether a URL's host is a loopback address — the test that separates
    /// `onDevice` from `remoteEndpoint`.
    ///
    /// `.local` mDNS names and LAN addresses are deliberately NOT loopback:
    /// they are other machines, and inference there is not on-device.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host == "[::1]" || host == "0.0.0.0"
    }
}
