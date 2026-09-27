import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The Host's window for a Plugin View: near the pointer, on screen, taking
/// keyboard focus without activating Spinnet, and readable by VoiceOver.
final class PluginViewPanelTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 440, height: 300)

    func testAViewIsCentredUnderThePointer() {
        let topLeft = PluginViewPanelWindow.topLeft(for: size, near: NSPoint(x: 700, y: 600), within: screen)
        XCTAssertEqual(topLeft.x + size.width / 2, 700)
        XCTAssertEqual(topLeft.y, 600 - PluginViewPanelWindow.pointerGap)
    }

    func testAViewStaysOnScreen() {
        let margin = PluginViewPanelWindow.screenMargin
        let left = PluginViewPanelWindow.topLeft(for: size, near: NSPoint(x: 5, y: 600), within: screen)
        XCTAssertEqual(left.x, margin)
        let right = PluginViewPanelWindow.topLeft(for: size, near: NSPoint(x: 1435, y: 600), within: screen)
        XCTAssertEqual(right.x + size.width, screen.maxX - margin)
        let bottom = PluginViewPanelWindow.topLeft(for: size, near: NSPoint(x: 700, y: 40), within: screen)
        XCTAssertEqual(bottom.y - size.height, margin, "A pointer near the bottom lifts the view onto the screen")
        let belowMenuBar = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let top = PluginViewPanelWindow.topLeft(for: size, near: NSPoint(x: 700, y: 898), within: belowMenuBar)
        XCTAssertEqual(top.y, belowMenuBar.maxY - margin)
    }

    /// The panel is key without activating Spinnet, so the App the user was
    /// in stays in front.
    func testThePanelTakesKeyboardFocusWithoutBringingSpinnetForward() throws {
        _ = NSApplication.shared
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Panel"))
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        let window = PluginViewPanelWindow(model: model)
        defer { window.close() }

        window.show(near: NSPoint(x: 400, y: 500))

        let snapshot = window.presentationSnapshot
        XCTAssertTrue(snapshot.isVisible)
        XCTAssertTrue(snapshot.isNonActivating)
        XCTAssertFalse(snapshot.becomesKeyOnlyIfNeeded)
        XCTAssertEqual(snapshot.frame.maxY, 500 - PluginViewPanelWindow.pointerGap, accuracy: 1)
    }
}
