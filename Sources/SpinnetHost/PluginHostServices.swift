import AppKit
import SpinnetCore

/// AppKit adapters for the narrow Host Services exposed to the fixture
/// Plugin. The Plugin helper never receives these objects or framework access.
final class AppKitPluginHostServiceProvider {
    private let windowLock = NSLock()
    /// The window a Plugin last read. Setting a frame applies only to it, and
    /// only while it is still focused, so a layout computed for one window is
    /// never applied to another that took focus in between.
    private var readWindow: AXUIElement?

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
        windowLock.lock()
        readWindow = window
        windowLock.unlock()
        let screens = onMain {
            NSScreen.screens.map { FocusedWindowScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        }
        guard let visibleFrame = FocusedWindowScreen.visibleFrame(for: frame, among: screens) else {
            throw PluginHostServiceError.unavailable("No display is available")
        }
        return FocusedWindow(frame: frame, visibleFrame: visibleFrame)
    }

    /// Moves the window last read, provided it is still focused. A window that
    /// refuses either half of the change fails before anything is set, a write
    /// that fails part-way restores the original frame, and no other window is
    /// tried.
    func setFocusedWindowFrame(_ frame: WindowRect) throws {
        let window = try focusedWindow()
        windowLock.lock()
        let expected = readWindow
        windowLock.unlock()
        guard let expected, CFEqual(expected, window) else {
            throw PluginHostServiceError.unavailable("The focused window changed after it was read")
        }
        let original = try self.frame(of: window)
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
