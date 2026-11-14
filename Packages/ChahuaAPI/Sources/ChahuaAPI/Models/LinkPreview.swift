import Foundation

/// Server-owned preview state. Clients never fetch metadata from the destination URL.
public struct MessageLinkPreview: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case pending
        case ready
        case unavailable
        case disabled
    }

    public struct Image: Codable, Hashable, Sendable {
        public let url: String
        public let width: Int
        public let height: Int

        public init(url: String, width: Int, height: Int) {
            self.url = url
            self.width = width
            self.height = height
        }
    }

    public let url: String
    public let status: Status
    public let expiresAt: Date?
    public let title: String?
    /// Optional plain-text summary; older responses omit this field.
    public let description: String?
    public let image: Image?

    public init(
        url: String, status: Status, expiresAt: Date? = nil, title: String? = nil,
        description: String? = nil, image: Image? = nil
    ) {
        self.url = url
        self.status = status
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
        self.image = image
    }

    public func isVisible(at now: Date) -> Bool {
        switch status {
        case .ready: true
        case .pending: expiresAt.map { $0 > now } ?? false
        case .unavailable, .disabled: false
        }
    }

    func projectingExpired(at now: Date) -> Self {
        guard status == .pending, let expiresAt, expiresAt <= now else { return self }
        return Self(
            url: url, status: .unavailable, expiresAt: expiresAt, title: title,
            description: description, image: image)
    }
}

public struct MessageMetadataResponse: Codable, Hashable, Sendable {
    public let linkPreviews: [MessageLinkPreview]

    public init(linkPreviews: [MessageLinkPreview] = []) {
        self.linkPreviews = linkPreviews
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        linkPreviews =
            try container.decodeIfPresent([MessageLinkPreview].self, forKey: .linkPreviews)
            ?? []
    }
}

/// Only user intent and explicitly supplied content may be submitted, never response statuses.
public struct LinkPreviewInput: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case enabled, disabled
    }

    public let url: String
    public let status: Status?
    public let title: String?
    public let imageUrl: String?

    public init(
        url: String, status: Status? = nil, title: String? = nil, imageUrl: String? = nil
    ) {
        self.url = url
        self.status = status
        self.title = title
        self.imageUrl = imageUrl
    }
}

public struct MessageMetadataInput: Codable, Hashable, Sendable {
    public let linkPreviews: [LinkPreviewInput]

    public init(linkPreviews: [LinkPreviewInput] = []) {
        self.linkPreviews = linkPreviews
    }
}
