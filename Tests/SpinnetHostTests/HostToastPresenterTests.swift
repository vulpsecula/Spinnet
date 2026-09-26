import AppKit
import XCTest
@testable import SpinnetHost

/// A toast without a view is the Host's own feedback near the pointer, like
/// Raycast's `showHUD` (ADR 0010).
final class HostToastPresenterTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 200, height: 36)

    func testAToastSitsCentredJustBelowThePointer() {
        let frame = HostToastPresenter.frame(of: size, near: NSPoint(x: 700, y: 500), within: screen)
        XCTAssertEqual(frame.midX, 700)
        XCTAssertEqual(frame.maxY, 500 - HostToastPresenter.pointerGap)
    }

    func testAToastStaysOnScreenAndGoesAboveAPointerAtTheBottom() {
        let left = HostToastPresenter.frame(of: size, near: NSPoint(x: 10, y: 500), within: screen)
        XCTAssertEqual(left.minX, screen.minX + HostToastPresenter.screenMargin)
        let right = HostToastPresenter.frame(of: size, near: NSPoint(x: 1435, y: 500), within: screen)
        XCTAssertEqual(right.maxX, screen.maxX - HostToastPresenter.screenMargin)
        let bottom = HostToastPresenter.frame(of: size, near: NSPoint(x: 700, y: 20), within: screen)
        XCTAssertEqual(bottom.minY, 20 + HostToastPresenter.pointerGap)
    }

    func testShowingAToastPresentsItNearThePointerAndItGoesAway() throws {
        _ = NSApplication.shared
        var dismissals: [() -> Void] = []
        let presenter = HostToastPresenter(schedule: { _, dismiss in dismissals.append(dismiss) })
        defer { presenter.dismiss() }
        let pointer = NSPoint(x: 400, y: 400)

        presenter.show("Copied", near: pointer)

        let snapshot = presenter.presentationSnapshot
        XCTAssertEqual(snapshot.message, "Copied")
        XCTAssertTrue(snapshot.isVisible)
        XCTAssertEqual(snapshot.frame.midX, pointer.x, accuracy: 1)
        XCTAssertLessThan(snapshot.frame.maxY, pointer.y)
        XCTAssertEqual(dismissals.count, 1)
        dismissals[0]()
        XCTAssertFalse(presenter.presentationSnapshot.isVisible)
    }
}
