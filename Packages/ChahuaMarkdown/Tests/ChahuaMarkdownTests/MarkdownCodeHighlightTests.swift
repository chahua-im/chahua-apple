import Foundation
import XCTest

@testable import ChahuaMarkdown

final class MarkdownCodeHighlightTests: XCTestCase {
    func testKnownRustKeywordUsesSourceRange() {
        let source = "fn main() { let value = 1; }"
        let spans = MarkdownCodeHighlight.spans(code: source, language: "rust")
        XCTAssertTrue(
            spans.contains { $0.kind == "keyword" && $0.range == NSRange(location: 0, length: 2) })
        XCTAssertTrue(
            spans.contains {
                $0.kind == "keyword" && (source as NSString).substring(with: $0.range) == "let"
            })
    }

    func testUnicodeRangesAreUTF16OffsetsIntoUnchangedSource() {
        let source = "// 👩🏽‍💻\nlet value = \"茶😀e\u{301}\";"
        let spans = MarkdownCodeHighlight.spans(code: source, language: "swift")
        let expected = (source as NSString).range(of: "\"茶😀e\u{301}\"")
        XCTAssertTrue(spans.contains { $0.kind == "string" && $0.range == expected })
        for span in spans {
            XCTAssertNotNil(Range(span.range, in: source))
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), source.utf16.count)
        }
    }

    func testUnknownOrUnlabelledCodeRemainsPlain() {
        for language in [nil, "", "not-a-real-language", "\"><script>"] as [String?] {
            XCTAssertEqual(MarkdownCodeHighlight.spans(code: "let x = 1", language: language), [])
        }
    }

    func testHTMLLikeSourceIsNeverSubstitutedWithMarkup() {
        let source = "const value = \"<img src=x onerror=alert(1)>&茶😀\";"
        let spans = MarkdownCodeHighlight.spans(code: source, language: "javascript")
        let expected = (source as NSString).range(of: "\"<img src=x onerror=alert(1)>&茶😀\"")
        XCTAssertTrue(spans.contains { $0.kind == "string" && $0.range == expected })
        for span in spans {
            XCTAssertNotNil(Range(span.range, in: source))
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), source.utf16.count)
            XCTAssertFalse((source as NSString).substring(with: span.range).contains("&lt;"))
        }
    }
}
