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

    func testResultsPopupShowsOnlyOnTheActiveDesktop() throws {
        let presentation = try ResultsPresentation(serviceInput: .object([
            "title": .string("Space Check"),
            "original": .string("Hello"),
            "sections": .array([.object([
                "title": .string("One"),
                "request": .object(["method": .string("GET"), "url": .string("https://api.example.com/one")]),
                "result_pointer": .string("/text")
            ])])
        ]))
        let popup = ResultsPopupController()
        defer { popup.close() }

        popup.present(ResultsPresentationSession(presentation: presentation) { _, _ in
            throw PluginHostServiceError.failed("not asked here")
        })

        assertStaysOnOneDesktop(try visibleWindow(labelled: "Space Check"))
    }

    func testSmartJumpShowsOnlyOnTheActiveDesktop() throws {
        let window = SmartJumpWindowController()
        defer { window.close() }

        window.present(SmartJumpSession(initialText: "", searchEngines: [], copy: { _ in }, perform: { _ in }))

        assertStaysOnOneDesktop(try visibleWindow(labelled: "Smart Jump"))
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
