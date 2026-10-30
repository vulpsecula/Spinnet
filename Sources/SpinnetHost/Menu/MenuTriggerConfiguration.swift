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

    /// Parses the compact notation shown in the manual editor. Keeping this
    /// parser beside the recorded representation means a manually entered
    /// shortcut follows the same key-code and modifier rules as a captured
    /// event, without depending on the active keyboard layout.
    init?(manualText value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var key = trimmed
        var modifiers: UInt32 = 0
        for (symbol, modifier) in Self.symbolModifiers where key.contains(symbol) {
            modifiers |= modifier
            key = key.replacingOccurrences(of: symbol, with: "")
        }

        let parts = key.split(separator: "+", omittingEmptySubsequences: true)
        if parts.count > 1 {
            key = String(parts.last!)
            for part in parts.dropLast() {
                guard let modifier = Self.namedModifier(String(part)) else { return nil }
                modifiers |= modifier
            }
        }

        guard modifiers != 0,
              let keyCode = Self.keyCode(for: key) else { return nil }
        self.init(
            keyCode: UInt32(keyCode),
            modifiers: modifiers,
            displayValue: Self.modifierSymbols(for: modifiers)
                + Self.displayKey(key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), keyCode: keyCode)
        )
    }

    init?(event: NSEvent) {
        var carbonModifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        guard carbonModifiers != 0 else { return nil }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        let displayKey = Self.displayKey(key, keyCode: event.keyCode)
        guard !displayKey.isEmpty else { return nil }

        keyCode = UInt32(event.keyCode)
        modifiers = carbonModifiers
        displayValue = Self.modifierSymbols(for: flags) + displayKey
    }

    private static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    private static func modifierSymbols(for modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    private static let symbolModifiers: [(String, UInt32)] = [
        ("⌘", UInt32(cmdKey)),
        ("⇧", UInt32(shiftKey)),
        ("⌥", UInt32(optionKey)),
        ("⌃", UInt32(controlKey))
    ]

    private static func namedModifier(_ value: String) -> UInt32? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "⌘": return UInt32(cmdKey)
        case "shift", "⇧": return UInt32(shiftKey)
        case "option", "opt", "alt", "⌥": return UInt32(optionKey)
        case "control", "ctrl", "⌃": return UInt32(controlKey)
        default: return nil
        }
    }

    private static func keyCode(for value: String) -> UInt16? {
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
            "8": UInt16(kVK_ANSI_8), "9": UInt16(kVK_ANSI_9),
            "-": UInt16(kVK_ANSI_Minus), "=": UInt16(kVK_ANSI_Equal),
            "[": UInt16(kVK_ANSI_LeftBracket), "]": UInt16(kVK_ANSI_RightBracket),
            "\\": UInt16(kVK_ANSI_Backslash), ";": UInt16(kVK_ANSI_Semicolon),
            "'": UInt16(kVK_ANSI_Quote), ",": UInt16(kVK_ANSI_Comma),
            ".": UInt16(kVK_ANSI_Period), "/": UInt16(kVK_ANSI_Slash),
            "`": UInt16(kVK_ANSI_Grave)
        ]
        if let code = alphaNumeric[key] { return code }

        switch key {
        case "RETURN", "ENTER": return UInt16(kVK_Return) // Not localized: a typed key name
        case "ESCAPE", "ESC": return UInt16(kVK_Escape) // Not localized: a typed key name
        case "TAB": return UInt16(kVK_Tab) // Not localized: a typed key name
        case "SPACE": return UInt16(kVK_Space) // Not localized: a typed key name
        case "DELETE", "BACKSPACE": return UInt16(kVK_Delete) // Not localized: a typed key name
        case "FORWARD DELETE", "FORWARDDELETE": return UInt16(kVK_ForwardDelete) // Not localized: a typed key name
        case "LEFT": return UInt16(kVK_LeftArrow) // Not localized: a typed key name
        case "RIGHT": return UInt16(kVK_RightArrow) // Not localized: a typed key name
        case "UP": return UInt16(kVK_UpArrow) // Not localized: a typed key name
        case "DOWN": return UInt16(kVK_DownArrow) // Not localized: a typed key name
        case "HOME": return UInt16(kVK_Home) // Not localized: a typed key name
        case "END": return UInt16(kVK_End) // Not localized: a typed key name
        case "PAGE UP", "PAGEUP": return UInt16(kVK_PageUp) // Not localized: a typed key name
        case "PAGE DOWN", "PAGEDOWN": return UInt16(kVK_PageDown) // Not localized: a typed key name
        case "HELP": return UInt16(kVK_Help) // Not localized: a typed key name
        default:
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
            return functionKeys[key]
        }
    }

    private static func displayKey(_ key: String, keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Escape: return localized("Esc")
        case kVK_Space: return localized("Space")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return localized("Home")
        case kVK_End: return localized("End")
        case kVK_PageUp: return localized("Page Up")
        case kVK_PageDown: return localized("Page Down")
        case kVK_Help: return localized("Help")
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default: return key
        }
    }
}

