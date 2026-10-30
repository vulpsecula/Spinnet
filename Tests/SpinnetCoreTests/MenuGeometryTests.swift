import CoreGraphics
import XCTest
@testable import SpinnetCore

final class MenuGeometryTests: XCTestCase {
    func testAlternateRingUsesClockwiseOrderAroundItsItem() throws {
        let menu = RadialMenuLayout(itemCount: 8)
        let ring = try XCTUnwrap(menu.alternateRing(itemIndex: 0, actionCount: 3))
        XCTAssertEqual(ring.hitTest(point: CGPoint(x: -80, y: 160), center: .zero), 0)
        XCTAssertEqual(ring.hitTest(point: CGPoint(x: 0, y: 180), center: .zero), 1)
        XCTAssertEqual(ring.hitTest(point: CGPoint(x: 80, y: 160), center: .zero), 2)
        XCTAssertNil(ring.hitTest(point: CGPoint(x: 0, y: -180), center: .zero))
    }
    func testAlternateRingFitsAtScreenEdgesAtEachMenuSize() {
        let visibleFrame = CGRect(x: 20, y: 30, width: 800, height: 600)
        for outerRadius: CGFloat in [71, 142, 213, 284] {
            let menu = RadialMenuLayout(itemCount: 8, innerRadius: outerRadius * 38 / 142, outerRadius: outerRadius)
                .fittingAlternateRing(in: visibleFrame)
            for pointer in [CGPoint(x: 20, y: 30), CGPoint(x: 820, y: 630)] {
                let frame = menu.overlayFrame(for: pointer, in: visibleFrame, padding: menu.alternateRingPadding)
                XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX - 0.01)
                XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY - 0.01)
                XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX + 0.01)
                XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY + 0.01)
                XCTAssertGreaterThanOrEqual(frame.width / 2, menu.alternateRingOuterRadius)
            }
        }
    }
    func testAlternateRingHitTestingAtEachMenuSize() throws {
        // The minimum, recommended and maximum Menu Size values.
        for outerRadius: CGFloat in [71, 142, 213, 284] {
            let menu = RadialMenuLayout(itemCount: 8, innerRadius: outerRadius * 38 / 142, outerRadius: outerRadius)
            let ring = try XCTUnwrap(menu.alternateRing(itemIndex: 2, actionCount: 7))
            let center = CGPoint(x: 400, y: 400)

            for index in 0..<7 {
                XCTAssertEqual(ring.hitTest(point: ring.actionCenter(index: index, center: center), center: center), index)
            }
            XCTAssertNil(ring.hitTest(point: center, center: center))
            XCTAssertNil(menu.alternateRing(itemIndex: 2, actionCount: 0))
        }
    }
    func testPointerDirectionSelectsExactlyOneClockwiseTopOriginItem() throws {
        let layout = RadialMenuLayout(itemCount: 8, innerRadius: 38, outerRadius: 142)

        XCTAssertEqual(layout.hitTest(point: CGPoint(x: 0, y: 100), center: .zero), 0)
        XCTAssertEqual(layout.hitTest(point: CGPoint(x: 100, y: 0), center: .zero), 2)
        XCTAssertEqual(layout.hitTest(point: CGPoint(x: 0, y: -100), center: .zero), 4)
        XCTAssertEqual(layout.hitTest(point: CGPoint(x: -100, y: 0), center: .zero), 6)
    }

    /// The first Menu Item sits centred on 12 o'clock, like a clock hand,
    /// rather than starting there.
    func testTheFirstItemIsCentredOnTwelveOClock() throws {
        let layout = RadialMenuLayout(itemCount: 8, innerRadius: 38, outerRadius: 142)
        func point(degreesClockwiseFromTop degrees: CGFloat) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(x: sin(radians) * 100, y: cos(radians) * 100)
        }

        XCTAssertEqual(layout.hitTest(point: point(degreesClockwiseFromTop: -20), center: .zero), 0)
        XCTAssertEqual(layout.hitTest(point: point(degreesClockwiseFromTop: 20), center: .zero), 0)
        XCTAssertEqual(layout.hitTest(point: point(degreesClockwiseFromTop: 25), center: .zero), 1)
        XCTAssertEqual(layout.hitTest(point: point(degreesClockwiseFromTop: -25), center: .zero), 7)

        let top = layout.itemCenter(index: 0, center: .zero)
        XCTAssertEqual(top.x, 0, accuracy: 0.001)
        XCTAssertEqual(top.y, layout.itemCenterRadius, accuracy: 0.001)
    }

    func testCenterDeadZoneAndVisibleFramePlacementKeepMenuUsableAtEdges() {
        let layout = RadialMenuLayout(itemCount: 8, innerRadius: 38, outerRadius: 142)
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertNil(layout.hitTest(point: CGPoint(x: 20, y: 0), center: .zero))
        XCTAssertNil(layout.hitTest(point: CGPoint(x: 200, y: 0), center: .zero))

        XCTAssertEqual(
            layout.constrainedCenter(for: CGPoint(x: 10, y: 10), in: visibleFrame, padding: 8),
            CGPoint(x: 150, y: 150)
        )
        XCTAssertEqual(
            layout.constrainedCenter(for: CGPoint(x: 790, y: 590), in: visibleFrame, padding: 8),
            CGPoint(x: 650, y: 450)
        )
    }
}
