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
    /// The user swapped two of the Plugin's own `choice` settings with the
    /// swap button between their controls. The Host has already stored both.
    case settingsSwapped(first: String, second: String)
    /// A Host-Fetched Section in `deliver` mode received its answer.
    case sectionDelivered(section: String, response: JSONValue)
    /// A Requested Host Operation that asked to `notify` reached its
    /// outcome (Candidate Contract `host_operations`). `id` is the Plugin's
    /// own label for it, `perform` its catalogue ID.
    case operationFinished(id: String?, perform: String, outcome: HostOperationOutcome)
    /// Candidate Contract `collections`: the user changed `field` of `page`.
    /// `values` holds every input of the page as committed text, never text
    /// an input method is still composing.
    case pageFieldChanged(page: String, field: String, values: JSONValue)
    /// Return in a page's `text_field` that searches no collection.
    /// `selection` maps the page's collection, if any, to its selected item.
    case pageSubmitted(page: String, field: String, values: JSONValue, selection: JSONValue)
    /// The user chose a page button that delivers an event.
    case pageActionChosen(page: String, action: String, values: JSONValue, selection: JSONValue)
    /// The user performed an item action that delivers an event: the default
    /// one by Return or double-click, any one from the item's context menu.
    case itemAction(page: String, collection: String, action: String, item: PluginPageItemSnapshot, values: JSONValue)
    /// The user neared the end of a collection that has more items.
    case loadMore(page: String, collection: String, loaded: Int)

    /// A field change waits out the debounce and gives way to a later one;
    /// every other event is delivered, in order.
    public var coalesces: Bool {
        switch self {
        case .fieldChanged, .pageFieldChanged: return true
        default: return false
        }
    }

    /// The page an event of a page was made in and the component it came
    /// from, which must both still be on screen, unchanged in kind and not
    /// reset, when it is dispatched. `action_chosen` names its button, which
    /// the session resolves to the `actions` component holding it.
    public var pageOrigin: (page: String, component: String)? {
        switch self {
        case .pageFieldChanged(let page, let field, _), .pageSubmitted(let page, let field, _, _): return (page, field)
        case .pageActionChosen(let page, let action, _, _): return (page, action)
        case .itemAction(let page, let collection, _, _, _), .loadMore(let page, let collection, _): return (page, collection)
        default: return nil
        }
    }

    /// The `type` the script reads.
    public var typeName: String {
        if case .object(let members) = json, case .string(let type)? = members["type"] { return type }
        return "an event"
    }

    /// A user gesture that may lead to an operation (ADR 0018): submitting
    /// a form or choosing an action. The Action's start, which has no event,
    /// is one too. Typing, setting changes, deliveries and results are not,
    /// so they never cause an effect by themselves.
    public var isGesture: Bool {
        switch self {
        case .submitted, .actionChosen, .pageSubmitted, .pageActionChosen, .itemAction: return true
        case .fieldChanged, .settingChanged, .settingsSwapped, .sectionDelivered, .operationFinished, .pageFieldChanged,
             .loadMore:
            return false
        }
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
        case .settingsSwapped(let first, let second):
            return .object(["type": .string("settings_swapped"), "keys": .array([.string(first), .string(second)])])
        case .sectionDelivered(let section, let response):
            return .object(["type": .string("section_delivered"), "section": .string(section),
                            "response": response])
        case .operationFinished(let id, let perform, let outcome):
            var members: [String: JSONValue] = ["type": .string("operation_finished"), "perform": .string(perform),
                                                "outcome": .string(outcome.name)]
            if let id { members["operation"] = .string(id) }
            if let reason = outcome.reason { members["reason"] = .string(reason.rawValue) }
            return .object(members)
        case .pageFieldChanged(let page, let field, let values):
            return .object(["type": .string("field_changed"), "page": .string(page), "field": .string(field), "values": values])
        case .pageSubmitted(let page, let field, let values, let selection):
            return .object(["type": .string("submitted"), "page": .string(page), "field": .string(field), "values": values,
                            "selection": selection])
        case .pageActionChosen(let page, let action, let values, let selection):
            return .object(["type": .string("action_chosen"), "page": .string(page), "action": .string(action),
                            "values": values, "selection": selection])
        case .itemAction(let page, let collection, let action, let item, let values):
            return .object(["type": .string("item_action"), "page": .string(page), "collection": .string(collection),
                            "action": .string(action), "item": item.json, "values": values])
        case .loadMore(let page, let collection, let loaded):
            return .object(["type": .string("load_more"), "page": .string(page), "collection": .string(collection),
                            "loaded": .number(Double(loaded))])
        }
    }
}

/// What an invocation hands a script besides its input: the View Event it
/// answers and the state the script returned with its last view. When the
/// Action starts, both are null.
public struct ViewEventDelivery: Equatable, Hashable {
    public let event: PluginViewEvent?
    public let state: JSONValue
    /// What the Host showed as where text would go when the user made the
    /// gesture this invocation answers. It stays in the Host: a
    /// synchronous `selection.replace` of a Plugin declaring
    /// `host_operations` is compared with it, and the script never sees it.
    public let insertionTarget: InsertionTargetCapture

