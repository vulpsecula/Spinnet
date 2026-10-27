import Foundation
import Darwin
import XCTest
@testable import SpinnetReviewedTools

final class HomebrewTaskProcessCensusTests: XCTestCase {
    func testMissingCensusCannotReportSuccessfulReaping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity_census_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var lease = HomebrewTaskProcessLease(taskID: directory.lastPathComponent, runnerPID: getpid(),
            runnerIdentity: try XCTUnwrap(HomebrewTaskProcess.startIdentity(getpid())), reservation: UUID().uuidString.lowercased())
        let done = expectation(description: "known leader reaped with unknown ownership")
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        process.processInventory = { nil }
        try process.start(output: { _ in }, finished: { result in
            XCTAssertEqual(result.outcome, "unknown")
            XCTAssertTrue(result.ownershipUncertain)
            lease.recordReaping(result)
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
        XCTAssertTrue(process.ownershipUncertain)
        XCTAssertFalse(lease.provesNoOwnedExecution)
        XCTAssertNotNil(lease.reservation)
        try lease.save(to: directory)
        XCTAssertTrue(try HomebrewTaskProcessLease.load(from: directory).ownershipUncertain)
    }

    func testExitedHistoryDoesNotConsumeTheLiveMemberBudget() {
        var census = HomebrewTaskProcess.Census()
        for pid in Int32(10)..<Int32(20) {
            let child = info(pid, parent: 2, group: 2)
            census.observe([child], leader: 2, leaderIdentity: 1, ownsGroup: true, leaderGroupBound: true,
                identity: { $0 == pid ? 1 : nil }, maximumMembers: 2)
            XCTAssertEqual(census.members, [pid: 1])
            XCTAssertFalse(census.ownershipUncertain)
        }
    }

    func testMemberOverflowStaysUnknownAndNeverAdmitsUnownedOrReusedPIDs() {
        var census = HomebrewTaskProcess.Census()
        census.observe([info(10, parent: 2, group: 2), info(11, parent: 2, group: 2), info(50, parent: 1, group: 50)],
            leader: 2, leaderIdentity: 1, ownsGroup: true, leaderGroupBound: true, identity: { _ in 1 }, maximumMembers: 2)
        XCTAssertTrue(census.ownershipUncertain)
        XCTAssertEqual(census.members.count, 1)
        XCTAssertNil(census.members[50])
        // A later complete/empty census cannot repair lost ancestry evidence.
        census.observe([], leader: 2, leaderIdentity: 1, ownsGroup: true, leaderGroupBound: false,
            identity: { _ in 2 }, maximumMembers: 2)
        XCTAssertTrue(census.ownershipUncertain)
        XCTAssertTrue(census.members.isEmpty)
    }

    func testDiscoveryDepthOverflowCannotProveAnEmptyLane() {
        var census = HomebrewTaskProcess.Census()
        let chain = [info(2, parent: 1, group: 2)] + (Int32(10)...Int32(74)).map {
            info($0, parent: $0 == 10 ? 2 : $0 - 1, group: $0)
        }
        census.observe(chain, leader: 2, leaderIdentity: 1, ownsGroup: false, leaderGroupBound: true, identity: { _ in 1 })
        XCTAssertTrue(census.ownershipUncertain)
        XCTAssertEqual(census.members.count, HomebrewTaskProcessLease.maximumDiscoveryDepth)
        XCTAssertNil(census.members[74], "A child beyond the bounded discovery rounds was not assigned Stop authority")
    }

    func testFailedOrTruncatedNativePIDListIsUnavailable() {
        XCTAssertNil(HomebrewTaskProcess.processIDs { address, _ in address == nil ? 1 : -1 })
        XCTAssertNil(HomebrewTaskProcess.processIDs { address, _ in address == nil ? 1 : 65 },
            "The second read filled all count+64 slots and may be truncated")
        XCTAssertNil(HomebrewTaskProcess.processIDs { _, _ in Int32(HomebrewTaskProcessLease.maximumProcessInventory + 1) })
        XCTAssertEqual(HomebrewTaskProcess.processIDs { address, _ in
            if address == nil { return 1 }
            address!.assumingMemoryBound(to: pid_t.self).pointee = 123
            return 1
        }, [123])
    }

    func testUncertainLeaseKeepsVerifiedStopMembersAfterAnOtherwiseNormalResult() {
        var lease = reservedLease()
        lease.ownershipUncertain = true
        lease.recordReaping(.init(outcome: "completed", exitStatus: 0, stop: nil))
        XCTAssertTrue(lease.ownershipUncertain)
        XCTAssertFalse(lease.provesNoOwnedExecution)
        XCTAssertNotNil(lease.reservation)
        XCTAssertEqual(lease.leaderPID, 10)
        XCTAssertEqual(lease.members, ["11": 1])
    }

    func testCompleteCensusAllowsANormalResultToReleaseTheLease() throws {
        let done = expectation(description: "normal complete census")
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        try process.start(output: { _ in }, finished: { result in
            XCTAssertEqual(result.outcome, "completed")
            XCTAssertFalse(result.ownershipUncertain)
            var lease = self.reservedLease()
            lease.recordReaping(result)
            XCTAssertTrue(lease.provesNoOwnedExecution)
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
    }

    private func reservedLease() -> HomebrewTaskProcessLease {
        .init(taskID: "activity_census", runnerPID: getpid(), runnerIdentity: 1,
            reservation: UUID().uuidString.lowercased(), leaderPID: 10, leaderIdentity: 1, members: ["11": 1])
    }

    private func info(_ pid: Int32, parent: Int32, group: Int32) -> proc_bsdinfo {
        var value = proc_bsdinfo()
        value.pbi_pid = UInt32(pid); value.pbi_ppid = UInt32(parent); value.pbi_pgid = UInt32(group)
        value.pbi_start_tvusec = 1
        return value
    }
}
