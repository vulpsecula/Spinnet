import Foundation

/// One user interaction in a Plugin View, delivered to the Command script
/// that presented the view as its `event` global (ADR 0010). Its JSON form is
/// what the script reads; `type` names the kind.
public enum PluginViewEvent: Equatable, Hashable {
    /// The user edited `field`. `values` holds every field of the form as it
    /// now stands, so coalescing pending changes to the latest loses nothing.
    case fieldChanged(field: String, values: JSONValue)
    /// The user submitted the form with `values`.
    case submitted(values: JSONValue)
    /// The user chose the view's action with this ID.
    case actionChosen(String)
    /// The user changed one of the Plugin's own settings in the view. The
    /// Host has already stored it as Plugin Settings.
    case settingChanged(key: String, value: JSONValue)
    /// A Host-Fetched Section in `deliver` mode received its answer.
    case sectionDelivered(section: String, response: JSONValue)

    /// A field change waits out the debounce and gives way to a later one;
    /// every other event is delivered, in order.
    public var coalesces: Bool {
        if case .fieldChanged = self { return true }
        return false
    }

    public var json: JSONValue {
        switch self {
        case .fieldChanged(let field, let values):
            return .object(["type": .string("field_changed"), "field": .string(field), "values": values])
        case .submitted(let values):
            return .object(["type": .string("submitted"), "values": values])
        case .actionChosen(let action):
            return .object(["type": .string("action_chosen"), "action": .string(action)])
        case .settingChanged(let key, let value):
            return .object(["type": .string("setting_changed"), "key": .string(key), "value": value])
        case .sectionDelivered(let section, let response):
            return .object(["type": .string("section_delivered"), "section": .string(section),
                            "response": response])
        }
    }
}

/// What an invocation hands a script besides its input: the View Event it
/// answers and the state the script returned with its last view. When the
/// Action starts, both are null.
public struct ViewEventDelivery: Equatable, Hashable {
    public let event: PluginViewEvent?
    public let state: JSONValue

    public init(event: PluginViewEvent?, state: JSONValue) {
        self.event = event
        self.state = state
    }

    /// The Action's own invocation, before any view exists.
    public static let actionStart = ViewEventDelivery(event: nil, state: .null)
}

/// A script's answer, read from the value it evaluated to: `{view, state}` to
/// show or update its Plugin View, `{close: true}` to close it, or `null` when
/// it has nothing to show. Any of them may add `toast`.
///
/// Anything else breaks the Documented Plugin Interface, and reading it
/// throws `PluginRuntimeError.protocolViolation`, which ends a View Session.
/// The view is opaque here beyond being an object; the renderer reads it.
public struct PluginScriptAnswer: Equatable {
    public let view: JSONValue?
    /// The state the Host keeps for the next View Event. Only an answer with
    /// a view sets it; `null` otherwise.
    public let state: JSONValue
    public let close: Bool
    public let toast: String?

    public init(view: JSONValue? = nil, state: JSONValue = .null, close: Bool = false, toast: String? = nil) {
        self.view = view
        self.state = state
        self.close = close
        self.toast = toast
    }

    public init(parsing value: JSONValue) throws {
        guard case .object(let members) = value else {
            guard value == .null else { throw Self.violation("must be an object or null") }
            self.init()
            return
        }
        let unknown = Set(members.keys).subtracting(["view", "state", "close", "toast"])
        guard unknown.isEmpty else {
            throw Self.violation("has unknown member \(unknown.sorted().joined(separator: ", "))")
        }
        var toast: String?
        switch members["toast"] {
        case nil:
            break
        case .string(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            toast = text
        default:
            throw Self.violation("has a toast that is not a non-empty string")
        }
        switch members["close"] {
        case nil:
            break
        case .bool(true):
            guard members["view"] == nil, members["state"] == nil else {
                throw Self.violation("closes the view and describes one")
            }
            self.init(close: true, toast: toast)
            return
        default:
            throw Self.violation("has a close that is not true")
        }
        guard let view = members["view"] else {
            guard members["state"] == nil else { throw Self.violation("has a state but no view") }
            self.init(toast: toast)
            return
        }
        guard case .object = view else { throw Self.violation("has a view that is not an object") }
        let state = members["state"] ?? .null
        guard Self.encodedSize(of: view) <= ScriptedActionBudgets.viewDescriptionBytes else {
            throw Self.violation("describes a view larger than 256 KiB")
        }
        guard Self.encodedSize(of: state) <= ScriptedActionBudgets.viewStateBytes else {
            throw Self.violation("returns a state larger than 64 KiB")
        }
        self.init(view: view, state: state, toast: toast)
    }

    /// The UTF-8 size of the value's JSON, which is how the budgets count.
    static func encodedSize(of value: JSONValue) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value).count) ?? Int.max
    }

    private static func violation(_ problem: String) -> PluginRuntimeError {
        .protocolViolation("The script's answer " + problem)
    }
}
