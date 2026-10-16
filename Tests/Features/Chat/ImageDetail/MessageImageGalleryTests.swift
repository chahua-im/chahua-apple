import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class MessageImageGalleryTests: XCTestCase {
    func testMixedAttachmentsKeepMediaInMessageOrderAndSkipFiles() throws {
        let attachments = [
            item("first", "image/jpeg"), item("video", "Video/MP4"),
            item("document", "application/pdf"), item("selected", "image/png"),
        ]
        let gallery = try XCTUnwrap(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "selected"))
        XCTAssertEqual(gallery.items.map(\.id), ["first", "video", "selected"])
        XCTAssertEqual(gallery.items[gallery.selectedIndex].id, "selected")
        let fromVideo = try XCTUnwrap(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "video"))
        XCTAssertEqual(fromVideo.selectedIndex, 1)
        XCTAssertNil(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "document"))
        XCTAssertNil(
            MessageImageGallery(messageID: "message", items: attachments, selectedID: "missing"))
    }

    private func item(_ id: String, _ kind: String) -> MessageImageItem {
        .init(
            id: id, url: URL(string: "https://example.com/\(id)"), contentType: kind,
            fileName: id, width: nil, height: nil)
    }
}
