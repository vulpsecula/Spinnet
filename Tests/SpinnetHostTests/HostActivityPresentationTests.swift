import AppKit
import SpinnetCore
import SpinnetPluginTestKit
import XCTest
@testable import SpinnetHost

final class HostActivityPresentationTests: XCTestCase {
    func testVisibleRowsRefreshWithTheActualRunLoopTimerAndPauseWhenHidden() throws {
        let recorded = RecordedKeepAwake()
        let owner = PluginID("clock")
        try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: owner, pluginName: "Clock")
        let model = HostActivityListModel(activities: recorded.activities, owner: owner)
        model.setAvailable(true)
        model.setVisible(true)
        recorded.advance(by: 1)
        let visibleTick = expectation(description: "Actual run-loop timer refreshes the visible control")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { visibleTick.fulfill() }
        wait(for: [visibleTick], timeout: 2)
        XCTAssertEqual(model.rows.first?.status, "59s remaining")
        model.setVisible(false)
        recorded.advance(by: 1)
        let hiddenTick = expectation(description: "A hidden control stays unchanged across a timer interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { hiddenTick.fulfill() }
        wait(for: [hiddenTick], timeout: 2)
        XCTAssertEqual(model.rows.first?.status, "59s remaining")
    }

    func testVisibleOwnControlCountsSecondsAndStopsWithoutCallingPlugin() throws {
        let recorded = RecordedKeepAwake()
        let owner = PluginID("own"), other = PluginID("other")
        let own = try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: owner, pluginName: "Own")
        let foreign = try recorded.effects.start(KeepAwakeRequest(), owner: other, pluginName: "Other")
        var tick: (() -> Void)?, schedules = 0, cancellations = 0
        let model = HostActivityListModel(activities: recorded.activities, owner: owner, scheduleTick: {
            tick = $0; schedules += 1; return { cancellations += 1 }
        })
        model.setAvailable(true)
        XCTAssertEqual(schedules, 0)
        model.setVisible(true)
        XCTAssertEqual(model.rows.map(\.id), [own.id])
        XCTAssertEqual(schedules, 1)
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(model.rows.first?.status, "59s remaining")
        model.stop(foreign.id)
        XCTAssertEqual(recorded.activities.list(for: other).count, 1)
        model.setVisible(false)
        XCTAssertEqual(cancellations, 1)
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(model.rows.first?.status, "59s remaining")
        model.setVisible(true)
        XCTAssertEqual(model.rows.first?.status, "58s remaining")
        model.stop(own.id)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(cancellations, 2)
        XCTAssertEqual(recorded.power.count, 2, "The other Plugin's effect remains")
        recorded.effects.shutdown()
    }

    func testOpenStatusItemRefreshesSecondsInPlaceAndStopsItsTimerWhenClosed() throws {
        _ = NSApplication.shared
        let recorded = RecordedKeepAwake()
        try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: PluginID("clock"), pluginName: "Clock")
        var tick: (() -> Void)?, cancellations = 0
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: recorded.activities, scheduleTick: {
            tick = $0; return { cancellations += 1 }
        })
        let menu = controller.makeMenu()
        XCTAssertNil(tick, "A closed menu has no timer")
        controller.menuWillOpen(menu)
        let row = try XCTUnwrap(menu.items.first { $0.title == "1m 00s remaining" })
        let stop = try XCTUnwrap(menu.items.first { $0.action != nil && $0.title.hasPrefix("Stop ") })
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(row.title, "59s remaining")
        XCTAssertTrue(menu.items.contains { $0 === stop }, "Tick keeps the native Stop item identity")
        controller.menuDidClose(menu)
        XCTAssertEqual(cancellations, 1)
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(row.title, "59s remaining")
    }

    func testActualPanelWorkspaceVisibilityPausesNativeActivityUpdatesAndCloseLeavesEffectHeld() throws {
        _ = NSApplication.shared
        let oldPolicy = NSApplication.shared.activationPolicy()
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        defer { _ = NSApplication.shared.setActivationPolicy(oldPolicy) }
        NSApplication.shared.finishLaunching()
        let recorded = RecordedKeepAwake()
        try recorded.effects.start(KeepAwakeRequest(mode: .duration(60)), owner: PageHarness.pluginID, pluginName: "Clock")
        var window: PluginViewPanelWindow?
        let harness = try PageHarness(activities: recorded.activities, makePageWindow: { model in
            let native = PluginViewPanelWindow(pageModel: model); window = native; return native
        })
        try harness.open(.object(["id": .string("activities"), "title": .string("Activity visibility probe"), "content": .array([
            .object(["kind": .string("activity_list"), "id": .string("held")])])]))
        let panel = try XCTUnwrap(window)
        defer { panel.close(); recorded.effects.shutdown() }
        let model = try XCTUnwrap(harness.windows.pageModel(for: PageHarness.pluginID))
        // Let WindowServer deliver ordering and occlusion notifications
        // before deciding whether a visible-desktop check is available.
        let deadline = Date().addingTimeInterval(0.2)
        while let event = NSApplication.shared.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
            if Date() >= deadline { break }
        }
        guard panel.sourceIsVisible else {
            throw XCTSkip("WindowServer did not report the test panel visible; live desktop acceptance remains required")
        }
        XCTAssertEqual(model.activityList.rows.first?.status, "1m 00s remaining")
        recorded.advance(by: 1)
        let visibleTick = expectation(description: "The visible panel updates using its actual one-second timer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { visibleTick.fulfill() }
        wait(for: [visibleTick], timeout: 2)
        XCTAssertEqual(model.activityList.rows.first?.status, "59s remaining")
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        // While hidden there is neither countdown nor registry delivery.
        let hiddenRows = model.activityList.rows
        recorded.advance(by: 1)
        let waited = expectation(description: "Allow an actual one-second timer opportunity")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(model.activityList.rows, hiddenRows)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(panel.sourceIsVisible)
        XCTAssertEqual(model.activityList.rows.first?.status, "58s remaining")
        panel.close()
        XCTAssertEqual(recorded.power.count, 2, "Closing the actual panel does not stop its Effect")
    }
}
