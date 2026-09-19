import XCTest
@testable import SpinnetHost

final class HostRelaunchTests: XCTestCase {

    /// The helper waits for this process to exit, so the new instance never
    /// runs beside the old one, then reopens the same app bundle.
    func testTheRelaunchWaitsForThisProcessThenReopensTheBundle() throws {
        let bundle = URL(fileURLWithPath: "/Users/me/Spinnet Builds/SpinnetHost.app")
        let arguments = try XCTUnwrap(HostRelaunch.shellArguments(waitingFor: 4242, reopening: bundle))
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertEqual(arguments.count, 4)
        // The path travels as a positional argument, never inside the script,
        // so spaces or quotes in it cannot change what runs.
        XCTAssertFalse(arguments[1].contains("Spinnet Builds"))
        XCTAssertTrue(arguments[1].contains("kill -0 4242"))
        XCTAssertTrue(arguments[1].contains("/usr/bin/open"))
        XCTAssertEqual(arguments[3], bundle.path)
    }

    func testOnlyAnAppBundleCanBeReopened() {
        XCTAssertNil(HostRelaunch.shellArguments(waitingFor: 1, reopening: URL(fileURLWithPath: "/tmp/.build/debug")))
    }
}
