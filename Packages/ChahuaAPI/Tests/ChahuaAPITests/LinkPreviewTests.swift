import Foundation
import XCTest

@testable import ChahuaAPI

final class LinkPreviewTests: XCTestCase {
    func testExistingPreviewPayloadWithoutDescriptionRemainsValid() throws {
        let preview = try JSONDecoder().decode(
            MessageLinkPreview.self,
            from: Data(
                #"{"url":"https://example.com/article","status":"ready","title":"Article"}"#.utf8))
        XCTAssertEqual(preview.url, "https://example.com/article")
        XCTAssertNil(preview.description)
    }

    func testMetadataDecodesOptionalDescriptionPerPreview() throws {
        let metadata = try JSONDecoder().decode(
            MessageMetadataResponse.self,
            from: Data(
                """
                {"linkPreviews":[
                  {"url":"https://example.com/article","status":"ready",
                   "description":"A useful summary."},
                  {"url":"https://example.com/other","status":"ready","description":null}
                ]}
                """.utf8))
        XCTAssertEqual(metadata.linkPreviews.map(\.description), ["A useful summary.", nil])
    }
}
