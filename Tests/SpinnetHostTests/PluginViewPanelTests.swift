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

    // MARK: - Pin and resizing (#73)

    private func shownPanel(fields: Int = 1, near pointer: NSPoint = NSPoint(x: 400, y: 600),
                            restoring pinned: PluginPanelGeometry? = nil,
                            screens: [PluginPanelScreen]? = nil,
                            resizing: PluginPageResizing? = PluginPageResizing()) throws -> (PluginViewHarness, PluginViewPanelWindow) {
        _ = NSApplication.shared
        let harness = try PluginViewHarness()
        try harness.present(Self.form(fields: fields))
        let window = PluginViewPanelWindow(model: try XCTUnwrap(harness.windows.model(for: harness.pluginID)))
        if let screens { window.screens = { screens } }
        // The panel is resizable as a page declares it (#80); the Level 1
        // form here stands in for any content.
        window.resizing = resizing
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.show(near: pointer, restoring: pinned)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (harness, window)
    }

    private static func form(fields: Int) -> JSONValue {
        PluginViewHarness.form(title: "Panel", fields: (0..<fields).map {
            .object(["key": .string("f\($0)"), "kind": .string("text"), "title": .string("Field \($0)")])
        })
    }

    /// Pin floats the panel and nothing else: whether the user may resize
    /// it is the page's declaration (#80, ADR 0016 amended), pinned or not.
    /// Either way it takes the keyboard without becoming main or activating
    /// Spinnet, and AppKit never restores it at launch.
    func testPinFloatsThePanelAndTheDeclarationLetsTheUserResizeIt() throws {
        let (_, window) = try shownPanel(resizing: nil)
        defer { window.close() }
        var panel = window.panelSnapshot
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isFloating)
        XCTAssertFalse(panel.isResizable)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isRestorable)
        XCTAssertTrue(window.presentationSnapshot.isNonActivating)
        XCTAssertFalse(window.presentationSnapshot.becomesKeyOnlyIfNeeded)

        window.floats = true
        panel = window.panelSnapshot
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isFloating)
        XCTAssertFalse(panel.isResizable, "Pinning a page that does not declare resizing does not make it resizable")

        window.floats = false
        window.resizing = PluginPageResizing(minimumWidth: 500, minimumHeight: 200)
        panel = window.panelSnapshot
        XCTAssertEqual(panel.level, .normal)
        XCTAssertTrue(panel.isResizable, "A declaring page is resizable unpinned")
        XCTAssertEqual(panel.minimumSize, NSSize(width: 500, height: 200))
        XCTAssertTrue(window.presentationSnapshot.isNonActivating, "Resizable does not make it activating")

        let chosen = NSRect(x: 100, y: 100, width: 640, height: 420)
        window.simulateUserResize(to: chosen)
        window.floats = true
        window.floats = false
        XCTAssertEqual(window.presentationSnapshot.frame, chosen, "Pinning and unpinning leave the size alone")
        window.simulateUserResize(to: NSRect(x: 100, y: 100, width: 300, height: 100))
        XCTAssertEqual(window.presentationSnapshot.frame.size, NSSize(width: 500, height: 200),
                       "The declared minimum holds")
    }

    /// A page that stops declaring resizing returns to the Host's default
    /// layout: not resizable, following its content again.
    func testAPageThatStopsDeclaringResizingReturnsToItsContentsSize() throws {
        let (_, window) = try shownPanel()
        defer { window.close() }
        let followed = window.presentationSnapshot.frame
        window.simulateUserResize(to: NSRect(x: 120, y: 80, width: 700, height: 500))
        XCTAssertTrue(window.panelSnapshot.fills)
        var reported: [PluginPanelGeometry] = []
        window.onGeometryChange = { reported.append($0) }

        window.resizing = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertFalse(window.panelSnapshot.isResizable)
        XCTAssertFalse(window.panelSnapshot.fills)
        XCTAssertEqual(window.presentationSnapshot.frame.size.width, followed.width, accuracy: 1)
        XCTAssertEqual(window.presentationSnapshot.frame.size.height, followed.height, accuracy: 1)
        XCTAssertEqual(window.presentationSnapshot.frame.maxY, 580, accuracy: 1, "It keeps its top")
        XCTAssertEqual(reported.last?.isUserSized, false)
    }

    /// A remembered user size is restored only for a page that declares
    /// resizing; any other opens at its content's size where the pinned
    /// panel last was.
    func testAPinnedSizeIsRestoredOnlyForAResizablePage() throws {
        let main = try XCTUnwrap(NSScreen.screens.first)
        let screen = PluginPanelScreen(frame: main.frame, visible: main.visibleFrame)
        let pinned = PluginPanelGeometry(frame: NSRect(x: screen.visible.minX + 200, y: screen.visible.minY + 100,
                                                       width: 620, height: 400), isUserSized: true)
        let (_, window) = try shownPanel(restoring: pinned, screens: [screen], resizing: nil)
        defer { window.close() }
        let frame = window.presentationSnapshot.frame
        XCTAssertEqual(frame.width, PluginViewPanelWindow.width, accuracy: 1)
        XCTAssertNotEqual(frame.height, pinned.frame.height)
        XCTAssertEqual(frame.maxY, pinned.frame.maxY, accuracy: 1)
        XCTAssertFalse(window.panelSnapshot.fills)
        XCTAssertFalse(window.geometry.isUserSized)
    }

    /// Before the user resizes, the panel grows with its content from the
    /// same top; afterwards content updates leave the user's frame alone and
    /// the content fills it.
    func testContentUpdatesDoNotOverwriteTheUsersSize() throws {
        let (harness, window) = try shownPanel()
        defer { window.close() }
        let top = window.presentationSnapshot.frame.maxY
        let small = window.presentationSnapshot.frame.height
        try harness.present(Self.form(fields: 4))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(window.presentationSnapshot.frame.height, small, "Followed content grows the panel")
        XCTAssertEqual(window.presentationSnapshot.frame.maxY, top, accuracy: 1)
        XCTAssertFalse(window.panelSnapshot.fills)

        var reported: [PluginPanelGeometry] = []
        window.onGeometryChange = { reported.append($0) }
        let chosen = NSRect(x: 120, y: 80, width: 700, height: 300)
        window.simulateUserResize(to: chosen)
        XCTAssertEqual(reported.last, PluginPanelGeometry(frame: chosen, isUserSized: true))
        XCTAssertTrue(window.panelSnapshot.fills)

        try harness.present(Self.form(fields: 8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try harness.present(Self.form(fields: 1))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(window.presentationSnapshot.frame, chosen)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.width, chosen.width, accuracy: 1, "The content fills the user's width")
    }

    /// Remembered pinned geometry comes back where it was, or inside the
    /// visible screen when the screen it was on is gone or smaller.
    func testRestoredGeometryIsKeptInsideTheVisibleScreen() throws {
        // The display it was on is gone; the main display remains. (AppKit
        // itself keeps an ordered-front window on a real display, so the
        // remaining screen is the real main one.)
        let main = try XCTUnwrap(NSScreen.screens.first)
        let screen = PluginPanelScreen(frame: main.frame, visible: main.visibleFrame)
        let inside = PluginPanelGeometry(frame: NSRect(x: screen.visible.minX + 200, y: screen.visible.minY + 100,
                                                       width: 520, height: 400), isUserSized: true)
        let (_, kept) = try shownPanel(restoring: inside, screens: [screen])
        let frame = kept.presentationSnapshot.frame
        XCTAssertEqual(frame.size, inside.frame.size)
        XCTAssertEqual(frame.maxY, inside.frame.maxY, accuracy: 1)
        // Ordering the panel front, AppKit's own `constrainFrameRect` may
        // nudge it sideways (34 pt observed on macOS 27 at x 200); the panel
        // then remembers where AppKit put it.
        XCTAssertEqual(frame.minX, inside.frame.minX, accuracy: 40)
        XCTAssertEqual(kept.geometry.frame, frame)
        XCTAssertTrue(kept.panelSnapshot.fills)
        kept.close()

        let gone = PluginPanelGeometry(frame: NSRect(x: screen.frame.maxX + 3000, y: 100, width: 520, height: 400),
                                       isUserSized: true)
        let (_, moved) = try shownPanel(restoring: gone, screens: [screen])
        defer { moved.close() }
        XCTAssertTrue(screen.visible.contains(moved.presentationSnapshot.frame), "\(moved.presentationSnapshot.frame)")
        XCTAssertEqual(moved.presentationSnapshot.frame.size, gone.frame.size)
    }

    func testAScreenChangeKeepsAnOpenPanelOnScreenAndIsRemembered() throws {
        let main = try XCTUnwrap(NSScreen.screens.first)
        let wide = PluginPanelScreen(frame: main.frame, visible: main.visibleFrame)
        let (_, window) = try shownPanel(screens: [wide])
        defer { window.close() }
        let origin = wide.visible.origin
        window.simulateUserResize(to: NSRect(x: origin.x + 600, y: origin.y + 300, width: 560, height: 400))
        var reported: [PluginPanelGeometry] = []
        window.onGeometryChange = { reported.append($0) }

        // The display becomes smaller (as with a resolution change).
        let narrowed = NSRect(origin: origin, size: NSSize(width: 900, height: 580))
        let narrow = PluginPanelScreen(frame: narrowed, visible: narrowed)
        window.screens = { [narrow] }
        window.simulateScreenChange()

        XCTAssertTrue(narrow.visible.contains(window.presentationSnapshot.frame), "\(window.presentationSnapshot.frame)")
        XCTAssertEqual(reported.last?.frame, window.presentationSnapshot.frame)
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

/// A Host Confirmation shown from an unpinned view takes the keyboard
/// without closing the view: the view's own operation is waiting on it.
/// When the confirmation goes, the view has the keyboard again.
final class HostConfirmationFocusTests: XCTestCase {
    func testAConfirmationDoesNotCloseAnUnpinnedViewAndHandsTheKeyboardBack() throws {
        _ = NSApplication.shared
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Panel"))
        let window = PluginViewPanelWindow(model: try XCTUnwrap(harness.windows.model(for: harness.pluginID)))
        defer { window.close() }
        var resigned = 0
        window.onResignKey = { resigned += 1 }
        window.show(near: NSPoint(x: 400, y: 600))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(window.presentationSnapshot.isKey)

        let confirmations = HostConfirmationPanel()
        let action = try harness.action()
        let dismiss = confirmations.confirm(HostConfirmation(title: "Force Quit TextEdit?", message: "m",
                                                             confirmTitle: "Force Quit", isDestructive: true),
                                            for: action) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(window.presentationSnapshot.isKey, "The confirmation has the keyboard")
        XCTAssertEqual(resigned, 0, "The view is not closed for it")

        dismiss()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(window.presentationSnapshot.isKey, "The view has the keyboard again")
        XCTAssertEqual(resigned, 0)
    }
}
