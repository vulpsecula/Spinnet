import XCTest
@testable import SpinnetHost

final class HostSingleInstanceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func instance(_ pid: Int32, launchedAfter seconds: TimeInterval) -> HostSingleInstance.Instance {
        .init(processIdentifier: pid, launchDate: start.addingTimeInterval(seconds))
    }

    func testAloneSpinnetKeepsRunning() {
        XCTAssertNil(HostSingleInstance.instance(toDeferTo: [], from: instance(10, launchedAfter: 0)))
    }

    /// System Settings' Quit & Reopen reopens Spinnet while Spinnet reopens
    /// itself too, and on a first install the two can name different copies
    /// of the app. The later one leaves, so one Status Item quits Spinnet.
    func testALaterSpinnetDefersToTheOneAlreadyRunning() {
        let earlier = instance(10, launchedAfter: 0)
        XCTAssertEqual(HostSingleInstance.instance(toDeferTo: [earlier], from: instance(11, launchedAfter: 0.2)), earlier)
    }

    /// The earlier Spinnet sees the later one too, and stays.
    func testTheEarlierSpinnetStays() {
        XCTAssertNil(HostSingleInstance.instance(toDeferTo: [instance(11, launchedAfter: 0.2)],
                                                 from: instance(10, launchedAfter: 0)))
    }

    /// Two copies launched in the same instant must not both leave.
    func testALaunchTieKeepsExactlyOne() {
        let low = instance(10, launchedAfter: 0)
        let high = instance(11, launchedAfter: 0)
        XCTAssertNil(HostSingleInstance.instance(toDeferTo: [high], from: low))
        XCTAssertEqual(HostSingleInstance.instance(toDeferTo: [low], from: high), low)
    }

    /// A Spinnet with no known launch date counts as the one already running.
    func testAnUndatedSpinnetCountsAsEarlier() {
        let undated = HostSingleInstance.Instance(processIdentifier: 12, launchDate: nil)
        XCTAssertEqual(HostSingleInstance.instance(toDeferTo: [undated], from: instance(10, launchedAfter: 0)), undated)
    }
}
