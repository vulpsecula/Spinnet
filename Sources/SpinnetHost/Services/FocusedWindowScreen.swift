import CoreGraphics
import SpinnetCore

/// One display as AppKit describes it, in bottom-left coordinates.
///
/// Accessibility reports window frames from the top-left of the primary
/// display, so the screen a window is on has to be translated before a Plugin
/// can lay the window out within it.
struct FocusedWindowScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect

    /// The visible frame of the screen holding most of `window`, in the
    /// window's top-left coordinates. The first screen is the primary display,
    /// which is also where a window on no screen at all is laid out.
    static func visibleFrame(for window: WindowRect, among screens: [FocusedWindowScreen]) -> WindowRect? {
        guard let primary = screens.first else { return nil }
        let flip = { (rect: CGRect) in
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let windowRect = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
        let overlap = { (screen: FocusedWindowScreen) -> CGFloat in
            let shared = flip(screen.frame).intersection(windowRect)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? primary
        let visible = flip(screen.visibleFrame)
        return WindowRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
    }

    /// `window` with its screen's visible frame and every display's, all in
    /// the window's top-left coordinates. Displays are listed left to right,
    /// then top to bottom, so the order does not depend on which is primary.
    static func focusedWindow(_ window: WindowRect, among screens: [FocusedWindowScreen]) -> FocusedWindow? {
        guard let primary = screens.first,
              let visibleFrame = visibleFrame(for: window, among: screens) else { return nil }
        let displays = screens.map { screen in
            WindowRect(x: screen.visibleFrame.minX, y: primary.frame.maxY - screen.visibleFrame.maxY,
                       width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard let displayIndex = displays.firstIndex(of: visibleFrame) else { return nil }
        return FocusedWindow(frame: window, visibleFrame: visibleFrame, displays: displays, displayIndex: displayIndex)
    }
}
