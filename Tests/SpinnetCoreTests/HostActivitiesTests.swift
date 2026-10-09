import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Tests the approved resource/OS boundary: callers observe Host activities
/// and the resource they own, without reaching into registry storage.
final class HostActivitiesTests: XCTestCase {
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
