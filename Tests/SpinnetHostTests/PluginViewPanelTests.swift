import AppKit
import SpinnetCore
import SwiftUI
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

    /// The view draws its own header, so the transparent title bar adds no
    /// empty band above it: the panel is as tall as its content.
    func testThePanelIsAsTallAsItsContent() throws {
        _ = NSApplication.shared
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Panel"))
        let model = try XCTUnwrap(harness.windows.model(for: harness.pluginID))
        let window = PluginViewPanelWindow(model: model)
        defer { window.close() }
        window.show(near: NSPoint(x: 400, y: 500))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let alone = NSHostingView(rootView: PluginViewContent(model: model))
        XCTAssertEqual(window.presentationSnapshot.frame.height, alone.fittingSize.height, accuracy: 1)

        // The header's pin and close buttons sit where the title bar is, and
        // a click there still reaches them rather than the title bar.
        let content = try XCTUnwrap(window.contentView)
        let frame = try XCTUnwrap(content.superview)
        let corner = NSPoint(x: frame.bounds.maxX - 24, y: frame.isFlipped ? 20 : frame.bounds.maxY - 20)
        let hit = try XCTUnwrap(frame.hitTest(corner))
        XCTAssertTrue(hit.isDescendant(of: content), "\(hit) took the click")
    }
}
