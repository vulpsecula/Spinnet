import AppKit
import Carbon
import SpinnetCore

enum HostCommandError: Error, CustomStringConvertible, LocalizedError {
    case invalidInput
    case failed(String)

    var description: String {
        switch self {
        case .invalidInput:
            return "The Action input is invalid for this Host Command"
        case .failed(let message):
            return message
        }
    }

    var errorDescription: String? { description }
}

/// The first Host Command implementation is intentionally small: the
/// production Host owns opening URLs, while the Action seam remains injectable
/// for tests and future Host Commands.
final class AppKitHostCommandExecutor: HostCommandExecutor {
    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        guard action.hostCommand == .openURL,
              case .string(let value) = action.input,
              let url = URL(string: value),
              url.scheme?.isEmpty == false else {
            throw HostCommandError.invalidInput
        }

        guard NSWorkspace.shared.open(url) else {
            throw HostCommandError.failed("The URL could not be opened")
        }
        return .object(["opened": .string(value)])
    }
}

final class AccessibilityPermissionController {
    private let isTrustedCheck: () -> Bool
    private let requestAccess: () -> Void
    private var hasRequestedThisLaunch = false

    init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        request: @escaping () -> Void = {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    ) {
        isTrustedCheck = isTrusted
        requestAccess = request
    }

    var isAuthorized: Bool { isTrustedCheck() }

    func requestOnceIfNeeded() {
        guard !isAuthorized, !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true
        requestAccess()
    }
}

final class GlobalTriggerController {
    private enum HotKey: UInt32 {
        case invoke = 1
        case escape = 2
    }

    private var eventHandler: EventHandlerRef?
    private var invokeHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapSource: CFRunLoopSource?
    private var permissionRetryTimer: Timer?
    private var mouseGestureOrigin: CGPoint?
    private var mouseGestureDidDrag = false
    private var isCapturingMouseButton = false
    private var mouseButtonCaptureHandler: ((Int) -> Void)?
    private let signature = OSType(0x53504E54) // SPNT
    private let accessibilityPermission: AccessibilityPermissionController
    private let mouseButtonStateCheck: (Int) -> Bool

    var configuration = MenuTriggerConfiguration()
    private(set) var keyboardShortcutRegistered = true
    private(set) var mouseInterceptionAvailable = false

    var onInvoke: (() -> Void)?
    var onEscape: (() -> Void)?
    var onMouseDrag: ((CGPoint) -> Void)?
    var onMouseDragRelease: ((CGPoint) -> Void)?
    var onAccessibilityPermissionChanged: ((Bool) -> Void)?

    init(
        accessibilityPermission: AccessibilityPermissionController = AccessibilityPermissionController(),
        mouseButtonStateCheck: @escaping (Int) -> Bool = { buttonNumber in
            guard buttonNumber >= 0, buttonNumber < Int.bitWidth else { return false }
            let buttonMask = Int(1) << buttonNumber
            if NSEvent.pressedMouseButtons & buttonMask != 0 {
                return true
            }
            guard let button = CGMouseButton(rawValue: UInt32(buttonNumber)) else { return false }
            return CGEventSource.buttonState(
                .hidSystemState,
                button: button
            )
        }
    ) {
        self.accessibilityPermission = accessibilityPermission
        self.mouseButtonStateCheck = mouseButtonStateCheck
    }

