import ChahuaAPI
import Foundation

nonisolated enum OutgoingAttachmentUploadError: LocalizedError {
    case unsafeAllocation
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unsafeAllocation: "The attachment upload URL or headers are invalid."
        case .invalidResponse: "The attachment upload returned an invalid response."
        case .httpStatus(let status): "The attachment upload failed (HTTP \(status))."
        }
    }
}

nonisolated struct OutgoingAttachmentUploader: Sendable {
    let directory: URL

    func upload(
        file: URL,
        allocation: OutgoingUploadAllocation,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let validation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try OutgoingImageFiles.file(file, directory: directory)
        }
        let source = try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: {
            validation.cancel()
        }
        try Task.checkCancellation()
        let url = allocation.uploadURL
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, url.user == nil, url.password == nil,
            !allocation.headers.keys.contains(where: {
                ["authorization", "proxy-authorization", "cookie"].contains($0.lowercased())
            })
        else { throw OutgoingAttachmentUploadError.unsafeAllocation }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in allocation.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // This transport is deliberately independent of ChahuaClient's authenticated session.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let progress = UploadProgressDelegate(onProgress: onProgress)
        onProgress(0)
        do {
            // Foundation's async upload owns cancellation, including cancellation before task registration.
            let (_, response) = try await session.upload(for: request, fromFile: source, delegate: progress)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw OutgoingAttachmentUploadError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw OutgoingAttachmentUploadError.httpStatus(response.statusCode)
            }
            onProgress(1)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }
}

nonisolated private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // A presigned request is valid only for its original target; never forward signed headers.
        completionHandler(nil)
    }
}
