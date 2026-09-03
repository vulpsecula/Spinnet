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
