import Foundation

/// Server-owned preview state. Clients never fetch metadata from the destination URL.
public struct MessageLinkPreview: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case pending
        case ready
        case unavailable
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
    public let image: Image?

    public init(
        url: String, status: Status, expiresAt: Date? = nil, title: String? = nil,
        image: Image? = nil
    ) {
        self.url = url
        self.status = status
        self.expiresAt = expiresAt
        self.title = title
        self.image = image
    }

    public func isVisible(at now: Date) -> Bool {
        switch status {
        case .ready: true
        case .pending: expiresAt.map { $0 > now } ?? false
        case .unavailable: false
        }
    }

    func projectingExpired(at now: Date) -> Self {
        guard status == .pending, let expiresAt, expiresAt <= now else { return self }
        return Self(
            url: url, status: .unavailable, expiresAt: expiresAt, title: title, image: image)
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
