import Foundation

/// Ephemeral upload instructions for one allocation-and-PUT attempt.
public struct OutgoingUploadAllocation: Sendable {
    public let attachmentId: String
    public let uploadURL: URL
    public let headers: [String: String]

    public init(attachmentId: String, uploadURL: URL, headers: [String: String]) {
        self.attachmentId = attachmentId
        self.uploadURL = uploadURL
        self.headers = headers
    }
}

public struct AttachmentConfigResponse: Codable, Equatable, Sendable {
    public let maxFileSizeBytes: Int64

    public init(maxFileSizeBytes: Int64) {
        self.maxFileSizeBytes = maxFileSizeBytes
    }
}

private struct AttachmentUploadBody: Encodable {
    let filename: String
    let contentType: String
    let size: Int64
    let purpose = "media"
    let width: Int
    let height: Int
    let order: Int
}

private struct AttachmentUploadResponse: Decodable {
    let attachmentId: String
    let uploadUrl: URL
    let uploadHeaders: [String: String]
}

public extension ChahuaClient {
    func attachmentConfig() async throws -> AttachmentConfigResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["attachments", "config"]),
            decoding: AttachmentConfigResponse.self
        )
    }

    func requestAttachmentUpload(
        fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int
    ) async throws -> OutgoingUploadAllocation {
        let response = try await send(
            HTTPRequestSpec.json(.post, ["attachments", "upload-url"], body: AttachmentUploadBody(
                filename: fileName, contentType: contentType, size: size,
                width: width, height: height, order: order
            )),
            decoding: AttachmentUploadResponse.self
        )
        return OutgoingUploadAllocation(
            attachmentId: response.attachmentId, uploadURL: response.uploadUrl,
            headers: response.uploadHeaders
        )
    }
}
