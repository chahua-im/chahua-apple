import UniformTypeIdentifiers
import XCTest

@testable import chahua_apple

@MainActor
final class ComposerPastePolicyTests: XCTestCase {
    func testTextWithWebArchiveStaysNative() {
        XCTAssertNil(
            ComposerPastePolicy.attachmentDataTypeIdentifier(in: [
                "com.apple.webarchive", UTType.utf8PlainText.identifier,
            ]))
    }

    func testPDFWithTextFallbackStillImportsDocument() {
        XCTAssertEqual(
            ComposerPastePolicy.attachmentDataTypeIdentifier(in: [
                "public.url-name", UTType.utf8PlainText.identifier, UTType.pdf.identifier,
            ]), UTType.pdf.identifier)
    }

    func testBinaryFileWithoutTextRepresentationStillImports() {
        XCTAssertEqual(
            ComposerPastePolicy.attachmentDataTypeIdentifier(in: [UTType.data.identifier]),
            UTType.data.identifier)
    }
}
