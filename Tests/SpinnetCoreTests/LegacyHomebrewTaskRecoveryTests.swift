import Foundation
import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class LegacyHomebrewTaskRecoveryTests: XCTestCase {
    func testRecoveredInspectionRetainsTheLaneUntilActualReapingIsProven() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "inspection_" + UUID().uuidString.lowercased()
        try JSONEncoder().encode(JSONValue.object(["id": .string(id), "owner": .string("legacy"), "name": .string("Homebrew")]))
            .write(to: root.appendingPathComponent("pending-inspection.json"))
        let transport = RecoveryTransport()
        let activities = HostActivities()
        let host = HostReviewedToolTasks(activities: activities, journal: root,
            runnerURL: root.appendingPathComponent("must-not-run"),
            preflight: { _ in XCTFail("Recovery cannot prepare new work while its lane is held"); return .null },
            nativeInspection: transport, hostIsCurrent: {})
        XCTAssertTrue(waitUntil { transport.recoveryCalls > 0 })
        XCTAssertTrue(host.hasRunningTasks)
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("new"), pluginName: "New")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-inspection.json").path))
        XCTAssertEqual(transport.admissionCalls, 0)
        transport.setIdle()
        XCTAssertTrue(waitUntil { host.refresh(); return !host.hasRunningTasks })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-inspection.json").path))
        XCTAssertFalse(activities.list().contains { $0.kind == "inspection" })
        XCTAssertEqual(transport.admissionCalls, 0, "Reading old status never resumes inspection or admission")
    }

    func testUnavailableLegacyInspectionStatusKeepsTheLaneAndNeverReplays() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "inspection_" + UUID().uuidString.lowercased()
        try JSONEncoder().encode(JSONValue.object(["id": .string(id), "owner": .string("legacy"), "name": .string("Homebrew")]))
            .write(to: root.appendingPathComponent("pending-inspection.json"))
        let transport = RecoveryTransport(unavailable: true)
        let recovery = LegacyHomebrewTaskRecovery(activities: HostActivities(), journal: root, transport: transport,
            isRunning: { _ in XCTFail("Inspection recovery is not Task execution"); return false },
            stop: { _ in XCTFail("Reading status cannot stop an unrelated Task") })
        XCTAssertTrue(waitUntil { transport.recoveryCalls > 0 })
        XCTAssertTrue(recovery.hasPendingInspection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-inspection.json").path))
        XCTAssertEqual(transport.admissionCalls, 0)
    }

    func testMismatchedRootPlanCannotProveAnotherJournalIdleOrStopItsTask() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "activity_1234567890abcdef1234567890abcdef"
        let otherID = "activity_abcdef1234567890abcdef1234567890"
        let taskDirectory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var record = HomebrewTaskJournal(id: id, owner: "legacy", pluginName: "Homebrew",
            input: .object(["tool": .string("homebrew"), "operation": .string("upgrade"),
                            "kind": .string("cask"), "name": .string("example")]),
            package: .object([:]), executable: "/opt/homebrew/bin/brew", started: Date(), detached: false,
            runnerPID: Int32.max, runnerIdentity: 1, processGroup: nil, processIdentity: nil,
            stage: "completed", log: [], result: .object(["outcome": .string("completed")]), ended: Date())
        record.privilegePlan = try HomebrewPrivilegePlan(taskID: otherID, prefix: "/opt/homebrew",
            casks: [.init(name: "example", version: "1", sha256: String(repeating: "a", count: 64),
                          packages: ["Example.pkg"])], operation: "upgrade")
        try record.save(to: taskDirectory)
        try HomebrewTaskProcessLease(taskID: id, runnerPID: Int32.max, runnerIdentity: 1).save(to: taskDirectory)

        let status = expectation(description: "Never query a different Task's Root status")
        let stop = expectation(description: "Never stop a different Task's Root work")
        status.isInverted = true
        stop.isInverted = true
        let recovery = LegacyHomebrewTaskRecovery(activities: HostActivities(), journal: root, transport: nil,
            isRunning: { _ in status.fulfill(); return false }, stop: { _ in stop.fulfill() })
        XCTAssertTrue(recovery.mayHavePrivilegedExecution(record, refresh: true))
        XCTAssertFalse(recovery.privilegePlanIsProvenIdle(record))
        recovery.stopPrivilegedExecution(record, onFailure: { XCTFail("Mismatched authority must not be sent") })

        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root,
            runnerURL: root.appendingPathComponent("must-not-launch"),
            preflight: { _ in XCTFail("Recovery cannot replay or prepare new work"); return .null },
            nativeInspection: nil,
            privilegedTaskIsRunning: { _ in status.fulfill(); return false },
            stopPrivilegedTask: { _ in stop.fulfill() }, hostIsCurrent: {})
        host.refresh()
        XCTAssertTrue(host.hasRunningTasks, "A reaped local lease cannot prove mismatched Root authority idle")
        try host.stop(id)
        host.refresh()
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("new"), pluginName: "New")) {
            XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy))
        }
        wait(for: [status, stop], timeout: 0.1)
        XCTAssertTrue(host.hasRunningTasks)
        let saved = try HomebrewTaskJournal.load(from: taskDirectory)
        XCTAssertEqual(saved.privilegePlan?.taskID, otherID, "Unknown authority remains available for explicit recovery")
        XCTAssertEqual(saved.result, record.result, "Recovery must not overwrite the recorded outcome or replay it")
    }

    func testNewCLIPlansDoNotUseLegacyInspectionAuthority() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecoveryTransport()
        let host = HostReviewedToolTasks(activities: HostActivities(), journal: root,
            runnerURL: root.appendingPathComponent("must-not-run"),
            executable: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") }, preflight: { _ in .object([:]) },
            nativeInspection: transport, hostIsCurrent: {})
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
        let plan = try host.prepare(input, owner: .init("new"), pluginName: "Homebrew")
        XCTAssertEqual(plan.executionModel, "native-cli-v1")
        host.decline(plan)
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertEqual(transport.admissionCalls, 0)
        XCTAssertEqual(transport.recoveryCalls, 0, "New Tasks do not require a legacy daemon")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    private final class RecoveryTransport: HomebrewNativeInspectionTransporting {
        private let lock = NSLock()
        private var calls = 0, admissions = 0
        private var idle = false
        private let unavailable: Bool
        init(unavailable: Bool = false) { self.unavailable = unavailable }
        var recoveryCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var admissionCalls: Int { lock.lock(); defer { lock.unlock() }; return admissions }
        func setIdle() { lock.lock(); idle = true; lock.unlock() }
        private func unexpected() { lock.lock(); admissions += 1; lock.unlock() }
        func reserve(_ draft: HomebrewNativeInspection.Draft, cancellation: HostFetchedSections.Cancellation) throws -> HomebrewNativeInspection.Reservation {
            unexpected(); throw HomebrewNativeInspection.Failure.wrongState
        }
        func inspect(_ reservation: HomebrewNativeInspection.Reservation, draft: HomebrewNativeInspection.Draft,
                     cancellation: HostFetchedSections.Cancellation) throws -> (summary: HomebrewNativeInspection.Summary, disclosure: HomebrewNativeInspection.Disclosure) {
            unexpected(); throw HomebrewNativeInspection.Failure.wrongState
        }
        func admit(_ reservation: HomebrewNativeInspection.Reservation, plan: HomebrewPrivilegePlan,
                   cancellation: HostFetchedSections.Cancellation) throws { unexpected(); throw HomebrewNativeInspection.Failure.wrongState }
        func cancel(_ inspectionID: String) { unexpected() }
        func status(_ inspectionID: String) throws -> HomebrewNativeInspection.Status { unexpected(); throw HomebrewNativeInspection.Failure.wrongState }
        func laneStatus() throws -> HomebrewNativeInspection.Status { unexpected(); throw HomebrewNativeInspection.Failure.wrongState }
        func recoverStatus(_ inspectionID: String) throws -> HomebrewNativeInspection.Status {
            lock.lock(); calls += 1; let idle = self.idle; lock.unlock()
            if unavailable { throw HomebrewNativeInspection.Failure.storeUnavailable }
            return .init(inspectionID: inspectionID, state: .cancelled, laneHeld: !idle, workerUnreaped: !idle)
        }
    }
}
