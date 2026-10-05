import AppKit
@testable import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Every Host window belongs to the Desktop it was shown on. None joins all
/// Spaces, so none is drawn on, or reachable from, another Desktop.
final class HostWindowSpaceTests: XCTestCase {
    func testRuntimeMenuShowsOnlyOnTheActiveDesktop() throws {
        let menu = MenuPresentationController(items: [.empty, .empty, .empty])
        defer { menu.dismiss() }

        menu.open(at: try centreOfMainScreen())

        let panel = try XCTUnwrap(NSApp.windows.first { $0.level == .popUpMenu && $0.isVisible })
        assertStaysOnOneDesktop(panel)
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
        XCTAssertNil(NSApp.windows.first { $0.level == .popUpMenu && $0.isVisible })
    }

    func testFeedbackShowsOnlyOnTheActiveDesktop() throws {
        let presenter = HostFeedbackPresenter()
        defer { presenter.dismiss() }

        presenter.showMessage("Hello")

        assertStaysOnOneDesktop(try visibleWindow(labelled: "Spinnet feedback"))
    }

    func testAPluginViewShowsOnlyOnTheActiveDesktop() throws {
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Space Check"))
        let window = PluginViewPanelWindow(model: try XCTUnwrap(harness.windows.model(for: harness.pluginID)))
        defer { window.close() }

        window.show(near: try centreOfMainScreen())

        assertStaysOnOneDesktop(try visibleWindow(labelled: "Space Check"))
    }

    /// An unpinned view sits at the normal window level, where ordering a
    /// window of an App that is not active puts it behind the active App's
    /// windows; it must still appear in front of the App the user works in.
    func testAPluginViewAppearsInFrontOfTheActiveApp() throws {
        let front = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw XCTSkip("The tests are the active App, so there is no other App to be in front of")
        }
        let harness = try PluginViewHarness()
        try harness.present(PluginViewHarness.form(title: "Order Check"))
        let window = PluginViewPanelWindow(model: try XCTUnwrap(harness.windows.model(for: harness.pluginID)))
        defer { window.close() }

        window.show(near: try centreOfMainScreen())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let number = try XCTUnwrap(window.contentView?.window?.windowNumber)
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let panelIndex = try XCTUnwrap(onScreen.firstIndex { $0[kCGWindowNumber as String] as? Int == number })
        guard let frontIndex = onScreen.firstIndex(where: {
            $0[kCGWindowOwnerPID as String] as? Int32 == front.processIdentifier && $0[kCGWindowLayer as String] as? Int == 0
        }) else { throw XCTSkip("The active App shows no normal window") }
        XCTAssertLessThan(panelIndex, frontIndex, "The view is behind the active App's window")
    }

    private func assertStaysOnOneDesktop(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace), file: file, line: line)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), file: file, line: line)
    }

    private func visibleWindow(labelled label: String) throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == label })
    }

    private func centreOfMainScreen() throws -> CGPoint {
        let frame = try XCTUnwrap(NSScreen.main).visibleFrame
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}
