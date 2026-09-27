import Foundation

/// A Plugin View as the Host draws it, read from the `view` a script answers
/// with (ADR 0010). The vocabulary is fixed: a title, the Plugin's own
/// setting controls, a Form, a Detail, and Actions, drawn in that order, at
/// least one of the last three present. `PluginAPI/schemas/plugin-view.schema.json`
/// publishes the shape and `spinnet.ui` builds it.
///
/// Anything outside it, such as an unknown member, a field kind the view
/// does not draw, or a setting the Plugin does not declare, breaks the
/// Documented Plugin Interface: reading it throws a protocol violation, which
/// ends the View Session. The Host never draws a Plugin's own markup.
public struct PluginViewDescription: Equatable {
    public let title: String
    public let subtitle: String?
    /// Controls for the Plugin's own `choice` and `toggle` settings.
    public let settings: [PluginViewSettingControl]
    public let form: PluginViewForm?
    public let detail: PluginViewDetail?
    public let actions: [PluginViewAction]

    /// Most setting controls one view may offer.
    public static let maximumSettings = 6
    public static let maximumFields = 20
    public static let maximumSections = 20
    public static let maximumActions = 12
    /// Longest field key, section ID or action ID, in characters.
    public static let maximumIdentifierLength = 64

    /// `settingsFields` are the Plugin's declared `settings_fields`, which a
    /// setting control must name.
    public init(parsing view: JSONValue, settingsFields: [CommandConfigurationField]) throws {
        let members = try Self.object(view, "The view", allowed: ["title", "subtitle", "settings", "form", "detail", "actions"])
        title = try Self.text(members["title"], "The view's title")
        subtitle = try members["subtitle"].map { try Self.text($0, "The view's subtitle", allowsBlank: true) }
        settings = try Self.settings(members["settings"], declared: settingsFields)
        form = try members["form"].map(PluginViewForm.init(parsing:))
        detail = try members["detail"].map(PluginViewDetail.init(parsing:))
        actions = try members["actions"].map(Self.actions) ?? []
        guard form != nil || detail != nil || !actions.isEmpty else {
            throw Self.violation("The view has no form, detail or actions")
        }
    }

    private static func settings(_ value: JSONValue?, declared: [CommandConfigurationField]) throws -> [PluginViewSettingControl] {
        guard let value else { return [] }
        let items = try array(value, "The view's settings", maximum: maximumSettings)
        var seen: Set<String> = []
        let controls = try items.map { item in
            let members = try object(item, "A setting control", allowed: ["key", "swap_with"])
            let key = try text(members["key"], "A setting control's key")
            guard let field = declared.first(where: { $0.key == key }), [.choice, .toggle].contains(field.kind) else {
                throw violation("A setting control may only name the Plugin's own choice or toggle settings, and \(key) is not one")
            }
            guard seen.insert(key).inserted else { throw violation("The view offers the setting \(key) twice") }
            return PluginViewSettingControl(key: key, title: field.displayTitle, kind: field.kind,
                                            choices: field.choices.map { PluginViewChoice(value: $0, title: field.displayTitle(forChoice: $0)) },
                                            swapWith: try members["swap_with"].map { try text($0, "The setting control \(key)'s swap_with") })
        }
        // A swap button sits between two neighbouring choices, so it can only
        // exchange a control's value with the one drawn right after it, and
        // only when each can hold whatever the other holds.
        for (index, control) in controls.enumerated() {
            guard let other = control.swapWith else { continue }
            guard control.kind == .choice, index + 1 < controls.count, controls[index + 1].key == other,
                  controls[index + 1].kind == .choice else {
                throw violation("The setting control \(control.key) may only swap with the choice setting control after it, and \(other) is not that")
            }
            guard Set(control.choices.map(\.value)) == Set(controls[index + 1].choices.map(\.value)) else {
                throw violation("The setting controls \(control.key) and \(other) may only swap when they offer the same choices")
            }
        }
        return controls
    }

