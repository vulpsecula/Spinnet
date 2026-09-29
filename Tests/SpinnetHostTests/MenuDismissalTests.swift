import AppKit
import XCTest
@testable import SpinnetHost

/// A press on the Menu that lands on no Menu Item closes it. Ordered out while
/// it handles that press, the panel stays on screen as far as the window
/// server is concerned, with no monitors left to close it, so a closed Menu
/// is also made invisible and click-through until it opens again.
final class MenuDismissalTests: XCTestCase {
    func testAPressInTheCenterLeavesNothingToSeeOrClickUntilTheMenuOpensAgain() throws {
        _ = NSApplication.shared
        let menu = MenuPresentationController(items: [.empty, .empty, .empty])
        defer { menu.dismiss() }
        let screen = try XCTUnwrap(NSScreen.main)
        let point = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        menu.open(at: point)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.level == .popUpMenu && $0.isVisible })

        try press(at: NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2), in: panel)

        XCTAssertFalse(menu.isOpen)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0, "nothing is left to see")
        XCTAssertTrue(panel.ignoresMouseEvents, "nothing is left to click")

        menu.open(at: point)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    /// Delivers the press the way the running App does, through its event
    /// queue, so the Menu's event monitors see it.
    private func press(at point: NSPoint, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.postEvent(event, atStart: false)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              let next = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
            if next.type == .leftMouseDown { break }
        }
    }
}
