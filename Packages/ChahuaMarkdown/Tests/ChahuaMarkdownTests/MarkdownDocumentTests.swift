import Foundation
import XCTest

@testable import ChahuaMarkdown

final class MarkdownDocumentTests: XCTestCase {
    func testSupportedFormattingNestsWithoutStockMarkdownDrift() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "**bold __italic__ ~~gone~~ ||secret||**").blocks,
            [
                .paragraph([
                    .strong([
                        .text("bold "), .emphasis([.text("italic")]), .text(" "),
                        .strikethrough([.text("gone")]), .text(" "), .spoiler([.text("secret")]),
                    ])
                ])
            ])
        for text in [
            "*italic*", "***both***", "****bold****", "_literal_", "# heading", "> quote", "---",
            "&amp;", "<b>literal</b>",
        ] {
            XCTAssertEqual(
                MarkdownDocument(parsing: text).blocks, [.paragraph([.text(text)])], text)
        }
        XCTAssertEqual(
            MarkdownDocument(parsing: "___italic___").blocks,
            [
                .paragraph([.text("_"), .emphasis([.text("italic")]), .text("_")])
            ])
    }

    func testNormalizationReflowsOnlyExactSupportedPairs() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "** bold __ italic __ end **").blocks,
            [
                .paragraph([
                    .strong([.text("bold  "), .emphasis([.text("italic")]), .text("  end")])
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "a ** hello ** b").blocks,
            [
                .paragraph([.text("a  "), .strong([.text("hello")]), .text("  b")])
            ])
        for text in ["1** x **2", "a__ x __b", "|| secret ||", "** bold ~~"] {
            XCTAssertEqual(
                MarkdownDocument(parsing: text).blocks, [.paragraph([.text(text)])], text)
        }
        XCTAssertEqual(
            MarkdownDocument(parsing: "** unmatched\n** bold **").blocks,
            [
                .paragraph([.text("** unmatched\n"), .strong([.text("bold")])])
            ])
    }

    func testEscapingAndUnicodeAreLossless() {
        XCTAssertEqual(
            MarkdownDocument(parsing: #"\**literal\** and \[label\](https\://example.com)"#).blocks,
            [
                .paragraph([.text("**literal** and [label](https://example.com)")])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "**你好👩🏽‍💻e\u{301}**").blocks,
            [
                .paragraph([.strong([.text("你好👩🏽‍💻e\u{301}")])])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "**one**  \r\ntwo\\\rthree").blocks,
            [
                .paragraph([.strong([.text("one")]), .text("\ntwo\nthree")])
            ])
    }

    func testCodeSpansUseMatchingRunsAndParagraphBoundaries() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "`` ` **x** @[uid:1] ` ``").blocks,
            [
                .paragraph([.code("` **x** @[uid:1] `")])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "`one\ntwo`").blocks, [.paragraph([.code("one two")])])
        XCTAssertEqual(
            MarkdownDocument(parsing: "`one\n\ntwo`").blocks,
            [
                .paragraph([.text("`one\n\ntwo`")])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "`unclosed **bold**").blocks,
            [
                .paragraph([.text("`unclosed "), .strong([.text("bold")])])
            ])
        XCTAssertEqual(MarkdownDocument(parsing: "`   `").blocks, [.paragraph([.code("   ")])])
    }

    func testMentionsRemainSemanticOnlyOutsideCode() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "Hi **@[uid:42]** `@[uid:7]` @[uid:2147483647]").blocks,
            [
                .paragraph([
                    .text("Hi "), .strong([.mention(42)]), .text(" "), .code("@[uid:7]"),
                    .text(" "), .mention(Int32.max),
                ])
            ])
        for text in ["@[uid:-1]", "@[uid:2147483648]", "@[uid:x]"] {
            XCTAssertEqual(MarkdownDocument(parsing: text).blocks, [.paragraph([.text(text)])])
        }
        XCTAssertEqual(
            MarkdownDocument(parsing: "\\@[uid:1]").blocks,
            [.paragraph([.text("\\"), .mention(1)])])
    }

    func testLabelledLinksAndUnsafeDestinations() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "[**label**](https://example.com/a_(b) \"title\")").blocks,
            [
                .paragraph([
                    .link(
                        destination: "https://example.com/a_(b)",
                        children: [.strong([.text("label")])])
                ])
            ])
        for source in [
            "[label](/local)", "[label](mailto:a@example.com)", "[label](ftp://example.com)",
        ] {
            XCTAssertEqual(MarkdownDocument(parsing: source).blocks, [.paragraph([.text("label")])])
        }
        XCTAssertEqual(
            MarkdownDocument(parsing: "[example.com](/local)").blocks,
            [
                .paragraph([.text("example.com")])
            ])
        for source in [
            "[label](javascript:alert(1))", "[label](vbscript:bad)", "[label](file:///tmp/x)",
            "[label](data:text/html,bad)",
        ] {
            XCTAssertEqual(MarkdownDocument(parsing: source).blocks, [.paragraph([.text(source)])])
        }
        XCTAssertEqual(
            MarkdownDocument(parsing: "![diagram](diagram.png)").blocks,
            [
                .paragraph([.text("![diagram](diagram.png)")])
            ])
    }

    func testBareHTTPLinksTrimProsePunctuationAndFormatting() {
        XCTAssertEqual(
            MarkdownDocument(
                parsing: "(**https://example.com/a_(b)**). mail@example.com www.example.com"
            ).blocks,
            [
                .paragraph([
                    .text("("),
                    .strong([
                        .link(
                            destination: "https://example.com/a_(b)",
                            children: [.text("https://example.com/a_(b)")])
                    ]),
                    .text("). mail@example.com "),
                    .link(
                        destination: "http://www.example.com", children: [.text("www.example.com")]),
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "see https://example.com/x?q=1, next").blocks,
            [
                .paragraph([
                    .text("see "),
                    .link(
                        destination: "https://example.com/x?q=1",
                        children: [.text("https://example.com/x?q=1")]), .text(", next"),
                ])
            ])
    }

    func testFencesRespectNestedListIndentationAndClosingRuns() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "- ```swift\n  ** x ** @[uid:1]\n  ````\n- after").blocks,
            [
                .list(
                    orderedStart: nil,
                    items: [
                        [.codeBlock(language: "swift", code: "** x ** @[uid:1]\n")],
                        [.paragraph([.text("after")])],
                    ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "````rust\n```\nlet x = 1;\n````").blocks,
            [
                .codeBlock(language: "rust", code: "```\nlet x = 1;\n")
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "```\"><img\n<b>raw</b>\n```").blocks,
            [
                .codeBlock(language: nil, code: "<b>raw</b>\n")
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "```\nunclosed").blocks,
            [.codeBlock(language: nil, code: "unclosed")])
        XCTAssertEqual(
            MarkdownDocument(parsing: "~~~\nplain\n~~~").blocks,
            [.paragraph([.text("~~~\nplain\n~~~")])])
    }

    func testListsSupportStartsNestedBlocksLazyContinuationAndRestrictedBullets() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "3. three\n   - nested\n4. four").blocks,
            [
                .list(
                    orderedStart: 3,
                    items: [
                        [
                            .paragraph([.text("three")]),
                            .list(orderedStart: nil, items: [[.paragraph([.text("nested")])]]),
                        ],
                        [.paragraph([.text("four")])],
                    ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "- first\ncontinued\n\n  second paragraph\n\noutside").blocks,
            [
                .list(
                    orderedStart: nil,
                    items: [
                        [
                            .paragraph([.text("first\ncontinued")]),
                            .paragraph([.text("second paragraph")]),
                        ]
                    ]),
                .paragraph([.text("outside")]),
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "* item\n* two").blocks,
            [.paragraph([.text("* item\n* two")])])
        XCTAssertEqual(
            MarkdownDocument(parsing: "paragraph\n2. not an interrupt").blocks,
            [
                .paragraph([.text("paragraph\n2. not an interrupt")])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "+ one\n- two").blocks,
            [
                .list(orderedStart: nil, items: [[.paragraph([.text("one")])]]),
                .list(orderedStart: nil, items: [[.paragraph([.text("two")])]]),
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "-\titem\n\tcontinued").blocks,
            [
                .list(orderedStart: nil, items: [[.paragraph([.text("item\ncontinued")])]])
            ])
    }

    func testSummaryRetainsStructureAndHidesSpoilersSemantically() {
        XCTAssertEqual(
            MarkdownDocument(
                parsing:
                    "**hello**\nworld\n\n3. ||secret||\n   - @[uid:7]\n4. four\n\n```swift\n a\t b\n c \n```"
            ).summary,
            [
                .strong([.text("hello")]), .text(" world 3. "), .spoiler([.text("secret")]),
                .text(" • "), .mention(7), .text(" 4. four "), .code("a\t b c"),
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "a  b\u{2028}\u{2029}c").summary, [.text("a  b c")])
        XCTAssertEqual(MarkdownDocument(parsing: "```\n \n```\n\nrest").summary, [.text("rest")])
        XCTAssertEqual(MarkdownDocument(parsing: "").summary, [])
    }

    func testPlainMessagesPreserveSourceWhitespaceAndOnlyRestoreMentions() {
        for source in [
            " \t hello  \r\n\r\nworld \t ",
            "\n\n* literal* \t\n***literal***\n# heading\n> quote\n---\n",
            "\t![diagram](diagram.png) \n",
            " \t `unmatched\n\ncode`  ",
            " \t \r\n",
        ] {
            XCTAssertEqual(
                MarkdownDocument(parsing: source).blocks, [.paragraph([.text(source)])], source)
        }
        let source = " \t@[uid:7]  \r\n\r\n @[uid:42]\t "
        XCTAssertEqual(
            MarkdownDocument(parsing: source).blocks,
            [
                .paragraph([
                    .text(" \t"), .mention(7), .text("  \r\n\r\n "), .mention(42), .text("\t "),
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: source).summary,
            [
                .text(" \t"), .mention(7), .text("    "), .mention(42), .text("\t "),
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: " \t first\r\n\r\nsecond\u{2028}\u{2029}last  ").summary,
            [
                .text(" \t first second last  ")
            ])
    }

    func testRealMarkupAndEscapedPunctuationActivateNormalizedMarkdownPath() {
        XCTAssertEqual(
            MarkdownDocument(parsing: " \t **bold** \n\n ").blocks,
            [
                .paragraph([.strong([.text("bold")])])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: " \t \\*literal\\* \n\n ").blocks,
            [
                .paragraph([.text("*literal*")])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: " \t https://example.com \n\n ").blocks,
            [
                .paragraph([
                    .link(
                        destination: "https://example.com", children: [.text("https://example.com")]
                    )
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: " \t [label](/relative) \n\n ").blocks,
            [
                .paragraph([.text("label")])
            ])
    }

    func testCodeSummaryPreservesHorizontalWhitespaceAwayFromLineBreaks() {
        XCTAssertEqual(MarkdownDocument(parsing: "`a  \tb`").summary, [.code("a  \tb")])
        XCTAssertEqual(
            MarkdownDocument(parsing: "```\n  a  \tb  \n \tc  \td \n```").summary,
            [
                .code("a  \tb c  \td")
            ])
    }

    func testFuzzyDomainsMatchPWAWithoutLinkingEmailOrUnsupportedTLDs() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "www.example.com example.com example.co.uk").blocks,
            [
                .paragraph([
                    .link(
                        destination: "http://www.example.com", children: [.text("www.example.com")]),
                    .text(" "),
                    .link(destination: "http://example.com", children: [.text("example.com")]),
                    .text(" "),
                    .link(destination: "http://example.co.uk", children: [.text("example.co.uk")]),
                ])
            ])
        for source in ["user@example.com", "user.name@example.com", "example.invalid", "127.0.0.1"]
        {
            XCTAssertEqual(
                MarkdownDocument(parsing: source).blocks, [.paragraph([.text(source)])], source)
        }
        XCTAssertEqual(
            MarkdownDocument(parsing: " \t example.com \n\n ").blocks,
            [
                .paragraph([
                    .link(destination: "http://example.com", children: [.text("example.com")])
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "`example.com www.example.com`").blocks,
            [
                .paragraph([.code("example.com www.example.com")])
            ])
    }

    func testAutomaticLinksPreserveAnglesUnderscoresAndPathPunctuation() {
        XCTAssertEqual(
            MarkdownDocument(parsing: "<https://example.com>").blocks,
            [
                .paragraph([
                    .text("<"),
                    .link(
                        destination: "https://example.com", children: [.text("https://example.com")]
                    ), .text(">"),
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "https://example.com/a_b__c example.com/a_b__c").blocks,
            [
                .paragraph([
                    .link(
                        destination: "https://example.com/a_b__c",
                        children: [.text("https://example.com/a_b__c")]), .text(" "),
                    .link(
                        destination: "http://example.com/a_b__c",
                        children: [.text("example.com/a_b__c")]),
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "(example.com/a_(b)), next").blocks,
            [
                .paragraph([
                    .text("("),
                    .link(
                        destination: "http://example.com/a_(b)",
                        children: [.text("example.com/a_(b)")]), .text("), next"),
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: "example.com/a__b__c").blocks,
            [
                .paragraph([
                    .link(
                        destination: "http://example.com/a",
                        children: [.text("example.com/a")]),
                    .emphasis([.text("b")]), .text("c"),
                ])
            ])
        XCTAssertEqual(
            MarkdownDocument(parsing: #"\https\://example.com"#).blocks,
            [.paragraph([.text(#"\https://example.com"#)])])
    }
}