    public init(event: PluginViewEvent?, state: JSONValue, insertionTarget: InsertionTargetCapture = .notShown) {
        self.event = event
        self.state = state
        self.insertionTarget = insertionTarget
    }

    /// Whether the invocation answers a gesture: the Action's start or a
    /// gesture event.
    public var answersGesture: Bool { event?.isGesture ?? true }

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
    /// The page the answer describes instead of a view, under Candidate
    /// Contract `collections`, already read as the Host draws it.
    public let page: PluginPage?
    /// The page as the script wrote it.
    public let pageJSON: JSONValue?
    /// The state the Host keeps for the next View Event. Only an answer with
    /// a view sets it; `null` otherwise.
    public let state: JSONValue
    public let close: Bool
    public let toast: String?
    /// The Requested Host Operation the answer carries, under Candidate
    /// Contract `host_operations`; it commits with the rest of the answer.
    public let operation: RequestedHostOperation?

    public init(view: JSONValue? = nil, state: JSONValue = .null, close: Bool = false, toast: String? = nil,
                operation: RequestedHostOperation? = nil, page: PluginPage? = nil, pageJSON: JSONValue? = nil) {
        self.view = view
        self.page = page
        self.pageJSON = pageJSON
        self.state = state
        self.close = close
        self.toast = toast
        self.operation = operation
    }

    /// Reads a Plugin API Level 1 answer.
    public init(parsing value: JSONValue) throws {
        try self.init(parsing: value, permits: { _ in false })
    }

    /// Reads an answer of a Plugin to which `permits` says which interface
    /// members its declarations offer: one declaring `host_operations` may
    /// add `operation`, which may come with a view, a toast, both or
    /// neither, but not with `close`, and one declaring `collections` may
    /// describe a `page` instead of a `view`, never both. Whether the answer
    /// answers a gesture is the View Session's to check.
    public init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        guard case .object(let members) = value else {
            guard value == .null else { throw Self.violation("must be an object or null") }
            self.init()
            return
        }
        let allowsOperation = permits(HostOperationsContract.answerOperation)
        let allowsPage = permits(CollectionsContract.answerPage)
        let unknown = Set(members.keys).subtracting(["view", "state", "close", "toast"] + (allowsOperation ? ["operation"] : [])
                                                    + (allowsPage ? ["page"] : []))
        guard unknown.isEmpty else {
            throw Self.violation("has unknown member \(unknown.sorted().joined(separator: ", "))")
        }
        let operation = try members["operation"].map { try RequestedHostOperation(parsing: $0, permits: permits) }
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
            guard members["view"] == nil, members["page"] == nil, members["state"] == nil else {
                throw Self.violation("closes the view and describes one")
            }
            guard operation == nil else {
                throw Self.violation("closes the view and requests an operation; an operation closes it with closes_view")
            }
            self.init(close: true, toast: toast)
            return
        default:
            throw Self.violation("has a close that is not true")
        }
        if let pageJSON = members["page"] {
            guard members["view"] == nil else { throw Self.violation("describes both a view and a page") }
            let state = members["state"] ?? .null
            try Self.checkBudgets(description: pageJSON, named: "page", state: state)
            let page = try PluginPage(parsing: pageJSON, permits: permits)
            self.init(state: state, toast: toast, operation: operation, page: page, pageJSON: pageJSON)
            return
        }
        guard let view = members["view"] else {
            guard members["state"] == nil else { throw Self.violation("has a state but no view") }
            self.init(toast: toast, operation: operation)
            return
        }
        guard case .object = view else { throw Self.violation("has a view that is not an object") }
        let state = members["state"] ?? .null
        try Self.checkBudgets(description: view, named: "view", state: state)
        self.init(view: view, state: state, toast: toast, operation: operation)
    }

    /// A view or page counts against the 256 KiB description budget and its
    /// state against 64 KiB.
    private static func checkBudgets(description: JSONValue, named noun: String, state: JSONValue) throws {
        guard encodedSize(of: description) <= ScriptedActionBudgets.viewDescriptionBytes else {
            throw violation("describes a \(noun) larger than 256 KiB")
        }
        guard encodedSize(of: state) <= ScriptedActionBudgets.viewStateBytes else {
            throw violation("returns a state larger than 64 KiB")
        }
    }

    /// The description to show: the page's JSON or the view.
    public var description: JSONValue? { pageJSON ?? view }

    /// Reads an answer to `event`, or to the Action's start when it is nil,
    /// as a View Session reads it: only an answer to a gesture may request an
    /// operation, so typing, deliveries and results never cause an effect,
    /// and a script cannot loop by answering its result with a request.
    public init(parsing value: JSONValue, answering event: PluginViewEvent?,
                permits: (PluginInterfaceMember) -> Bool) throws {
        try self.init(parsing: value, permits: permits)
        if operation != nil, let event, !event.isGesture {
            throw Self.violation("to \(event.typeName) requests an operation; only an answer to a gesture may")
        }
    }

    /// The UTF-8 size of the value's JSON as a helper message carries it,
    /// slashes unescaped, which is how the budgets count.
    static func encodedSize(of value: JSONValue) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value).count) ?? Int.max
    }

    private static func violation(_ problem: String) -> PluginRuntimeError {
        .protocolViolation("The script's answer " + problem)
    }
}

