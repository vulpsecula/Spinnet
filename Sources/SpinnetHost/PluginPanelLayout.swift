import AppKit

/// One display as a Plugin View's panel sees it: its whole frame, which
/// holds the pointer even over the menu bar, and the visible part a panel
/// may occupy.
struct PluginPanelScreen: Equatable {
    var frame: NSRect
    var visible: NSRect

    static func current() -> [PluginPanelScreen] {
        NSScreen.screens.map { PluginPanelScreen(frame: $0.frame, visible: $0.visibleFrame) }
    }
}

/// The geometry the Host remembers for a pinned view (ADR 0016): where the
/// panel was and whether its size is the user's or still its content's.
struct PluginPanelGeometry: Equatable, Codable {
    var frame: NSRect
    var isUserSized: Bool
}

/// Where a Plugin View's panel sits and who decides its size. It follows its
/// content's preferred size, growing downwards from its top, until the user
/// resizes it or a remembered pinned size is restored; from then on the
/// size is the user's and content updates leave the frame alone. Geometry
/// restored from memory or kept across a screen change is constrained to
/// the visible screens. Moves are the user's and are not nudged.
struct PluginPanelLayout: Equatable {
    /// Space between the pointer and the panel's top edge.
    static let pointerGap: CGFloat = 12
    /// Space kept between the panel and the screen's edges when the Host
    /// places it.
    static let screenMargin: CGFloat = 8
    /// The smallest user size unless the page asks for more: the content is
    /// laid out for the default width, so the panel only grows wider than it.
    static let minimumSize = NSSize(width: 440, height: 120)
    /// Used when AppKit reports no screen at all.
    static let fallbackScreen = PluginPanelScreen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                                  visible: NSRect(x: 0, y: 0, width: 1440, height: 900))

    private(set) var frame: NSRect
    /// Whether the content's preferred size drives the panel's size.
    private(set) var followsContent: Bool
    /// The top the panel grows down from while it follows its content; it
    /// is kept when the panel is lifted to stay on screen.
    private var top: CGFloat

    var geometry: PluginPanelGeometry { PluginPanelGeometry(frame: frame, isUserSized: !followsContent) }

    /// The panel's frame when a view opens: beside the pointer, or where the
    /// remembered pinned geometry puts it.
    static func opening(contentSize: NSSize, pointer: NSPoint, screens: [PluginPanelScreen],
                        restoring pinned: PluginPanelGeometry?, minimumSize: NSSize = minimumSize) -> PluginPanelLayout {
        let screens = screens.isEmpty ? [fallbackScreen] : screens
        if let pinned, pinned.isUserSized {
            let size = NSSize(width: max(pinned.frame.width, minimumSize.width),
                              height: max(pinned.frame.height, minimumSize.height))
            let frame = constrain(NSRect(origin: pinned.frame.origin, size: size), to: screens)
            return PluginPanelLayout(frame: frame, followsContent: false, top: frame.maxY)
        }
        if let pinned {
            let placed = NSRect(x: pinned.frame.minX, y: pinned.frame.maxY - contentSize.height,
                                width: contentSize.width, height: contentSize.height)
            let frame = constrain(placed, to: screens)
            return PluginPanelLayout(frame: frame, followsContent: true, top: frame.maxY)
        }
        let screen = screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? screens[0]
        let topLeft = besidePointer(size: contentSize, pointer: pointer, visible: screen.visible)
        return PluginPanelLayout(frame: NSRect(x: topLeft.x, y: topLeft.y - contentSize.height,
                                               width: contentSize.width, height: contentSize.height),
                                 followsContent: true, top: topLeft.y)
    }

    /// Centred under the pointer, its top just below it, and inside the
    /// visible frame.
    static func besidePointer(size: NSSize, pointer: NSPoint, visible: NSRect) -> NSPoint {
        let x = min(max(pointer.x - size.width / 2, visible.minX + screenMargin),
                    visible.maxX - size.width - screenMargin)
        var top = min(pointer.y - pointerGap, visible.maxY - screenMargin)
        if top - size.height < visible.minY + screenMargin {
            top = min(visible.minY + screenMargin + size.height, visible.maxY - screenMargin)
        }
        return NSPoint(x: x, y: top)
    }

    /// `frame` unchanged when a screen's visible part holds it whole;
    /// otherwise moved, and shrunk if it must be, inside the screen holding
    /// most of it, or the first screen when none does.
    static func constrain(_ frame: NSRect, to screens: [PluginPanelScreen]) -> NSRect {
        let screens = screens.isEmpty ? [fallbackScreen] : screens
        if screens.contains(where: { $0.visible.contains(frame) }) { return frame }
        let area = { (screen: PluginPanelScreen) -> CGFloat in
            let overlap = screen.visible.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let best = screens.max { area($0) < area($1) }!
        let visible = area(best) > 0 ? best.visible : screens[0].visible
        let room = visible.insetBy(dx: screenMargin, dy: screenMargin)
        let width = min(frame.width, room.width), height = min(frame.height, room.height)
        let x = min(max(frame.minX, room.minX), room.maxX - width)
        let y = min(max(frame.minY, room.minY), room.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// The content asked for a new size. Followed, the panel keeps its left
    /// edge and top, and is lifted only as far as the screen's bottom
    /// requires; a user-sized panel does not change.
    mutating func contentSizeChanged(to size: NSSize, screens: [PluginPanelScreen]) {
        guard followsContent else { return }
        let screens = screens.isEmpty ? [Self.fallbackScreen] : screens
        let placed = NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height)
        let screen = screens.max { overlap($0, placed) < overlap($1, placed) } ?? screens[0]
        let bottom = screen.visible.minY + Self.screenMargin
        frame = NSRect(x: placed.minX, y: max(placed.minY, bottom), width: size.width, height: size.height)
    }

    /// The user started dragging an edge: the size is theirs from now on.
    mutating func userBeganResizing() {
        followsContent = false
    }

    /// The content's size drives the panel's again, from the panel's top,
    /// as when a page stops declaring that it may be resized.
    mutating func followContent(of size: NSSize, screens: [PluginPanelScreen]) {
        followsContent = true
        top = frame.maxY
        contentSizeChanged(to: size, screens: screens)
    }

    /// The user finished resizing to `frame`, no smaller than `minimumSize`.
    mutating func userResized(to newFrame: NSRect, minimumSize: NSSize = minimumSize) {
        followsContent = false
        let size = NSSize(width: max(newFrame.width, minimumSize.width),
                          height: max(newFrame.height, minimumSize.height))
        frame = NSRect(x: newFrame.minX, y: newFrame.maxY - size.height, width: size.width, height: size.height)
        top = frame.maxY
    }

    /// The user moved the panel; it grows from its new top.
    mutating func moved(to newFrame: NSRect) {
        frame = newFrame
        top = newFrame.maxY
    }

    /// Displays were added, removed or rearranged.
    mutating func screensChanged(_ screens: [PluginPanelScreen]) {
        frame = Self.constrain(frame, to: screens)
        top = frame.maxY
    }

    private func overlap(_ screen: PluginPanelScreen, _ rect: NSRect) -> CGFloat {
        let overlap = screen.visible.intersection(rect)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
