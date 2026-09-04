import AppKit
import Carbon

struct MenuKeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayValue: String

    init(keyCode: UInt32, modifiers: UInt32, displayValue: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayValue = displayValue
    }

    init?(event: NSEvent) {
        var carbonModifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        guard carbonModifiers != 0,
              let key = event.charactersIgnoringModifiers?.uppercased(),
              !key.isEmpty else { return nil }

        keyCode = UInt32(event.keyCode)
        modifiers = carbonModifiers
        displayValue = Self.modifierSymbols(for: flags) + Self.displayKey(key, keyCode: event.keyCode)
    }

    private static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    private static func displayKey(_ key: String, keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return key
        }
    }
}

struct MenuTriggerConfiguration: Equatable {
    static let defaultMouseButton = 3

    var mouseButton: Int
    var clickDragEnabled: Bool
    var keyboardShortcut: MenuKeyboardShortcut?

    init(
        mouseButton: Int = defaultMouseButton,
        clickDragEnabled: Bool = false,
        keyboardShortcut: MenuKeyboardShortcut? = nil
    ) {
        self.mouseButton = mouseButton
        self.clickDragEnabled = clickDragEnabled
        self.keyboardShortcut = keyboardShortcut
    }

    init(defaults: UserDefaults) {
        if defaults.object(forKey: Keys.mouseButton) == nil {
            mouseButton = Self.defaultMouseButton
        } else {
            mouseButton = defaults.integer(forKey: Keys.mouseButton)
        }
        clickDragEnabled = defaults.bool(forKey: Keys.clickDragEnabled)
        keyboardShortcut = defaults.data(forKey: Keys.keyboardShortcut)
            .flatMap { try? JSONDecoder().decode(MenuKeyboardShortcut.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(mouseButton, forKey: Keys.mouseButton)
        defaults.set(clickDragEnabled, forKey: Keys.clickDragEnabled)
        if let keyboardShortcut,
           let data = try? JSONEncoder().encode(keyboardShortcut) {
            defaults.set(data, forKey: Keys.keyboardShortcut)
        } else {
            defaults.removeObject(forKey: Keys.keyboardShortcut)
        }
    }

    private enum Keys {
        static let mouseButton = "trigger.mouse-button"
        static let clickDragEnabled = "trigger.click-drag-enabled"
        static let keyboardShortcut = "trigger.keyboard-shortcut"
    }
}

enum MouseTriggerButton {
    static func isSupported(_ buttonNumber: Int) -> Bool {
        buttonNumber >= 2
    }

    static func displayName(for buttonNumber: Int) -> String {
        switch buttonNumber {
        case 2: return "Middle Button"
        case 3: return "Side Button 1"
        case 4: return "Side Button 2"
        default: return "Mouse Button \(buttonNumber + 1)"
        }
    }
}
