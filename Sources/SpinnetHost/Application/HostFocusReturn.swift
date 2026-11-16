import AppKit

/// Gives keyboard focus back to the window the user acted in once a system
/// dialog shown for another process closes. macOS's administrator dialog
/// belongs to the `osascript` child that asked for it, and on dismissal macOS
/// activates the previous regular app; an accessory app such as Spinnet is
/// never that app, so it would otherwise lose focus.
struct HostFocusReturn {
    private weak var window: NSWindow?
    private let wasActive: Bool

    /// Captures the active state and key window when the user acts.
    static func capture() -> HostFocusReturn {
        HostFocusReturn(window: NSApp?.keyWindow, wasActive: NSApp?.isActive == true)
    }

    private init(window: NSWindow?, wasActive: Bool) {
        self.window = window
        self.wasActive = wasActive
    }

    /// Only returns focus Spinnet had, to a window that is still open.
    func restore() {
        guard wasActive, let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
    }
}
