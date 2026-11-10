import Foundation

public extension HostCommand {
    /// The object members that hold this Host Command's value, in the order
    /// they are read. A string input is the value itself. Empty for Host
    /// Commands whose input carries no single value.
    var valueKeys: [String] {
        switch self {
        case .openURL: return ["url"]
        case .openApplication: return ["path", "bundle_id", "bundle_identifier", "bundleIdentifier"]
        case .openFile, .openFolder: return ["path"]
        case .invokeService: return ["name", "service"]
        case .invokeShortcut: return ["name", "shortcut"]
        case .copyText: return ["text"]
        case .presentFeedback: return ["message", "text"]
        case .invokeKeyboardShortcut, .pasteText, .cutText, .captureArea, .captureFullScreen,
             .captureWindow, .openDeepLink:
            return []
        }
    }
}

/// How a configured Command input reads as the text of its configuration
/// field, and how edited text is written back. Existing Actions may use an
/// object input with extra members (for example, a Shortcut payload); a
/// field edit replaces only the member the field represents.
public enum CommandInputValue {
    /// The members a toggle field's object input may hold its value in.
    public static let toggleKeys = ["enabled", "value", "checked"]

    /// The object members that hold a field's value, in the order they are
    /// read. Empty when the field's value is the whole input.
    public static func valueKeys(for kind: CommandConfigurationFieldKind, hostCommand: HostCommand?) -> [String] {
        switch kind {
        case .application: return HostCommand.openApplication.valueKeys
        case .file, .folder: return ["path"]
        case .url: return HostCommand.openURL.valueKeys
        case .shortcut: return HostCommand.invokeShortcut.valueKeys
        case .text:
            switch hostCommand {
            case .invokeService, .invokeShortcut: return hostCommand?.valueKeys ?? []
            default: return ["value"]
            }
        case .multilineText:
            return hostCommand == .presentFeedback ? HostCommand.presentFeedback.valueKeys : ["value"]
        case .choice: return ["value", "choice", "name"]
        case .toggle: return toggleKeys
        case .keyboardShortcut, .size, .position, .credential, .httpsEndpoint, .orderedChoices, .list:
            return []
        }
    }

    /// The text a field shows for `value`.
    public static func presentation(
        of value: JSONValue,
        field: CommandConfigurationField?,
        hostCommand: HostCommand?
    ) -> String {
        guard let field else { return encodedValue(for: value) }
        if field.kind == .toggle {
            return isOn(value).map { $0 ? "true" : "false" } ?? encodedValue(for: value)
        }
        let keys = valueKeys(for: field.kind, hostCommand: hostCommand)
        return stringMember(in: value, keys: keys) ?? encodedValue(for: value)
    }

    /// The input `text` stands for, keeping `original`'s other members.
    public static func resolve(
        text: String,
        field: CommandConfigurationField?,
        hostCommand: HostCommand?,
        original: JSONValue?
    ) -> JSONValue {
        if let original, text == presentation(of: original, field: field, hostCommand: hostCommand) {
            return original
        }
        guard let field else { return decodeOrString(text) }
        switch field.kind {
        case .application, .file, .folder, .url, .shortcut, .text, .multilineText, .choice:
            return replacingMember(
                in: original, keys: valueKeys(for: field.kind, hostCommand: hostCommand), with: .string(text)
            )
        case .toggle:
            let enabled = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            return replacingMember(in: original, keys: toggleKeys, with: .bool(enabled))
        case .keyboardShortcut:
            return decodeOrString(text)
        case .size, .position:
            // Kept as typed; the Host checks the grammar when the sheet saves.
            return .string(text)
        case .credential, .httpsEndpoint, .orderedChoices, .list:
            // Only members of a field set, never a lone field.
            return .string(text)
        }
    }

    /// A toggle input's state: a Boolean, "true" or "false", or an object
    /// whose first toggle member is a Boolean. Nil for anything else.
    public static func isOn(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let enabled): return enabled
        case .string(let text):
            switch text.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        case .object(let values):
            for key in toggleKeys {
                if case .bool(let enabled) = values[key] { return enabled }
            }
            return nil
        default: return nil
        }
    }

    /// The first string member of `value` among `keys`, or `value` itself
    /// when it is a string.
    public static func string(in value: JSONValue, keys: [String]) -> String? {
        if case .string(let text) = value { return text }
        return stringMember(in: value, keys: keys)
    }

    private static func encodedValue(for value: JSONValue) -> String {
        if case .string(let value) = value { return value }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func decodeOrString(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(text)
        }
        return value
    }

    private static func stringMember(in value: JSONValue, keys: [String]) -> String? {
        guard case .object(let values) = value else { return nil }
        for key in keys {
            if case .string(let member) = values[key] { return member }
        }
        return nil
    }

    /// `original` with its first member among `keys` set to `member`, or
    /// `member` alone when `original` has none of them.
    private static func replacingMember(in original: JSONValue?, keys: [String], with member: JSONValue) -> JSONValue {
        guard case .object(var values) = original,
              let key = keys.first(where: { values[$0] != nil }) else { return member }
        values[key] = member
        return .object(values)
    }
}
