import Foundation
import XCTest
import SpinnetCore

/// Detail text supports a Markdown subset: bold, italic, inline code, code
/// blocks and links. Anything outside it shows as the plain text it is.
final class PluginViewMarkdownTests: XCTestCase {
    private typealias Markdown = PluginViewMarkdown

    func testPlainTextIsOneParagraphOfPlainText() {
        XCTAssertEqual(Markdown.parse("Hello, world"), [.paragraph([.text("Hello, world", [])])])
        XCTAssertEqual(Markdown.parse(""), [])
    }

    func testBoldItalicAndInlineCode() {
        XCTAssertEqual(Markdown.parse("a **bold** b"), [.paragraph([
            .text("a ", []), .text("bold", .bold), .text(" b", [])
        ])])
        XCTAssertEqual(Markdown.parse("__bold__ and *italic* and _also_"), [.paragraph([
            .text("bold", .bold), .text(" and ", []), .text("italic", .italic), .text(" and ", []),
            .text("also", .italic)
        ])])
        XCTAssertEqual(Markdown.parse("run `ls -la` now"), [.paragraph([
            .text("run ", []), .text("ls -la", .code), .text(" now", [])
        ])])
        XCTAssertEqual(Markdown.parse("**bold _and italic_**"), [.paragraph([
            .text("bold ", .bold), .text("and italic", [.bold, .italic])
        ])])
        XCTAssertEqual(Markdown.parse("*italic **and bold** too*"), [.paragraph([
            .text("italic ", .italic), .text("and bold", [.bold, .italic]), .text(" too", .italic)
        ])])
    }

    func testInlineCodeKeepsItsContentLiteral() {
        XCTAssertEqual(Markdown.parse("`**not bold**`"), [.paragraph([.text("**not bold**", .code)])])
        XCTAssertEqual(Markdown.parse("``a ` b``"), [.paragraph([.text("a ` b", .code)])])
    }

    func testCodeBlocksKeepTheirLinesLiteral() {
        XCTAssertEqual(Markdown.parse("Before\n```swift\nlet x = **1**\n  indented\n```\nAfter"), [
            .paragraph([.text("Before", [])]),
            .code("let x = **1**\n  indented"),
            .paragraph([.text("After", [])])
        ])
        XCTAssertEqual(Markdown.parse("```\nnever closed"), [.code("never closed")],
                       "An unclosed fence runs to the end of the text")
    }

    func testHTTPLinksAreLinks() throws {
        XCTAssertEqual(Markdown.parse("See [the docs](https://example.com/a?b=1) now"), [.paragraph([
            .text("See ", []),
            .link("the docs", try XCTUnwrap(URL(string: "https://example.com/a?b=1")), []),
            .text(" now", [])
        ])])
        XCTAssertEqual(Markdown.parse("**[bold link](http://example.com)**"), [.paragraph([
            .link("bold link", try XCTUnwrap(URL(string: "http://example.com")), .bold)
        ])])
    }

    /// Acceptance: Markdown outside the subset shows as plain text.
    func testMarkdownOutsideTheSubsetShowsAsPlainText() {
        let outside = [
            "# Heading",
            "- item\n- item",
            "1. first",
            "> quoted",
            "![image](https://example.com/a.png)",
            "<b>html</b>",
            "~~struck~~",
            "| a | b |",
            "---",
            "[not a web link](javascript:alert(1))",
            "[mail](mailto:a@example.com)",
            "[relative](/path)",
            "snake_case_name",
            "2 * 3 * 4",
            "**unclosed",
            "`unclosed",
            "[unclosed](https://example.com",
            "\\*escaped\\*"
        ]
        for text in outside {
            let blocks = Markdown.parse(text)
            let expected = text == "\\*escaped\\*" ? "*escaped*" : text
            XCTAssertEqual(Markdown.plainText(of: blocks), expected, text)
            for case .paragraph(let runs) in blocks {
                XCTAssertTrue(runs.allSatisfy { if case .text(_, []) = $0 { return true } else { return false } },
                              "\(text) has no styled or linked run: \(runs)")
            }
        }
    }

    func testPlainTextOfStyledTextDropsTheMarkers() {
        XCTAssertEqual(Markdown.plainText(of: Markdown.parse("a **b** [c](https://x.example) `d`\n```\ne\n```")),
                       "a b c d\ne")
    }
}
