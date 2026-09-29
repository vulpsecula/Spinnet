import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Smart Jump's recognition, arithmetic and search, which live in its
/// script: each test types text into its view, which recognizes it without
/// any effect, then submits it and reads what the script asks the Host to
/// open.
final class SmartJumpRecognitionTests: XCTestCase {
    private var smartJump: SmartJumpDriver!

    override func setUpWithError() throws {
        smartJump = try SmartJumpDriver()
    }

    override func tearDown() {
        smartJump?.shutdown()
        smartJump = nil
    }

    private func target(_ text: String, engines: JSONValue? = nil,
                        file: StaticString = #filePath, line: UInt = #line) throws -> SmartJumpTarget {
        try smartJump.target(of: text, engines: engines, file: file, line: line)
    }

    func testNumericDOISuffixesTakePrecedenceOverArithmetic() throws {
        for doi in ["10.1000/123", "10.1000/0", "10.1000/123.456"] {
            XCTAssertEqual(try target(doi), .link("https://doi.org/" + doi, .doi))
        }
    }

    func testLeadingPathsStopAtProseJustLikeEmbeddedPaths() throws {
        for text in ["/tmp/report.pdf is the document", "/tmp/report.pdf\nPlease read this", "See /tmp/report.pdf for details"] {
            XCTAssertEqual(try target(text), .localPath("/tmp/report.pdf"))
        }
        XCTAssertEqual(try target("~/Download/ then github.com"), .localPath("~/Download/"))
    }

    func testHiddenDirectoryPathsRemainLocalPathsAndPassValidation() throws {
        for path in ["/tmp/.agent/", "~/.agents/skills"] {
            XCTAssertEqual(try target(path), .localPath(path))
            let expanded = (path as NSString).expandingTildeInPath
            XCTAssertEqual(try OpenableLocalPath.validate(path), URL(fileURLWithPath: expanded).standardizedFileURL)
        }
    }

    func testQuotedPathsKeepSpacesAndNumericPathsAreNotArithmetic() throws {
        XCTAssertEqual(try target("\"/tmp/My Report.pdf\""), .localPath("/tmp/My Report.pdf"))
        XCTAssertEqual(try target("\"~/My Folder/\""), .localPath("~/My Folder/"))
        XCTAssertEqual(try target("/123/456"), .localPath("/123/456"))
        XCTAssertEqual(try target("See \"/tmp/My Report.pdf\" for details"), .localPath("/tmp/My Report.pdf"))
        XCTAssertEqual(try target("/"), .localPath("/"))
        XCTAssertEqual(try target("~/"), .localPath("~/"))
    }

    func testArithmeticHasPrecedenceAndNeverEvaluatesCode() throws {
        for (expression, answer) in [("2+3*4", "14"), ("32-68*(50/6-3.28)+5", "-306.626666666667"),
                                     ("−2 × (3 + .5) ÷ 2", "-3.5"), ("0.1+0.2", "0.3"), ("1 - -2", "3")] {
            XCTAssertEqual(try target(expression), .calculation(answer), expression)
        }
        let invalid = "Invalid arithmetic expression; use numbers, + − × ÷ and parentheses"
        XCTAssertEqual(try target("1/0"), .refused("Cannot divide by zero"))
        XCTAssertEqual(try target("0/0"), .refused("Cannot divide by zero"))
        for expression in ["2**3", "(2+3", "1..2+3", "2 3+1", "2(3)",
                           String(repeating: "(", count: 40) + "1+1" + String(repeating: ")", count: 40),
                           String(repeating: "9", count: 400) + "*9", "1+" + String(repeating: "1", count: 511)] {
            XCTAssertEqual(try target(expression), .refused(invalid), expression)
        }
        for text in ["Math.random()", "process.exit()", "alert(1)", "2+foo(3)"] {
            // Code-like text is just a search string, never executable input.
            XCTAssertEqual(try target(text), SmartJumpDriver.google(text), text)
        }
    }

    /// The result is written as `%.15g` writes it, so the view shows what
    /// the Host's window showed.
    func testResultsKeepFifteenSignificantDigits() throws {
        for (expression, answer) in [("10/3", "3.33333333333333"), ("2/3", "0.666666666666667"),
                                     ("100000000000000000000*1", "1E+20"), ("0.00001*1", "1E-05"),
                                     ("0.0001*1", "0.0001"), ("123456789012345678", "1.23456789012346E+17"),
                                     ("999999999999999", "999999999999999"), ("0*-1", "0"), ("(1)", "1")] {
            XCTAssertEqual(try target(expression), .calculation(answer), expression)
        }
    }

