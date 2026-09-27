import CoreGraphics
import XCTest
@testable import SpinnetHost

final class StageManagerStripTests: XCTestCase {
    // A 1920×1080 display with a 30-point menu bar and the Dock hidden, and a
    // 1440×900 display to its right, both in AppKit's bottom-left coordinates.
    private let main = FocusedWindowScreen(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050)
    )
    private let side = FocusedWindowScreen(
        frame: CGRect(x: 1920, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1440, height: 875)
    )

    func testTheStripIsReservedOnTheLeftWhenNoThumbnailIsShowing() {
        // Stage Manager hides the strip while a window covers it, and an empty
        // strip shows nothing, so the reserved width must not depend on it.
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [])
        XCTAssertEqual(
            strip.excluded(from: main).visibleFrame,
            CGRect(x: 190, y: 0, width: 1730, height: 1050)
        )
    }

    func testThumbnailsWithinTheReservedWidthDoNotMoveItsEdge() {
        // Narrow and wide thumbnails leave the same edge, so a layout run twice
        // lands on the same frame and the half cycle can tell where it is.
        let narrow = StageManagerStrip(dockSide: .bottom, thumbnails: [CGRect(x: 15, y: 300, width: 131, height: 135)])
        let wide = StageManagerStrip(dockSide: .bottom, thumbnails: [CGRect(x: 15, y: 500, width: 162, height: 151)])
        XCTAssertEqual(narrow.excluded(from: main), wide.excluded(from: main))
    }

    func testThumbnailsReachingPastTheReservedWidthWidenIt() {
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [CGRect(x: 15, y: 300, width: 220, height: 200)])
        XCTAssertEqual(strip.excluded(from: main).visibleFrame.minX, 235)
    }

    func testTheStripMovesRightWhenTheDockIsOnTheLeft() {
        let docked = FocusedWindowScreen(
            frame: main.frame,
            visibleFrame: CGRect(x: 70, y: 0, width: 1850, height: 1050)
        )
        let strip = StageManagerStrip(dockSide: .left, thumbnails: [])
        XCTAssertEqual(
            strip.excluded(from: docked).visibleFrame,
            CGRect(x: 70, y: 0, width: 1660, height: 1050)
        )
    }

    func testThumbnailsShowWhichSideTheStripIsOn() {
        // Thumbnails near the right edge place the strip there, whatever the
        // Dock suggests.
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [CGRect(x: 1700, y: 300, width: 200, height: 150)])
        XCTAssertEqual(
            strip.excluded(from: main).visibleFrame,
            CGRect(x: 0, y: 0, width: 1700, height: 1050)
        )
    }

    func testEachDisplayIsJudgedByItsOwnThumbnails() {
        // Thumbnails on the main display's left say nothing about the display
        // beside it, whose own thumbnails put its strip on the right.
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [
            CGRect(x: 15, y: 300, width: 250, height: 150),
            CGRect(x: 3200, y: 300, width: 140, height: 150)
        ])
        XCTAssertEqual(strip.excluded(from: main).visibleFrame.minX, 265)
        XCTAssertEqual(
            strip.excluded(from: side).visibleFrame,
            CGRect(x: 1920, y: 0, width: 1250, height: 875)
        )
    }

    func testThumbnailsAreAssignedByTheirCentreNotTheirOverhang() {
        // Stage Manager draws app icons a few points past the display's edge.
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [CGRect(x: -7, y: 400, width: 66, height: 82)])
        XCTAssertEqual(strip.excluded(from: main).visibleFrame.minX, 190)
    }

    func testAWindowAsWideAsAQuarterOfTheDisplayIsNotAThumbnail() {
        // Stage Manager moves full-size windows of its own while it animates.
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [CGRect(x: 450, y: 100, width: 1013, height: 819)])
        XCTAssertEqual(strip.excluded(from: main).visibleFrame.minX, 190)
    }

    func testTheFrameIsLeftAloneOnADisplayTooNarrowForTheStrip() {
        let tiny = FocusedWindowScreen(
            frame: CGRect(x: 0, y: 0, width: 180, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 180, height: 300)
        )
        let strip = StageManagerStrip(dockSide: .bottom, thumbnails: [])
        XCTAssertEqual(strip.excluded(from: tiny), tiny)
    }

    func testWindowServerBoundsAreFlippedIntoAppKitCoordinates() {
        // The window server measures from the top-left of the primary display.
        XCTAssertEqual(
            StageManagerStrip.appKitRect(fromWindowServer: CGRect(x: 15, y: 100, width: 162, height: 150), primaryHeight: 1080),
            CGRect(x: 15, y: 830, width: 162, height: 150)
        )
    }

    func testTheStripIsReservedOnlyWhileStageManagerShowsRecentApps() {
        XCTAssertTrue(StageManagerStrip.isShown(globallyEnabled: true, autoHide: false))
        XCTAssertFalse(StageManagerStrip.isShown(globallyEnabled: true, autoHide: true))
        XCTAssertFalse(StageManagerStrip.isShown(globallyEnabled: false, autoHide: false))
        XCTAssertFalse(StageManagerStrip.isShown(globallyEnabled: nil, autoHide: nil))
        XCTAssertTrue(StageManagerStrip.isShown(globallyEnabled: true, autoHide: nil))
    }
}
