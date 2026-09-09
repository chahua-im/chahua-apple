import ChahuaAPI
import Foundation
import XCTest
@testable import chahua_apple

@MainActor
final class BubbleMediaLayoutTests: XCTestCase {
    func testSmallImagesUpscaleWithoutExceedingTheAvailableLane() throws {
        let image = try attachment(id: "small", width: 40, height: 40)
        let size = try XCTUnwrap(BubbleMediaLayout.singleSize(for: image, viewport: CGSize(width: 600, height: 800), availableWidth: 300))
        XCTAssertEqual(size.width, 120, accuracy: 0.001)
        XCTAssertEqual(size.height, 120, accuracy: 0.001)
        let narrow = try XCTUnwrap(BubbleMediaLayout.singleSize(for: image, viewport: CGSize(width: 100, height: 80), availableWidth: 30))
        XCTAssertLessThanOrEqual(narrow.width, 30)
        XCTAssertLessThanOrEqual(narrow.height, 48)
    }

    func testInvalidGalleryDimensionsUseTheSameFallbackAsMissingDimensions() throws {
        let missing = [try attachment(id: "a", width: nil, height: 100), try attachment(id: "b", width: 200, height: 100)]
        let invalid = [try attachment(id: "a", width: -3, height: 100), try attachment(id: "b", width: 200, height: 100)]
        let viewport = CGSize(width: 600, height: 400)
        let expected = try XCTUnwrap(BubbleMediaLayout.gallery(for: missing, viewport: viewport, availableWidth: 300))
        let actual = try XCTUnwrap(BubbleMediaLayout.gallery(for: invalid, viewport: viewport, availableWidth: 300))
        XCTAssertEqual(actual.cells.map(\.frame), expected.cells.map(\.frame))
    }

    func testAsymmetricGalleryChoosesBalancedRowsAndPreservesOrdering() throws {
        let dimensions = [(250, 100), (50, 100), (150, 100), (75, 100), (200, 100), (50, 100)]
        let images = try dimensions.enumerated().map { index, dimensions in
            try attachment(id: String(index), width: dimensions.0, height: dimensions.1)
        }
        let gallery = try XCTUnwrap(BubbleMediaLayout.gallery(for: images, viewport: CGSize(width: 600, height: 400), availableWidth: 300))
        XCTAssertEqual(gallery.cells.map(\.attachment.id), ["0", "1", "2", "3", "4", "5"])
        XCTAssertEqual(gallery.cells[0].frame.height, 296 / 4.5, accuracy: 0.001)
        XCTAssertEqual(gallery.cells[2].frame.maxX, 300, accuracy: 0.001)
        XCTAssertEqual(gallery.cells[3].frame.minY, gallery.cells[0].frame.maxY + 2, accuracy: 0.001)
        XCTAssertEqual(gallery.cells[5].frame.maxX, 300, accuracy: 0.001)
        for cell in gallery.cells {
            XCTAssertTrue(CGRect(origin: .zero, size: gallery.size).insetBy(dx: -0.001, dy: -0.001).contains(cell.frame))
        }
        XCTAssertLessThanOrEqual(gallery.size.height, 240)
    }

    func testGalleryCapacityKeepsOverflowInTheSixthVisibleTile() throws {
        for count in [2, 3, 4, 5, 6, 7, 20] {
            let images = try (0 ..< count).map { try attachment(id: String($0), width: 100 + $0 * 40, height: 200) }
            let gallery = try XCTUnwrap(BubbleMediaLayout.gallery(
                for: images, viewport: CGSize(width: 600, height: 400), availableWidth: 300
            ))
            XCTAssertEqual(gallery.cells.map(\.attachment.id), (0 ..< min(count, 6)).map(String.init))
            XCTAssertEqual(gallery.cells.last?.overflowCount, count > 6 ? count - 5 : 0)
            for cell in gallery.cells {
                XCTAssertGreaterThan(cell.frame.width, 0)
                XCTAssertGreaterThan(cell.frame.height, 0)
                XCTAssertLessThanOrEqual(cell.frame.maxX, 300.001)
                XCTAssertLessThanOrEqual(cell.frame.maxY, 240.001)
            }
        }
    }

    private func attachment(id: String, width: Int?, height: Int?) throws -> AttachmentResponse {
        let object: [String: Any] = ["id": id, "url": "https://example.invalid/\(id).png", "kind": "image/png", "size": 1, "fileName": "\(id).png", "width": width as Any? ?? NSNull(), "height": height as Any? ?? NSNull()]
        return try JSONDecoder().decode(AttachmentResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
