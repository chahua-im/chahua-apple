import Foundation

/// Per-host handlers keep concurrent tests independent, including delayed callbacks.
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (FixtureURLProtocol) -> Void
    private static let registry = Registry()
    private let state = State()

    static func install(_ handler: @escaping Handler) -> URL {
        let host = UUID().uuidString.lowercased() + ".invalid"
        registry.set(host, handler)
        return URL(string: "https://\(host)/asset")!
    }

    static func uninstall(_ url: URL) { registry.set(url.host!, nil) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let handler = Self.registry.get(host) else {
            fail(URLError(.resourceUnavailable))
            return
        }
        handler(self)
    }
    override func stopLoading() { state.cancel() }
    var wasCancelled: Bool { state.cancelled }

    func respond(status: Int = 200, headers: [String: String], body: Data, finish: Bool = true) {
        guard let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { send(body) }
        if finish { complete() }
    }
    func send(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func complete() { client?.urlProtocolDidFinishLoading(self) }
    func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]
        func set(_ host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }
        func get(_ host: String) -> Handler? { lock.withLock { handlers[host] } }
    }
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var cancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }
}

final class FixtureRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FixtureURLProtocol] = []
    var values: [FixtureURLProtocol] { lock.withLock { stored } }
    func append(_ value: FixtureURLProtocol) { lock.withLock { stored.append(value) } }
}

final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date()) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}
