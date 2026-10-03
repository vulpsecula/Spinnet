import AppKit
import ApplicationServices

/// Read-mostly Accessibility helpers the probe uses around the Host's
/// insertion: to find the window it opened, to describe the focused element,
/// and to read the result back. None of them is the Host's code path; that
/// is `AppKitPluginHostServiceProvider.insertText(_:intoApplication:)` alone.
enum AX {
    static func application(_ processIdentifier: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(processIdentifier)
        // A hung App must not stall the whole run. This applies to this
        // element only; the Host's own element keeps the system default.
        AXUIElementSetMessagingTimeout(element, 3)
        return element
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        let (error, value) = copy(element, attribute)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        let (error, value) = copy(element, attribute)
        guard error == .success, let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        let (error, value) = copy(element, attribute)
        guard error == .success else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        let (error, value) = copy(element, attribute)
        guard error == .success, let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        let (error, value) = copy(element, attribute)
        guard error == .success, let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        return (value as? NSNumber)?.boolValue
    }

    static func settable(_ element: AXUIElement, _ attribute: String) -> (AXError, Bool) {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return (error, settable.boolValue)
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }

    static func processIdentifier(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] { elements(app, kAXWindowsAttribute) }

    static func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute) }

    /// The window holding `element`: its window attribute, or the first
    /// window among its ancestors.
    static func window(containing element: AXUIElement) -> AXUIElement? {
        if role(element) == kAXWindowRole { return element }
        if let window = self.element(element, kAXWindowAttribute) { return window }
        var current = element
        for _ in 0..<64 {
            guard let parent = self.element(current, kAXParentAttribute) else { return nil }
            if role(parent) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    static func hasAncestor(_ element: AXUIElement, role wanted: String) -> Bool {
        var current = element
        for _ in 0..<64 {
            guard let parent = self.element(current, kAXParentAttribute) else { return false }
            if role(parent) == wanted { return true }
            current = parent
        }
        return false
    }

    /// Breadth-first search below `root`, bounded so a huge web page cannot
    /// stall the run.
    static func first(below root: AXUIElement, maxNodes: Int = 4000, skipping skippedRoles: Set<String> = [],
                      where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            if !CFEqual(element, root), matches(element) { return element }
            if let role = role(element), skippedRoles.contains(role), !CFEqual(element, root) { continue }
            queue.append(contentsOf: elements(element, kAXChildrenAttribute))
        }
        return nil
    }

    /// A menu item by its key equivalent, which does not depend on the
    /// system language. Modifiers 0 means Command alone.
    static func menuItem(of app: AXUIElement, commandCharacter: String, modifiers: Int = 0) -> AXUIElement? {
        guard let menuBar = element(app, kAXMenuBarAttribute) else { return nil }
        var queue = elements(menuBar, kAXChildrenAttribute)
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let item = queue.removeFirst()
            visited += 1
            if role(item) == kAXMenuItemRole,
               string(item, kAXMenuItemCmdCharAttribute)?.uppercased() == commandCharacter.uppercased(),
               (number(item, kAXMenuItemCmdModifiersAttribute) ?? 0) == modifiers,
               bool(item, kAXEnabledAttribute) != false {
                return item
            }
            queue.append(contentsOf: elements(item, kAXChildrenAttribute))
        }
        return nil
    }

    static func equal(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "kAXErrorFailure"
        case .illegalArgument: return "kAXErrorIllegalArgument"
        case .invalidUIElement: return "kAXErrorInvalidUIElement"
        case .invalidUIElementObserver: return "kAXErrorInvalidUIElementObserver"
        case .cannotComplete: return "kAXErrorCannotComplete"
        case .attributeUnsupported: return "kAXErrorAttributeUnsupported"
        case .actionUnsupported: return "kAXErrorActionUnsupported"
        case .notificationUnsupported: return "kAXErrorNotificationUnsupported"
        case .notImplemented: return "kAXErrorNotImplemented"
        case .notificationAlreadyRegistered: return "kAXErrorNotificationAlreadyRegistered"
        case .notificationNotRegistered: return "kAXErrorNotificationNotRegistered"
        case .apiDisabled: return "kAXErrorAPIDisabled"
        case .noValue: return "kAXErrorNoValue"
        case .parameterizedAttributeUnsupported: return "kAXErrorParameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "kAXErrorNotEnoughPrecision"
        @unknown default: return "AXError(\(error.rawValue))"
        }
    }
}

/// Synthetic input, used only to put the caret where a user would before
/// pressing Insert, and only into a process the probe owns or a window it
/// has just checked is its own.
enum SyntheticInput {
    static func keystroke(_ keyCode: CGKeyCode, command: Bool, to processIdentifier: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            if command { event.flags = .maskCommand }
            event.postToPid(processIdentifier)
            usleep(30_000)
        }
    }

    /// Clicks at `point` (global, top-left origin) only if the frontmost
    /// on-screen window there belongs to `processIdentifier`.
    @discardableResult
    static func click(at point: CGPoint, ifTopWindowBelongsTo processIdentifier: pid_t) -> Bool {
        guard WindowList.topWindowOwner(at: point) == processIdentifier else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(60_000)
        }
        return true
    }

    static let keyL: CGKeyCode = 0x25
    static let keyN: CGKeyCode = 0x2D
}

/// The window server's list, which needs no Accessibility query: used to
/// wait for a Chromium or Electron App without touching its accessibility
/// state before the Host does.
enum WindowList {
    struct Window {
        let ownerPID: pid_t
        let bounds: CGRect
        let layer: Int
    }

    static func onScreen() -> [Window] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return Window(ownerPID: pid, bounds: bounds, layer: entry[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    static func mainWindow(of processIdentifier: pid_t) -> Window? {
        onScreen().first { $0.ownerPID == processIdentifier && $0.layer == 0 && $0.bounds.width >= 300 && $0.bounds.height >= 200 }
    }

    static func topWindowOwner(at point: CGPoint) -> pid_t? {
        onScreen().first { $0.layer == 0 && $0.bounds.contains(point) }?.ownerPID
    }
}
