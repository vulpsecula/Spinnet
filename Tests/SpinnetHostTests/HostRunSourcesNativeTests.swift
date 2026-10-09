import AppKit
import XCTest
@testable import SpinnetHost

/// Real NSPanel visibility and workspace notifications at the native Host seam.
final class HostRunSourcesNativeTests: XCTestCase {
    private func pumpEvents() {
        let deadline = Date().addingTimeInterval(0.2)
        while let event = NSApplication.shared.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
            if Date() >= deadline { break }
        }
    }


    func testRealWorkspaceNotificationsReachPanelVisibilityObserverAndCloseStopsIt() throws {
        _ = NSApplication.shared
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Source observer probe"))
        let window = PluginViewPanelWindow(model: try XCTUnwrap(harness.windows.model(for: harness.pluginID)))
        var calls: [Bool] = []
        window.onSourceVisibility = { calls.append($0) }
        window.show(near: NSPoint(x: 450, y: 500))
        defer { window.close() }
        calls.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(calls, [false], "The actual screen-sleep observer immediately hides sources")
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(calls, [false, false, false], "Screen wake cannot override the inactive session")
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(calls.count, 4)
        window.close()
        XCTAssertEqual(calls.last, false)
    }

    func testPanelVisibilityFollowsOcclusionDisplayAndActiveSessionThenCloses() throws {
        _ = NSApplication.shared
        let oldPolicy = NSApplication.shared.activationPolicy()
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        defer { _ = NSApplication.shared.setActivationPolicy(oldPolicy) }
        NSApplication.shared.finishLaunching()
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Source visibility probe"))
        let window = PluginViewPanelWindow(model: try XCTUnwrap(harness.windows.model(for: harness.pluginID)))
        var changes: [Bool] = []
        window.onSourceVisibility = { changes.append($0) }
        window.show(near: NSPoint(x: 450, y: 500))
        defer { window.close() }
        pumpEvents()
        guard window.sourceIsVisible else {
            throw XCTSkip("WindowServer reports this ordered-in test panel occluded; native visible-desktop verification is required")
        }
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(window.sourceIsVisible)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(window.sourceIsVisible)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertFalse(window.sourceIsVisible)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertTrue(window.sourceIsVisible)
        let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Source visibility probe" })
        panel.orderOut(nil)
        pumpEvents()
        XCTAssertFalse(window.sourceIsVisible)
        window.show(near: NSPoint(x: 450, y: 500))
        pumpEvents()
        XCTAssertTrue(window.sourceIsVisible)
        window.close()
        XCTAssertEqual(changes.last, false)
    }
}
