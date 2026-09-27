import AppKit

/// The strip of recent applications Stage Manager keeps along one side of
/// each display.
///
/// AppKit's visible frame leaves the strip in, so a window laid out to the
/// visible frame would cover it. The Host takes the strip out before a Plugin
/// sees the frame, and every window layout then leaves it clear.
///
/// The strip is reserved at a fixed width, not measured each time: Stage
/// Manager hides the strip while a window covers it, and its thumbnails change
/// size with their windows, so a measured edge would move between two runs of
/// the same layout. Thumbnails are consulted only for the side the strip is on
/// and for a strip wider than the reserved width.
struct StageManagerStrip: Equatable {
    enum DockSide: Equatable {
        case left, bottom, right
    }

    /// Wide enough for the widest thumbnails Stage Manager draws on a
    /// 1920-point display, with a margin beside them.
    static let reservedWidth: CGFloat = 190

    /// Where the Dock is, which decides the side of a display that shows no
    /// thumbnails: Stage Manager moves its strip right when the Dock is left.
    let dockSide: DockSide
    /// The thumbnails on screen, in AppKit's bottom-left coordinates.
    let thumbnails: [CGRect]

    /// `screen` with the strip taken out of its visible frame. A display too
    /// narrow to lose the strip is left as it is.
    func excluded(from screen: FocusedWindowScreen) -> FocusedWindowScreen {
        // A thumbnail belongs to the display holding its centre, since app
        // icons overhang the edge. Anything wider than a quarter of the
        // display is Stage Manager mid-animation, not a thumbnail at rest.
        let own = thumbnails.filter {
            screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.width < screen.frame.width / 4
        }
        let visible = screen.visibleFrame
        let onLeft = own.isEmpty
            ? dockSide != .left
            : own.reduce(CGRect.null) { $0.union($1) }.midX < screen.frame.midX

        var (minX, maxX) = (visible.minX, visible.maxX)
        if onLeft {
            minX = max(visible.minX + Self.reservedWidth, own.map(\.maxX).max() ?? visible.minX)
        } else {
            maxX = min(visible.maxX - Self.reservedWidth, own.map(\.minX).min() ?? visible.maxX)
        }
        guard minX < maxX else { return screen }
        return FocusedWindowScreen(
            frame: screen.frame,
            visibleFrame: CGRect(x: minX, y: visible.minY, width: maxX - minX, height: visible.height)
        )
    }

    /// Whether Stage Manager is on and keeps its recent applications in view.
    /// With them hidden, the strip appears only while the pointer is at the
    /// edge, over whatever is there, so nothing is reserved for it.
    static func isShown(globallyEnabled: Bool?, autoHide: Bool?) -> Bool {
        globallyEnabled == true && autoHide != true
    }

    /// A window-server rectangle, measured from the top-left of the primary
    /// display, in AppKit's bottom-left coordinates.
    static func appKitRect(fromWindowServer rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The strip as the system shows it now, or `nil` when there is none to
    /// leave clear. Stage Manager's settings are not public API; the keys are
    /// the ones System Settings writes.
    static func current(primaryHeight: CGFloat) -> StageManagerStrip? {
        let windowManager = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(windowManager)
        guard isShown(
            globallyEnabled: CFPreferencesCopyAppValue("GloballyEnabled" as CFString, windowManager) as? Bool,
            autoHide: CFPreferencesCopyAppValue("AutoHide" as CFString, windowManager) as? Bool
        ) else { return nil }

        let dock = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dock)
        let dockSide: DockSide
        switch CFPreferencesCopyAppValue("orientation" as CFString, dock) as? String {
        case "left": dockSide = .left
        case "right": dockSide = .right
        default: dockSide = .bottom
        }

        // Stage Manager draws each thumbnail as an ordinary-level window of
        // its own process. Reading their bounds needs no Screen Recording.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let thumbnails = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerName as String] as? String == "WindowManager",
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  !rect.isEmpty else { return nil }
            return appKitRect(fromWindowServer: rect, primaryHeight: primaryHeight)
        }
        return StageManagerStrip(dockSide: dockSide, thumbnails: thumbnails)
    }
}
