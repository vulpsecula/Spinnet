import Foundation

/// Moves the vacancy along the shorter arc; the untouched arc keeps its positions.
public struct CircularSlotReorder {
    public enum Direction { case clockwise, counterclockwise }
    public let direction: Direction
    /// Original indices in their resulting positions, shared by preview and persistence.
    public let order: [Int]

    public init(count: Int, source: Int, target: Int, preferredDirection: Direction = .clockwise) {
        precondition(count > 0 && (0..<count).contains(source) && (0..<count).contains(target))
        let clockwise = (target - source + count) % count
        let counterclockwise = (source - target + count) % count
        direction = clockwise == counterclockwise ? preferredDirection
            : clockwise < counterclockwise ? .clockwise : .counterclockwise
        let step = direction == .clockwise ? 1 : -1
        var indices = Array(0..<count)
        var vacancy = source
        while vacancy != target {
            let next = (vacancy + step + count) % count
            indices[vacancy] = next
            vacancy = next
        }
        indices[target] = source
        order = indices
    }
}