struct MenuTriggerConfiguration: Equatable {
    static let defaultMouseButton = 3
    /// Seconds the trigger must be held before the Menu opens. Zero opens
    /// on the press; above zero a shorter press goes back to the Current App.
    static let openingDelayRange: ClosedRange<TimeInterval> = 0...1

    var mouseButton: Int
    var clickDragEnabled: Bool
    var keyboardShortcut: MenuKeyboardShortcut?
    var openingDelay: TimeInterval
    var alternateActionMode: AlternateActionMode

    init(
        mouseButton: Int = defaultMouseButton,
        clickDragEnabled: Bool = false,
        keyboardShortcut: MenuKeyboardShortcut? = nil,
        openingDelay: TimeInterval = 0,
        alternateActionMode: AlternateActionMode = .rightClick
    ) {
        self.mouseButton = MouseTriggerButton.isSupported(mouseButton)
            ? mouseButton
            : Self.defaultMouseButton
        self.clickDragEnabled = clickDragEnabled
        self.keyboardShortcut = keyboardShortcut
        self.openingDelay = Self.boundedOpeningDelay(openingDelay)
        self.alternateActionMode = alternateActionMode
    }

    static func boundedOpeningDelay(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return 0 }
        return min(max(delay, openingDelayRange.lowerBound), openingDelayRange.upperBound)
    }

    init(defaults: UserDefaults) {
        if defaults.object(forKey: Keys.mouseButton) == nil {
            mouseButton = Self.defaultMouseButton
        } else {
            let storedMouseButton = defaults.integer(forKey: Keys.mouseButton)
            mouseButton = MouseTriggerButton.isSupported(storedMouseButton)
                ? storedMouseButton
                : Self.defaultMouseButton
        }
        clickDragEnabled = defaults.bool(forKey: Keys.clickDragEnabled)
        keyboardShortcut = defaults.data(forKey: Keys.keyboardShortcut)
            .flatMap { try? JSONDecoder().decode(MenuKeyboardShortcut.self, from: $0) }
        openingDelay = Self.boundedOpeningDelay(defaults.double(forKey: Keys.openingDelay))
        alternateActionMode = defaults.string(forKey: Keys.alternateActionMode)
            .flatMap(AlternateActionMode.init(rawValue:)) ?? .rightClick
    }

    func save(to defaults: UserDefaults) {
        defaults.set(
            MouseTriggerButton.isSupported(mouseButton) ? mouseButton : Self.defaultMouseButton,
            forKey: Keys.mouseButton
        )
        defaults.set(clickDragEnabled, forKey: Keys.clickDragEnabled)
        if let keyboardShortcut,
           let data = try? JSONEncoder().encode(keyboardShortcut) {
            defaults.set(data, forKey: Keys.keyboardShortcut)
        } else {
            defaults.removeObject(forKey: Keys.keyboardShortcut)
        }
        defaults.set(Self.boundedOpeningDelay(openingDelay), forKey: Keys.openingDelay)
        defaults.set(alternateActionMode.rawValue, forKey: Keys.alternateActionMode)
    }

    private enum Keys {
        static let mouseButton = "trigger.mouse-button"
        static let clickDragEnabled = "trigger.click-drag-enabled"
        static let keyboardShortcut = "trigger.keyboard-shortcut"
        static let openingDelay = "trigger.opening-delay"
        static let alternateActionMode = "menu.alternate-action-mode"
    }
}

enum MouseTriggerButton {
    static func isSupported(_ buttonNumber: Int) -> Bool {
        buttonNumber >= 2
    }

    static func displayName(for buttonNumber: Int) -> String {
        switch buttonNumber {
        case 2: return localized("Middle Button")
        case 3: return localized("Side Button 1")
        case 4: return localized("Side Button 2")
        default: return localized("Mouse Button \(buttonNumber + 1)")
        }
    }
}
