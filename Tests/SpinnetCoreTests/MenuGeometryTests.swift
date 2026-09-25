import CoreGraphics
import XCTest
@testable import SpinnetCore

final class MenuGeometryTests: XCTestCase {
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
