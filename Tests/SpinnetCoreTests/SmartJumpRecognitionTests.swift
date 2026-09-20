import XCTest
@testable import SpinnetCore

final class SmartJumpRecognitionTests: XCTestCase {
    func testNumericDOISuffixesTakePrecedenceOverArithmetic() throws {
        for doi in ["10.1000/123", "10.1000/0", "10.1000/123.456"] {
            XCTAssertEqual(try SmartJumpClassifier().classify(doi), .link(URL(string: "https://doi.org/" + doi)!, .doi))
        }
    }
    func testLeadingPathsStopAtProseJustLikeEmbeddedPaths() throws {
        for text in ["/tmp/report.pdf is the document", "/tmp/report.pdf\nPlease read this", "See /tmp/report.pdf for details"] {
            XCTAssertEqual(try SmartJumpClassifier().classify(text), .localPath("/tmp/report.pdf"))
        }
        XCTAssertEqual(try SmartJumpClassifier().classify("~/Download/ then github.com"), .localPath("~/Download/"))
    }

    func testQuotedPathsKeepSpacesAndNumericPathsAreNotArithmetic() throws {
        let classifier = SmartJumpClassifier()
        XCTAssertEqual(try classifier.classify("\"/tmp/My Report.pdf\""), .localPath("/tmp/My Report.pdf"))
        XCTAssertEqual(try classifier.classify("\"~/My Folder/\""), .localPath("~/My Folder/"))
        XCTAssertEqual(try classifier.classify("/123/456"), .localPath("/123/456"))
        XCTAssertEqual(try classifier.classify("See \"/tmp/My Report.pdf\" for details"), .localPath("/tmp/My Report.pdf"))
    }
    func testArithmeticHasPrecedenceAndNeverEvaluatesCode() throws {
        let classifier = SmartJumpClassifier()
        for (expression, answer) in [("2+3*4", 14.0), ("32-68*(50/6-3.28)+5", -306.62666666666667),
                                     ("−2 × (3 + .5) ÷ 2", -3.5), ("0.1+0.2", 0.3), ("1 - -2", 3)] {
            guard case .calculation(let result) = try classifier.classify(expression) else {
                return XCTFail("Expected calculation: \(expression)")
            }
            XCTAssertEqual(result, answer, accuracy: 0.000000001)
        }
        for expression in ["1/0", "0/0", "2**3", "(2+3", "1..2+3", "2 3+1", "2(3)",
                           String(repeating: "(", count: 40) + "1+1" + String(repeating: ")", count: 40),
                           String(repeating: "9", count: 400) + "*9"] {
            XCTAssertThrowsError(try classifier.classify(expression), expression)
        }
        for text in ["Math.random()", "process.exit()", "alert(1)", "2+foo(3)"] {
            // Code-like text is just a search string, never executable input.
            XCTAssertEqual(try classifier.classify(text), .search(try SmartJumpSearchEngine.google.url(for: text), "Google"))
        }
    }
    func testSearchUsesTheFirstConfiguredEngineAndEncodesTextAsData() throws {
        XCTAssertEqual(try SmartJumpClassifier().classify("cats & dogs"),
                       .search(URL(string: "https://www.google.com/search?q=cats%20%26%20dogs")!, "Google"))
        let engines = try SmartJumpSearchEngine.parse("Example | https://example.com/search?q={query}\nGoogle | https://www.google.com/search?q={query}")
        let classifier = SmartJumpClassifier(searchEngines: engines)
        XCTAssertEqual(try classifier.classify("猫 & x#y"),
                       .search(URL(string: "https://example.com/search?q=%E7%8C%AB%20%26%20x%23y")!, "Example"))
        XCTAssertEqual(try classifier.classify("   "), .input)
        for setting in ["", "Example | javascript:{query}", "Example | http://example.com/search?q={query}",
                        "Example | https://{query}.com/", "Example | https://example.com",
                        "A | https://a.com/?q={query}\nA | https://b.com/?q={query}"] {
            XCTAssertThrowsError(try SmartJumpSearchEngine.parse(setting), setting)
        }
    }
    func testSpecialTargetsAreRecognisedAloneAndInPassages() throws {
        let cases: [(String, SmartJumpTarget)] = [
            ("10.1109/TMAG.2018.2810199", .link(URL(string: "https://doi.org/10.1109/TMAG.2018.2810199")!, .doi)),
            ("BV1Et41137T6", .link(URL(string: "https://www.bilibili.com/video/BV1Et41137T6")!, .video)),
            ("av170001", .link(URL(string: "https://www.bilibili.com/video/av170001")!, .video)),
            ("https://example.com/app.dmg?download=1", .link(URL(string: "https://example.com/app.dmg?download=1")!, .download)),
            ("~/Download/", .localPath("~/Download/")),
            ("/tmp/report.pdf", .localPath("/tmp/report.pdf")),
            ("\"/tmp/My Report.pdf\"", .localPath("/tmp/My Report.pdf"))
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try SmartJumpClassifier().classify(text), expected, text)
            XCTAssertEqual(try SmartJumpClassifier().classify("Look here: \(text), please."), expected, text)
        }
        XCTAssertEqual(try SmartJumpClassifier().classify("10.1109/TMAG.2018.2810199 then github.com"), cases[0].1)
        XCTAssertEqual(try SmartJumpClassifier().classify("github.com then 10.1109/TMAG.2018.2810199"),
                       .link(URL(string: "https://github.com")!, .web))
    }

    func testLinkStopsAtLineBreakAndDoesNotAbsorbTheNextSection() throws {
        let text = "rom any piece of writing.\n\nhttps://creatoreconomy.so/p/use-my-no-ai-slop-skill-to-remove-20-ai-slop-patterns\n\nResources\n\nhttps://github.com/petergyang/no-ai-slop#readme-ov-file"
        XCTAssertEqual(try SmartJumpClassifier().classify(text),
                       .link(URL(string: "https://creatoreconomy.so/p/use-my-no-ai-slop-skill-to-remove-20-ai-slop-patterns")!, .web))
    }
    func testAddressesInsideTextUseHTTPSAndTheFirstTargetWins() throws {
        let classifier = SmartJumpClassifier()
        XCTAssertEqual(try classifier.classify("Visit github.com then https://example.com."),
                       .link(URL(string: "https://github.com")!, .web))
        XCTAssertEqual(try classifier.classify("See https://example.com/a?q=1."),
                       .link(URL(string: "https://example.com/a?q=1")!, .web))
    }
}
