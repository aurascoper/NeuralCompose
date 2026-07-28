import Foundation

/// Intercepts `URLSession` traffic so readiness probing can be tested without
/// a running Ollama daemon.
///
/// This exists so no test in this suite makes a real provider request. The
/// alternative — pointing tests at `localhost:11434` and hoping — makes the
/// suite pass or fail based on whether the developer happens to have `ollama
/// serve` running, which is the opposite of a regression test.
final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: Handler?
    nonisolated(unsafe) private static var storedRequestedURLs: [URL] = []

    static var handler: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }

    /// Every URL the code under test actually requested. Used to prove a probe
    /// *happened* — deleting the probe must fail a test, and a test that only
    /// checks the outcome would still pass if the outcome were hardcoded.
    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }; return storedRequestedURLs
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        storedHandler = nil
        storedRequestedURLs = []
    }

    /// A session wired to this protocol. Ephemeral so nothing is cached
    /// between tests.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Canned responses

    /// An `/api/tags` envelope listing the given models.
    static func tagsResponse(
        _ models: [(name: String, digest: String?)],
        for request: URLRequest,
        statusCode: Int = 200
    ) -> (HTTPURLResponse, Data) {
        let entries: [[String: Any]] = models.map { model in
            var entry: [String: Any] = ["name": model.name]
            if let digest = model.digest { entry["digest"] = digest }
            return entry
        }
        let body = try! JSONSerialization.data(withJSONObject: ["models": entries])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, body)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.storedRequestedURLs.append(url)
            Self.lock.unlock()
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
