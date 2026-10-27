import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class NativeWorkerSupervisorTests: XCTestCase {
    func testRefusedOrCancelledAdmissionNeverSpawnsOrReleasesALane() throws {
        let process = worker("/bin/sleep", arguments: ["5"])
        var admissions = 0, releases = 0
        XCTAssertThrowsError(try NativeWorkerSupervisor.run(process, timeout: 1, maximumOutputBytes: 32,
            stopGrace: 1, isCancelled: { false }, willStart: { _ in admissions += 1; return false },
            didReap: { _ in releases += 1 })) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
        }
        XCTAssertThrowsError(try NativeWorkerSupervisor.run(process, timeout: 1, maximumOutputBytes: 32,
            stopGrace: 1, isCancelled: { true }, willStart: { _ in admissions += 1; return true },
            didReap: { _ in releases += 1 })) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.planChanged))
        }
        XCTAssertEqual(admissions, 1)
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(process.processIdentifier, 0)
    }

    func testFailedSpawnReleasesTheAdmittedLaneExactlyOnce() {
        let process = worker("/private/tmp/spinnet-no-worker-" + UUID().uuidString)
        var admissions = 0, releases = 0
        XCTAssertThrowsError(try NativeWorkerSupervisor.run(process, timeout: 1, maximumOutputBytes: 32,
            stopGrace: 1, isCancelled: { false }, willStart: { admitted in
                XCTAssertTrue(admitted === process); admissions += 1; return true
            }, didReap: { reaped in
                XCTAssertTrue(reaped === process); releases += 1
            }))
        XCTAssertEqual(admissions, 1)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(process.processIdentifier, 0)
    }

    func testAReapedAnswerContainsTheBoundedBytesAndObservedExit() throws {
        let process = worker("/usr/bin/printf", arguments: ["worker answer"])
        var reaped = false
        let outcome = try NativeWorkerSupervisor.run(process, timeout: 2, maximumOutputBytes: 32,
            stopGrace: 1, isCancelled: { false }, willStart: { _ in true }, didReap: { _ in reaped = true })
        guard case .reaped(let result, let bytes, let failure) = outcome else { return XCTFail("The worker must actually reap") }
        XCTAssertTrue(reaped)
        XCTAssertNil(HomebrewTaskProcess.startIdentity(process.processIdentifier))
        XCTAssertEqual(result?.outcome, "completed")
        XCTAssertEqual(result?.exitStatus, 0)
        XCTAssertEqual(bytes, Data("worker answer".utf8))
        XCTAssertNil(failure)
    }

    func testOutputOverflowRefusesTheAnswerInsteadOfReturningAPrefixAsSuccess() throws {
        let process = worker("/usr/bin/printf", arguments: ["too large"])
        let outcome = try NativeWorkerSupervisor.run(process, timeout: 2, maximumOutputBytes: 3,
            stopGrace: 1, isCancelled: { false }, willStart: { _ in true }, didReap: { _ in })
        guard case .reaped(_, let bytes, let failure) = outcome else { return XCTFail("The stopped worker must reap") }
        XCTAssertEqual(failure, .outputTooLarge)
        XCTAssertLessThanOrEqual(bytes.count, 3)
        XCTAssertNil(HomebrewTaskProcess.startIdentity(process.processIdentifier))
    }

    private func worker(_ path: String, arguments: [String] = []) -> HomebrewTaskProcess {
        HomebrewTaskProcess(executable: URL(fileURLWithPath: path), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
            interruptGrace: 0.2, terminateGrace: 0.2)
    }
}
