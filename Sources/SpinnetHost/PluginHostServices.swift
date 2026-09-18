import AppKit
import SpinnetCore

/// AppKit adapters for the narrow Host Services exposed to the fixture
/// Plugin. The Plugin helper never receives these objects or framework access.
final class AppKitPluginHostServiceProvider {
    private let windowLock = NSLock()
    private let closedWindowSweep = DispatchQueue(label: "com.vulpsecula.Spinnet.closed-window-sweep", qos: .utility)
    /// The window a Plugin last read. Setting a frame applies only to it, and
    /// only while it is still focused, so a layout computed for one window is
    /// never applied to another that took focus in between.
    private var readWindow: AXUIElement?
    /// Where each window was before Spinnet last moved it, for Restore. Held
    /// in memory only and never persisted.
    private var rememberedFrames = RememberedWindowFrames<AXWindowKey>()

    func isGranted(_ permission: PluginSystemPermission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    func readSelectedText() throws -> String {
        guard isGranted(.accessibility) else {
            throw PluginHostServiceError.systemPermissionDenied(.accessibility)
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw PluginHostServiceError.failed("Focused application has no accessible text selection")
        }
        let focusedElement = focusedValue as! AXUIElement

        var selectedValue: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedStatus == .success,
              let selectedText = selectedValue as? String else {
            throw PluginHostServiceError.failed("Focused application has no readable text selection")
        }
        return selectedText
    }

    func readFocusedWindow() throws -> FocusedWindow {
        let window = try focusedWindow()
        let frame = try frame(of: window)
        windowLock.withLock { readWindow = window }
        let screens = onMain {
            NSScreen.screens.map { FocusedWindowScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        }
        guard let focused = FocusedWindowScreen.focusedWindow(frame, among: screens) else {
            throw PluginHostServiceError.unavailable("No display is available")
        }
        return focused
    }

    /// Moves the window last read, provided it is still focused. A window that
    /// refuses either half of the change fails before anything is set, a write
    /// that fails part-way restores the original frame, and no other window is
    /// tried.
    func setFocusedWindowFrame(_ frame: WindowRect) throws {
        let window = try focusedWindow()
        try refuseLayoutInFullScreen(window)
        let expected = windowLock.withLock { readWindow }
        guard let expected, CFEqual(expected, window) else {
            throw PluginHostServiceError.unavailable("The focused window changed after it was read")
        }
        let original = try self.frame(of: window)
        try replaceFrame(of: window, from: original, with: frame)
        // Remember the frame the window settled on, which may differ from the
        // one requested if the window clamped it, so the next layout can tell
        // whether the window is still where Spinnet put it.
        let applied = (try? self.frame(of: window)) ?? frame
        windowLock.withLock { rememberedFrames.recordMove(of: AXWindowKey(window), from: original, to: applied) }
        // Checking every remembered window can wait on unresponsive
        // applications, so it happens after the layout, not before it.
        closedWindowSweep.async { [weak self] in self?.forgetClosedWindows() }
    }

    /// Returns the focused window to the frame it had before Spinnet last
    /// moved it, under the same rules as `setFocusedWindowFrame`. The frame is
    /// looked up for the focused window itself, so it can never be applied to
    /// another window. A window Spinnet never moved does not move.
    func restoreFocusedWindowFrame() throws {
        let window = try focusedWindow()
        try refuseLayoutInFullScreen(window)
        let key = AXWindowKey(window)
        let remembered = windowLock.withLock { rememberedFrames.frameToRestore(for: key) }
        guard let remembered else { throw PluginHostServiceError.nothingToRestore }
        let original = try self.frame(of: window)
        try replaceFrame(of: window, from: original, with: remembered)
        windowLock.withLock { rememberedFrames.forget(key) }
    }

    /// Checks both halves are settable before changing anything, and puts
    /// `original` back if the window rejects the change part-way.
    private func replaceFrame(of window: AXUIElement, from original: WindowRect, with frame: WindowRect) throws {
        for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success,
                  settable.boolValue else {
                throw PluginHostServiceError.unavailable("The focused window cannot be moved or resized")
            }
        }
        guard apply(frame, to: window) else {
            _ = apply(original, to: window)
            throw PluginHostServiceError.failed("The focused window did not accept the new frame")
        }
    }

    /// Drops remembered frames for windows that no longer exist. Accessibility
    /// reports a closed window's element as invalid; a short timeout keeps an
    /// unresponsive application from stalling the request, and such a window
    /// is kept until it answers or ages out of the bound.
    private func forgetClosedWindows() {
        let windows = windowLock.withLock { rememberedFrames.windows }
        let closed = Set(windows.filter { key in
            AXUIElementSetMessagingTimeout(key.element, 0.25)
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(key.element, kAXRoleAttribute as CFString, &role) == .invalidUIElement
        })
        guard !closed.isEmpty else { return }
        windowLock.withLock { rememberedFrames.forget { closed.contains($0) } }
    }

    // MARK: Full screen

    /// macOS's attribute for a window's full-screen state. AppKit windows
    /// support it, but it has no `kAX…` constant in the public headers.
    private static let fullScreenAttribute = "AXFullScreen" as CFString

    /// Moves whichever window is focused into or out of full screen. A window
    /// that does not report the state, or does not let it be set, fails before
    /// anything changes.
    func toggleFocusedWindowFullScreen() throws {
        let window = try focusedWindow()
        var settable = DarwinBoolean(false)
        guard let isFullScreen = fullScreenState(of: window),
              AXUIElementIsAttributeSettable(window, Self.fullScreenAttribute, &settable) == .success,
              settable.boolValue else {
            throw PluginHostServiceError.unavailable("The focused window cannot enter or leave full screen")
        }
        let target = (isFullScreen ? kCFBooleanFalse : kCFBooleanTrue) as CFTypeRef
        guard AXUIElementSetAttributeValue(window, Self.fullScreenAttribute, target) == .success else {
            throw PluginHostServiceError.failed("The focused window did not change its full screen state")
        }
    }

    /// A frame layout would fight macOS full screen, which owns the window's
    /// frame until the window leaves it, so the layout is refused instead.
    private func refuseLayoutInFullScreen(_ window: AXUIElement) throws {
        if fullScreenState(of: window) == true {
            throw PluginHostServiceError.unavailable("The focused window is in full screen; leave full screen before choosing a layout")
        }
    }

    private func fullScreenState(of window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, Self.fullScreenAttribute, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func apply(_ frame: WindowRect, to window: AXUIElement) -> Bool {
        var origin = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else {
            return false
        }
        // Size, then position, then size again: a window moving to a smaller
        // display may clamp its size against the display it is leaving.
        return [
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent),
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position),
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        ].allSatisfy { $0 == .success }
    }

