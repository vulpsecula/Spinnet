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

final class GlobalTriggerController {
    private enum HotKey: UInt32 {
        case invoke = 1
        case escape = 2
    }

    private var eventHandler: EventHandlerRef?
    private var invokeHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private let signature = OSType(0x53504E54) // SPNT

    var configuration = MenuTriggerConfiguration()
    private(set) var keyboardShortcutRegistered = true

    var onInvoke: (() -> Void)?
    var onEscape: (() -> Void)?

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

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            _ = self?.handleMouseButton(event.buttonNumber)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) {
            [weak self] event in
            self?.handleMouseButton(event.buttonNumber) == true ? nil : event
        }

        keyboardShortcutRegistered = registerInvokeShortcut()
        return true
    }

    func apply(_ configuration: MenuTriggerConfiguration) -> Bool {
        let escapeWasRegistered = escapeHotKey != nil
        let started = start(configuration: configuration)
        if escapeWasRegistered { _ = registerEscape() }
        return started && keyboardShortcutRegistered
    }

    @discardableResult
    func handleMouseButton(_ buttonNumber: Int) -> Bool {
        guard buttonNumber == configuration.mouseButton else { return false }
        onInvoke?()
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
        unregisterEscape()
        if let invokeHotKey { UnregisterEventHotKey(invokeHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        invokeHotKey = nil
        eventHandler = nil
        globalMouseMonitor = nil
        localMouseMonitor = nil
        keyboardShortcutRegistered = true
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
