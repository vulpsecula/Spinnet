import AppKit
import IOKit.pwr_mgt
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The actual OS assertions and native Status Item menu boundary. Run these
/// in the serialized native acceptance session; no sleeping/locking occurs.
final class KeepAwakeHostTests: XCTestCase {
    func testActualOSOwnsBothAssertionsAndReleasesThemOnStop() throws {
        let activities = HostActivities()
        let effect = HostKeepAwake(activities: activities, power: DesktopPowerAssertions(), schedule: { _, _ in {} })
        defer { effect.shutdown() }
        let before = try ownKeepAwakeAssertions()
        let activity = try effect.start(KeepAwakeRequest(), owner: PluginID("com.example.native-test"), pluginName: "Native Test")
        let running = try ownKeepAwakeAssertions()
        XCTAssertEqual(running.count, before.count + 2)
        XCTAssertTrue(running.contains(kIOPMAssertionTypePreventUserIdleSystemSleep))
        XCTAssertTrue(running.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep))
        activities.stop(activity.id)
        XCTAssertEqual(try ownKeepAwakeAssertions().count, before.count)
    }

    func testStatusItemNamesAndStopsEveryOwnerWithScopeDisclosure() throws {
        _ = NSApplication.shared
        let activities = HostActivities()
        var coffeeHeld = true, otherHeld = true
        let first = try activities.register(owner: PluginID("coffee"), pluginName: "Coffee", kind: "keep_awake",
            status: "Until stopped", stop: { coffeeHeld = false })
        try activities.register(owner: PluginID("other"), pluginName: "Other", kind: "keep_awake",
            status: "For 60 seconds", stop: { otherHeld = false })
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        let menu = controller.makeMenu()
        XCTAssertTrue(menu.items.contains { $0.title == "Coffee — Keep Awake" })
        XCTAssertTrue(menu.items.contains { $0.title == "Other — Keep Awake" })
        XCTAssertTrue(menu.items.contains { $0.title.contains("Mac and display") })
        XCTAssertTrue(menu.items.contains { $0.title.contains("lid closure") })
        let stop = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == first.id })
        XCTAssertTrue(stop.isEnabled)
        menu.performActionForItem(at: menu.index(of: stop))
        XCTAssertFalse(coffeeHeld)
        XCTAssertTrue(otherHeld)
        XCTAssertFalse(controller.makeMenu().items.contains { $0.title == "Coffee — Keep Awake" })
        activities.shutdown()
        XCTAssertFalse(otherHeld)
    }

    private func ownKeepAwakeAssertions() throws -> [String] {
        var assertions: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&assertions)
        XCTAssertEqual(result, kIOReturnSuccess)
        let all = try XCTUnwrap(assertions).takeRetainedValue() as NSDictionary
        let own = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
        return own.filter { ($0[kIOPMAssertionNameKey] as? String) == "Spinnet Keep Awake" }
            .compactMap { $0[kIOPMAssertionTypeKey] as? String }
    }
}
