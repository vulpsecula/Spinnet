import Foundation
import SpinnetTestSupport
import XCTest
@testable import SpinnetCore

/// A Spinnet release check asks GitHub for the Spinnet repository's newest
/// published release and compares it by SemVer with the running version,
/// against recorded GitHub answers.
final class SpinnetReleaseCheckTests: XCTestCase {
    private let latestURL = "https://api.github.com/repos/vulpsecula/Spinnet/releases/latest"
    private var transport: RecordedGitHubTransport!

    override func setUp() {
        transport = RecordedGitHubTransport()
    }

    private func checker(running: String = "1.0.0") -> SpinnetReleaseChecker {
        SpinnetReleaseChecker(transport: transport, runningVersion: running)
    }

    private func publishLatest(tag: String, draft: Bool = false, prerelease: Bool = false) throws {
        transport.answer(latestURL, body: try JSONSerialization.data(withJSONObject: [
            "id": 1, "tag_name": tag, "name": "Spinnet \(tag)", "draft": draft, "prerelease": prerelease,
            "html_url": "https://github.com/vulpsecula/Spinnet/releases/tag/\(tag)", "assets": []
        ] as [String: Any]))
    }

    private func failedCheck(running: String = "1.0.0") -> SpinnetReleaseCheckError? {
        do {
            _ = try checker(running: running).check()
            return nil
        } catch {
            return error as? SpinnetReleaseCheckError
        }
    }

    func testANewerReleaseIsOfferedWithItsReleasePage() throws {
        try publishLatest(tag: "v1.2.0")

        let check = try checker().check()

        XCTAssertEqual(check, .newer(SpinnetRelease(
            version: "1.2.0", page: URL(string: "https://github.com/vulpsecula/Spinnet/releases/tag/v1.2.0")!)))
        XCTAssertEqual(transport.requestedURLs, [latestURL], "One question, and nothing is downloaded")
    }

    func testTheSameOrAnOlderReleaseIsUpToDateBySemVer() throws {
        try publishLatest(tag: "v1.10.0")
        XCTAssertEqual(try checker(running: "1.10.0").check(), .upToDate(latest: "1.10.0"))
        XCTAssertEqual(try checker(running: "1.9.0").check(), .newer(SpinnetRelease(
            version: "1.10.0", page: URL(string: "https://github.com/vulpsecula/Spinnet/releases/tag/v1.10.0")!)),
            "1.10.0 is newer than 1.9.0 by SemVer, not by text")
        XCTAssertEqual(try checker(running: "2.0.0").check(), .upToDate(latest: "1.10.0"))
        XCTAssertEqual(try checker(running: "1.10.0-beta.1").check(), .newer(SpinnetRelease(
            version: "1.10.0", page: URL(string: "https://github.com/vulpsecula/Spinnet/releases/tag/v1.10.0")!)),
            "A release is newer than its own prerelease")
    }

    func testARepositoryWithoutAPublishedReleaseIsUpToDate() throws {
        transport.answer(latestURL, status: 404, body: Data(#"{"message": "Not Found"}"#.utf8))

        XCTAssertEqual(try checker().check(), .upToDate(latest: nil))
    }

    func testBeingOfflineOrTimingOutFailsTheCheck() {
        XCTAssertEqual(failedCheck(), .offline, "Nothing recorded answers as if offline")

        let slow = TimingOutTransport()
        XCTAssertThrowsError(try SpinnetReleaseChecker(transport: slow).check()) {
            XCTAssertEqual($0 as? SpinnetReleaseCheckError, .timedOut)
        }
    }

    func testGitHubsRateLimitFailsTheCheckAndSaysWhenItResets() {
        transport.answer(latestURL, status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000000"])
        XCTAssertEqual(failedCheck(), .rateLimited(resetsAt: Date(timeIntervalSince1970: 1_700_000_000)))

        transport.answer(latestURL, status: 429)
        XCTAssertEqual(failedCheck(), .rateLimited(resetsAt: nil))
    }

    func testAnUnexpectedOrUnreadableAnswerFailsTheCheck() throws {
        transport.answer(latestURL, status: 500)
        XCTAssertEqual(failedCheck(), .unexpectedStatus(500))

        transport.answer(latestURL, body: Data("<html>".utf8))
        XCTAssertEqual(failedCheck(), .unreadableAnswer("it is not a release."))

        try publishLatest(tag: "nightly")
        XCTAssertEqual(failedCheck(), .unreadableAnswer("its tag nightly does not name a SemVer version."))

        try publishLatest(tag: "v9.0.0", prerelease: true)
        XCTAssertEqual(failedCheck(), .unreadableAnswer("it is a draft or a prerelease."),
                       "Only a published, final release is compared")
    }
}

/// A transport whose every request times out.
private final class TimingOutTransport: HTTPSTransport {
    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        throw HTTPSTransportError.timedOut
    }
}
