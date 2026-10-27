import Foundation
import Darwin
import XCTest
import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewTerminalLeaseTests: XCTestCase {
    func testRecoveryKeepsTerminalUnknownLeaseBusyWhileRunnerIsStillAlive() throws {
        let directory = try fixture(terminal: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let host = makeHost(journal: directory.deletingLastPathComponent())

        try assertBusy(host, directory: directory)
    }

    func testRefreshKeepsTerminalUnknownLeaseBusyWhileRunnerIsStillAlive() throws {
        let directory = try fixture(terminal: false)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let host = makeHost(journal: directory.deletingLastPathComponent())
        XCTAssertTrue(host.hasRunningTasks, "The initially running journal holds the lane")

        var record = try HomebrewTaskJournal.load(from: directory)
        record.result = .object(["outcome": .string("unknown")])
        record.ended = Date()
        try record.save(to: directory)
        host.refresh()

        try assertBusy(host, directory: directory)
    }

    func testIndependentEmptyLeaseEvidenceReleasesTerminalHistoryWhileRunnerLives() throws {
        let directory = try fixture(terminal: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let host = makeHost(journal: directory.deletingLastPathComponent())
        try assertBusy(host, directory: directory)

        let previous = try HomebrewTaskProcessLease.load(from: directory)
        let reaped = HomebrewTaskProcessLease(taskID: previous.taskID,
            runnerPID: previous.runnerPID, runnerIdentity: previous.runnerIdentity)
        try reaped.save(to: directory)
        host.refresh()

        XCTAssertFalse(host.hasRunningTasks, "An independently empty lease releases the lane without waiting for runner exit")
        XCTAssertFalse(makeHost(journal: directory.deletingLastPathComponent()).hasRunningTasks)
        XCTAssertEqual(try HomebrewTaskJournal.load(from: directory).result, .object(["outcome": .string("unknown")]))
    }

    private func makeHost(journal: URL) -> HostReviewedToolTasks {
        HostReviewedToolTasks(activities: .init(), journal: journal,
            runnerURL: journal.appendingPathComponent("must-not-launch"),
            executable: { throw PluginHostServiceError.tool(.missing) },
            nativeInspection: nil, hostIsCurrent: {})
    }

    private func fixture(terminal: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("activity_terminal_lease")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let birth = try XCTUnwrap(HomebrewTaskProcess.startIdentity(getpid()))
        var record: [String: Any] = [
            "id": directory.lastPathComponent, "owner": "brew", "pluginName": "Homebrew",
            "input": ["tool": "homebrew", "operation": "cleanup"], "package": [:],
            "executable": "/opt/homebrew/bin/brew", "started": Date().timeIntervalSinceReferenceDate,
            "detached": false, "runnerPID": getpid(), "runnerIdentity": birth,
            "stage": "running", "log": [], "executionModel": "native-cli-v1"
        ]
        if terminal {
            record["result"] = ["outcome": "unknown"]
            record["ended"] = Date().timeIntervalSinceReferenceDate
        }
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"), options: .atomic)
        var lease = HomebrewTaskProcessLease(taskID: directory.lastPathComponent,
            runnerPID: getpid(), runnerIdentity: birth, reservation: UUID().uuidString.lowercased())
        lease.ownershipUncertain = true
        try lease.save(to: directory)
        return directory
    }

    private func assertBusy(_ host: HostReviewedToolTasks, directory: URL,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try HomebrewTaskJournal.load(from: directory)
        XCTAssertEqual(HomebrewTaskProcess.startIdentity(getpid()), record.runnerIdentity, file: file, line: line)
        XCTAssertEqual(record.result, .object(["outcome": .string("unknown")]), file: file, line: line)
        XCTAssertFalse(try HomebrewTaskProcessLease.load(from: directory).provesNoOwnedExecution, file: file, line: line)
        XCTAssertTrue(host.hasRunningTasks, "A terminal result cannot release an uncertain lease before its live runner exits", file: file, line: line)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("next"), pluginName: "Next"), file: file, line: line) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy), file: file, line: line)
        }
    }
}
