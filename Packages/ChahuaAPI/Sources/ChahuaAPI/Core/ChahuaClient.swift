import Foundation

public actor ChahuaClient: ChahuaAPIClient {
    private let configuration: ChahuaConfiguration
    private let session: URLSession
    private let tokenStorage: any TokenStorage
    private var credential: ChahuaCredential?
    private var didLoadStoredToken = false
    private var refreshTask: Task<String, any Error>?

    public init(
        configuration: ChahuaConfiguration,
        session: URLSession? = nil,
        tokenStorage: any TokenStorage = InMemoryTokenStorage()
    ) {
        self.configuration = configuration
        self.tokenStorage = tokenStorage

        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.urlCache = nil
            sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    public func currentCredential() async throws -> ChahuaCredential? {
        if credential == nil, !didLoadStoredToken {
            didLoadStoredToken = true
            if let token = try await tokenStorage.loadToken() {
                credential = .session(token: token)
            }
        }
        return credential
    }

    public func setCredential(_ credential: ChahuaCredential?) async throws {
        self.credential = credential
        didLoadStoredToken = true

        switch credential {
        case let .session(token):
            try await tokenStorage.saveToken(token)
        case nil:
            try await tokenStorage.deleteToken()
        case .uid:
            break
        }
    }

    func send<Response: Decodable>(
        _ spec: HTTPRequestSpec,
        decoding: Response.Type
    ) async throws -> Response {
        let (data, status) = try await perform(spec)
        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(statusCode: status, description: String(describing: error))
        }
    }

    func send(_ spec: HTTPRequestSpec) async throws {
        _ = try await perform(spec)
    }

    private func perform(_ spec: HTTPRequestSpec) async throws -> (Data, Int) {
        let credential = spec.requiresAuth ? try await currentCredential() : nil
        let firstResponse = try await execute(spec, credential: credential)

        if firstResponse.status == 401,
           spec.allowsTokenRefresh,
           case .session = credential
        {
            let token = try await refreshedToken()
            let retryResponse = try await execute(spec, credential: .session(token: token))
            guard retryResponse.status != 401 else {
                throw APIError.unauthorized
            }
            guard (200 ..< 300).contains(retryResponse.status) else {
                throw APIError.http(status: retryResponse.status, body: retryResponse.data)
            }
            return retryResponse
        }

        guard (200 ..< 300).contains(firstResponse.status) else {
            throw APIError.http(status: firstResponse.status, body: firstResponse.data)
        }
        return firstResponse
    }

    private func execute(
        _ spec: HTTPRequestSpec,
        credential: ChahuaCredential?
    ) async throws -> (data: Data, status: Int) {
        let request = try makeRequest(spec, credential: credential)
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw APIError.unexpectedResponse
            }
            return (data, response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw APIError.transport(error)
        }
    }

    private func makeRequest(
        _ spec: HTTPRequestSpec,
        credential: ChahuaCredential?
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidBaseURL(configuration.baseURL)
        }

        components.path = components.path.hasSuffix("/")
            ? String(components.path.dropLast()) + spec.path
            : components.path + spec.path
        components.queryItems = spec.query.isEmpty ? nil : spec.query

        guard let url = components.url else {
            throw APIError.invalidBaseURL(configuration.baseURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType = spec.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let userAgent = configuration.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        switch credential {
        case let .session(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .uid(uid):
            request.setValue(String(uid), forHTTPHeaderField: "X-User-Id")
        case nil:
            break
        }
        request.httpMethod = spec.method.rawValue
        request.httpBody = spec.body
        request.timeoutInterval = configuration.requestTimeout
        return request
    }

    func refreshedToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task<String, any Error> { [self] in
            try await performRefresh()
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        do {
            let response = try await execute(
                HTTPRequestSpec(
                    method: .post,
                    path: "/auth/refresh",
                    requiresAuth: true,
                    allowsTokenRefresh: false
                ),
                credential: try await currentCredential()
            )
            guard (200 ..< 300).contains(response.status) else {
                throw APIError.http(status: response.status, body: response.data)
            }
            let token = try JSONCoding.decoder.decode(AuthTokenResponse.self, from: response.data).token
            credential = .session(token: token)
            try await tokenStorage.saveToken(token)
            return token
        } catch {
            credential = nil
            try? await tokenStorage.deleteToken()
            throw APIError.unauthorized
        }
    }
}
