import Foundation
import XCTest
@testable import ChahuaAPI

final class ChahuaAPITests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func testAuthenticateInstallsValidatedTokenForLaterRequests() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.append(request)
            guard request.url?.path == "/users/me" else { return (404, "") }
            return (200, #"{"uid":1,"username":"fixture","gender":0,"stickerPackOrder":[],"permissions":[],"avatarUrl":null}"#)
        }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            session: testSession()
        )

        _ = try await client.authenticate(candidateJWT: "candidate")
        _ = try await client.me()

        let recorded = requests.values
        XCTAssertEqual(recorded.map { $0.url?.path }, ["/users/me", "/users/me"])
        XCTAssertTrue(recorded.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer candidate" })
    }

    func testAuthenticateRejectsInvalidCandidateWithoutInstallingIt() async throws {
        StubURLProtocol.handler = { _ in (401, "") }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            session: testSession()
        )

        do { _ = try await client.authenticate(candidateJWT: "candidate"); XCTFail("Expected invalid token") }
        catch APIError.invalidToken { }
    }

    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("Missing handler") }
        let result = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
