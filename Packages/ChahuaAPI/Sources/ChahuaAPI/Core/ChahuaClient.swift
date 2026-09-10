import Foundation

/// Actor-backed production implementation of `ChahuaAPIClient`.
///
/// A client owns one bearer-token session. Authenticate it once, then share that
/// instance across callers. Authenticated requests refresh a rejected token once;
/// callers receiving `APIError.invalidToken` must clear their persisted session.
public actor ChahuaClient: ChahuaAPIClient, RealtimeConnectionProviding {
    private let configuration: ChahuaConfiguration
    private let session: URLSession
    private var token: String?
    private var refreshTask: Task<String, any Error>?
    private var sessionGeneration = UUID()

    /// Creates a client with an optional already-validated token.
    ///
    /// Supply `session` only for deterministic transport tests. The default
    /// session disables URL caching and uses `configuration.requestTimeout`.
    public init(
        configuration: ChahuaConfiguration,
        token: String? = nil,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.default
            sessionConfiguration.urlCache = nil
            sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    public func authenticate(candidateJWT: String) async throws -> MeResponse {
        let generation = sessionGeneration
        let candidate = candidateJWT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw APIError.invalidToken }
        let me = try await fetchMe(token: candidate)
        try checkSession(generation)
        installSessionToken(candidate)
        return me
    }

    public func createDevSession(uid: Int32, clientID: String) async throws -> String {
        let generation = sessionGeneration
        guard uid > 0, !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.invalidResponse(statusCode: 400)
        }
        let spec = try HTTPRequestSpec.json(
            .post,
            ["auth", "dev-session"],
            body: DevSessionRequest(uid: uid),
            requiresAuth: false,
            allowsTokenRefresh: false,
            headers: ["X-Client-Id": clientID]
        )
        let (data, status) = try await execute(spec, token: nil)
        try checkSession(generation)
        guard status == 200 else { throw APIError.invalidResponse(statusCode: status) }
        let devSessionToken = try decodeAuthToken(data, status: status)
        installSessionToken(devSessionToken)
        return devSessionToken
    }

    /// Opens with the current HTTP session JWT; only the first pong establishes readiness.
    /// An existing refresh is shared, but opening a socket never starts a refresh.
    public func openRealtimeConnection() async throws -> any RealtimeConnection {
        let generation = sessionGeneration
        var connection: URLSessionRealtimeConnection?
        do {
            if let refreshTask { _ = try await refreshTask.value }
            try checkSession(generation)
            guard let token, !token.isEmpty else { throw APIError.invalidToken }
            guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
                throw APIError.invalidBaseURL(configuration.baseURL)
            }
            switch components.scheme?.lowercased() {
            case "https": components.scheme = "wss"
            case "http": components.scheme = "ws"
            default: throw APIError.invalidBaseURL(configuration.baseURL)
            }
            components.path = components.path.hasSuffix("/")
                ? components.path + "ws"
                : components.path + "/ws"
            components.query = nil
            components.fragment = nil
            components.user = nil
            components.password = nil
            guard let url = components.url, components.host?.isEmpty == false else {
                throw APIError.invalidBaseURL(configuration.baseURL)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = configuration.requestTimeout
            if let userAgent = configuration.userAgent {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            let socket = session.webSocketTask(with: request)
            let opened = URLSessionRealtimeConnection(socket: socket)
            connection = opened
            socket.resume()
            try await opened.authenticate(ticket: token)
            try checkSession(generation)
            try await opened.sendPing(state: .active)
            try checkSession(generation)
            return opened
        } catch {
            if let connection { await connection.close() }
            try checkSession(generation)
            throw error
        }
    }

    private func installSessionToken(_ token: String) {
        sessionGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        self.token = token
    }

    private func checkSession(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    public func me() async throws -> MeResponse {
        try await send(HTTPRequestSpec(method: .get, path: ["users", "me"]), decoding: MeResponse.self)
    }

    func send<Response: Decodable>(_ spec: HTTPRequestSpec, decoding: Response.Type) async throws -> Response {
        let generation = sessionGeneration
        let (data, status) = try await perform(spec)
        try checkSession(generation)
        do { return try JSONCoding.decoder.decode(Response.self, from: data) }
        catch { throw APIError.decoding(statusCode: status, description: String(describing: error)) }
    }

    func send(_ spec: HTTPRequestSpec) async throws {
        let generation = sessionGeneration
        _ = try await perform(spec)
        try checkSession(generation)
    }

    private func perform(_ spec: HTTPRequestSpec) async throws -> (Data, Int) {
        let generation = sessionGeneration
        let initialToken = spec.requiresAuth ? token : nil
        let firstResponse = try await execute(spec, token: initialToken)
        try checkSession(generation)
        if firstResponse.status == 401, spec.allowsTokenRefresh, initialToken != nil {
            let refreshed: String
            do { refreshed = try await refreshedToken() }
            catch {
                try checkSession(generation)
                throw error
            }
            try checkSession(generation)
            let retryResponse = try await execute(spec, token: refreshed)
            try checkSession(generation)
            if retryResponse.status == 401 {
                token = nil
                throw APIError.invalidToken
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

    private func execute(_ spec: HTTPRequestSpec, token: String?) async throws -> (data: Data, status: Int) {
        let generation = sessionGeneration
        let request = try makeRequest(spec, token: token)
        do {
            let (data, response) = try await session.data(for: request)
            try checkSession(generation)
            guard let response = response as? HTTPURLResponse else { throw APIError.unexpectedResponse }
            return (data, response.statusCode)
        } catch {
            try checkSession(generation)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw APIError.transport(error)
            }
            throw error
        }
    }

    private func makeRequest(_ spec: HTTPRequestSpec, token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidBaseURL(configuration.baseURL)
        }
        let path = try spec.encodedPath()
        components.percentEncodedPath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) + path
            : components.percentEncodedPath + path
        components.queryItems = spec.query.isEmpty ? nil : spec.query
        guard let url = components.url else { throw APIError.invalidBaseURL(configuration.baseURL) }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType = spec.contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let userAgent = configuration.userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        for (field, value) in spec.headers { request.setValue(value, forHTTPHeaderField: field) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpMethod = spec.method.rawValue
        request.httpBody = spec.body
        request.timeoutInterval = configuration.requestTimeout
        return request
    }

    private func fetchMe(token: String) async throws -> MeResponse {
        let generation = sessionGeneration
        let spec = HTTPRequestSpec(method: .get, path: ["users", "me"], requiresAuth: false, allowsTokenRefresh: false)
        let (data, status) = try await execute(spec, token: token)
        try checkSession(generation)
        if status == 401 { throw APIError.invalidToken }
        guard (200 ..< 300).contains(status) else { throw APIError.invalidResponse(statusCode: status) }
        do { return try JSONCoding.decoder.decode(MeResponse.self, from: data) }
        catch { throw APIError.decoding(statusCode: status, description: String(describing: error)) }
    }

    private func decodeAuthToken(_ data: Data, status: Int) throws -> String {
        do {
            let token = try JSONCoding.decoder.decode(AuthTokenResponse.self, from: data).token
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw APIError.invalidToken }
            return token
        } catch let error as APIError { throw error }
        catch { throw APIError.decoding(statusCode: status, description: String(describing: error)) }
    }

    private func refreshedToken() async throws -> String {
        let generation = sessionGeneration
        let task: Task<String, any Error>
        let ownsTask: Bool
        if let refreshTask {
            task = refreshTask
            ownsTask = false
        } else {
            task = Task { [self] in try await performRefresh(generation: generation) }
            refreshTask = task
            ownsTask = true
        }
        defer {
            if ownsTask, generation == sessionGeneration { refreshTask = nil }
        }
        do {
            let refreshed = try await task.value
            try checkSession(generation)
            return refreshed
        } catch {
            try checkSession(generation)
            throw error
        }
    }

    private func performRefresh(generation: UUID) async throws -> String {
        try checkSession(generation)
        guard let token else { throw APIError.invalidToken }
        let spec = HTTPRequestSpec(method: .post, path: ["auth", "refresh"], requiresAuth: false, allowsTokenRefresh: false)
        let response = try await execute(spec, token: token)
        try checkSession(generation)
        if response.status == 401 {
            self.token = nil
            throw APIError.invalidToken
        }
        guard (200 ..< 300).contains(response.status) else {
            throw APIError.invalidResponse(statusCode: response.status)
        }
        let refreshed = try decodeAuthToken(response.data, status: response.status)
        self.token = refreshed
        return refreshed
    }
}
