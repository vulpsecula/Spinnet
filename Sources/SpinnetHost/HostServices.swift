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

final class GlobalHotKeyController {
    private enum HotKey: UInt32 {
        case invoke = 1
    }

    private var eventHandler: EventHandlerRef?
    private var invokeHotKey: EventHotKeyRef?
    private let signature = OSType(0x53504E54) // SPNT

    var onInvoke: (() -> Void)?

    func start() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>
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

        let modifiers = UInt32(controlKey | optionKey)
        let invokeStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            EventHotKeyID(signature: signature, id: HotKey.invoke.rawValue),
            GetApplicationEventTarget(),
            0,
            &invokeHotKey
        )
        if invokeStatus != noErr {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let invokeHotKey { UnregisterEventHotKey(invokeHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        invokeHotKey = nil
        eventHandler = nil
    }

    deinit { stop() }

    private func handle(_ id: UInt32) {
        guard id == HotKey.invoke.rawValue else { return }
        onInvoke?()
    }
}
