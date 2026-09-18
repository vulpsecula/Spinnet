import CoreGraphics
import SpinnetCore
import XCTest
@testable import SpinnetHost

final class FocusedWindowScreenTests: XCTestCase {
    // A 1440×900 primary display with a 25-point menu bar and a Dock along the
    // bottom, and a 1920×1080 display to its left whose top sits 100 points
    // higher, both in AppKit's bottom-left coordinates.
    private let primary = FocusedWindowScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805)
    )
    private let left = FocusedWindowScreen(
        frame: CGRect(x: -1920, y: -80, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -80, width: 1920, height: 1080)
    )

    func testVisibleFrameIsReportedInTopLeftCoordinates() {
        let window = WindowRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(
            FocusedWindowScreen.visibleFrame(for: window, among: [primary, left]),
            WindowRect(x: 0, y: 25, width: 1440, height: 805)
        )
    }

    func testTheScreenHoldingMostOfTheWindowIsChosen() {
        // Mostly on the left display, which extends 100 points above the primary.
        let window = WindowRect(x: -900, y: -50, width: 1000, height: 400)
        XCTAssertEqual(
            FocusedWindowScreen.visibleFrame(for: window, among: [primary, left]),
            WindowRect(x: -1920, y: -100, width: 1920, height: 1080)
        )
    }

    func testAWindowOnNoScreenFallsBackToThePrimaryDisplay() {
        let window = WindowRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertEqual(
            FocusedWindowScreen.visibleFrame(for: window, among: [primary, left]),
            WindowRect(x: 0, y: 25, width: 1440, height: 805)
        )
        XCTAssertNil(FocusedWindowScreen.visibleFrame(for: window, among: []))
    }

    // A 1280×800 display right of the primary whose top sits 400 points above
    // it, with its own menu bar reserved.
    private let right = FocusedWindowScreen(
        frame: CGRect(x: 1440, y: 500, width: 1280, height: 800),
        visibleFrame: CGRect(x: 1440, y: 500, width: 1280, height: 775)
    )

    func testDisplaysAreListedLeftToRightInTopLeftCoordinates() throws {
        // AppKit lists the primary display first, whatever its position.
        let window = WindowRect(x: 1500, y: -300, width: 400, height: 300)
        let focused = try XCTUnwrap(FocusedWindowScreen.focusedWindow(window, among: [primary, right, left]))
        XCTAssertEqual(focused.frame, window)
        XCTAssertEqual(focused.displays, [
            WindowRect(x: -1920, y: -100, width: 1920, height: 1080),
            WindowRect(x: 0, y: 25, width: 1440, height: 805),
            WindowRect(x: 1440, y: -375, width: 1280, height: 775)
        ])
        XCTAssertEqual(focused.displayIndex, 2)
        XCTAssertEqual(focused.visibleFrame, focused.displays[2])
    }

    func testDisplaysSharingALeftEdgeAreListedTopToBottom() throws {
        let above = FocusedWindowScreen(
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875)
        )
        let window = WindowRect(x: 100, y: 100, width: 400, height: 300)
        let focused = try XCTUnwrap(FocusedWindowScreen.focusedWindow(window, among: [primary, above]))
        XCTAssertEqual(focused.displays, [
            WindowRect(x: 0, y: -875, width: 1440, height: 875),
            WindowRect(x: 0, y: 25, width: 1440, height: 805)
        ])
        XCTAssertEqual(focused.displayIndex, 1)
    }

    func testAWindowOnNoScreenIsReportedOnThePrimaryDisplay() throws {
        let window = WindowRect(x: 5000, y: 5000, width: 100, height: 100)
        let focused = try XCTUnwrap(FocusedWindowScreen.focusedWindow(window, among: [primary, left]))
        XCTAssertEqual(focused.visibleFrame, WindowRect(x: 0, y: 25, width: 1440, height: 805))
        XCTAssertEqual(focused.displayIndex, 1)
        XCTAssertNil(FocusedWindowScreen.focusedWindow(window, among: []))
    }
}
