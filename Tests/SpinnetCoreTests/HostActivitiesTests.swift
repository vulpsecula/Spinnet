import XCTest
import SpinnetCore
import SpinnetPluginTestKit
import SpinnetReviewedTools

/// Tests the approved resource/OS boundary: callers observe Host activities
/// and the resource they own, without reaching into registry storage.
final class HostActivitiesTests: XCTestCase {
    func testEndedTaskRemainsVisibleUntilTheHostClearsIt() throws {
        let activities = HostActivities(), owner = PluginID("task-owner"), other = PluginID("other")
        var stops = 0
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                           removesOnStop: false, stop: { stops += 1 })
        activities.updateTask(task.id, status: "Ended: completed", detail: .object([
            "name": .string("Upgrade"), "status": .string("ended"),
            "result": .object(["outcome": .string("completed")])]))

        XCTAssertEqual(activities.list().map(\.id), [task.id])
        XCTAssertEqual(activities.list(for: owner).map(\.id), [task.id])
        XCTAssertTrue(activities.list(for: other).isEmpty)
        XCTAssertTrue(activities.clearEndedTask(task.id))
        XCTAssertTrue(activities.list().isEmpty)
        XCTAssertEqual(stops, 0, "Clearing history does not stop a resource")
    }

    func testClearEndedTasksLeavesRunningTasksAndEffectsAlone() throws {
        let activities = HostActivities(), owner = PluginID("owner")
        let ended = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        let running = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        let effect = try activities.register(owner: owner, pluginName: "Coffee", kind: "keep_awake", status: "On", stop: {})
        activities.updateTask(ended.id, status: "Ended: failed", detail: .object(["status": .string("ended")]))
        activities.updateTask(running.id, status: "Running", detail: .object(["status": .string("running")]))

        XCTAssertFalse(activities.clearEndedTask(running.id))
        XCTAssertFalse(activities.clearEndedTask(effect.id))
        activities.clearEndedTasks()
        XCTAssertEqual(Set(activities.list().map(\.id)), Set([running.id, effect.id]))
    }

    func testEndedHistoryMakesRoomForANewActivityOwnedByTheSamePlugin() throws {
        let activities = HostActivities(), owner = PluginID("owner")
        var stopped = 0
        for index in 0..<HostActivities.maximumPerPlugin {
            let id = "task-\(index)"
            try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                    id: id, removesOnStop: false, stop: { stopped += 1 })
            activities.updateTask(id, status: "Ended: completed", detail: .object(["status": .string("ended")]))
        }
        let effect = try activities.register(owner: owner, pluginName: "Coffee", kind: "keep_awake", status: "On", stop: {})
        XCTAssertEqual(activities.list().count, HostActivities.maximumPerPlugin)
        XCTAssertFalse(activities.list().contains { $0.id == "task-0" })
        XCTAssertTrue(activities.list().contains { $0.id == effect.id })
        XCTAssertEqual(stopped, 0)
    }

    func testEndedHistoryMakesRoomAtTheGlobalActivityLimit() throws {
        let activities = HostActivities()
        for index in 0..<HostActivities.maximumTotal {
            let id = "task-\(index)", owner = PluginID("owner-\(index / HostActivities.maximumPerPlugin)")
            try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", id: id, stop: {})
            activities.updateTask(id, status: "Ended: completed", detail: .object(["status": .string("ended")]))
        }
        let effect = try activities.register(owner: PluginID("new-owner"), pluginName: "Coffee", kind: "keep_awake", status: "On", stop: {})
        XCTAssertEqual(activities.list().count, HostActivities.maximumTotal)
        XCTAssertFalse(activities.list().contains { $0.id == "task-0" })
        XCTAssertTrue(activities.list().contains { $0.id == effect.id })
    }

    func testClearingEndedTaskReleasesItsRetainedHistoryOnce() throws {
        let activities = HostActivities(), owner = PluginID("owner")
        var retainedHistory = true, stops = 0
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                           removesOnStop: false, onClear: { retainedHistory = false }, stop: { stops += 1 })
        XCTAssertFalse(activities.clearEndedTask(task.id))
        XCTAssertTrue(retainedHistory)
        activities.updateTask(task.id, status: "Ended: completed", detail: .object(["status": .string("ended")]))
        XCTAssertTrue(activities.clearEndedTask(task.id))
        XCTAssertFalse(retainedHistory)
        XCTAssertFalse(activities.clearEndedTask(task.id))
        XCTAssertEqual(stops, 0)
    }

    func testEvictingEndedHistoryReleasesOnlyTheOldestHistory() throws {
        let activities = HostActivities(), owner = PluginID("owner")
        var released: [String] = []
        for index in 0..<HostActivities.maximumPerPlugin {
            let id = "task-\(index)"
            try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", id: id,
                                    onClear: { released.append(id) }, stop: {})
            activities.updateTask(id, status: "Ended: completed", detail: .object(["status": .string("ended")]))
        }
        try activities.register(owner: owner, pluginName: "Coffee", kind: "keep_awake", status: "On", stop: {})
        XCTAssertEqual(released, ["task-0"])
    }

    func testOldEndedTaskRemainsUntilClearedAcrossTaskRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_old_task", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-7200).timeIntervalSinceReferenceDate
        let journal: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew",
            "input": ["tool": "homebrew", "operation": "cleanup"], "package": [:],
            "executable": "/opt/homebrew/bin/brew", "started": old, "ended": old, "detached": false,
            "stage": "finished", "log": [], "result": ["outcome": "completed"]]
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent("task.json"))
        let activities = HostActivities(retention: .never)
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        host.refresh()
        XCTAssertEqual(activities.list().first?.json.value(atPointer: "/result/outcome"), .string("completed"))
        XCTAssertTrue(activities.clearEndedTask(id))
        host.refresh()
        XCTAssertTrue(activities.list().isEmpty)
        let restoredActivities = HostActivities()
        let restored = HostReviewedToolTasks(activities: restoredActivities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        restored.refresh()
        XCTAssertTrue(restoredActivities.list().isEmpty, "Cleared Task history does not return from its journal")
    }

    func testRetentionExpiresEndedTasksByTheirEndTimeAndLeavesRunningWork() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let activities = HostActivities(now: { now }), owner = PluginID("owner")
        var clears = 0
        let ended = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", onClear: { clears += 1 }, stop: {})
        let running = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        activities.updateTask(ended.id, status: "Ended", detail: .object(["status": .string("ended")]), endedAt: now)
        now.addTimeInterval(3599)
        activities.expireEndedTasks()
        XCTAssertEqual(activities.list().count, 2)
        now.addTimeInterval(1)
        activities.expireEndedTasks()
        XCTAssertEqual(activities.list().map(\.id), [running.id])
        XCTAssertEqual(clears, 1)
    }

    func testImmediateRetentionClearsATaskWhenItEndsButLeavesRunningWork() throws {
        let immediate = try XCTUnwrap(EndedTaskRetention(rawValue: "immediately"))
        let now = Date(timeIntervalSince1970: 10_000)
        let activities = HostActivities(retention: immediate, now: { now }), owner = PluginID("owner")
        var clears = 0, stops = 0
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                           removesOnStop: false, onClear: { clears += 1 }, stop: { stops += 1 })
        activities.updateTask(task.id, status: "Running", detail: .object(["status": .string("running")]), endedAt: now)
        XCTAssertEqual(activities.list().map(\.id), [task.id])
        XCTAssertEqual(clears, 0)

        // The runner's wall clock can be ahead of the Host's clock.
        activities.updateTask(task.id, status: "Ended", detail: .object(["status": .string("ended")]),
                              endedAt: now.addingTimeInterval(60))
        XCTAssertTrue(activities.list().isEmpty)
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(stops, 0)
    }

    func testChangingToImmediateRetentionClearsOnlyEndedTasks() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let activities = HostActivities(retention: .never, now: { now }), owner = PluginID("owner")
        var clears = 0
        let ended = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                            onClear: { clears += 1 }, stop: {})
        let running = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        let effect = try activities.register(owner: owner, pluginName: "Coffee", kind: "keep_awake", status: "On", stop: {})
        activities.updateTask(ended.id, status: "Ended", detail: .object(["status": .string("ended")]),
                              endedAt: now.addingTimeInterval(60))
        activities.updateTask(running.id, status: "Running", detail: .object(["status": .string("running")]))

        activities.setEndedTaskRetention(.immediately)
        XCTAssertEqual(Set(activities.list().map(\.id)), Set([running.id, effect.id]))
        XCTAssertEqual(clears, 1)
    }

    func testNeverRetentionKeepsHistoryAndChangingRetentionClearsExpiredHistory() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let activities = HostActivities(retention: .never, now: { now })
        let task = try activities.register(owner: PluginID("owner"), pluginName: "Packages", kind: "task", status: "Running", stop: {})
        activities.updateTask(task.id, status: "Ended", detail: .object(["status": .string("ended")]), endedAt: now.addingTimeInterval(-86_400))
        activities.expireEndedTasks()
        XCTAssertEqual(activities.list().count, 1)
        activities.setEndedTaskRetention(.sevenDays)
        XCTAssertEqual(activities.list().count, 1)
        activities.setEndedTaskRetention(.oneDay)
        XCTAssertTrue(activities.list().isEmpty)
    }

    func testRecoveryExpiresOldEndedTaskAndRemovesItsJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_old_task", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-7200).timeIntervalSinceReferenceDate
        let journal: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew", "input": ["tool": "homebrew", "operation": "cleanup"], "package": [:], "executable": "/opt/homebrew/bin/brew", "started": old, "ended": old, "detached": false, "stage": "finished", "log": [], "result": ["outcome": "completed"]]
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent("task.json"))
        let activities = HostActivities()
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        host.refresh()
        XCTAssertTrue(activities.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testImmediateRetentionClearsRecoveredEndedTaskAndItsJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_recovered_task", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), ended = now.addingTimeInterval(60).timeIntervalSinceReferenceDate
        let journal: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew",
            "input": ["tool": "homebrew", "operation": "cleanup"], "package": [:],
            "executable": "/opt/homebrew/bin/brew", "started": now.timeIntervalSinceReferenceDate,
            "ended": ended, "detached": false, "stage": "finished", "log": [], "result": ["outcome": "completed"]]
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent("task.json"))
        let activities = HostActivities(retention: .immediately, now: { now })
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        host.refresh()
        XCTAssertTrue(activities.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let restoredActivities = HostActivities()
        let restored = HostReviewedToolTasks(activities: restoredActivities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        restored.refresh()
        XCTAssertTrue(restoredActivities.list().isEmpty)
    }

    func testChangingToImmediateRetentionRemovesRecoveredHistoryPermanently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = "activity_retained_task", directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date().timeIntervalSinceReferenceDate
        let journal: [String: Any] = ["id": id, "owner": "brew", "pluginName": "Homebrew",
            "input": ["tool": "homebrew", "operation": "cleanup"], "package": [:],
            "executable": "/opt/homebrew/bin/brew", "started": now, "ended": now, "detached": false,
            "stage": "finished", "log": [], "result": ["outcome": "completed"]]
        try JSONSerialization.data(withJSONObject: journal).write(to: directory.appendingPathComponent("task.json"))
        let activities = HostActivities(retention: .never)
        let host = HostReviewedToolTasks(activities: activities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        XCTAssertEqual(activities.list().map(\.id), [id])

        activities.setEndedTaskRetention(.immediately)
        host.refresh()
        XCTAssertTrue(activities.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let restoredActivities = HostActivities()
        let restored = HostReviewedToolTasks(activities: restoredActivities, journal: root, runnerURL: URL(fileURLWithPath: "/missing"), nativeInspection: nil)
        restored.refresh()
        XCTAssertTrue(restoredActivities.list().isEmpty)
    }

    func testReadOnlyInspectionHasAHostStopControlWithoutPluginVisibility() throws {
        let activities = HostActivities(), owner = PluginID("com.example.brew")
        var stopped = false
        let inspection = try activities.register(owner: owner, pluginName: "Homebrew", kind: "inspection",
            status: "Awaiting read-only receipt inspection", visibleToOwner: false, removesOnStop: false, stop: { stopped = true })
        XCTAssertTrue(activities.list(for: owner).isEmpty)
        XCTAssertEqual(activities.list().map(\.id), [inspection.id])
        XCTAssertFalse(activities.stop(inspection.id, for: owner))
        activities.updateStatus(inspection.id, status: "Stopping inspection; waiting for owned worker")
        XCTAssertEqual(activities.list().first?.status, "Stopping inspection; waiting for owned worker")
        XCTAssertTrue(activities.stop(inspection.id))
        XCTAssertTrue(stopped)
        XCTAssertEqual(activities.list().count, 1, "Stop is not proof a worker was reaped")
        activities.removeEndedTask(inspection.id)
        XCTAssertTrue(activities.list().isEmpty)
    }

    func testOnlyTheOwnerOrHostCanStopAResourceAndItIsReleasedOnce() throws {
        let activities = HostActivities()
        let owner = PluginID(rawValue: "com.example.coffee")
        let other = PluginID(rawValue: "com.example.other")
        var resourceIsHeld = true
        let activity = try activities.register(owner: owner, pluginName: "Coffee", kind: "keep_awake",
            status: "Until stopped", stop: { resourceIsHeld = false })
        XCTAssertEqual(activities.list(for: owner).map(\.id), [activity.id])
        XCTAssertEqual(activities.list(for: other), [])
        XCTAssertFalse(activities.stop(activity.id, for: other))
        XCTAssertTrue(resourceIsHeld)
        XCTAssertTrue(activities.stop(activity.id, for: owner))
        XCTAssertFalse(resourceIsHeld)
        XCTAssertFalse(activities.stop(activity.id, for: owner))
    }

    func testDurationExpiresWithoutAPluginViewOrHelperAndReleasesBothAssertions() throws {
        let recorded = RecordedKeepAwake()
        let owner = PluginID(rawValue: "com.example.coffee")
        try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: owner, pluginName: "Coffee")
        XCTAssertEqual(recorded.activities.list(for: owner).count, 1)
        XCTAssertEqual(recorded.power.held, [.idleSystem, .idleDisplay])
        recorded.advance(by: 59)
        XCTAssertEqual(recorded.power.held, [.idleSystem, .idleDisplay])
        recorded.advance(by: 1)
        XCTAssertEqual(recorded.activities.list(for: owner), [])
        XCTAssertEqual(recorded.power.held, [])
    }

    func testFailureOfEitherAssertionLeavesNoHeldResourceOrActivity() {
        for assertion in [KeepAwakeAssertion.idleSystem, .idleDisplay] {
            let recorded = RecordedKeepAwake()
            recorded.power.failing = assertion
            XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee"))
            XCTAssertEqual(recorded.power.count, 0)
            XCTAssertEqual(recorded.activities.list(), [])
        }
    }

    func testInvalidationDuringCreationCannotResurrectAnEffect() {
        let recorded = RecordedKeepAwake()
        recorded.power.whileAcquiring = { assertion in
            if assertion == .idleDisplay { recorded.effects.invalidate(PluginID("coffee")) }
        }
        XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee"))
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(recorded.activities.list(), [])
    }

    func testAppAliveBindsOneOwnersExactRunningAppAndEndsOnExitOrRelaunch() throws {
        let apps = RecordedApps(front: .textEdit)
        let recorded = RecordedKeepAwake(apps: apps)
        let owner = PluginID("coffee")
        guard case .object(let front) = apps.targets.identifyFrontmost(of: apps, for: owner),
              case .string(let target)? = front["target"] else { return XCTFail("No target") }
        XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(mode: .appAlive(target)), owner: PluginID("other"), pluginName: "Other"))
        try recorded.effects.start(KeepAwakeRequest(mode: .appAlive(target)), owner: owner, pluginName: "Coffee")
        apps.bringToFront(.safari)
        XCTAssertEqual(recorded.power.held, [.idleSystem, .idleDisplay])
        apps.relaunch(.textEdit)
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertEqual(recorded.activities.list(), [])
        XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(mode: .appAlive(target)), owner: owner, pluginName: "Coffee"))
    }

    func testOwnerInvalidationAndHostExitReleaseOnlyTheirOwnEffectsWithNoRecovery() throws {
        let recorded = RecordedKeepAwake()
        try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee")
        try recorded.effects.start(KeepAwakeRequest(mode: .duration(100)), owner: PluginID("other"), pluginName: "Other")
        recorded.effects.invalidate(PluginID("coffee"))
        XCTAssertEqual(recorded.power.count, 2)
        XCTAssertEqual(recorded.activities.list().map(\.owner), [PluginID("other")])
        recorded.effects.shutdown()
        recorded.advance(by: 100)
        XCTAssertEqual(recorded.power.count, 0)
        XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee"))
        XCTAssertEqual(RecordedKeepAwake().activities.list(), [])
    }

    func testActivityBudgetRefusesTheNinthWithoutLeakingAssertions() throws {
        let recorded = RecordedKeepAwake()
        for _ in 0..<8 { try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee") }
        XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee"))
        XCTAssertEqual(recorded.power.count, 16)
        recorded.effects.shutdown()
        XCTAssertEqual(recorded.power.count, 0)
    }

    func testAuthorityReadAfterAnOldInvocationIsDeniedBeforeAcquiringResources() {
        let recorded = RecordedKeepAwake()
        XCTAssertThrowsError(try recorded.effects.start(KeepAwakeRequest(), owner: PluginID("coffee"), pluginName: "Coffee",
            authorize: { throw PluginHostServiceError.capabilityDenied(.keepAwake) }))
        XCTAssertEqual(recorded.power.count, 0)
    }
}
