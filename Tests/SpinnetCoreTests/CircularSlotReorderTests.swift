import XCTest
@testable import SpinnetCore

final class CircularSlotReorderTests: XCTestCase {
    func testCrossingSeamMovesOnlyTheAdjacentSlot() {
        XCTAssertEqual(CircularSlotReorder(count: 8, source: 0, target: 7).order, [7, 1, 2, 3, 4, 5, 6, 0])
        XCTAssertEqual(CircularSlotReorder(count: 8, source: 7, target: 0).order, [7, 1, 2, 3, 4, 5, 6, 0])
    }

    func testOppositeTargetRespectsPreferredDirection() {
        XCTAssertEqual(CircularSlotReorder(count: 8, source: 0, target: 4, preferredDirection: .clockwise).order,
                       [1, 2, 3, 4, 0, 5, 6, 7])
        XCTAssertEqual(CircularSlotReorder(count: 8, source: 0, target: 4, preferredDirection: .counterclockwise).order,
                       [7, 1, 2, 3, 0, 4, 5, 6])
    }

    func testEveryMovePreservesAllSlotsAndTouchesOnlyShortestArc() {
        for count in 1...12 {
            for source in 0..<count {
                for target in 0..<count {
                    for direction in [CircularSlotReorder.Direction.clockwise, .counterclockwise] {
                        let plan = CircularSlotReorder(count: count, source: source, target: target, preferredDirection: direction)
                        XCTAssertEqual(Set(plan.order), Set(0..<count))
                        XCTAssertEqual(plan.order[target], source)
                        let distance = min((target - source + count) % count, (source - target + count) % count)
                        XCTAssertEqual(plan.order.indices.filter { plan.order[$0] != $0 }.count,
                                       source == target ? 0 : distance + 1)
                    }
                }
            }
        }
    }
}
