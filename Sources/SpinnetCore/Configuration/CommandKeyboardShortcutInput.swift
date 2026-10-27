import Foundation

/// The Command's keyboard grammar, shared by configuration and execution.
/// Named keys/modifiers are resolved to platform constants only by the Host.
/// The numeric forms retain their original virtual code and modifier bits.
public struct CommandKeyboardShortcutInput: Equatable {
    public enum Key: Equatable {
        case virtualCode(UInt16)
        case named(String)
    }

    public enum Modifier: Hashable {
        case command, shift, option, control, function, capsLock
    }

    public let key: Key
    public let modifiers: Set<Modifier>
    public let rawModifierFlags: UInt64

    public init(_ input: JSONValue) throws {
        switch input {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw Self.invalid("Expected a keyboard shortcut") }
            var key = trimmed
            var modifiers = Set<Modifier>()
            let symbols: [(String, Modifier)] = [("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)]
            for (symbol, modifier) in symbols where key.contains(symbol) {
                modifiers.insert(modifier)
                key = key.replacingOccurrences(of: symbol, with: "")
            }
            let parts = key.split(separator: "+", omittingEmptySubsequences: true)
            if parts.count > 1 {
                key = String(parts.last!)
                for part in parts.dropLast() { modifiers.insert(try Self.modifier(String(part))) }
            } else if key.contains("+") {
                // A separator with only one nonempty part, such as A+, never
                // named a runtime key. Do not admit it as a configured value.
                throw Self.invalid("Expected a keyboard shortcut")
            }
            self.key = try Self.namedKey(key)
            self.modifiers = modifiers
            rawModifierFlags = 0
        case .object(let values):
            if case .number(let value)? = values["key_code"], value.isFinite,
               value.rounded() == value, (0...127).contains(value) {
                key = .virtualCode(UInt16(value))
            } else if let text = Self.stringValue(in: values, keys: ["key", "character"]) {
                key = try Self.namedKey(text)
            } else {
                throw Self.invalid("Expected a key or key_code")
            }
            let parsed = try Self.modifiers(values["modifiers"] ?? values["modifier_flags"])
            modifiers = parsed.names
            rawModifierFlags = parsed.raw
        default:
            throw Self.invalid("Expected a keyboard shortcut")
        }
    }

    private static func namedKey(_ text: String) throws -> Key {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if key.count == 1, let scalar = key.unicodeScalars.first,
           (65...90).contains(scalar.value) || (48...57).contains(scalar.value) {
            return .named(key)
        }
        let names: Set<String> = ["RETURN", "ENTER", "ESCAPE", "ESC", "TAB", "SPACE", "DELETE", "BACKSPACE",
                                  "LEFT", "RIGHT", "UP", "DOWN"]
        guard names.contains(key) || (1...20).contains(where: { key == "F\($0)" }) else {
            throw invalid("Unknown keyboard key \(text)")
        }
        return .named(key)
    }

    private static func modifiers(_ input: JSONValue?) throws -> (names: Set<Modifier>, raw: UInt64) {
        guard let input else { return ([], 0) }
        switch input {
        case .number(let value):
            guard let raw = UInt64(exactly: value) else { throw invalid("Keyboard modifiers are invalid") }
            return ([], raw)
        case .string(let value):
            let parts = value.split(separator: "+", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { throw invalid("Keyboard modifiers are invalid") }
            return (Set(try parts.map { try modifier(String($0)) }), 0)
        case .array(let values):
            return (Set(try values.map { value in
                guard case .string(let text) = value else { throw invalid("Keyboard modifiers are invalid") }
                return try modifier(text)
            }), 0)
        default:
            throw invalid("Keyboard modifiers are invalid")
        }
    }

    private static func modifier(_ text: String) throws -> Modifier {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "⌘": return .command
        case "shift", "⇧": return .shift
        case "option", "opt", "alt", "⌥": return .option
        case "control", "ctrl", "⌃": return .control
        case "function", "fn": return .function
        case "caps_lock", "caps lock": return .capsLock
        default: throw invalid("Unknown keyboard modifier \(text)")
        }
    }

    private static func stringValue(in values: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func invalid(_ message: String) -> HostCommandExecutionError { .invalidInput(message) }
}