    func start(configuration: MenuTriggerConfiguration) -> Bool {
        stop()
        self.configuration = configuration
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalTriggerController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                var identifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard parameterStatus == noErr else { return parameterStatus }
                controller.handle(identifier.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { return false }

        mouseInterceptionAvailable = installMouseEventTap()
        onAccessibilityPermissionChanged?(accessibilityPermission.isAuthorized)
        if !mouseInterceptionAvailable {
            accessibilityPermission.requestOnceIfNeeded()
            schedulePermissionRetry()
        }

        keyboardShortcutRegistered = registerInvokeShortcut()
        return true
    }

    func apply(_ configuration: MenuTriggerConfiguration) -> Bool {
        self.configuration = configuration
        mouseGestureOrigin = nil
        mouseGestureDidDrag = false
        if let invokeHotKey {
            UnregisterEventHotKey(invokeHotKey)
            self.invokeHotKey = nil
        }
        keyboardShortcutRegistered = registerInvokeShortcut()
        return keyboardShortcutRegistered
    }

    @discardableResult
    func handleMouseButton(_ buttonNumber: Int) -> Bool {
        guard buttonNumber == configuration.mouseButton else { return false }
        onInvoke?()
        return true
    }

    func interceptMouseEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let mouseEventTap { CGEvent.tapEnable(tap: mouseEventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved
                || type == .otherMouseDown
                || type == .otherMouseUp
                || type == .otherMouseDragged else {
            return Unmanaged.passUnretained(event)
        }
        if isCapturingMouseButton, type == .otherMouseDown {
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard MouseTriggerButton.isSupported(buttonNumber) else {
                return Unmanaged.passUnretained(event)
            }
            let captureHandler = mouseButtonCaptureHandler
            isCapturingMouseButton = false
            mouseButtonCaptureHandler = nil
            captureHandler?(buttonNumber)
            return nil
        }
        if isCapturingMouseButton {
            return Unmanaged.passUnretained(event)
        }

        if type == .mouseMoved || type == .otherMouseDragged {
            let gestureWasTracked = trackMouseGestureMotion(event)
            if type == .mouseMoved {
                return Unmanaged.passUnretained(event)
            }
            if gestureWasTracked {
                return nil
            }
        }

        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard buttonNumber == configuration.mouseButton else {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .otherMouseDown:
            guard mouseGestureOrigin == nil else { return nil }
            mouseGestureOrigin = event.location
            mouseGestureDidDrag = false
            onInvoke?()
        case .otherMouseDragged:
            _ = trackMouseGestureMotion(event)
        case .otherMouseUp:
            if configuration.clickDragEnabled, mouseGestureDidDrag {
                onMouseDragRelease?(appKitScreenLocation(for: event))
            }
            mouseGestureOrigin = nil
            mouseGestureDidDrag = false
        default:
            break
        }
        return nil
    }

    @discardableResult
    private func trackMouseGestureMotion(_ event: CGEvent) -> Bool {
        guard configuration.clickDragEnabled else { return false }
        if mouseGestureOrigin == nil,
           configuration.mouseButton >= 3,
           mouseButtonStateCheck(configuration.mouseButton) {
            mouseGestureOrigin = event.location
            mouseGestureDidDrag = false
            onInvoke?()
            return true
        }
        guard let origin = mouseGestureOrigin else { return false }
        let distance = hypot(event.location.x - origin.x, event.location.y - origin.y)
        guard distance >= 8 else { return true }
        mouseGestureDidDrag = true
        onMouseDrag?(appKitScreenLocation(for: event))
        return true
    }

    private func appKitScreenLocation(for event: CGEvent) -> CGPoint {
        NSEvent(cgEvent: event)?.locationInWindow ?? NSEvent.mouseLocation
    }

    func setMouseButtonCaptureActive(
        _ isActive: Bool,
        onCapture: ((Int) -> Void)? = nil
    ) {
        isCapturingMouseButton = isActive
        mouseButtonCaptureHandler = isActive ? onCapture : nil
        mouseGestureOrigin = nil
        mouseGestureDidDrag = false
    }

    func retryMouseInterceptionIfAuthorized() {
        guard !mouseInterceptionAvailable, accessibilityPermission.isAuthorized else { return }
        mouseInterceptionAvailable = installMouseEventTap()
        onAccessibilityPermissionChanged?(accessibilityPermission.isAuthorized)
        if mouseInterceptionAvailable {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
        }
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.retryMouseInterceptionIfAuthorized()
        }
    }

    private func installMouseEventTap() -> Bool {
        let eventMask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<GlobalTriggerController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return controller.interceptMouseEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseEventTap = tap
        mouseEventTapSource = source
        return true
    }

    private func registerInvokeShortcut() -> Bool {
        guard let shortcut = configuration.keyboardShortcut else { return true }

        let invokeStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: signature, id: HotKey.invoke.rawValue),
            GetApplicationEventTarget(),
            0,
            &invokeHotKey
        )
        if invokeStatus != noErr {
            return false
        }
        return true
    }

    func registerEscape() -> Bool {
        guard escapeHotKey == nil else { return true }
        return RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: signature, id: HotKey.escape.rawValue),
            GetApplicationEventTarget(),
            0,
            &escapeHotKey
        ) == noErr
    }

    func unregisterEscape() {
        guard let escapeHotKey else { return }
        UnregisterEventHotKey(escapeHotKey)
        self.escapeHotKey = nil
    }

    func stop() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        unregisterEscape()
        if let invokeHotKey { UnregisterEventHotKey(invokeHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let mouseEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseEventTapSource, .commonModes)
        }
        if let mouseEventTap { CFMachPortInvalidate(mouseEventTap) }
        invokeHotKey = nil
        eventHandler = nil
        mouseEventTap = nil
        mouseEventTapSource = nil
        keyboardShortcutRegistered = true
        mouseInterceptionAvailable = false
        mouseGestureOrigin = nil
        mouseGestureDidDrag = false
        isCapturingMouseButton = false
        mouseButtonCaptureHandler = nil
    }

    deinit { stop() }

    private func handle(_ id: UInt32) {
        guard let hotKey = HotKey(rawValue: id) else { return }
        switch hotKey {
        case .invoke: onInvoke?()
        case .escape: onEscape?()
        }
    }
}
