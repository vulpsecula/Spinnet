import AppKit

/// Resolves only a focused window. Keeping the native reads at this boundary
/// lets tests replay applications that omit the system-wide AX focus value.
enum FocusedWindowLookup {
    static func read(
        systemFocusedApplication: () -> AXUIElement?,
        frontmostProcessIdentifier: () -> pid_t?,
        applicationForProcessIdentifier: (pid_t) -> AXUIElement,
        focusedWindow: (AXUIElement) -> AXUIElement?
    ) -> AXUIElement? {
        if let application = systemFocusedApplication() {
            return focusedWindow(application)
        }

        // Some applications, including Spotify, expose a focused window by
        // PID while the system-wide AXFocusedApplication value is absent.
        // Do not accept that window if another application took focus during
        // the read. The provider also compares window identity before writing.
        guard let pid = frontmostProcessIdentifier(), pid > 0,
              let window = focusedWindow(applicationForProcessIdentifier(pid)),
              frontmostProcessIdentifier() == pid else { return nil }
        return window
    }
}
