import CoreGraphics
import Foundation

/// The geometry contract for a Menu. Angles start at 12 o'clock and advance
/// clockwise, matching the pointer semantics used by the Host's overlay.
public struct RadialMenuLayout: Equatable {
    public let itemCount: Int
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    public let itemCenterRadius: CGFloat

    public init(
        itemCount: Int,
        innerRadius: CGFloat = 38,
        outerRadius: CGFloat = 142,
        itemCenterRadius: CGFloat? = nil
    ) {
        precondition(itemCount > 0, "A Menu must contain at least one Menu Item")
        precondition(innerRadius >= 0 && outerRadius > innerRadius, "Menu radii are invalid")
        self.itemCount = itemCount
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.itemCenterRadius = itemCenterRadius ?? (innerRadius + outerRadius) / 2
    }

    /// Returns the only Menu Item containing `point`, or nil for the center
    /// dead zone and all points outside the radial ring.
    public func hitTest(point: CGPoint, center: CGPoint) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius else {
            return nil
        }

        var clockwiseFromTop = (.pi / 2) - atan2(dy, dx)
        if clockwiseFromTop < 0 {
            clockwiseFromTop += 2 * .pi
        }
        let itemIndex = Int(floor((clockwiseFromTop / (2 * .pi)) * CGFloat(itemCount)))
        return itemIndex % itemCount
    }

    public func itemCenter(index: Int, center: CGPoint) -> CGPoint {
        precondition((0..<itemCount).contains(index), "Menu Item index is out of range")
        let step = (2 * CGFloat.pi) / CGFloat(itemCount)
        let angle = (CGFloat.pi / 2) - (CGFloat(index) + 0.5) * step
        return CGPoint(
            x: center.x + cos(angle) * itemCenterRadius,
            y: center.y + sin(angle) * itemCenterRadius
        )
    }

    /// Clamps the Menu's center so the complete interactive ring remains in
    /// the display's visible frame. The returned point is in the same global
    /// coordinate space as `visibleFrame`.
    public func constrainedCenter(
        for preferredCenter: CGPoint,
        in visibleFrame: CGRect,
        padding: CGFloat = 8
    ) -> CGPoint {
        precondition(padding >= 0, "Menu padding cannot be negative")
        let margin = outerRadius + padding
        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - margin
        let minimumY = visibleFrame.minY + margin
        let maximumY = visibleFrame.maxY - margin

        func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat, midpoint: CGFloat) -> CGFloat {
            guard minimum <= maximum else { return midpoint }
            return min(max(value, minimum), maximum)
        }

        return CGPoint(
            x: clamp(preferredCenter.x, minimum: minimumX, maximum: maximumX, midpoint: visibleFrame.midX),
            y: clamp(preferredCenter.y, minimum: minimumY, maximum: maximumY, midpoint: visibleFrame.midY)
        )
    }

    public func overlayFrame(
        for preferredCenter: CGPoint,
        in visibleFrame: CGRect,
        padding: CGFloat = 8
    ) -> CGRect {
        let center = constrainedCenter(for: preferredCenter, in: visibleFrame, padding: padding)
        let radius = outerRadius + padding
        return CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }
}
