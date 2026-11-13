import ChahuaAPI
import CoreGraphics
import Foundation

/// One viewer item: an image or a video attachment.
struct MessageImageItem: Identifiable, Hashable {
    let id: String
    let url: URL?
    let contentType: String
    let fileName: String
    let pixelSize: CGSize?

    init(id: String, url: URL?, contentType: String, fileName: String, width: Int?, height: Int?) {
        self.id = id
        self.url = url
        self.contentType = contentType
        self.fileName = fileName
        if let width, let height, width > 0, height > 0 {
            pixelSize = CGSize(width: width, height: height)
        } else {
            pixelSize = nil
        }
    }

    var isVideo: Bool { contentType.lowercased().hasPrefix("video/") }
    var isImage: Bool { contentType.lowercased().hasPrefix("image/") }
}

/// An immutable snapshot of one message's images and videos, never a conversation-wide
/// media query.
struct MessageImageGallery: Identifiable {
    let id = UUID()
    let messageID: String
    let items: [MessageImageItem]
    let selectedIndex: Int
    var conversationTitle: String?
    let sentAt: Date?

    init?(
        messageID: String, items: [MessageImageItem], selectedID: String,
        sentAt: Date? = nil
    ) {
        let media = items.filter { $0.isImage || $0.isVideo }
        guard let selectedIndex = media.firstIndex(where: { $0.id == selectedID }) else {
            return nil
        }
        self.messageID = messageID
        self.items = media
        self.selectedIndex = selectedIndex
        self.sentAt = sentAt
    }

    init?(entry: ConversationTimelineEntry, attachmentIndex: Int) {
        let items: [MessageImageItem]
        let messageID: String
        let sentAt: Date
        guard entry.messageType == .text || entry.messageType == .file,
            entry.presentationMessage?.isDeleted != true
        else { return nil }
        if case .pending(let message) = entry {
            messageID = message.clientGeneratedID
            sentAt = message.enqueuedAt
        } else if let message = entry.presentationMessage {
            messageID = message.id.description
            sentAt = message.createdAt
        } else {
            return nil
        }
        items = entry.mediaAttachments.map {
            switch $0 {
            case .local(let attachment):
                MessageImageItem(
                    id: attachment.id, url: URL(fileURLWithPath: attachment.uploadPath),
                    contentType: attachment.mimeType, fileName: attachment.fileName,
                    width: attachment.width, height: attachment.height)
            case .server(let attachment):
                MessageImageItem(
                    id: attachment.id, url: URL(string: attachment.url),
                    contentType: attachment.kind, fileName: attachment.fileName,
                    width: attachment.width.map(Int.init), height: attachment.height.map(Int.init))
            }
        }
        guard items.indices.contains(attachmentIndex) else { return nil }
        self.init(
            messageID: messageID, items: items, selectedID: items[attachmentIndex].id,
            sentAt: sentAt)
    }
}
