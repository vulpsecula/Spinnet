import XCTest
import SpinnetCore
import Darwin

final class HomebrewNativeCommandExecutionTests: XCTestCase {
    func testOutputOverflowStartsStopGraceBeforeOriginalTimeoutAndRetainsActualReaper() throws {
        let reaped = DispatchSemaphore(value: 0)
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' INT TERM; printf 'overflow'; while :; do /bin/sleep 1; done"],
            environment: ["PATH": "/usr/bin:/bin"], interruptGrace: 0.5, terminateGrace: 0.5)
        let started = Date()
        let outcome = try HomebrewNativeCommandExecution.execute(process, timeout: 5, stopGrace: 0.01,
            maximumOutputBytes: 1, didReap: { _ in reaped.signal() })
        XCTAssertEqual(outcome.state, .unknown)
        XCTAssertNil(outcome.result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6, "Output Stop begins its own grace without waiting for the original five-second deadline")
        XCTAssertEqual(reaped.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(reaped.wait(timeout: .now() + 4), .success)
        XCTAssertTrue(process.ownedProcessIdentities.isEmpty)
    }

    func testFixedReadOutputIsExactAndOversizeIsRefusedAfterReaping() throws {
        let exact = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["status\\n"], environment: ["PATH": "/usr/bin:/bin"])
        let reply = try HomebrewNativeCommandExecution.execute(exact, timeout: 2, maximumOutputBytes: 64)
        XCTAssertEqual(reply.output, Data("status\n".utf8))
        let oversized = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [String(repeating: "x", count: 129)], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertThrowsError(try HomebrewNativeCommandExecution.execute(oversized, timeout: 2, maximumOutputBytes: 128)) { error in
            XCTAssertEqual(error as? PluginHostServiceError, .tool(.outputTooLarge))
        }
        XCTAssertTrue(oversized.ownedProcessIdentities.isEmpty)
    }
    func testAbsoluteDeadlineStopsAndReapsAnOwnedBlockedCommand() throws {
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/tail"), arguments: ["-f", "/dev/null"], environment: ["PATH": "/usr/bin:/bin"], interruptGrace: 0.05, terminateGrace: 0.05)
        var reaped = false
        let started = Date()
        let outcome = try HomebrewNativeCommandExecution.execute(process, timeout: 0.1, stopGrace: 2, didReap: { _ in reaped = true })
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(reaped)
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.result?.outcome, "stopped")
    }
    func testStopBeforeSpawnNeverExecutesTheOwnedCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spinnet-native-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("should-not-exist")
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertThrowsError(try HomebrewNativeCommandExecution.execute(process, timeout: 1, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testUnknownReplyKeepsTheLaneUntilTheOwnedIgnoringChildActuallyReaps() throws {
        let reaped = DispatchSemaphore(value: 0)
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' INT TERM; while :; do /bin/sleep 1; done"], environment: ["PATH": "/usr/bin:/bin"], interruptGrace: 0.5, terminateGrace: 0.5)
        let started = Date()
        let outcome = try HomebrewNativeCommandExecution.execute(process, timeout: 0.1, stopGrace: 0.01, didReap: { _ in reaped.signal() })
        XCTAssertEqual(outcome.state, .unknown)
        XCTAssertNil(outcome.result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertEqual(reaped.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(reaped.wait(timeout: .now() + 4), .success)
        XCTAssertNil(HomebrewTaskProcess.startIdentity(process.processIdentifier))
    }

    func testResourceIdentitySnapshotContainsOnlyThisLiveCommandAndClearsAfterReap() throws {
        let done = DispatchSemaphore(value: 0)
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/tail"), arguments: ["-f", "/dev/null"], environment: ["PATH": "/usr/bin:/bin"], interruptGrace: 0.05, terminateGrace: 0.05)
        XCTAssertTrue(process.ownedProcessIdentities.isEmpty)
        try process.start(output: { _ in }, finished: { _ in done.signal() })
        let pid = process.processIdentifier
        let identity = try XCTUnwrap(HomebrewTaskProcess.startIdentity(pid))
        XCTAssertEqual(process.ownedProcessIdentities[pid], identity)
        XCTAssertFalse(process.ownedProcessIdentities.keys.contains(Int32(getpid())))
        process.stop()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(process.ownedProcessIdentities.isEmpty)
    }

}
