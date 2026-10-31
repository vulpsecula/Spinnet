import AppKit
import SpinnetWindowing
import XCTest

final class HostWindowPolicyTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testWindowsAndPanelsDefaultToOneDesktopThroughEveryInitializer() {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let windows: [NSWindow] = [
            HostWindow(),
            HostPanel(),
            HostWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false),
            HostWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false, screen: NSScreen.main),
            HostPanel(contentRect: frame, styleMask: .nonactivatingPanel, backing: .buffered, defer: false),
            HostPanel(contentRect: frame, styleMask: .nonactivatingPanel, backing: .buffered, defer: false, screen: NSScreen.main)
        ]
        for window in windows {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            assertOneDesktop(window)
        }
    }

    func testChangingOtherWindowBehaviorCannotEnableAllDesktops() {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let windows: [NSWindow] = [
            HostWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false),
            HostPanel(contentRect: frame, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        ]
        for window in windows {
            window.isReleasedWhenClosed = false
            defer { window.close() }

            window.collectionBehavior = [.canJoinAllSpaces, .transient, .stationary, .ignoresCycle]
            assertOneDesktop(window)
            XCTAssertTrue(window.collectionBehavior.contains(.transient))
            XCTAssertTrue(window.collectionBehavior.contains(.stationary))
            XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))

            window.collectionBehavior.insert(.canJoinAllSpaces)
            assertOneDesktop(window)
            window.collectionBehavior.remove(.moveToActiveSpace)
            assertOneDesktop(window)
            window.collectionBehavior = []
            assertOneDesktop(window)
        }
    }

    func testPanelsAllowFullScreenAuxiliaryPresentation() {
        let panel = HostPanel(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }

        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        assertOneDesktop(panel)
    }

    func testNativeDialogsUseTheSameDesktopPolicy() {
        let alert = HostDialogs.makeAlert()
        let chooser = HostDialogs.makeOpenPanel()
        assertOneDesktop(alert.window)
        assertOneDesktop(chooser)
    }

    private func assertOneDesktop(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace), file: file, line: line)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), file: file, line: line)
    }
}