    private static func actions(_ value: JSONValue) throws -> [PluginViewAction] {
        let actions = try array(value, "The view's actions", minimum: 1, maximum: maximumActions).map(PluginViewAction.init(parsing:))
        var ids: Set<String> = []
        var shortcuts: Set<PluginViewShortcut> = []
        for action in actions {
            if case .event(let id) = action.kind, !ids.insert(id).inserted {
                throw violation("The view has two actions with the ID \(id)")
            }
            if let shortcut = action.shortcut, !shortcuts.insert(shortcut).inserted {
                throw violation("The view gives two actions the shortcut \(shortcut.displayText)")
            }
        }
        return actions
    }

    // MARK: - Reading members

    static func violation(_ problem: String) -> PluginRuntimeError {
        .protocolViolation(problem)
    }

    static func object(_ value: JSONValue, _ name: String, allowed: Set<String>) throws -> [String: JSONValue] {
        guard case .object(let members) = value else { throw violation("\(name) is not an object") }
        let unknown = Set(members.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw violation("\(name) has unknown member \(unknown.sorted().joined(separator: ", "))")
        }
        return members
    }

    static func array(_ value: JSONValue, _ name: String, minimum: Int = 0, maximum: Int) throws -> [JSONValue] {
        guard case .array(let items) = value else { throw violation("\(name) is not a list") }
        guard items.count >= minimum, items.count <= maximum else {
            throw violation("\(name) must hold \(minimum) to \(maximum) items")
        }
        return items
    }

    static func text(_ value: JSONValue?, _ name: String, allowsBlank: Bool = false) throws -> String {
        guard case .string(let text)? = value else { throw violation("\(name) is not a string") }
        guard allowsBlank || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw violation("\(name) is blank")
        }
        return text
    }

    static func identifier(_ value: JSONValue?, _ name: String) throws -> String {
        let identifier = try text(value, name)
        guard identifier.count <= maximumIdentifierLength else {
            throw violation("\(name) is longer than \(maximumIdentifierLength) characters")
        }
        return identifier
    }
}

/// One value a `choice` may take and what to show for it.
public struct PluginViewChoice: Equatable, Hashable {
    public let value: String
    public let title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

/// A control for one of the Plugin's own `choice` or `toggle` settings. The
/// Host shows what is stored now; a change is stored as Plugin Settings are
/// and then delivered as `setting_changed`. The Action does not run again.
public struct PluginViewSettingControl: Equatable {
    public let key: String
    public let title: String
    public let kind: CommandConfigurationFieldKind
    public let choices: [PluginViewChoice]
    /// The key of the `choice` control drawn right after this one, when a
    /// swap button between the two exchanges their values, as a pair of
    /// languages or units is swapped.
    public let swapWith: String?

    public init(key: String, title: String, kind: CommandConfigurationFieldKind, choices: [PluginViewChoice],
                swapWith: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.choices = choices
        self.swapWith = swapWith
    }
}

/// A Form: fields of the kinds Plugin Settings use, whose values the Host
/// sends with `field_changed` and `submitted`.
public struct PluginViewForm: Equatable {
    public let fields: [PluginViewField]
    public let submitTitle: String
    /// Return submits from any field, a multiline one included, where
    /// Shift-Return starts a new line; the form then draws no submit button.
    public let submitsOnReturn: Bool

    /// The kinds a view's field may have: those whose value is text, a
    /// switch, or one choice. The others need a Host sheet or panel, or are
    /// secrets the Plugin must never see.
    public static let fieldKinds: [CommandConfigurationFieldKind] = [.text, .multilineText, .toggle, .choice, .url]

