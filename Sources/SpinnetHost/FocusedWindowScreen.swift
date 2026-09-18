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
}
