import Foundation

/// The fast mode of the test suite, for the edit-and-test loop. With
/// `SPINNET_FAST_TESTS=1`, tests that take seconds and check a timing budget,
/// a real process or tool on this Mac, or the whole repository's text skip
/// themselves with `try XCTSkipIf(SlowTests.skipped, SlowTests.reason)`.
/// The full suite runs them all and is the one to report.
public enum SlowTests {
    public static let skipped = ProcessInfo.processInfo.environment["SPINNET_FAST_TESTS"] == "1"
    public static let reason = "A slow test: the fast mode (SPINNET_FAST_TESTS=1) leaves it to the full suite"
}
