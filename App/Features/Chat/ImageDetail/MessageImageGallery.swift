import ChahuaAPI
import CoreGraphics
import Foundation

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
}

/// An immutable snapshot of one message, never a conversation-wide media query.
struct MessageImageGallery: Identifiable {
    let id = UUID()
    let messageID: String
    let items: [MessageImageItem]
    let selectedIndex: Int

    init?(messageID: String, items: [MessageImageItem], selectedID: String) {
        let images = items.filter { $0.contentType.lowercased().hasPrefix("image/") }
        guard let selectedIndex = images.firstIndex(where: { $0.id == selectedID }) else {
            return nil
        }
        self.messageID = messageID
        self.items = images
        self.selectedIndex = selectedIndex
    }

    init?(entry: ConversationTimelineEntry, attachmentIndex: Int) {
        let items: [MessageImageItem]
        let messageID: String
        switch entry {
        case .remote(let message):
            guard !message.isDeleted, message.messageType == .text else { return nil }
            messageID = message.id
            items = message.attachments.map {
                MessageImageItem(
                    id: $0.id, url: URL(string: $0.url), contentType: $0.kind,
                    fileName: $0.fileName, width: $0.width.map(Int.init),
                    height: $0.height.map(Int.init))
            }
        case .pending(let message):
            messageID = message.clientGeneratedID
            items = message.attachments.map {
                MessageImageItem(
                    id: $0.id, url: URL(fileURLWithPath: $0.uploadPath), contentType: $0.mimeType,
                    fileName: $0.fileName, width: $0.width, height: $0.height)
            }
        }
        guard items.indices.contains(attachmentIndex) else { return nil }
        self.init(messageID: messageID, items: items, selectedID: items[attachmentIndex].id)
    }
}
