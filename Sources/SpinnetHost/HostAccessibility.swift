import AppKit

/// Own-process AX messages can synchronously enter AppKit. Keep native I/O
/// behind one Host-internal adapter so callers do not duplicate thread policy.
struct HostAccessibility {
    struct Native {
        var trusted: () -> Bool = AXIsProcessTrusted
        var systemWide = AXUIElementCreateSystemWide()
        var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var processIdentifier: (AXUIElement) -> pid_t? = { element in
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }
        var copy: (AXUIElement, CFString) -> (AXError, CFTypeRef?) = { element, attribute in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            return (error, value)
        }
        var settable: (AXUIElement, CFString) -> (AXError, Bool) = { element, attribute in
            var value = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(element, attribute, &value)
            return (error, value.boolValue)
        }
        var set: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue
        var timeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout
        var count: (AXUIElement, CFString) -> (AXError, CFIndex) = { element, attribute in
            var count: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, attribute, &count)
            return (error, count)
        }
        var values: (AXUIElement, CFString, CFIndex) -> (AXError, CFArray?) = { element, attribute, count in
            var values: CFArray?
            let error = AXUIElementCopyAttributeValues(element, attribute, 0, count, &values)
            return (error, values)
        }
        var multiple: (AXUIElement, CFArray) -> (AXError, CFArray?) = { element, attributes in
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(), &values)
            return (error, values)
        }
        var action: (AXUIElement, CFString) -> AXError = AXUIElementPerformAction
    }

    let native: Native
    init(native: Native = .init()) { self.native = native }

    private func perform<Value>(_ element: AXUIElement, unavailable: Value, _ work: () -> Value) -> Value {
        // Only this exact server element is exempt. Elements returned by a
        // focus query are classified again before any native callback.
        if CFEqual(element, native.systemWide) { return work() }
        // GetPid reads address metadata; it does not invoke AX attributes.
        guard let pid = native.processIdentifier(element), pid > 0 else { return unavailable }
        guard pid == ProcessInfo.processInfo.processIdentifier else { return work() }
        // Never call while holding a caller's lock or synchronously waiting
        // on this worker from main. Existing main calls execute inline.
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
    func copy(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        perform(element, unavailable: (.invalidUIElement, nil)) { native.copy(element, attribute) }
    }
    func settable(_ element: AXUIElement, _ attribute: CFString) -> (AXError, Bool) {
        perform(element, unavailable: (.invalidUIElement, false)) { native.settable(element, attribute) }
    }
    func set(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        perform(element, unavailable: .invalidUIElement) { native.set(element, attribute, value) }
    }
    func timeout(_ element: AXUIElement, _ timeout: Float) -> AXError {
        perform(element, unavailable: .invalidUIElement) { native.timeout(element, timeout) }
    }
    func count(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFIndex) {
        perform(element, unavailable: (.invalidUIElement, 0)) { native.count(element, attribute) }
    }
    func values(_ element: AXUIElement, _ attribute: CFString, _ count: CFIndex) -> (AXError, CFArray?) {
        perform(element, unavailable: (.invalidUIElement, nil)) { native.values(element, attribute, count) }
    }
    func multiple(_ element: AXUIElement, _ attributes: CFArray) -> (AXError, CFArray?) {
        perform(element, unavailable: (.invalidUIElement, nil)) { native.multiple(element, attributes) }
    }
    func action(_ element: AXUIElement, _ action: CFString) -> AXError {
        perform(element, unavailable: .invalidUIElement) { native.action(element, action) }
    }
}
