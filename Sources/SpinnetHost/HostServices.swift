import AppKit
import Carbon
import Darwin
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

/// The adapter boundary keeps real macOS integrations out of automated tests.
/// Each method represents one documented Host Command operation and returns
/// whether the external request was accepted by the system.
protocol HostCommandAdapter {
    func openApplication(_ value: String) -> Bool
    func openFile(_ path: String) -> Bool
    func openFolder(_ path: String) -> Bool
    func openURL(_ url: URL) -> Bool
    func invokeKeyboardShortcut(_ shortcut: HostKeyboardShortcut) -> Bool
    func invokeService(name: String, input: String?) -> Bool
    func invokeShortcut(name: String, input: String?) -> Bool
    func copyText(_ text: String) -> Bool
    func pasteText() -> Bool
    func cutText() -> Bool
}

struct HostKeyboardShortcut: Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt64
}

/// AppKit and Carbon implementation of the common Host Command adapters.
/// Plugins never receive this object or the framework handles it owns.
final class AppKitHostCommandAdapter: HostCommandAdapter {
    private static let shortcutExecutionTimeout: TimeInterval = 4

    func openApplication(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if looksLikePath(trimmed) {
            let url = fileURL(for: trimmed)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            return NSWorkspace.shared.open(url)
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    func openFile(_ path: String) -> Bool {
        let url = fileURL(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return NSWorkspace.shared.open(url)
    }

    func openFolder(_ path: String) -> Bool {
        let url = fileURL(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return NSWorkspace.shared.open(url)
    }

    func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func invokeKeyboardShortcut(_ shortcut: HostKeyboardShortcut) -> Bool {
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: false
        ) else { return false }

        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func invokeService(name: String, input: String?) -> Bool {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        if let input {
            guard pasteboard.setString(input, forType: .string) else { return false }
        }
        return NSPerformService(name, pasteboard)
    }

    func invokeShortcut(name: String, input: String?) -> Bool {
        // The URL scheme only reports that the Shortcuts app accepted the
        // request. The public command-line interface waits for the Shortcut
        // to run and returns a failure for an unknown name or failed action.
        let inputURL: URL?
        if let input {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("spinnet-shortcut-input-\(UUID().uuidString).txt")
            do {
                try Data(input.utf8).write(to: url, options: .atomic)
            } catch {
                return false
            }
            inputURL = url
        } else {
            inputURL = nil
        }
        defer {
            if let inputURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name] + (inputURL.map { ["--input-path", $0.path] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let deadline = Date(timeIntervalSinceNow: Self.shortcutExecutionTimeout)
            while process.isRunning {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    return false
                }
                Thread.sleep(forTimeInterval: min(0.01, remaining))
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func copyText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        guard pasteboard.clearContents() != 0 else { return false }
        return pasteboard.setString(text, forType: .string)
    }

    func pasteText() -> Bool {
        invokeKeyboardShortcut(Self.commandShortcut(for: UInt16(kVK_ANSI_V)))
    }

    func cutText() -> Bool {
        invokeKeyboardShortcut(Self.commandShortcut(for: UInt16(kVK_ANSI_X)))
    }

    private static func commandShortcut(for keyCode: UInt16) -> HostKeyboardShortcut {
        HostKeyboardShortcut(
            keyCode: keyCode,
            modifiers: UInt64(CGEventFlags.maskCommand.rawValue)
        )
    }

    private func fileURL(for path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~") || value.contains("/") || value.hasSuffix(".app")
    }
}

/// The Host-level executor validates and authorizes a Command before handing
/// it to an external adapter. Contextual execution is used by the registry
/// path so a Plugin cannot bypass its current Capability decision.
final class AppKitHostCommandExecutor: ContextualHostCommandExecutor {
    private let adapter: HostCommandAdapter
    private let grantStore: PluginCapabilityGrantStore?
    private let systemPermissionCheck: (PluginSystemPermission) -> Bool
    private let selectedTextProvider: (() throws -> String)?
    private let feedbackPresenter: (String) -> Void
    /// The capture Host Service, shared with Plugins that ask for a capture:
    /// it applies the Screenshots settings to the source it is given.
    private let screenCapture: (ScreenCaptureSource) throws -> Void

    init(
        adapter: HostCommandAdapter = AppKitHostCommandAdapter(),
        grantStore: PluginCapabilityGrantStore? = nil,
        systemPermissionCheck: @escaping (PluginSystemPermission) -> Bool = { permission in
            switch permission {
            case .accessibility:
                return AXIsProcessTrusted()
            case .screenRecording:
                return CGPreflightScreenCaptureAccess()
            }
        },
        selectedTextProvider: (() throws -> String)? = nil,
        feedbackPresenter: @escaping (String) -> Void = { _ in },
        screenCapture: @escaping (ScreenCaptureSource) throws -> Void = { _ in
            throw PluginHostServiceError.unavailable("Screen capture")
        }
    ) {
        self.adapter = adapter
        self.grantStore = grantStore
        self.systemPermissionCheck = systemPermissionCheck
        self.selectedTextProvider = selectedTextProvider
        self.feedbackPresenter = feedbackPresenter
        self.screenCapture = screenCapture
    }

    func execute(_ action: ActionConfiguration) throws -> JSONValue {
        try execute(action, package: nil)
    }

    func execute(_ action: ActionConfiguration, in package: PluginPackage) throws -> JSONValue {
        try execute(action, package: package)
    }

    private func execute(
        _ action: ActionConfiguration,
        package: PluginPackage?
    ) throws -> JSONValue {
        guard action.execution == .host,
              let command = action.hostCommand else {
            throw HostCommandExecutionError.invalidInput("Action does not contain a Host Command")
        }

        if let package {
            guard package.manifest.id == action.pluginID,
                  let declared = package.manifest.commands.first(where: { $0.id == action.commandID }),
                  declared.matchesExecutableDefinition(action.declaredCommand) else {
                throw HostCommandExecutionError.unavailable("Command is no longer registered")
            }
        }

        try authorize(action, package: package)
        guard command.isValidInput(action.input) else {
            throw HostCommandExecutionError.invalidInput(
                "Input is invalid for \(command.rawValue)"
            )
        }

        switch command {
        case .openURL:
            guard let url = command.resolvedURL(from: action.input),
                  let value = stringValue(from: action.input, keys: ["url"]) else {
                throw HostCommandExecutionError.invalidInput("Expected a URL string")
            }
            guard adapter.openURL(url) else {
                throw HostCommandExecutionError.failed("The URL could not be opened")
            }
            return .object(["opened": .string(value)])
        case .openApplication:
            let value = try requiredString(
                from: action.input,
                keys: ["path", "bundle_id", "bundle_identifier", "bundleIdentifier"],
                description: "an application path or bundle identifier"
            )
            guard adapter.openApplication(value) else {
                throw HostCommandExecutionError.unavailable("The application is not available")
            }
            return .object(["opened": .string(value)])
        case .openFile:
            let path = try requiredString(
                from: action.input,
                keys: ["path"],
                description: "a file path"
            )
            guard adapter.openFile(path) else {
                throw HostCommandExecutionError.unavailable("The file is not available")
            }
            return .object(["opened": .string(path)])
        case .openFolder:
            let path = try requiredString(
                from: action.input,
                keys: ["path"],
                description: "a folder path"
            )
            guard adapter.openFolder(path) else {
                throw HostCommandExecutionError.unavailable("The folder is not available")
            }
            return .object(["opened": .string(path)])
        case .invokeKeyboardShortcut:
            let shortcut = try parseKeyboardShortcut(action.input)
            guard adapter.invokeKeyboardShortcut(shortcut) else {
                throw HostCommandExecutionError.failed("The keyboard shortcut could not be sent")
            }
            return .object(["posted": .bool(true)])
        case .invokeService:
            let request = try namedRequest(
                from: action.input,
                primaryKey: "service",
                description: "a macOS Service name"
            )
            guard adapter.invokeService(name: request.name, input: request.input) else {
                throw HostCommandExecutionError.failed("The macOS Service could not be invoked")
            }
            return .object(["invoked": .string(request.name)])
        case .invokeShortcut:
            let request = try namedRequest(
                from: action.input,
                primaryKey: "shortcut",
                description: "a Shortcut name"
            )
            guard adapter.invokeShortcut(name: request.name, input: request.input) else {
                throw HostCommandExecutionError.failed("The Shortcut could not be invoked")
            }
            return .object(["invoked": .string(request.name)])
        case .copyText:
            let text: String
            if action.input == .null {
                guard let selectedTextProvider else {
                    throw HostCommandExecutionError.unavailable(
                        "Selected text is unavailable from the Host"
                    )
                }
                text = try selectedTextProvider()
            } else {
                text = try requiredString(
                    from: action.input,
                    keys: ["text"],
                    description: "text to copy",
                    allowEmpty: true
                )
            }
            guard adapter.copyText(text) else {
                throw HostCommandExecutionError.failed("The clipboard could not be updated")
            }
            return .object(["copied": .string(text)])
        case .pasteText:
            guard adapter.pasteText() else {
                throw HostCommandExecutionError.failed("The clipboard could not be pasted")
            }
            return .object(["pasted": .bool(true)])
        case .cutText:
            guard adapter.cutText() else {
                throw HostCommandExecutionError.failed("The selection could not be cut")
            }
            return .object(["cut": .bool(true)])
        case .presentFeedback:
            let message = try requiredString(
                from: action.input,
                keys: ["message", "text"],
                description: "a feedback message"
            )
            feedbackPresenter(message)
            return .object(["presented": .string(message)])
        case .captureArea, .captureFullScreen, .captureWindow:
            guard let source = command.captureSource else {
                throw HostCommandExecutionError.invalidInput("Not a capture Host Command")
            }
            // Starting the capture is the Action; the user finishes or
            // cancels it on screen afterwards.
            do {
                try screenCapture(source)
            } catch PluginHostServiceError.unavailable(let reason) {
                throw HostCommandExecutionError.unavailable(reason)
            } catch PluginHostServiceError.failed(let reason) {
                throw HostCommandExecutionError.failed(reason)
            }
            return .null
        }
    }

    private func authorize(_ action: ActionConfiguration, package: PluginPackage?) throws {
        let required = package?.manifest.requiredCapabilities(for: action.declaredCommand, input: action.input)
            ?? action.hostCommand?.requiredCapability.map { [$0] } ?? []
        for capability in required {
            guard let package, package.manifest.declares(capability, for: action.commandID),
                  let grantStore,
                  grantStore.decision(for: package.manifest.id, pluginVersion: package.manifest.version,
                                      capability: capability, scope: package.manifest.scope(for: capability)) == .granted else {
                throw HostCommandExecutionError.capabilityDenied(capability)
            }
            guard capability.isSupportedByHostServices else {
                throw HostCommandExecutionError.unavailable("Required Host Service is not available in this version")
            }
        }
        let permissions = package?.manifest.requiredSystemPermissions(for: action.declaredCommand, input: action.input)
            ?? action.hostCommand?.requiredSystemPermission.map { [$0] } ?? []
        for permission in permissions where !systemPermissionCheck(permission) {
            throw HostCommandExecutionError.systemPermissionDenied(permission)
        }
    }

    private func requiredString(
        from input: JSONValue,
        keys: [String],
        description: String,
        allowEmpty: Bool = false
    ) throws -> String {
        if allowEmpty {
            switch input {
            case .string(let value):
                return value
            case .object(let values):
                for key in keys {
                    if case .string(let value) = values[key] { return value }
                }
            default:
                break
            }
        }
        guard let value = stringValue(from: input, keys: keys) else {
            throw HostCommandExecutionError.invalidInput("Expected \(description)")
        }
        return value
    }

    private func namedRequest(
        from input: JSONValue,
        primaryKey: String,
        description: String
    ) throws -> (name: String, input: String?) {
        switch input {
        case .string(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostCommandExecutionError.invalidInput("Expected \(description)")
            }
            return (name, nil)
        case .object(let values):
            guard let name = stringValue(from: input, keys: ["name", primaryKey]) else {
                throw HostCommandExecutionError.invalidInput("Expected \(description)")
            }
            let payload: String?
            if let rawPayload = values["input"] ?? values["text"] {
                guard case .string(let value) = rawPayload else {
                    throw HostCommandExecutionError.invalidInput("Expected text input for \(description)")
                }
                payload = value
            } else {
                payload = nil
            }
            return (name, payload)
        default:
            throw HostCommandExecutionError.invalidInput("Expected \(description)")
        }
    }

    private func parseKeyboardShortcut(_ input: JSONValue) throws -> HostKeyboardShortcut {
        switch input {
        case .string(let value):
            return try parseKeyboardShortcutString(value)
        case .object(let values):
            let parsedKeyCode: UInt16
            if case .number(let rawKeyCode) = values["key_code"],
               rawKeyCode.isFinite,
               rawKeyCode.rounded() == rawKeyCode,
               (0...127).contains(rawKeyCode) {
                parsedKeyCode = UInt16(rawKeyCode)
            } else if let key = stringValue(from: input, keys: ["key", "character"]) {
                parsedKeyCode = try keyCode(for: key)
            } else {
                throw HostCommandExecutionError.invalidInput("Expected a key or key_code")
            }
            let modifiers = try parseModifiers(values["modifiers"] ?? values["modifier_flags"])
            return HostKeyboardShortcut(keyCode: parsedKeyCode, modifiers: modifiers)
        default:
            throw HostCommandExecutionError.invalidInput("Expected a keyboard shortcut")
        }
    }

    private func parseKeyboardShortcutString(_ value: String) throws -> HostKeyboardShortcut {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HostCommandExecutionError.invalidInput("Expected a keyboard shortcut")
        }
        var modifiers: UInt64 = 0
        var key = trimmed
        let symbols: [(String, UInt64)] = [
            ("⌘", UInt64(CGEventFlags.maskCommand.rawValue)),
            ("⇧", UInt64(CGEventFlags.maskShift.rawValue)),
            ("⌥", UInt64(CGEventFlags.maskAlternate.rawValue)),
            ("⌃", UInt64(CGEventFlags.maskControl.rawValue))
        ]
        for (symbol, flag) in symbols where key.contains(symbol) {
            modifiers |= flag
            key = key.replacingOccurrences(of: symbol, with: "")
        }
        let parts = key.split(separator: "+", omittingEmptySubsequences: true)
        if parts.count > 1 {
            key = String(parts.last!)
            for modifier in parts.dropLast() {
                modifiers |= try parseModifier(String(modifier))
            }
        }
        return HostKeyboardShortcut(
            keyCode: try keyCode(for: key),
            modifiers: modifiers
        )
    }

    private func parseModifiers(_ input: JSONValue?) throws -> UInt64 {
        guard let input else { return 0 }
        switch input {
        case .number(let value):
            guard let modifiers = UInt64(exactly: value) else {
                throw HostCommandExecutionError.invalidInput("Keyboard modifiers are invalid")
            }
            return modifiers
        case .string(let value):
            return try value.split(separator: "+").reduce(into: UInt64(0)) { result, part in
                result |= try parseModifier(String(part))
            }
        case .array(let values):
            return try values.reduce(into: UInt64(0)) { result, value in
                guard case .string(let modifier) = value else {
                    throw HostCommandExecutionError.invalidInput("Keyboard modifiers are invalid")
                }
                result |= try parseModifier(modifier)
            }
        default:
            throw HostCommandExecutionError.invalidInput("Keyboard modifiers are invalid")
        }
    }

    private func parseModifier(_ value: String) throws -> UInt64 {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "⌘":
            return UInt64(CGEventFlags.maskCommand.rawValue)
        case "shift", "⇧":
            return UInt64(CGEventFlags.maskShift.rawValue)
        case "option", "opt", "alt", "⌥":
            return UInt64(CGEventFlags.maskAlternate.rawValue)
        case "control", "ctrl", "⌃":
            return UInt64(CGEventFlags.maskControl.rawValue)
        case "function", "fn":
            return UInt64(CGEventFlags.maskSecondaryFn.rawValue)
        case "caps_lock", "caps lock":
            return UInt64(CGEventFlags.maskAlphaShift.rawValue)
        default:
            throw HostCommandExecutionError.invalidInput("Unknown keyboard modifier \(value)")
        }
    }

    private func keyCode(for value: String) throws -> UInt16 {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let alphaNumeric: [String: UInt16] = [
            "A": UInt16(kVK_ANSI_A), "B": UInt16(kVK_ANSI_B),
            "C": UInt16(kVK_ANSI_C), "D": UInt16(kVK_ANSI_D),
            "E": UInt16(kVK_ANSI_E), "F": UInt16(kVK_ANSI_F),
            "G": UInt16(kVK_ANSI_G), "H": UInt16(kVK_ANSI_H),
            "I": UInt16(kVK_ANSI_I), "J": UInt16(kVK_ANSI_J),
            "K": UInt16(kVK_ANSI_K), "L": UInt16(kVK_ANSI_L),
            "M": UInt16(kVK_ANSI_M), "N": UInt16(kVK_ANSI_N),
            "O": UInt16(kVK_ANSI_O), "P": UInt16(kVK_ANSI_P),
            "Q": UInt16(kVK_ANSI_Q), "R": UInt16(kVK_ANSI_R),
            "S": UInt16(kVK_ANSI_S), "T": UInt16(kVK_ANSI_T),
            "U": UInt16(kVK_ANSI_U), "V": UInt16(kVK_ANSI_V),
            "W": UInt16(kVK_ANSI_W), "X": UInt16(kVK_ANSI_X),
            "Y": UInt16(kVK_ANSI_Y), "Z": UInt16(kVK_ANSI_Z),
            "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1),
            "2": UInt16(kVK_ANSI_2), "3": UInt16(kVK_ANSI_3),
            "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
            "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7),
            "8": UInt16(kVK_ANSI_8), "9": UInt16(kVK_ANSI_9)
        ]
        if let code = alphaNumeric[key] { return code }
        let named: [String: UInt16] = [
            "RETURN": UInt16(kVK_Return),
            "ENTER": UInt16(kVK_Return),
            "ESCAPE": UInt16(kVK_Escape),
            "ESC": UInt16(kVK_Escape),
            "TAB": UInt16(kVK_Tab),
            "SPACE": UInt16(kVK_Space),
            "DELETE": UInt16(kVK_Delete),
            "BACKSPACE": UInt16(kVK_Delete),
            "LEFT": UInt16(kVK_LeftArrow),
            "RIGHT": UInt16(kVK_RightArrow),
            "UP": UInt16(kVK_UpArrow),
            "DOWN": UInt16(kVK_DownArrow)
        ]
        if let code = named[key] { return code }
        let functionKeys: [String: UInt16] = [
            "F1": UInt16(kVK_F1), "F2": UInt16(kVK_F2),
            "F3": UInt16(kVK_F3), "F4": UInt16(kVK_F4),
            "F5": UInt16(kVK_F5), "F6": UInt16(kVK_F6),
            "F7": UInt16(kVK_F7), "F8": UInt16(kVK_F8),
            "F9": UInt16(kVK_F9), "F10": UInt16(kVK_F10),
            "F11": UInt16(kVK_F11), "F12": UInt16(kVK_F12),
            "F13": UInt16(kVK_F13), "F14": UInt16(kVK_F14),
            "F15": UInt16(kVK_F15), "F16": UInt16(kVK_F16),
            "F17": UInt16(kVK_F17), "F18": UInt16(kVK_F18),
            "F19": UInt16(kVK_F19), "F20": UInt16(kVK_F20)
        ]
        if let code = functionKeys[key] { return code }
        throw HostCommandExecutionError.invalidInput("Unknown keyboard key \(value)")
    }

    private func stringValue(from input: JSONValue, keys: [String]) -> String? {
        switch input {
        case .string(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        case .object(let values):
            for key in keys {
                if case .string(let value) = values[key],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return nil
        default:
            return nil
        }
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
    /// False once stopped. A stopped controller installs nothing, so a
    /// permission retry or a trigger edit cannot bring listening back while
    /// Spinnet is switched off.
    private(set) var isRunning = false

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
        isRunning = true

        mouseInterceptionAvailable = installMouseEventTap()
        onAccessibilityPermissionChanged?(accessibilityPermission.isAuthorized)
        if !mouseInterceptionAvailable {
            // Do not trigger a macOS prompt during launch. The Settings
            // permission guide is the explicit user action that opens the
            // Accessibility pane, so users can skip it and still use any
            // permission-free Menu Actions.
            schedulePermissionRetry()
        }

        keyboardShortcutRegistered = registerInvokeShortcut()
        return true
    }

    func apply(_ configuration: MenuTriggerConfiguration) -> Bool {
        self.configuration = configuration
        guard isRunning else { return true }
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
        guard isRunning, !mouseInterceptionAvailable, accessibilityPermission.isAuthorized else { return }
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
        isRunning = false
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
