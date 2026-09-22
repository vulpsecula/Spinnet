import AppKit
import XCTest
@testable import SpinnetHost

final class MenuPresentationSpaceTests: XCTestCase {
    func testRuntimeMenuShowsOnlyOnTheActiveDesktop() throws {
        let menu = MenuPresentationController(items: [.empty, .empty, .empty])
        defer { menu.dismiss() }

        menu.open(at: try centreOfMainScreen())

        let panel = try XCTUnwrap(openMenuPanel())
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testSwitchingDesktopDismissesTheOpenMenu() throws {
        let menu = MenuPresentationController(items: [.empty, .empty, .empty])
        var dismissals = 0
        menu.onDismiss = { dismissals += 1 }
        menu.open(at: try centreOfMainScreen())

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared
        )

        XCTAssertFalse(menu.isOpen)
        XCTAssertEqual(dismissals, 1)
        XCTAssertNil(openMenuPanel())
    }

    private func centreOfMainScreen() throws -> CGPoint {
        let frame = try XCTUnwrap(NSScreen.main).visibleFrame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func openMenuPanel() -> NSWindow? {
        NSApp.windows.first { $0.level == .popUpMenu && $0.isVisible }
    }
}
