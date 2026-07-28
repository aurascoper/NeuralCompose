import Foundation

/// Answers *"can this exact model run right now?"* before the loop is enabled,
/// without generating anything.
///
/// The gap this closes: `LiveRuntimeFactory` previously constructed an Ollama
/// runtime for whatever model name it was handed. An unpulled model resolved
/// fine and failed at the first generation — after the loop was enabled, after
/// the privacy banner claimed an active runtime, and at a point where the only
/// recovery left was an error mid-conversation.
///
/// The probe reads `GET /api/tags`, which lists locally pulled models. It is
/// **not** a generation request: no prompt is sent, so a readiness check can
/// never itself constitute egress.
public struct OllamaReadinessProbe: Sendable {

    /// A model the daemon actually has.
    public struct AvailableModel: Sendable, Equatable {
        public let name: String
        public let digest: String?
        public init(name: String, digest: String?) {
            self.name = name
            self.digest = digest
        }
    }

    public enum ProbeOutcome: Sendable, Equatable {
        /// The exact requested model is present. Carries the canonical name the
        /// daemon reports, which may differ from the request by an implicit tag.
        case present(AvailableModel)
        /// The daemon answered, but does not have the requested model.
        case modelMissing(available: [String])
        /// The daemon did not answer within the bounded timeout, or answered
        /// unusably. The associated text is for the log, never for the UI.
        case unreachable(detail: String)
    }

    public let baseURL: URL
    public let session: URLSession
    /// Bounded so a hung daemon cannot stall loop startup indefinitely.
    public let timeout: TimeInterval

    public init(
        baseURL: URL,
        session: URLSession? = nil,
        timeout: TimeInterval = 3.0
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = timeout
            cfg.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Probes for `model`. Never throws — an infrastructure failure is a
    /// *value* here, because the caller has to fold it into a readiness verdict
    /// rather than propagate it as a generation error.
    public func probe(model: String) async -> ProbeOutcome {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable(detail: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .unreachable(detail: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            return .unreachable(detail: "HTTP \(http.statusCode)")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["models"] as? [[String: Any]]
        else {
            return .unreachable(detail: "unparseable /api/tags envelope")
        }

        let available: [AvailableModel] = entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return AvailableModel(name: name, digest: entry["digest"] as? String)
        }

        if let exact = available.first(where: { $0.name == model }) {
            return .present(exact)
        }
        // Ollama stores an untagged pull under `:latest`, so a request for
        // `qwen2.5` and a stored `qwen2.5:latest` are the same model. This is
        // canonicalization, not fuzzy matching: no other tag substitutes, and
        // the *stored* name is what gets recorded so the UI shows what is
        // actually loaded rather than what was typed.
        if !model.contains(":"),
           let tagged = available.first(where: { $0.name == "\(model):latest" }) {
            return .present(tagged)
        }
        return .modelMissing(available: available.map(\.name))
    }
}
