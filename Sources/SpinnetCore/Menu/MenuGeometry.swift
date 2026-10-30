import CoreGraphics
import Foundation

/// The geometry contract for a Menu. Angles advance clockwise from 12
/// o'clock, matching the pointer semantics used by the Host's overlay, and
/// the first Menu Item is centred on 12 o'clock.
public struct RadialMenuLayout: Equatable {
    /// Room around the disc for the focused Menu Item, which rises past the
    /// rim, and for the shadows beneath both.
    public static let defaultOverlayPadding: CGFloat = 28

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

    /// The square content size used by both the Editor Mode view and the
    /// Runtime Mode overlay. Keeping this derived from the same padding as the
    /// overlay prevents a size preset from drifting between drawing and the
    /// window that contains it.
    public var contentDiameter: CGFloat {
        (outerRadius + Self.defaultOverlayPadding) * 2
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

        return itemIndex(inDirectionOf: point, center: center)
    }

    /// The Slot in the direction of a point, even beyond the Menu's rim.
    public func itemIndex(inDirectionOf point: CGPoint, center: CGPoint) -> Int {
        let dx = point.x - center.x
        let dy = point.y - center.y
        var clockwiseFromTop = (.pi / 2) - atan2(dy, dx)
        if clockwiseFromTop < 0 {
            clockwiseFromTop += 2 * .pi
        }
        let itemIndex = Int(floor((clockwiseFromTop / (2 * .pi)) * CGFloat(itemCount) + 0.5))
        return itemIndex % itemCount
    }

    /// Reserves the same space for every Alternate Ring, regardless of which
    /// Slot opens it, so neither the window nor the Menu moves during a gesture.
    public var alternateRingOuterRadius: CGFloat { outerRadius * 1.55 }
    public var alternateRingPadding: CGFloat {
        alternateRingOuterRadius - outerRadius + Self.defaultOverlayPadding
    }

    /// Fits the complete Menu and Alternate Ring to the screen before the
    /// center is clamped, including on a small display at a large Menu Size.
    public func fittingAlternateRing(in visibleFrame: CGRect) -> RadialMenuLayout {
        let availableRadius = max(0.01, min(visibleFrame.width, visibleFrame.height) / 2
                                  - Self.defaultOverlayPadding - 0.01)
        let scale = min(1, availableRadius / alternateRingOuterRadius)
        guard scale < 1 else { return self }
        return RadialMenuLayout(itemCount: itemCount, innerRadius: innerRadius * scale,
                                outerRadius: outerRadius * scale, itemCenterRadius: itemCenterRadius * scale)
    }

    public func alternateRing(itemIndex: Int, actionCount: Int) -> AlternateRingLayout? {
        guard (0..<itemCount).contains(itemIndex), actionCount > 0 else { return nil }
        return AlternateRingLayout(menu: self, itemIndex: itemIndex, actionCount: actionCount)
    }

    public func itemCenter(index: Int, center: CGPoint) -> CGPoint {
        precondition((0..<itemCount).contains(index), "Menu Item index is out of range")
        let step = (2 * CGFloat.pi) / CGFloat(itemCount)
        let angle = (CGFloat.pi / 2) - CGFloat(index) * step
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
        padding: CGFloat = Self.defaultOverlayPadding
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
        padding: CGFloat = Self.defaultOverlayPadding
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

/// An arc of Alternate Actions centred on their Menu Item. Angles use the
/// Menu's clockwise-from-top convention in the same coordinates as hitTest.
public struct AlternateRingLayout: Equatable {
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    public let actionCount: Int
    public let centerAngle: CGFloat
    public let span: CGFloat

    fileprivate init(menu: RadialMenuLayout, itemIndex: Int, actionCount: Int) {
        innerRadius = menu.outerRadius
        outerRadius = menu.alternateRingOuterRadius
        self.actionCount = actionCount
        centerAngle = CGFloat(itemIndex) * 2 * .pi / CGFloat(menu.itemCount)
        // Give each Action room for a label where possible. Large sets can
        // use the complete circumference without overlapping themselves.
        span = min(2 * .pi, max(2 * .pi / CGFloat(menu.itemCount), CGFloat(actionCount) * 0.55))
    }

    public func angleRange(for index: Int) -> ClosedRange<CGFloat> {
        precondition((0..<actionCount).contains(index), "Alternate Action index is out of range")
        let step = span / CGFloat(actionCount)
        let start = centerAngle - span / 2 + CGFloat(index) * step
        return start...(start + step)
    }

    public func actionCenter(index: Int, center: CGPoint) -> CGPoint {
        let range = angleRange(for: index)
        let angle = (range.lowerBound + range.upperBound) / 2
        let radius = (innerRadius + outerRadius) / 2
        return CGPoint(x: center.x + sin(angle) * radius, y: center.y + cos(angle) * radius)
    }

    public func hitTest(point: CGPoint, center: CGPoint) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance > innerRadius, distance <= outerRadius else { return nil }
        let angle = atan2(dx, dy)
        let relative = atan2(sin(angle - centerAngle), cos(angle - centerAngle))
        guard relative >= -span / 2, relative < span / 2 else { return nil }
        return min(Int((relative + span / 2) / span * CGFloat(actionCount)), actionCount - 1)
    }
}
