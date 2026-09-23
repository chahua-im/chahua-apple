import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class MessageImageGalleryTests: XCTestCase {
    func testMixedAttachmentsPreserveTappedImageAndMessageOrder() throws {
        let attachments = [
            item("first", "image/jpeg"), item("video", "video/mp4"),
            item("selected", "image/png"), item("last", "image/gif"),
        ]
        let gallery = try XCTUnwrap(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "selected"))
        XCTAssertEqual(gallery.items.map(\.id), ["first", "selected", "last"])
        XCTAssertEqual(gallery.items[gallery.selectedIndex].id, "selected")
        XCTAssertNil(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "video"))
        XCTAssertNil(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "missing"))
    }

    private func item(_ id: String, _ kind: String) -> MessageImageItem {
        .init(
            id: id, url: URL(string: "https://example.com/\(id)"), contentType: kind,
            fileName: id, width: nil, height: nil)
    }
}