    public init(parsing value: JSONValue) throws {
        let members = try PluginViewDescription.object(value, "The form",
                                                       allowed: ["fields", "submit_title", "submit_on_return"])
        fields = try PluginViewDescription.array(members["fields"] ?? .null, "The form's fields", minimum: 1,
                                                 maximum: PluginViewDescription.maximumFields).map(PluginViewField.init(parsing:))
        submitTitle = try members["submit_title"].map { try PluginViewDescription.text($0, "The form's submit_title") } ?? "Submit"
        switch members["submit_on_return"] {
        case nil, .bool(false)?: submitsOnReturn = false
        case .bool(true)?: submitsOnReturn = true
        default: throw PluginViewDescription.violation("The form's submit_on_return is not a boolean")
        }
        if submitsOnReturn, members["submit_title"] != nil {
            throw PluginViewDescription.violation("A form that submits on Return draws no submit button, so it has no submit_title")
        }
        var keys: Set<String> = []
        for field in fields where !keys.insert(field.key).inserted {
            throw PluginViewDescription.violation("The form has two fields with the key \(field.key)")
        }
    }

    /// Every field's value as the view describes it, keyed by field.
    public var values: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) }))
    }
}

public struct PluginViewField: Equatable {
    public let key: String
    public let kind: CommandConfigurationFieldKind
    public let title: String
    public let placeholder: String?
    /// A string for text kinds, a boolean for a toggle, one of the choices
    /// for a choice. Without one, a field starts empty, off, or on its first
    /// choice.
    public let value: JSONValue
    public let choices: [PluginViewChoice]

    public init(parsing value: JSONValue) throws {
        let members = try PluginViewDescription.object(value, "A form field", allowed: [
            "key", "kind", "title", "placeholder", "value", "choices", "choice_titles"
        ])
        let key = try PluginViewDescription.identifier(members["key"], "A form field's key")
        self.key = key
        guard case .string(let kindName)? = members["kind"],
              let kind = CommandConfigurationFieldKind(rawValue: kindName), PluginViewForm.fieldKinds.contains(kind) else {
            throw PluginViewDescription.violation("The form field \(key) must be of kind "
                + PluginViewForm.fieldKinds.map(\.rawValue).joined(separator: ", "))
        }
        self.kind = kind
        title = try PluginViewDescription.text(members["title"], "The form field \(key)'s title")
        placeholder = try members["placeholder"].map { try PluginViewDescription.text($0, "The form field \(key)'s placeholder", allowsBlank: true) }
        if kind == .choice {
            let values = try PluginViewDescription.array(members["choices"] ?? .null, "The form field \(key)'s choices",
                                                         minimum: 1, maximum: 100).map {
                try PluginViewDescription.text($0, "A choice of \(key)", allowsBlank: true)
            }
            guard Set(values).count == values.count else {
                throw PluginViewDescription.violation("The form field \(key) repeats a choice")
            }
            var titles = values
            if let declared = members["choice_titles"] {
                titles = try PluginViewDescription.array(declared, "The form field \(key)'s choice_titles",
                                                         minimum: values.count, maximum: values.count).map {
                    try PluginViewDescription.text($0, "A choice title of \(key)")
                }
            }
            choices = zip(values, titles).map { PluginViewChoice(value: $0, title: $1) }
        } else {
            guard members["choices"] == nil, members["choice_titles"] == nil else {
                throw PluginViewDescription.violation("Only a choice field has choices, and \(key) is a \(kind.rawValue)")
            }
            choices = []
        }
        switch (kind, members["value"]) {
        case (.toggle, nil): self.value = .bool(false)
        case (.toggle, .bool(let isOn)?): self.value = .bool(isOn)
        case (.choice, nil): self.value = .string(choices[0].value)
        case (.choice, .string(let chosen)?) where choices.contains(where: { $0.value == chosen }):
            self.value = .string(chosen)
        case (.text, nil), (.multilineText, nil), (.url, nil): self.value = .string("")
        case (.text, .string(let text)?), (.multilineText, .string(let text)?), (.url, .string(let text)?):
            self.value = .string(text)
        default:
            throw PluginViewDescription.violation("The form field \(key) holds a value its kind cannot")
        }
    }
}

/// A Detail: sections of text, shown one after another.
public struct PluginViewDetail: Equatable {
    public let sections: [PluginViewSection]