    func testSearchUsesTheFirstConfiguredEngineAndEncodesTextAsData() throws {
        XCTAssertEqual(try target("cats & dogs"),
                       .search("https://www.google.com/search?q=cats%20%26%20dogs", engine: "Google"))
        let engines = JSONValue.array([
            SmartJumpDriver.engine("Example", "https://example.com/search?q={query}"),
            SmartJumpDriver.engine("Google", "https://www.google.com/search?q={query}")
        ])
        XCTAssertEqual(try target("猫 & x#y", engines: engines),
                       .search("https://example.com/search?q=%E7%8C%AB%20%26%20x%23y", engine: "Example"))
        XCTAssertEqual(try target("   ", engines: engines), .input)
        // No engine at all searches Google.
        XCTAssertEqual(try target("cats", engines: .array([])), SmartJumpDriver.google("cats"))
        XCTAssertEqual(try target("cats", engines: .null), SmartJumpDriver.google("cats"))
    }

    func testSpecialTargetsAreRecognisedAloneAndInPassages() throws {
        let cases: [(String, SmartJumpTarget)] = [
            ("10.1109/TMAG.2018.2810199", .link("https://doi.org/10.1109/TMAG.2018.2810199", .doi)),
            ("BV1Et41137T6", .link("https://www.bilibili.com/video/BV1Et41137T6", .video)),
            ("av170001", .link("https://www.bilibili.com/video/av170001", .video)),
            ("https://example.com/app.dmg?download=1", .link("https://example.com/app.dmg?download=1", .download)),
            ("~/Download/", .localPath("~/Download/")),
            ("/tmp/report.pdf", .localPath("/tmp/report.pdf")),
            ("\"/tmp/My Report.pdf\"", .localPath("/tmp/My Report.pdf"))
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try target(text), expected, text)
            XCTAssertEqual(try target("Look here: \(text), please."), expected, text)
        }
        XCTAssertEqual(try target("10.1109/TMAG.2018.2810199 then github.com"), cases[0].1)
        XCTAssertEqual(try target("github.com then 10.1109/TMAG.2018.2810199"), .link("https://github.com", .web))
        XCTAssertEqual(try target("AV170001"), .link("https://www.bilibili.com/video/av170001", .video),
                       "An AV number is written in lower case")
    }

    func testLinkStopsAtLineBreakAndDoesNotAbsorbTheNextSection() throws {
        let text = "rom any piece of writing.\n\nhttps://creatoreconomy.so/p/use-my-no-ai-slop-skill-to-remove-20-ai-slop-patterns\n\nResources\n\nhttps://github.com/petergyang/no-ai-slop#readme-ov-file"
        XCTAssertEqual(try target(text),
                       .link("https://creatoreconomy.so/p/use-my-no-ai-slop-skill-to-remove-20-ai-slop-patterns", .web))
    }

    func testAddressesInsideTextUseHTTPSAndTheFirstTargetWins() throws {
        XCTAssertEqual(try target("Visit github.com then https://example.com."), .link("https://github.com", .web))
        XCTAssertEqual(try target("See https://example.com/a?q=1."), .link("https://example.com/a?q=1", .web))
        XCTAssertEqual(try target("(see https://en.wikipedia.org/wiki/Foo_(bar))."),
                       .link("https://en.wikipedia.org/wiki/Foo_(bar)", .web), "A bracket the link opened stays")
    }

    /// Only a word character, not a letter from another script run into the
    /// link, stops a target from starting: ICU's \w, which the patterns were
    /// first written for, counts Chinese as word characters.
    func testTargetsDoNotStartInsideAWord() throws {
        XCTAssertEqual(try target("中文10.1000/123"), SmartJumpDriver.google("中文10.1000/123"))
        XCTAssertEqual(try target("xBV1Et41137T6"), SmartJumpDriver.google("xBV1Et41137T6"))
        XCTAssertEqual(try target("a@example.com"), SmartJumpDriver.google("a@example.com"))
        XCTAssertEqual(try target("路径 /Users/me/报告.pdf 在这里"), .localPath("/Users/me/报告.pdf"))
    }

    /// A link the Host would not open is no target, so the text is searched.
    func testALinkTheHostWouldRefuseIsSearchedInstead() throws {
        for text in ["mailto:someone@example.com", "javascript:alert(1)", "https://", "https://中-", "https://a:bc/"] {
            XCTAssertEqual(try target(text), SmartJumpDriver.google(text), text)
        }
        XCTAssertEqual(try target("https://例子.com/a"), .link("https://例子.com/a", .web),
                       "A host the Host can write in Punycode opens")
    }

    func testTextOverSixteenKiBIsRefused() throws {
        XCTAssertEqual(try target(String(repeating: "x", count: 16 * 1024 + 1)),
                       .refused("Smart Jump accepts up to 16 KiB of text"))
        let longest = "/" + String(repeating: "x", count: 16 * 1024 - 1)
        XCTAssertEqual(try target(longest), .localPath(longest))
    }

    func testASearchLinkTheHostWouldNotOpenIsRefused() throws {
        let text = String(repeating: "猫", count: 300)
        XCTAssertEqual(try target(text), .refused("The link is longer than 2048 characters"))
    }
}
