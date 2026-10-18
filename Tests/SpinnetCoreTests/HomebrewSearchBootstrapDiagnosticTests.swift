import Foundation
import XCTest
import SpinnetCore

final class HomebrewSearchBootstrapDiagnosticTests: XCTestCase {
    private let warning = "/opt/homebrew/Library/Homebrew/utils.sh: line 144: cannot create temp file for here document: Operation not permitted"
    private func search(_ stderr: String, stdout: String = "", status: Int32 = 1) throws -> JSONValue {
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            HomebrewReadOutput(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
        })
        return try profile.read(.object(["tool": .string("homebrew"), "operation": .string("search"), "kind": .string("cask"), "query": .string("wget")]), owner: .init("diagnostic.fixture"))
    }
    func testExactBootstrapETagWarningsDoNotTurnAnExactSearchMissIntoFailure() throws {
        let miss = "Error: No formulae or casks found for \"wget\"."
        for diagnostic in [miss, warning + "\n" + warning + "\n" + miss + "\n"] {
            XCTAssertEqual(try search(diagnostic).value(atPointer: "/packages"), .array([]))
        }
    }
    func testOtherFailuresAndInconsistentOutputNeverBecomeEmptySearchResults() throws {
        let miss = "Error: No formulae or casks found for \"wget\"."
        for diagnostic in [warning + "\n" + warning, warning + "\n" + miss,
                           warning + "\n" + warning + "\n" + warning + "\n" + miss,
                           warning.replacingOccurrences(of: "line 144", with: "line 145") + "\n" + warning + "\n" + miss,
                           warning.replacingOccurrences(of: "/opt/homebrew/", with: "/other/homebrew/") + "\n" + warning + "\n" + miss,
                           warning + "\n" + warning + "\nCache is corrupt", "Unexpected warning\n" + miss,
                           warning + "\n" + warning + "\nError: No formulae or casks found for \"other\"."] {
            XCTAssertThrowsError(try search(diagnostic), diagnostic)
        }
        XCTAssertThrowsError(try search(warning + "\n" + warning + "\n" + miss, stdout: "unexpected"))
        XCTAssertThrowsError(try search(warning + "\n" + warning + "\n" + miss, status: 2))
    }
    func testExactInfoMissMayContainOnlyTheSamePairOfBootstrapWarnings() throws {
        let diagnostic = warning + "\n" + warning + "\nError: No available formula with the name \"missing\"."
        let profile = HomebrewReadProfile(executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, execute: { _, _, _, _ in
            HomebrewReadOutput(status: 1, stdout: Data(), stderr: Data(diagnostic.utf8))
        })
        let result = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("formula"), "names": .array([.string("missing")])]), owner: .init("diagnostic.fixture"))
        XCTAssertEqual(result.value(atPointer: "/packages"), .array([]))
        XCTAssertEqual(result.value(atPointer: "/not_found"), .array([.string("missing")]))
    }

}
