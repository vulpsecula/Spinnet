import XCTest
import Foundation
import Darwin
import SpinnetCore

final class ReviewedTaskOrphanRecoveryTests: XCTestCase {
    private final class Power: PowerAssertions {
        var held = 0, acquired = 0, released = 0
        func acquire(_ assertion: KeepAwakeAssertion, reason: String) throws -> () -> Void {
            XCTAssertEqual(assertion, .idleSystem); held += 1; acquired += 1
            return { self.held -= 1; self.released += 1 }
        }
    }
    func testUnknownPendingSpawnCannotSignalAReusedPidOrFreeTheLane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_unbound", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/tail"); unrelated.arguments = ["-f", "/dev/null"]
        unrelated.standardInput = FileHandle.nullDevice; unrelated.standardOutput = FileHandle.nullDevice; unrelated.standardError = FileHandle.nullDevice
        try unrelated.run(); defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let birth = try XCTUnwrap(HomebrewTaskProcess.startIdentity(unrelated.processIdentifier))
        let record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "cleanup"],
            "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "detached": false, "runnerPID": 999998, "runnerIdentity": 123, "stage": "starting", "log": []]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
        try HomebrewTaskProcessLease(taskID: id, runnerPID: 999998, runnerIdentity: 123, reservation: UUID().uuidString.lowercased(),
            leaderPID: unrelated.processIdentifier, leaderIdentity: birth + 1, members: [String(unrelated.processIdentifier): birth + 1]).save(to: directory)
        let activities = HostActivities(), power = Power()
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil, recoveryPower: power)
        try host.stop(id); host.refresh()
        XCTAssertTrue(unrelated.isRunning, "A numeric PID or reused process group never grants signal authority")
        XCTAssertTrue(host.hasRunningTasks); XCTAssertEqual(power.held, 1)
        XCTAssertTrue(activities.list().first?.status.contains("unknown") == true)
    }

    func testRecoveryInventoryCannotHideAnActiveTaskAfterSixtyFourEndedJournals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<66 {
            let id = "activity_inventory_\(index)", directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "cleanup"],
                "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "detached": false, "stage": "ended", "log": []]
            if index < 65 { record["result"] = ["outcome": "completed"]; record["ended"] = Date().timeIntervalSinceReferenceDate }
            else { record["stage"] = "running"; record["runnerPID"] = getpid(); record["runnerIdentity"] = HomebrewTaskProcess.startIdentity(getpid())! }
            try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
        }
        let activities = HostActivities(), power = Power()
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil, recoveryPower: power)
        XCTAssertEqual(power.held, 1, "Incomplete recovery must retain a true idle-system-sleep assertion")
        XCTAssertTrue(host.hasRunningTasks, "An incomplete bounded inventory is busy, never empty")
        XCTAssertTrue(activities.list().contains { $0.kind == "native_lane" && $0.status.contains("inventory") }, "The Host must disclose incomplete recovery instead of silently dropping saved journals")
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("next"), pluginName: "Next")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
    }

    func testMalformedRunnerMetadataRefusesRecoveryWithoutTrapOrNewWork() throws {
        for text in ["broken JSON", "{\"pid\":1e100,\"identity\":-1}", "{\"pid\":-1,\"identity\":123}",
                     "{\"pid\":42.5,\"identity\":123}", "{\"pid\":42,\"identity\":1e100}", "{\"pid\":\(getpid()),\"identity\":\(HomebrewTaskProcess.startIdentity(getpid())!),\"padding\":\"" + String(repeating: "x", count: 4096) + "\"}"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let id = "activity_bad_metadata", directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "cleanup"],
                "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "detached": false, "stage": "running", "log": []]
            try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
            let metadata = directory.appendingPathComponent("runner.json")
            try Data(text.utf8).write(to: metadata); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            let activities = HostActivities(), power = Power()
            let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil, recoveryPower: power)
            XCTAssertTrue(host.hasRunningTasks)
            XCTAssertTrue(activities.list().contains { $0.kind == "native_lane" && $0.status.contains("inventory") }, "Bad runner metadata must be an explicit recovery refusal")
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
            XCTAssertThrowsError(try host.prepare(input, owner: .init("next"), pluginName: "Next")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
        }
    }

    func testRunnerMetadataRequiresAnOwnedRegularFileAndAcceptsValidBoundedIntegers() throws {
        for symlink in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let id = "activity_runner_metadata", directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "cleanup"],
                "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "detached": false, "stage": "running", "log": []]
            try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
            let metadata = directory.appendingPathComponent("runner.json")
            let target = symlink ? root.appendingPathComponent("unowned.json") : metadata
            try Data("{\"pid\":\(getpid()),\"identity\":\(HomebrewTaskProcess.startIdentity(getpid())!)}".utf8).write(to: target)
            if symlink { try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target) }
            let activities = HostActivities()
            let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
            XCTAssertTrue(host.hasRunningTasks)
            XCTAssertEqual(activities.list().contains { $0.kind == "native_lane" }, symlink)
            if !symlink { XCTAssertEqual(activities.list().first?.kind, "task") }
        }
    }

    func testKnownPrivilegedTerminalResultsSurviveRootConnectionFailureAndRecovery() throws {
        for outcome in ["completed", "failed"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let id = "activity_terminal_root", directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let plan = try HomebrewPrivilegePlan(taskID: id, prefix: "/opt/homebrew", casks: [.init(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])])
            let expected: JSONValue = .object(["outcome": .string(outcome), "exit_status": .number(outcome == "completed" ? 0 : 2)])
            let record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "install", "kind": "cask", "name": "example"],
                "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "ended": Date().timeIntervalSinceReferenceDate, "detached": false,
                "runnerPID": 999999, "runnerIdentity": 123, "stage": "finished", "log": [], "privilegePlan": try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)),
                "result": try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))]
            try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
            try HomebrewTaskProcessLease(taskID: id, runnerPID: 999999, runnerIdentity: 123).save(to: directory)
            let activities = HostActivities(), power = Power(), stateLock = NSLock()
            var reachable = false, running = true, stops = 0, successfulQueries = 0
            let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil, recoveryPower: power,
                privilegedTaskIsRunning: { _ in
                    stateLock.lock(); defer { stateLock.unlock() }
                    guard reachable else { throw PluginHostServiceError.unavailable("Background component startup failed") }
                    successfulQueries += 1
                    return running
                },
                stopPrivilegedTask: { _ in stateLock.lock(); stops += 1; stateLock.unlock() })
            XCTAssertTrue(host.hasRunningTasks)
            XCTAssertEqual(power.held, 1)
            XCTAssertTrue(activities.list().first?.canStop == true)
            try host.stop(id)
            let stopReached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in stateLock.lock(); defer { stateLock.unlock() }; return stops == 1 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [stopReached], timeout: 2), .completed)
            XCTAssertTrue(host.hasRunningTasks)
            let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
            XCTAssertThrowsError(try host.prepare(input, owner: .init("next"), pluginName: "Next")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
            stateLock.lock(); reachable = true; stateLock.unlock(); host.refresh()
            let connected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                stateLock.lock(); defer { stateLock.unlock() }; return successfulQueries > 0
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 3), .completed)
            XCTAssertTrue(host.hasRunningTasks, "A restored connection alone does not prove Root work ended")
            stateLock.lock(); running = false; stateLock.unlock(); host.refresh()
            let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !host.hasRunningTasks }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [reaped], timeout: 3), .completed)
            XCTAssertEqual(activities.list().first?.json.value(atPointer: "/result"), expected, "Recovery must preserve the actual recorded outcome")
            XCTAssertEqual(power.held, 0); XCTAssertEqual(power.released, 1)
        }
    }

    func testPrivilegedOrphanStopReachesRootAndLaneWaitsForAuthenticatedActualReap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_root_orphan", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try HomebrewPrivilegePlan(taskID: id, prefix: "/opt/homebrew", casks: [.init(name: "example", version: "1", sha256: String(repeating: "a", count: 64), packages: ["Example.pkg"])])
        let planObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
        let record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "install", "kind": "cask", "name": "example"],
            "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "detached": false, "runnerPID": 999999, "runnerIdentity": 123,
            "stage": "native work", "log": [], "privilegePlan": planObject]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
        try HomebrewTaskProcessLease(taskID: id, runnerPID: 999999, runnerIdentity: 123).save(to: directory)
        let activities = HostActivities(), power = Power(), stopped = expectation(description: "authenticated Root Stop requested")
        var rootRunning = true
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil,
            recoveryPower: power, privilegedTaskIsRunning: { value in XCTAssertEqual(value, plan); return rootRunning },
            stopPrivilegedTask: { value in XCTAssertEqual(value, plan); stopped.fulfill() })
        XCTAssertTrue(host.hasRunningTasks)
        try host.stop(id); wait(for: [stopped], timeout: 2)
        XCTAssertTrue(host.hasRunningTasks); XCTAssertEqual(power.held, 1)
        rootRunning = false; host.refresh()
        let reaped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !host.hasRunningTasks }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reaped], timeout: 3), .completed)
        XCTAssertEqual(power.held, 0); XCTAssertEqual(power.released, 1)
        XCTAssertEqual(activities.list().first?.json.value(atPointer: "/result/outcome"), .string("unknown"))
    }

    func testKilledRunnerRetainsOwnedChildStopSleepAndLaneUntilActualReapProof() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-pid")
        let runner = Process(); runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = ["-c", "/usr/bin/tail -f /dev/null & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "fixture", marker.path]
        runner.standardInput = FileHandle.nullDevice; runner.standardOutput = FileHandle.nullDevice; runner.standardError = FileHandle.nullDevice
        try runner.run()
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let child = try XCTUnwrap(Int32(try String(contentsOf: marker)))
        defer { if HomebrewTaskProcess.startIdentity(child) != nil { kill(child, SIGKILL) }; if runner.isRunning { runner.terminate(); runner.waitUntilExit() } }
        let runnerBirth = try XCTUnwrap(HomebrewTaskProcess.startIdentity(runner.processIdentifier)), childBirth = try XCTUnwrap(HomebrewTaskProcess.startIdentity(child))
        let id = "activity_orphan", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "cleanup"],
            "package": [:], "executable": "/opt/homebrew/bin/brew", "started": 0, "detached": false, "runnerPID": runner.processIdentifier,
            "runnerIdentity": runnerBirth, "processGroup": child, "processIdentity": childBirth, "stage": "running", "log": []]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("task.json"))
        var lease = HomebrewTaskProcessLease(taskID: id, runnerPID: runner.processIdentifier, runnerIdentity: runnerBirth,
            reservation: UUID().uuidString.lowercased(), leaderPID: child, leaderIdentity: childBirth, members: [String(child): childBirth])
        try lease.save(to: directory)
        kill(runner.processIdentifier, SIGKILL); runner.waitUntilExit()
        XCTAssertNotNil(HomebrewTaskProcess.startIdentity(child))
        let activities = HostActivities(), power = Power()
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"),
            preflight: { _ in .object([:]) }, nativeInspection: nil, recoveryPower: power)
        XCTAssertTrue(host.hasRunningTasks)
        XCTAssertEqual(power.held, 1)
        XCTAssertTrue(activities.list().first?.canStop == true)
        XCTAssertEqual(activities.list().first?.json.value(atPointer: "/prevents_idle_sleep"), .bool(true))
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("cleanup")]))
        XCTAssertThrowsError(try host.prepare(input, owner: .init("other"), pluginName: "Other")) { XCTAssertEqual($0 as? PluginHostServiceError, .tool(.busy)) }
        try host.stop(id)
        let stopped = Date().addingTimeInterval(18)
        while HomebrewTaskProcess.startIdentity(child) != nil, Date() < stopped { host.refresh(); Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertNil(HomebrewTaskProcess.startIdentity(child))
        host.refresh()
        XCTAssertTrue(host.hasRunningTasks, "Missing final census proof cannot fabricate a free lane")
        XCTAssertEqual(power.held, 1)
        // The fixture's actual reaper now commits the terminal process proof.
        lease.reservation = nil; lease.leaderPID = nil; lease.leaderIdentity = nil; lease.members = [:]
        try lease.save(to: directory); host.refresh()
        XCTAssertFalse(host.hasRunningTasks)
        XCTAssertEqual(power.held, 0); XCTAssertEqual(power.acquired, 1); XCTAssertEqual(power.released, 1)
        XCTAssertEqual(activities.list().first?.json.value(atPointer: "/result/outcome"), .string("unknown"))
    }
}
