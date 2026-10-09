import AppKit
import SpinnetCore
import SpinnetPluginTestKit
import XCTest
@testable import SpinnetHost

final class HostActivityPresentationTests: XCTestCase {
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
        XCTAssertEqual(model.rows.first?.status, "59 seconds remaining")
        model.stop(foreign.id)
        XCTAssertEqual(recorded.activities.list(for: other).count, 1)
        model.setVisible(false)
        XCTAssertEqual(cancellations, 1)
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(model.rows.first?.status, "59 seconds remaining")
        model.setVisible(true)
        XCTAssertEqual(model.rows.first?.status, "58 seconds remaining")
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
        let row = try XCTUnwrap(menu.items.first { $0.title == "60 seconds remaining" })
        let stop = try XCTUnwrap(menu.items.first { $0.action != nil && $0.title.hasPrefix("Stop ") })
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(row.title, "59 seconds remaining")
        XCTAssertTrue(menu.items.contains { $0 === stop }, "Tick keeps the native Stop item identity")
        controller.menuDidClose(menu)
        XCTAssertEqual(cancellations, 1)
        recorded.advance(by: 1); tick?()
        XCTAssertEqual(row.title, "59 seconds remaining")
    }

    func testActualPanelWorkspaceVisibilityPausesNativeActivityUpdatesAndCloseLeavesEffectHeld() throws {
        _ = NSApplication.shared
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
        if panel.sourceIsVisible {
            XCTAssertEqual(model.activityList.rows.first?.status, "59 seconds remaining")
        }
        panel.close()
        XCTAssertEqual(recorded.power.count, 2, "Closing the actual panel does not stop its Effect")
    }
}