    public init(parsing value: JSONValue) throws {
        let members = try PluginViewDescription.object(value, "The detail", allowed: ["sections"])
        sections = try PluginViewDescription.array(members["sections"] ?? .null, "The detail's sections", minimum: 1,
                                                   maximum: PluginViewDescription.maximumSections).map(PluginViewSection.init(parsing:))
        var ids: Set<String> = []
        for section in sections where !ids.insert(section.id).inserted {
            throw PluginViewDescription.violation("The detail has two sections with the ID \(section.id)")
        }
    }
}

/// One Detail section: `{id, title?, text?, fetch?}`. Without `fetch` it
/// shows `text`, in the Markdown subset of `PluginViewMarkdown`. With `fetch`
/// it is a Host-Fetched Section: the Host asks its `HostFetchedSectionProvider`
/// what to show, and reads `fetch` no further here than that it is an object.
public struct PluginViewSection: Equatable {
    /// Unique within the view; a Host-Fetched Section is known by it.
    public let id: String
    public let title: String?
    public let text: String?
    public let fetch: JSONValue?

    public init(id: String, title: String?, text: String?, fetch: JSONValue?) {
        self.id = id
        self.title = title
        self.text = text
        self.fetch = fetch
    }

    public init(parsing value: JSONValue) throws {
        let members = try PluginViewDescription.object(value, "A detail section", allowed: ["id", "title", "text", "fetch"])
        let id = try PluginViewDescription.identifier(members["id"], "A detail section's id")
        self.id = id
        title = try members["title"].map { try PluginViewDescription.text($0, "The section \(id)'s title") }
        text = try members["text"].map { try PluginViewDescription.text($0, "The section \(id)'s text", allowsBlank: true) }
        switch members["fetch"] {
        case nil: fetch = nil
        case .object?: fetch = members["fetch"]
        default: throw PluginViewDescription.violation("The section \(id)'s fetch is not an object")
        }
        guard members["text"] != nil || members["fetch"] != nil else {
            throw PluginViewDescription.violation("The section \(id) has neither text nor fetch")
        }
    }

    public var isHostFetched: Bool { fetch != nil }
}

/// An action button, with an optional keyboard shortcut. Either it delivers
/// `action_chosen` with its ID, or it is a standard action the Host performs
/// itself without a View Event.
public struct PluginViewAction: Equatable {
    public enum Kind: Equatable {
        case event(String)
        /// `closesView` ends the View Session once the action succeeds.
        case standard(PluginViewStandardAction, closesView: Bool)
    }

    public let title: String
    public let shortcut: PluginViewShortcut?
    public let kind: Kind

    public init(title: String, shortcut: PluginViewShortcut?, kind: Kind) {
        self.title = title
        self.shortcut = shortcut
        self.kind = kind
    }

    public init(parsing value: JSONValue) throws {
        let members = try PluginViewDescription.object(value, "An action", allowed: [
            "id", "title", "shortcut", "perform", "text", "url", "closes_view"
        ])
        let title = try PluginViewDescription.text(members["title"], "An action's title")
        self.title = title
        if let declared = members["shortcut"] {
            guard case .string(let text) = declared, let shortcut = PluginViewShortcut(parsing: text) else {
                throw PluginViewDescription.violation("The action \(title) has a shortcut the Host does not read")
            }
            guard !PluginViewShortcut.reserved.contains(shortcut) else {
                throw PluginViewDescription.violation("The action \(title) takes \(shortcut.displayText), which the view keeps for itself")
            }
            self.shortcut = shortcut
        } else {
            shortcut = nil
        }
        switch (members["id"], members["perform"]) {
        case (let id?, nil):
            guard members["text"] == nil, members["url"] == nil, members["closes_view"] == nil else {
                throw PluginViewDescription.violation("The action \(title) delivers an event and has a standard action's members")
            }
            kind = .event(try PluginViewDescription.identifier(id, "The action \(title)'s id"))
        case (nil, .string(let perform)?):
            let standard = try PluginViewStandardAction(perform: perform, members: members, title: title)
            let closesView: Bool
            switch members["closes_view"] {
            case nil: closesView = false
            case .bool(let value)?: closesView = value
            default: throw PluginViewDescription.violation("The action \(title)'s closes_view is not a boolean")
            }
            kind = .standard(standard, closesView: closesView)
        default:
            throw PluginViewDescription.violation("The action \(title) needs either an id or a perform")
        }
    }
}