    private func focusedWindow() throws -> AXUIElement {
        guard isGranted(.accessibility) else {
            throw PluginHostServiceError.systemPermissionDenied(.accessibility)
        }
        guard let application = elementAttribute(kAXFocusedApplicationAttribute, of: AXUIElementCreateSystemWide()),
              let window = elementAttribute(kAXFocusedWindowAttribute, of: application) else {
            throw PluginHostServiceError.unavailable("No focused window")
        }
        return window
    }

    private func frame(of window: AXUIElement) throws -> WindowRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = valueAttribute(kAXPositionAttribute, of: window),
              AXValueGetValue(position, .cgPoint, &origin),
              let extent = valueAttribute(kAXSizeAttribute, of: window),
              AXValueGetValue(extent, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            throw PluginHostServiceError.unavailable("The focused window does not report its frame")
        }
        return WindowRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    private func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func valueAttribute(_ attribute: String, of element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    func writeClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        guard pasteboard.clearContents() != 0,
              pasteboard.setString(text, forType: .string) else {
            throw PluginHostServiceError.failed("Clipboard could not be updated")
        }
    }
}

/// A window's identity for remembered frames. Accessibility elements compare
/// by the window they refer to rather than by reference, so two reads of the
/// same focused window produce equal keys.
struct AXWindowKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXWindowKey, rhs: AXWindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
