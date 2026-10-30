import AppKit
import SpinnetCore
import SpinnetPluginTestKit
import XCTest
@testable import SpinnetHost

final class HostActivityPresentationTests: XCTestCase {
    func testStatusMenuKeepsEndedTasksOpenableAndLetsTheUserClearThem() throws {
        _ = NSApplication.shared
        let activities = HostActivities(), owner = PluginID("task-owner")
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        activities.updateTask(task.id, status: "Running", detail: .object([
            "id": .string(task.id), "name": .string("Upgrade"), "status": .string("running")]))
        let running = controller.makeMenu()
        XCTAssertNotNil(running.items.first { $0.title == "Packages — Upgrade" }?.action)
        XCTAssertTrue(running.items.contains { $0.title == "Stop Packages — Upgrade" && $0.isEnabled })
        activities.updateTask(task.id, status: "Completed", detail: .object([
            "id": .string(task.id), "name": .string("Upgrade"), "status": .string("ended"),
            "result": .object(["outcome": .string("completed")])]))
        XCTAssertEqual(activities.list(for: owner).count, 1, "Keep task history available to the Plugin")
        let menu = controller.makeMenu()
        XCTAssertNotNil(menu.items.first { $0.title == "Packages — Upgrade" }?.action)
        XCTAssertTrue(menu.items.contains { $0.title == "Ended: completed" })
        let clear = try XCTUnwrap(menu.items.first { $0.title == "Clear Packages — Upgrade" })
        XCTAssertNotNil(clear.action)
        XCTAssertTrue(menu.items.contains { $0.title == "Clear Ended Tasks" })
        NSApp.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear)
        XCTAssertTrue(activities.list().isEmpty)
        let recovery = try activities.register(owner: owner, pluginName: "Packages", kind: "native_lane", status: "Awaiting reap proof", stop: {})
        XCTAssertTrue(controller.makeMenu().items.contains { $0.representedObject as? String == recovery.id }, "Keep unresolved resource supervision visible")
    }

    func testOpeningATaskFromTheStatusMenuReusesItsWindowWithoutStoppingIt() throws {
        _ = NSApplication.shared
        let activities = HostActivities(), owner = PluginID("task-owner")
        var stops = 0
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                           removesOnStop: false, stop: { stops += 1 })
        activities.updateTask(task.id, status: "Running", detail: .object([
            "name": .string("Upgrade"), "status": .string("running"), "stage": .string("fetching")]))
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        let item = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Packages — Upgrade" })
        let action = try XCTUnwrap(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Packages — Upgrade" && $0.isVisible })
        defer { window.close() }
        NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "Packages — Upgrade" && $0.isVisible }.count, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(stops, 0)
    }

    func testTaskWindowShowsSelectableOutputAndUpdatesWhileRunning() throws {
        _ = NSApplication.shared
        let activities = HostActivities(), owner = PluginID("task-owner")
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        func detail(_ stage: String, _ output: String) -> JSONValue {
            .object(["name": .string("Upgrade"), "status": .string("running"), "stage": .string(stage),
                     "log": .array([.string("latest log")]), "output": .string(output)])
        }
        activities.updateTask(task.id, status: "Running", detail: detail("fetching", "first output"))
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        let item = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Packages — Upgrade" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Packages — Upgrade" && $0.isVisible })
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let output = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(output.isSelectable)
        XCTAssertFalse(output.isEditable)
        XCTAssertEqual(output.string, "first output")
        XCTAssertEqual(window.accessibilityLabel(), "Task details for Packages — Upgrade")
        XCTAssertEqual(output.accessibilityLabel(), "Command output")
        activities.updateTask(task.id, status: "Running", detail: detail("installing", "new output"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(output.string, "new output")
    }

    func testTaskWindowStopUsesTheHostActivityStopControl() throws {
        _ = NSApplication.shared
        let activities = HostActivities(), owner = PluginID("task-owner")
        var stops = 0
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running",
                                           removesOnStop: false, stop: { stops += 1 })
        activities.updateTask(task.id, status: "Running", detail: .object(["name": .string("Upgrade"), "status": .string("running")]))
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        let item = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Packages — Upgrade" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Packages — Upgrade" && $0.isVisible })
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func children(_ object: NSObject) -> [NSObject] {
            let selector = NSSelectorFromString("accessibilityChildren")
            let accessible = object.responds(to: selector)
                ? object.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
            return accessible + ((object as? NSView)?.subviews ?? [])
        }
        func stopButton(_ object: NSObject, visited: inout Set<ObjectIdentifier>) -> (any NSAccessibilityButton)? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let label = NSSelectorFromString("accessibilityLabel")
            if object.responds(to: label), object.perform(label)?.takeUnretainedValue() as? String == "Stop Packages — Upgrade",
               let button = object as? any NSAccessibilityButton { return button }
            for child in children(object) { if let button = stopButton(child, visited: &visited) { return button } }
            return nil
        }
        var visited = Set<ObjectIdentifier>()
        let button = try XCTUnwrap(stopButton(try XCTUnwrap(window.contentView), visited: &visited))
        _ = button.accessibilityPerformPress()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(activities.list().map(\.id), [task.id], "Stopping a Task waits for its actual completion")
    }

    func testTaskWindowRemainsOpenAfterEndingAndClosesWhenCleared() throws {
        _ = NSApplication.shared
        let activities = HostActivities(), owner = PluginID("task-owner")
        let task = try activities.register(owner: owner, pluginName: "Packages", kind: "task", status: "Running", stop: {})
        activities.updateTask(task.id, status: "Running", detail: .object(["name": .string("Upgrade"), "status": .string("running")]))
        let controller = StatusItemController(openSettings: {}, quit: {}, activities: activities)
        let item = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Packages — Upgrade" })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Packages — Upgrade" && $0.isVisible })
        defer { window.close() }
        activities.updateTask(task.id, status: "Ended: completed", detail: .object([
            "name": .string("Upgrade"), "status": .string("ended"), "result": .object(["outcome": .string("completed")])]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(window.isVisible)
        let menu = controller.makeMenu()
        let ended = try XCTUnwrap(menu.items.first { $0.title == "Packages — Upgrade" })
        NSApp.sendAction(try XCTUnwrap(ended.action), to: ended.target, from: ended)
        XCTAssertTrue(window.isVisible)
        let clear = try XCTUnwrap(menu.items.first { $0.title == "Clear Packages — Upgrade" })
        NSApp.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(window.isVisible)
    }

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
