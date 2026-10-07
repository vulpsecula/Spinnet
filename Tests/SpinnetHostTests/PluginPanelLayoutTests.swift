import AppKit
import XCTest
@testable import SpinnetHost

/// Where a Plugin View's panel sits and who decides its size (#73, ADR
/// 0016): the content's preferred size until the user resizes the panel or
/// a remembered pinned size is restored, then the user's; remembered
/// geometry comes back inside the visible screens.
final class PluginPanelLayoutTests: XCTestCase {
    private let main = PluginPanelScreen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                         visible: NSRect(x: 0, y: 0, width: 1440, height: 875))
    /// A second display to the right of the main one.
    private let right = PluginPanelScreen(frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
                                          visible: NSRect(x: 1440, y: 0, width: 1920, height: 1080))
    private let margin = PluginPanelLayout.screenMargin
    private let content = NSSize(width: 440, height: 300)

    // MARK: - Opening

    func testAnUnpinnedOpeningIsBesideThePointerAndFollowsItsContent() {
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: nil)
        XCTAssertEqual(layout.frame, NSRect(x: 480, y: 600 - PluginPanelLayout.pointerGap - 300, width: 440, height: 300))
        XCTAssertTrue(layout.followsContent)
    }

    func testAnOpeningUsesTheScreenUnderThePointer() {
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 3355, y: 600),
                                               screens: [main, right], restoring: nil)
        XCTAssertEqual(layout.frame.maxX, right.visible.maxX - margin)
    }

    func testARestoredUserSizeIsKeptAndNoLongerFollowsContent() {
        let pinned = PluginPanelGeometry(frame: NSRect(x: 100, y: 100, width: 600, height: 500), isUserSized: true)
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: pinned)
        XCTAssertEqual(layout.frame, pinned.frame, "The pointer does not move a restored pinned panel")
        XCTAssertFalse(layout.followsContent)
        XCTAssertEqual(layout.geometry, pinned)
    }

    /// Pinned but never resized: the place comes back, the size is still
    /// the content's.
    func testARestoredPlaceWithoutAUserSizeKeepsItsTopLeftAndFollowsContent() {
        let pinned = PluginPanelGeometry(frame: NSRect(x: 100, y: 400, width: 440, height: 200), isUserSized: false)
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: pinned)
        XCTAssertEqual(layout.frame, NSRect(x: 100, y: 300, width: 440, height: 300))
        XCTAssertTrue(layout.followsContent)
    }

    // MARK: - Screen constraints

    /// The display it was pinned on is gone: the panel comes back on a
    /// screen that is there, whole.
    func testRestoredGeometryOnAMissingScreenComesBackOnAVisibleOne() {
        let onRight = PluginPanelGeometry(frame: NSRect(x: 2500, y: 300, width: 600, height: 500), isUserSized: true)
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: onRight)
        XCTAssertTrue(main.visible.insetBy(dx: margin, dy: margin).contains(layout.frame), "\(layout.frame)")
        XCTAssertEqual(layout.frame.size, onRight.frame.size)
    }

    func testRestoredGeometryLargerThanTheScreenShrinksToIt() {
        let huge = PluginPanelGeometry(frame: NSRect(x: 1500, y: 0, width: 1800, height: 1000), isUserSized: true)
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: huge)
        XCTAssertEqual(layout.frame, main.visible.insetBy(dx: margin, dy: margin))
    }

    func testRestoredGeometryPartlyOffItsScreenIsPulledOnToIt() {
        let hanging = PluginPanelGeometry(frame: NSRect(x: 1300, y: 700, width: 600, height: 500), isUserSized: true)
        let layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: hanging)
        XCTAssertEqual(layout.frame, NSRect(x: 1440 - margin - 600, y: 875 - margin - 500, width: 600, height: 500))
    }

    /// A panel straddling two displays stays on the one holding most of it.
    func testConstrainingPicksTheScreenHoldingMostOfThePanel() {
        let straddling = NSRect(x: 1300, y: 300, width: 600, height: 400)
        let constrained = PluginPanelLayout.constrain(straddling, to: [main, right])
        XCTAssertEqual(constrained.minX, right.visible.minX + margin)
    }

    /// A panel already inside a screen is not nudged to the margins.
    func testAPanelInsideAScreenIsNotMoved() {
        let inside = NSRect(x: 2, y: 2, width: 600, height: 400)
        XCTAssertEqual(PluginPanelLayout.constrain(inside, to: [main]), inside)
    }

    func testAScreenChangeKeepsAnOpenPanelVisible() {
        var layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 3000, y: 900),
                                               screens: [main, right], restoring: nil)
        layout.userResized(to: NSRect(x: 2800, y: 200, width: 500, height: 600))
        layout.screensChanged([main])
        XCTAssertTrue(main.visible.contains(layout.frame), "\(layout.frame)")
        XCTAssertEqual(layout.frame.size, NSSize(width: 500, height: 600))
        XCTAssertFalse(layout.followsContent)
    }

    // MARK: - Content size against the user's size

    func testFollowingContentGrowsDownwardsFromTheSameTop() {
        var layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: nil)
        let top = layout.frame.maxY
        layout.contentSizeChanged(to: NSSize(width: 440, height: 400), screens: [main])
        XCTAssertEqual(layout.frame.maxY, top)
        XCTAssertEqual(layout.frame.height, 400)
        XCTAssertEqual(layout.frame.minX, 480)
    }

    /// Content too tall for the room below the top lifts the panel; when it
    /// shrinks again, the panel returns to its top.
    func testGrowingPastTheBottomLiftsThePanelWithoutLosingItsTop() {
        var layout = PluginPanelLayout.opening(contentSize: NSSize(width: 440, height: 100),
                                               pointer: NSPoint(x: 700, y: 300), screens: [main], restoring: nil)
        let top = layout.frame.maxY
        layout.contentSizeChanged(to: NSSize(width: 440, height: 500), screens: [main])
        XCTAssertEqual(layout.frame.minY, margin)
        layout.contentSizeChanged(to: NSSize(width: 440, height: 100), screens: [main])
        XCTAssertEqual(layout.frame.maxY, top)
    }

    func testOnceTheUserResizesContentUpdatesNoLongerChangeTheFrame() {
        var layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: nil)
        layout.userBeganResizing()
        XCTAssertFalse(layout.followsContent, "Content stops driving the size as soon as the drag starts")
        let chosen = NSRect(x: 400, y: 100, width: 700, height: 480)
        layout.userResized(to: chosen)

        layout.contentSizeChanged(to: NSSize(width: 440, height: 200), screens: [main])
        layout.contentSizeChanged(to: NSSize(width: 440, height: 800), screens: [main])

        XCTAssertEqual(layout.frame, chosen)
        XCTAssertEqual(layout.geometry, PluginPanelGeometry(frame: chosen, isUserSized: true))
    }

    /// A user-sized panel keeps no less than the minimum, however small the
    /// drag or the remembered size.
    func testAUserSizeIsNeverBelowTheMinimum() {
        var layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: nil)
        layout.userResized(to: NSRect(x: 400, y: 100, width: 10, height: 10))
        XCTAssertEqual(layout.frame.size, PluginPanelLayout.minimumSize)
    }

    func testAMoveIsKeptAndContentThenGrowsFromTheNewTop() {
        var layout = PluginPanelLayout.opening(contentSize: content, pointer: NSPoint(x: 700, y: 600),
                                               screens: [main], restoring: nil)
        layout.moved(to: NSRect(x: 50, y: 200, width: 440, height: 300))
        layout.contentSizeChanged(to: NSSize(width: 440, height: 350), screens: [main])
        XCTAssertEqual(layout.frame, NSRect(x: 50, y: 150, width: 440, height: 350))
        XCTAssertEqual(layout.geometry, PluginPanelGeometry(frame: layout.frame, isUserSized: false))
    }
}
