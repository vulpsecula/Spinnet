import XCTest
@testable import SpinnetCore

final class HomebrewReadBootstrapNativeTests: XCTestCase {
    private func requireNativeProbe() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_HOMEBREW_NATIVE_PROBE"] == "1" else { throw XCTSkip("Opt-in read-only installed Homebrew probe") }
    }
    func testNativeReadOutputDoesNotContainSandboxBootstrapErrors() throws {
        try requireNativeProbe()
        for command in ["version", "list", "outdated", "search", "info", "tap"] {
            var input: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string(command)]
            if ["search", "info"].contains(command) { input["package"] = .string("wget") }
            let result = try HomebrewReadProfile().read(.object(input), owner: .init("bootstrap-native"), timeout: 15)
            guard case .string(let output)? = result.value(atPointer: "/output") else { return XCTFail("Missing native output") }
            XCTAssertFalse(output.contains("cannot create temp file for here document"), command + " contains denied bootstrap writes")
            XCTAssertEqual(result.value(atPointer: "/exit_status"), .number(0), command)
        }
    }
    func testNativeSearchMatchesAndMissesCompleteWithoutReviewedReadFailure() throws {
        try requireNativeProbe()
        let installed = try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string("installed")]), owner: .init("search-bootstrap-native"), timeout: 15)
        XCTAssertNotNil(installed.value(atPointer: "/packages"), "Search first loads installed state")
        for query in ["wget", "firefox", "google-chrome", "git", "zz-spinnet-no-such-package", "node@", "c++", "foo.bar", "@scope", "++"] {
            XCTAssertNoThrow(try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string("search"), "query": .string(query)]), owner: .init("search-bootstrap-native"), timeout: 15), query)
        }
    }
}