/// What the Host does itself when the user chooses a standard action, with
/// no View Event. Each needs the Capability its matching Host Service needs;
/// opening Plugin Settings needs none.
public enum PluginViewStandardAction: Equatable {
    /// `copy_text`, under `write_clipboard`.
    case copyText(String)
    /// `open_url`, under `open_url` and its link rules.
    case openURL(String)
    /// `insert_text`, into the App the view came from, under `insert_text`.
    case insertText(String)
    /// `open_plugin_settings`: the Plugin's own Plugin Settings sheet.
    case openPluginSettings

    /// The Host Service whose Capability and System Permission the action
    /// needs, or nil when it needs none.
    public var service: PluginHostService? {
        switch self {
        case .copyText: return .writeClipboard
        case .openURL: return .openURL
        case .insertText: return .insertText
        case .openPluginSettings: return nil
        }
    }

    /// Longest text `insert_text` accepts, as its Host Service does.
    public static let maximumInsertedBytes = HTTPSRequestBudgets.maximumResponseBodyBytes

    init(perform: String, members: [String: JSONValue], title: String) throws {
        func only(_ member: String?) throws {
            let present = Set(["text", "url"].filter { members[$0] != nil })
            guard present == Set([member].compactMap { $0 }) else {
                throw PluginViewDescription.violation("The action \(title) (\(perform)) needs "
                    + (member.map { "exactly a \($0)" } ?? "no text or url"))
            }
        }
        switch perform {
        case "copy_text":
            try only("text")
            self = .copyText(try PluginViewDescription.text(members["text"], "The action \(title)'s text", allowsBlank: true))
        case "open_url":
            try only("url")
            self = .openURL(try PluginViewDescription.text(members["url"], "The action \(title)'s url"))
        case "insert_text":
            try only("text")
            let text = try PluginViewDescription.text(members["text"], "The action \(title)'s text", allowsBlank: true)
            guard text.utf8.count <= Self.maximumInsertedBytes else {
                throw PluginViewDescription.violation("The action \(title) inserts more than 128 KiB")
            }
            self = .insertText(text)
        case "open_plugin_settings":
            try only(nil)
            self = .openPluginSettings
        default:
            throw PluginViewDescription.violation("The action \(title) performs \(perform), which is not a standard action")
        }
    }
}

/// An action's keyboard shortcut, written like `cmd+shift+k`: modifiers
/// from `cmd`, `ctrl`, `option` and `shift`, at least `cmd` or `ctrl`, then
/// a lowercase letter, a digit, or `return`.
public struct PluginViewShortcut: Hashable {
    public enum Modifier: String, CaseIterable, Hashable {
        case control = "ctrl"
        case option
        case shift
        case command = "cmd"

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }
    }

    public let key: String
    public let modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public init?(parsing text: String) {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let key = parts.popLast() else { return nil }
        let modifiers = parts.compactMap(Modifier.init(rawValue:))
        guard modifiers.count == parts.count, Set(modifiers).count == modifiers.count,
              modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        let isKey = key == "return" || (key.count == 1 && key.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        })
        guard isKey else { return nil }
        self.init(key: key, modifiers: Set(modifiers))
    }

    /// Shortcuts the view keeps for itself: closing, quitting, editing text,
    /// and ⌘↩, which submits the form.
    public static let reserved: Set<PluginViewShortcut> = Set(
        ["w", "q", "c", "v", "x", "a", "z", "return"].map { PluginViewShortcut(key: $0, modifiers: [.command]) }
            + [PluginViewShortcut(key: "z", modifiers: [.command, .shift])]
    )

    /// As a menu shows it, such as `⇧⌘K`.
    public var displayText: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + (key == "return" ? "↩" : key.uppercased())
    }
}
