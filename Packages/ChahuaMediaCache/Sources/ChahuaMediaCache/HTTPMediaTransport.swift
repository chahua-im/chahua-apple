import Foundation

private struct AvatarHTTPTrace: Sendable {
    let key: String
    let load: String?
    let request: String
    let queuedAt: ContinuousClock.Instant

    func event(_ message: @autoclosure () -> String) {
        AvatarCacheTrace.$load.withValue(load) {
            AvatarCacheTrace.event("key=\(key) http=\(request) \(message())")
        }
    }
}

/// Admission is global to this transport; cancellation also removes requests that
/// have not yet acquired one of its four network slots.
actor HTTPMediaTransport {
    private struct Pending {
        let id: UUID
        let request: URLRequest
        let onResponse: @Sendable (HTTPURLResponse, Date, Date) async throws -> Void
        let onData: @Sendable (Data) async throws -> Void
        let continuation: CheckedContinuation<Void, any Error>
        let trace: AvatarHTTPTrace?
    }

    private let protocolClasses: [AnyClass]?
    private let clock: @Sendable () -> Date
    private var pending: [Pending] = []
    private var active: [UUID: HTTPExecution] = [:]
    private var closed = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(protocolClasses: [AnyClass]? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.protocolClasses = protocolClasses
        self.clock = clock
    }

    func execute(request: URLRequest,
                 onResponse: @escaping @Sendable (HTTPURLResponse, Date, Date) async throws -> Void,
                 onData: @escaping @Sendable (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard !closed else { continuation.resume(throwing: MediaCacheError.closed); return }
                guard HTTPExecution.isHTTPURL(request.url), request.url?.user == nil, request.url?.password == nil,
                      (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil,
                      request.value(forHTTPHeaderField: "Accept-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                    continuation.resume(throwing: MediaCacheError.invalidRequest)
                    return
                }
                let trace: AvatarHTTPTrace?
                if AvatarCacheTrace.enabled, let key = AvatarCacheTrace.transportKey {
                    trace = AvatarHTTPTrace(key: key, load: AvatarCacheTrace.load,
                                            request: String(id.uuidString.prefix(8)), queuedAt: .now)
                } else {
                    trace = nil
                }
                pending.append(Pending(id: id, request: request, onResponse: onResponse,
                                       onData: onData, continuation: continuation, trace: trace))
                trace?.event("event=http_queued active=\(active.count) pending=\(pending.count)")
                admit()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
    }

    func shutdown() async {
        closed = true
        let waiting = pending
        pending.removeAll()
        for request in waiting {
            if let trace = request.trace {
                trace.event("event=http_end outcome=closed stage=queued duration_ms=\(AvatarCacheTrace.milliseconds(since: trace.queuedAt))")
            }
            request.continuation.resume(throwing: MediaCacheError.closed)
        }
        for execution in active.values { execution.cancel(with: MediaCacheError.closed) }
        if !active.isEmpty {
            await withCheckedContinuation { shutdownWaiters.append($0) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let request = pending.remove(at: index)
            if let trace = request.trace {
                trace.event("event=http_end outcome=cancel stage=queued duration_ms=\(AvatarCacheTrace.milliseconds(since: trace.queuedAt))")
            }
            request.continuation.resume(throwing: CancellationError())
        } else {
            active[id]?.cancel(with: CancellationError())
        }
    }

    private func admit() {
        while !closed && active.count < 4 && !pending.isEmpty {
            let request = pending.removeFirst()
            if let trace = request.trace {
                trace.event("event=http_admitted wait_ms=\(AvatarCacheTrace.milliseconds(since: trace.queuedAt)) active=\(active.count + 1)")
            }
            let execution = HTTPExecution(request: request.request, protocolClasses: protocolClasses,
                                          clock: clock, trace: request.trace,
                                          onResponse: request.onResponse, onData: request.onData) { result in
                Task { await self.completed(request.id, continuation: request.continuation, result: result) }
            }
            active[request.id] = execution
            execution.start()
        }
    }

    private func completed(_ id: UUID, continuation: CheckedContinuation<Void, any Error>,
                           result: Result<Void, any Error>) {
        guard active.removeValue(forKey: id) != nil else { return }
        continuation.resume(with: result)
        admit()
        if closed && active.isEmpty {
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
}

/// Each admitted execution has its own serial delegate queue. That queue remains
/// inside the current delegate call until its asynchronous consumer has drained.
/// This deliberately uses at most four utility-queue waits, rather than spawning
/// an unbounded sequence of Tasks retaining response Data. No cooperative executor
/// is blocked. Other executions can still drain while one consumer awaits disk IO.
///
/// URLSession owns the incoming delegate Data; the only handoff to the consumer is
/// one batch of at most 1 MiB, with the task suspended until that handoff completes.
/// Mutable lifetime/cancellation state is lock-protected; HTTP delegate bookkeeping
/// is confined to the per-execution serial queue.
private final class HTTPExecution: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBatchBytes = 1_048_576
    private let request: URLRequest
    private let protocolClasses: [AnyClass]?
    private let clock: @Sendable () -> Date
    private let onResponse: @Sendable (HTTPURLResponse, Date, Date) async throws -> Void
    private let onData: @Sendable (Data) async throws -> Void
    private let onFinish: @Sendable (Result<Void, any Error>) -> Void
    private let trace: AvatarHTTPTrace?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var callback: Task<Void, Never>?
    private var failure: (any Error)?
    private var finished = false

    // Accessed only before start or on the serial delegate queue.
    private var sentAt: Date
    private var receivedResponse = false
    private var deliversBody = false
    private var expectedBodyBytes: Int64?
    private var receivedBodyBytes: Int64 = 0

    init(request: URLRequest, protocolClasses: [AnyClass]?, clock: @escaping @Sendable () -> Date,
         trace: AvatarHTTPTrace?,
         onResponse: @escaping @Sendable (HTTPURLResponse, Date, Date) async throws -> Void,
         onData: @escaping @Sendable (Data) async throws -> Void,
         onFinish: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        self.request = request
        self.protocolClasses = protocolClasses
        self.clock = clock
        self.onResponse = onResponse
        self.trace = trace
        self.onData = onData
        self.onFinish = onFinish
        sentAt = clock()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.name = "ChahuaMediaCache.HTTP.\(UUID().uuidString)"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
        if let trace {
            trace.event("event=http_resumed queue_to_resume_ms=\(AvatarCacheTrace.milliseconds(since: trace.queuedAt))")
        }
    }

    func cancel(with error: any Error) {
        let work: (URLSessionDataTask?, Task<Void, Never>?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            if failure == nil { failure = error }
            return (task, callback)
        }
        work.1?.cancel()
        work.0?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !receivedResponse, let response = response as? HTTPURLResponse,
              Self.isHTTPURL(response.url) else {
            cancel(with: MediaCacheError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        receivedResponse = true
        let receivedAt = clock()
        let sentAt = sentAt
        if let trace {
            trace.event("event=http_response status=\(response.statusCode) queue_to_response_ms=\(AvatarCacheTrace.milliseconds(since: trace.queuedAt))")
        }
        do {
            let contentLength = try HTTPRepresentation.validatedContentLength(of: response)
            deliversBody = response.statusCode == 200
            expectedBodyBytes = deliversBody ? contentLength : 0
            try handoff { [onResponse] in try await onResponse(response, sentAt, receivedAt) }
            completionHandler(.allow)
        } catch {
            cancel(with: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivedResponse else { cancel(with: MediaCacheError.invalidResponse); return }
        guard !data.isEmpty else { return }
        let (nextByteCount, overflow) = receivedBodyBytes.addingReportingOverflow(Int64(data.count))
        guard deliversBody, !overflow, expectedBodyBytes.map({ nextByteCount <= $0 }) ?? true else {
            cancel(with: MediaCacheError.invalidResponse)
            return
        }
        dataTask.suspend()
        do {
            if data.count <= Self.maximumBatchBytes {
                try handoff { [onData] in try await onData(data) }
            } else {
                // A URLProtocol may provide a delegate buffer larger than CFNetwork's
                // usual packet size. Never turn it into an asynchronous buffer queue.
                var offset = 0
                while offset < data.count {
                    let end = offset + min(Self.maximumBatchBytes, data.count - offset)
                    let batch = data.subdata(in: offset..<end)
                    try handoff { [onData] in try await onData(batch) }
                    offset = end
                }
            }
            receivedBodyBytes = nextByteCount
            dataTask.resume()
        } catch {
            cancel(with: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let validCompletion = receivedResponse
            && (expectedBodyBytes.map { $0 == receivedBodyBytes } ?? true)
        finish(error: error ?? (validCompletion ? nil : MediaCacheError.invalidResponse))
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        // Normally completion already settled the execution. This also covers a
        // session-level failure before URLSession can deliver a task response.
        finish(error: error ?? MediaCacheError.invalidResponse)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let target = request.url, Self.isHTTPURL(target), target.user == nil, target.password == nil,
              !(response.url?.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http") else {
            cancel(with: MediaCacheError.invalidResponse)
            completionHandler(nil)
            return
        }
        var redirected = request
        if !Self.sameOrigin(response.url, target) {
            for name in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "Host"] {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
        }
        redirected.cachePolicy = .reloadIgnoringLocalCacheData
        redirected.httpShouldHandleCookies = false
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        sentAt = clock()
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler: completionHandler)
    }

    private func answer(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Default trust evaluation validates TLS; it does not supply credentials.
            completionHandler(.performDefaultHandling, nil)
        } else {
            let error: any Error
            if let response = challenge.failureResponse as? HTTPURLResponse {
                error = MediaCacheError.httpStatus(response.statusCode)
            } else {
                error = URLError(.userAuthenticationRequired)
            }
            cancel(with: error)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func handoff(_ operation: @escaping @Sendable () async throws -> Void) throws {
        let result = HandoffResult()
        let semaphore = DispatchSemaphore(value: 0)
        try lock.withLock {
            if let failure { throw failure }
            guard !finished else { throw CancellationError() }
            callback = Task.detached(priority: .utility) { [trace] in
                do {
                    try Task.checkCancellation()
                    if let trace {
                        try await AvatarCacheTrace.$load.withValue(trace.load) { try await operation() }
                    } else {
                        try await operation()
                    }
                    try Task.checkCancellation()
                    result.set(.success(()))
                } catch { result.set(.failure(error)) }
                semaphore.signal()
            }
        }
        // Wait for cancellation to drain the consumer too: it may already own a
        // disk write that must finish before deletion or shutdown may return.
        semaphore.wait()
        let cancellation = lock.withLock {
            callback = nil
            return failure
        }
        if let cancellation { throw cancellation }
        try result.get().get()
    }

    private func finish(error: (any Error)?) {
        let completion: (URLSession?, Result<Void, any Error>)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let session = session
            self.session = nil
            self.task = nil
            let result: Result<Void, any Error>
            if let failure = failure ?? error { result = .failure(failure) }
            else { result = .success(()) }
            return (session, result)
        }
        guard let completion else { return }
        if let trace {
            let outcome: String
            switch completion.1 {
            case .success:
                outcome = "complete"
            case .failure(let failure):
                if failure is CancellationError || (failure as? URLError)?.code == .cancelled {
                    outcome = "cancel"
                } else if failure as? MediaCacheError == .closed {
                    outcome = "closed"
                } else {
                    outcome = "error"
                }
            }
            trace.event("event=http_end outcome=\(outcome) stage=active duration_ms=\(AvatarCacheTrace.milliseconds(since: trace.queuedAt))")
        }
        completion.0?.finishTasksAndInvalidate()
        onFinish(completion.1)
    }

    static func isHTTPURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host, !host.isEmpty, url.baseURL == nil,
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }
}

private final class HandoffResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Void, any Error>?
    func set(_ value: Result<Void, any Error>) { lock.withLock { self.value = value } }
    func get() -> Result<Void, any Error> {
        lock.withLock { value ?? .failure(MediaCacheError.invalidResponse) }
    }
}
