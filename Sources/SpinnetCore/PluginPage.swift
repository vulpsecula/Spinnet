import Foundation

/// Pages and collections (ADR 0019), part of Plugin API Level 2: a Level 2
/// Plugin may answer with a page, a tree of identified View Components with
/// at most one List or Grid, whose immediate state the Host keeps across
/// answers until the Plugin resets it. A collection may give its `total` and
/// a slice of its items, and the Host asks for the rest with `load_range`;
/// an item action may toggle a mark; a performed page or item action may ask
/// to `notify`; and calling the Plugin again while its View Session is open
/// runs the called Action in the session as `called`.
///
/// They were proved as Candidate Contract `collections`, whose revisions 1
/// to 3 are retired into Level 2 (#79); `promoted` is revision 3's record,
/// whose members Level 2 holds.
public enum CollectionsContract {
    public static let name = "collections"
    /// The revision promoted into Level 2.
    public static let revision = 3

    public static var declaration: CandidateContractRevision {
        CandidateContractRevision(name: name, revision: revision)
    }

    /// An answer may carry `page` in place of a Level 1 `view`.
    public static let answerPage = PluginInterfaceMember.behaviour("answer_page")

    /// An explicit call of one of the Plugin's Actions while its View
    /// Session is open is queued into the session as `called`.
    public static let repeatedCallsIntoSession = PluginInterfaceMember.behaviour("repeated_calls_into_session")

    /// A collection may give its `total` and a slice of its items; the Host
    /// keeps only a window of them around what the user sees and asks for
    /// the rest with `load_range`.
    public static let collectionWindow = PluginInterfaceMember.behaviour("collection_window")
    /// An item action may toggle a mark items carry, which its context menu
    /// entry shows checked.
    public static let toggleItemActions = PluginInterfaceMember.behaviour("toggle_item_actions")
    /// A page or item action the Host performs may ask to `notify`, and its
    /// outcome reaches the Plugin as `operation_finished`.
    public static let performedActionOutcomes = PluginInterfaceMember.behaviour("performed_action_outcomes")
    /// The range request.
    public static let loadRange = PluginInterfaceMember.viewEvent("load_range")

    /// The rules a Level 2 Plugin's pages get.
    public static let behaviours = [
        "answer_page", "page_identity", "page_memory", "component_identity", "immediate_state_kept",
        "explicit_reset", "composition_priority", "page_event_provenance", "gesture_snapshots",
        "collection_keyboard_roles", "collection_selection", "item_standard_actions",
        "repeated_calls_into_session", "collection_window", "toggle_item_actions", "performed_action_outcomes"
    ]

    public static let componentKinds = PluginPageComponent.Kind.allCases.map(\.rawValue)
    /// The View Events pages add.
    public static let events = ["item_action", "load_range", "called"]

    /// The catalogue IDs a page action may perform, in the catalogue's order.
    public static var viewActionIDs: [String] {
        HostServiceCatalogue.operations
            .filter { $0.offering(at: .viewAction) == .offered(candidate: name, level1: true)
                || $0.offering(at: .viewAction) == .offered(candidate: name, level1: false) }
            .map(\.id)
    }

    /// The catalogue IDs an item action may perform on the item's text.
    public static let itemActionIDs = ["selection.replace", "clipboard.write"]

    /// Revision 3 as its `candidate.json` published it, whose members Level
    /// 2 holds.
    public static let promoted = CandidateContract(
        name: name, revision: revision, baseLevel: 1,
        requires: [HostOperationsContract.declaration, HostServiceCatalogue.declaration],
        members: behaviours.map(PluginInterfaceMember.behaviour)
            + viewActionIDs.map(PluginInterfaceMember.standardAction)
            + componentKinds.map(PluginInterfaceMember.viewComponent)
            + events.map(PluginInterfaceMember.viewEvent),
        tag: "plugin-api-candidate/\(name)/r\(revision)"
    )

    // MARK: Limits

    public static let maximumComponents = 40
    public static let maximumRowChildren = 4
    public static let maximumItems = 2_000
    public static let maximumSections = 32
    public static let maximumItemActions = 6
    public static let maximumButtons = 8
    public static let columns = 2...12
    public static let defaultColumns = 8
    public static let visibleRows = 1...12
    public static let defaultGridRows = 6
    public static let defaultListRows = 8
    /// Pages remembered besides the one on screen.
    public static let pageMemory = 4
    public static let maximumTitleLength = 256
    public static let maximumSymbolLength = 32
    public static let maximumAccessoryLength = 64
    public static let maximumItemTextLength = 4_096
    public static let maximumChoices = 100
    /// Revision 3: the most items the Host holds of one collection's window.
    public static let maximumWindowItems = 600
    /// Revision 3: the Host keeps the items within this many screens of
    /// what is on screen, and asks for missing ones within one screen.
    public static let windowScreens = 2
    public static let prefetchScreens = 1
    /// Revision 3: the longest mark a toggle item action names.
    public static let maximumMarkLength = 32

    /// The title a page action without one shows: the catalogue's
    /// `default_title` for its ID.
    public static func defaultTitle(of id: String) -> String {
        switch id {
        case "host.showPluginSettings": return "Plugin Settings"
        case "selection.replace": return "Insert"
        case "clipboard.write": return "Copy"
        case "clipboardHistory.show": return "Clipboard History"
        case "open.url": return "Open in Browser"
        default: return "Open"
        }
    }
}

// MARK: - The page

/// A View Page as a declaring Plugin describes it in an answer's `page`:
/// its ID, title and components, and the one-shot `reset` and initial
/// `focus` the Host applies. Reading it throws the protocol violation that
/// ends the View Session for anything the Host would not draw: an unknown
/// member or kind, a `shortcut` anywhere, duplicate IDs, two collections, a
/// reference naming nothing, or a bound exceeded.
public struct PluginPage: Equatable {
    public enum Reset: Equatable {
        /// Every component and the page's memory start again.
        case page
        /// These components start again from their description.
        case components([String])

        public func resets(_ id: String) -> Bool {
            switch self {
            case .page: return true
            case .components(let ids): return ids.contains(id)
            }
        }
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    /// The page asks for the Host's insertion target line.
    public let showsInsertionTarget: Bool
    public let focus: String?
    public let reset: Reset?
    public let content: [PluginPageComponent]
    /// Every component, row children included, in order.
    public let components: [PluginPageComponent]

    public init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        let members = try Self.object(value, "The page", allowed: [
            "id", "title", "subtitle", "shows_insertion_target", "focus", "reset", "content"
        ])
        let id = try Self.identifier(members["id"], "The page's id")
        self.id = id
        title = try Self.text(members["title"], "The page \(id)'s title")
        subtitle = try members["subtitle"].map { try Self.text($0, "The page \(id)'s subtitle", allowsBlank: true) }
        switch members["shows_insertion_target"] {
        case nil: showsInsertionTarget = false
        case .bool(let shows)?: showsInsertionTarget = shows
        default: throw Self.violation("The page \(id)'s shows_insertion_target is not true or false")
        }
        content = try Self.array(members["content"] ?? .null, "The page \(id)'s content", minimum: 1,
                                 maximum: CollectionsContract.maximumComponents)
            .map { try PluginPageComponent(parsing: $0, inRow: false, permits: permits) }
        components = content.flatMap { component -> [PluginPageComponent] in
            if case .row(_, let children) = component { return [component] + children }
            return [component]
        }
        guard components.count <= CollectionsContract.maximumComponents else {
            throw Self.violation("The page \(id) has more than \(CollectionsContract.maximumComponents) components")
        }
        var ids: Set<String> = []
        for component in components where !ids.insert(component.id).inserted {
            throw Self.violation("The page \(id) has two components with the ID \(component.id)")
        }
        let collections = components.compactMap(\.collection)
        guard collections.count <= 1 else { throw Self.violation("The page \(id) has more than one collection") }
        for case .textField(let field) in components {
            if let searched = field.collection, searched != collections.first?.id {
                throw Self.violation("The text_field \(field.id) searches \(searched), which is not the page's collection")
            }
        }
        var eventActions: Set<String> = []
        for case .actions(_, let actions) in components {
            for case .event(let action, _) in actions.map(\.kind) where !eventActions.insert(action).inserted {
                throw Self.violation("The page \(id) has two buttons with the ID \(action)")
            }
        }
        focus = try members["focus"].map { try Self.identifier($0, "The page \(id)'s focus") }
        if let focus, !ids.contains(focus) {
            throw Self.violation("The page \(id)'s focus names \(focus), which is not on the page")
        }
        switch members["reset"] {
        case nil:
            reset = nil
        case .string("page")?:
            reset = .page
        case .array(let items)?:
            let names = try items.map { try Self.identifier($0, "A component the page \(id) resets") }
            guard (1...CollectionsContract.maximumComponents).contains(names.count), Set(names).count == names.count else {
                throw Self.violation("The page \(id)'s reset must name 1 to \(CollectionsContract.maximumComponents) components once each")
            }
            if let unknown = names.first(where: { !ids.contains($0) }) {
                throw Self.violation("The page \(id)'s reset names \(unknown), which is not on the page")
            }
            reset = .components(names)
        default:
            throw Self.violation("The page \(id)'s reset is neither \"page\" nor a list of component IDs")
        }
    }

    /// The page's one List or Grid, if it has one.
    public var collection: PluginPageCollection? { components.lazy.compactMap(\.collection).first }

    public func component(_ id: String) -> PluginPageComponent? { components.first { $0.id == id } }

    /// The text and choice fields whose values events carry, in order.
    public var inputs: [PluginPageComponent] {
        components.filter { $0.kind == .textField || $0.kind == .choiceField }
    }

    /// The Host draws its insertion target line: the page asks for it, or
    /// its collection offers an item action that inserts.
    public var drawsInsertionTarget: Bool {
        showsInsertionTarget || collection?.actions.contains { $0.perform == "selection.replace" } == true
    }

    /// The `actions` component holding the button with event ID `action`.
    public func actionsComponent(holding action: String) -> String? {
        for case .actions(let id, let actions) in components
        where actions.contains(where: { $0.kind == .event(action, title: $0.title) }) {
            return id
        }
        return nil
    }

    // MARK: Reading members

    static func violation(_ problem: String) -> PluginRuntimeError { .protocolViolation(problem) }

    static func object(_ value: JSONValue, _ name: String, allowed: Set<String>) throws -> [String: JSONValue] {
        try PluginViewDescription.object(value, name, allowed: allowed)
    }

    static func array(_ value: JSONValue, _ name: String, minimum: Int = 0, maximum: Int) throws -> [JSONValue] {
        try PluginViewDescription.array(value, name, minimum: minimum, maximum: maximum)
    }

    static func text(_ value: JSONValue?, _ name: String, allowsBlank: Bool = false, maximum: Int? = nil) throws -> String {
        let text = try PluginViewDescription.text(value, name, allowsBlank: allowsBlank)
        if let maximum, text.count > maximum { throw violation("\(name) is longer than \(maximum) characters") }
        return text
    }

    static func identifier(_ value: JSONValue?, _ name: String) throws -> String {
        try PluginViewDescription.identifier(value, name)
    }

    static func flag(_ value: JSONValue?, _ name: String) throws -> Bool {
        switch value {
        case nil: return false
        case .bool(let flag)?: return flag
        default: throw violation("\(name) is not true or false")
        }
    }

    static func integer(_ value: JSONValue?, _ name: String, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard case .number(let number) = value, number.rounded() == number, range.contains(Int(number)) else {
            throw violation("\(name) is not a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(number)
    }
}

// MARK: - Components

/// One View Component of a page.
public enum PluginPageComponent: Equatable {
    public enum Kind: String, CaseIterable, Equatable {
        case row
        case textField = "text_field"
        case choiceField = "choice_field"
        case text
        case actions
        case list
        case grid
    }

    case row(id: String, content: [PluginPageComponent])
    case textField(PluginPageTextField)
    case choiceField(PluginPageChoiceField)
    case text(id: String, title: String?, text: String)
    case actions(id: String, actions: [PluginPageAction])
    case collection(PluginPageCollection)

    public var id: String {
        switch self {
        case .row(let id, _), .text(let id, _, _), .actions(let id, _): return id
        case .textField(let field): return field.id
        case .choiceField(let field): return field.id
        case .collection(let collection): return collection.id
        }
    }

    public var kind: Kind {
        switch self {
        case .row: return .row
        case .textField: return .textField
        case .choiceField: return .choiceField
        case .text: return .text
        case .actions: return .actions
        case .collection(let collection): return collection.style == .grid ? .grid : .list
        }
    }

    public var collection: PluginPageCollection? {
        if case .collection(let collection) = self { return collection }
        return nil
    }

    init(parsing value: JSONValue, inRow: Bool, permits: (PluginInterfaceMember) -> Bool) throws {
        guard case .object(let members) = value else { throw PluginPage.violation("A page component is not an object") }
        guard case .string(let kindName)? = members["kind"], let kind = Kind(rawValue: kindName) else {
            throw PluginPage.violation("A page component's kind must be one of "
                + CollectionsContract.componentKinds.joined(separator: ", "))
        }
        guard permits(.viewComponent(kind.rawValue)) else {
            throw PluginPage.violation("The \(kind.rawValue) component is not offered to this Plugin")
        }
        if inRow, kind == .row || kind == .list || kind == .grid {
            throw PluginPage.violation("A row holds no \(kind.rawValue): only text_field, choice_field, text and actions")
        }
        switch kind {
        case .row:
            let fields = try PluginPage.object(value, "A row", allowed: ["kind", "id", "content"])
            let id = try PluginPage.identifier(fields["id"], "A row's id")
            self = .row(id: id, content: try PluginPage.array(fields["content"] ?? .null, "The row \(id)'s content", minimum: 1,
                                                              maximum: CollectionsContract.maximumRowChildren)
                .map { try PluginPageComponent(parsing: $0, inRow: true, permits: permits) })
        case .textField:
            self = .textField(try PluginPageTextField(parsing: value))
        case .choiceField:
            self = .choiceField(try PluginPageChoiceField(parsing: value))
        case .text:
            let fields = try PluginPage.object(value, "A text component", allowed: ["kind", "id", "title", "text"])
            let id = try PluginPage.identifier(fields["id"], "A text component's id")
            self = .text(id: id, title: try fields["title"].map { try PluginPage.text($0, "The text \(id)'s title") },
                         text: try PluginPage.text(fields["text"], "The text \(id)'s text", allowsBlank: true))
        case .actions:
            let fields = try PluginPage.object(value, "An actions component", allowed: ["kind", "id", "actions"])
            let id = try PluginPage.identifier(fields["id"], "An actions component's id")
            self = .actions(id: id, actions: try PluginPage.array(fields["actions"] ?? .null, "The actions \(id)'s actions",
                                                                  minimum: 1, maximum: CollectionsContract.maximumButtons)
                .map { try PluginPageAction(parsing: $0, permits: permits) })
        case .list, .grid:
            self = .collection(try PluginPageCollection(parsing: value, style: kind == .grid ? .grid : .list, permits: permits))
        }
    }
}

/// A one-line text field. Its `value` is the text it starts with when new or
/// reset; afterwards what the user typed is the Host's.
public struct PluginPageTextField: Equatable {
    public let id: String
    public let title: String
    public let placeholder: String?
    public let value: String
    public let status: String?
    public let accent: PluginViewAccent?
    /// The page's collection this field searches.
    public let collection: String?

    init(parsing value: JSONValue) throws {
        let members = try PluginPage.object(value, "A text_field", allowed: [
            "kind", "id", "title", "placeholder", "value", "status", "accent", "collection"
        ])
        let id = try PluginPage.identifier(members["id"], "A text_field's id")
        self.id = id
        title = try PluginPage.text(members["title"], "The text_field \(id)'s title")
        placeholder = try members["placeholder"].map { try PluginPage.text($0, "The text_field \(id)'s placeholder", allowsBlank: true) }
        self.value = try members["value"].map { try PluginPage.text($0, "The text_field \(id)'s value", allowsBlank: true) } ?? ""
        status = try members["status"].map { try PluginPage.text($0, "The text_field \(id)'s status") }
        if let declared = members["accent"] {
            guard case .string(let name) = declared, let accent = PluginViewAccent(rawValue: name) else {
                throw PluginPage.violation("The text_field \(id)'s accent must be one of "
                    + PluginViewAccent.allCases.map(\.rawValue).joined(separator: ", "))
            }
            self.accent = accent
        } else {
            accent = nil
        }
        collection = try members["collection"].map { try PluginPage.identifier($0, "The text_field \(id)'s collection") }
    }
}

/// A pop-up of choices. Its `value` is the choice it starts with.
public struct PluginPageChoiceField: Equatable {
    public let id: String
    public let title: String
    public let choices: [PluginViewChoice]
    public let value: String

    init(parsing value: JSONValue) throws {
        let members = try PluginPage.object(value, "A choice_field", allowed: ["kind", "id", "title", "choices", "choice_titles", "value"])
        let id = try PluginPage.identifier(members["id"], "A choice_field's id")
        self.id = id
        title = try PluginPage.text(members["title"], "The choice_field \(id)'s title")
        let values = try PluginPage.array(members["choices"] ?? .null, "The choice_field \(id)'s choices", minimum: 1,
                                          maximum: CollectionsContract.maximumChoices).map {
            try PluginPage.text($0, "A choice of \(id)", allowsBlank: true)
        }
        guard Set(values).count == values.count else { throw PluginPage.violation("The choice_field \(id) repeats a choice") }
        var titles = values
        if let declared = members["choice_titles"] {
            titles = try PluginPage.array(declared, "The choice_field \(id)'s choice_titles", minimum: values.count,
                                          maximum: values.count).map { try PluginPage.text($0, "A choice title of \(id)") }
        }
        choices = zip(values, titles).map { PluginViewChoice(value: $0, title: $1) }
        let chosen = try members["value"].map { try PluginPage.text($0, "The choice_field \(id)'s value", allowsBlank: true) }
        if let chosen, !values.contains(chosen) {
            throw PluginPage.violation("The choice_field \(id)'s value \(chosen) is not one of its choices")
        }
        self.value = chosen ?? values[0]
    }
}

/// A button of an `actions` component: an event action delivering
/// `action_chosen`, or a page action the Host performs itself by catalogue
/// ID without a View Event. Neither has a shortcut.
public struct PluginPageAction: Equatable {
    public enum Kind: Equatable {
        case event(String, title: String)
        case perform(RequestedHostOperation)
    }

    public let title: String
    public let kind: Kind

    init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        guard case .object(var members) = value else { throw PluginPage.violation("A button is not an object") }
        if members["perform"] == nil {
            members = try PluginPage.object(value, "A button", allowed: ["id", "title"])
            let title = try PluginPage.text(members["title"], "A button's title")
            let id = try PluginPage.identifier(members["id"], "The button \(title)'s id")
            self.title = title
            kind = .event(id, title: title)
            return
        }
        let declaredTitle = members.removeValue(forKey: "title")
        // Revision 3 lets a performed action ask for its outcome.
        guard members["notify"] == nil || permits(CollectionsContract.performedActionOutcomes) else {
            throw PluginPage.violation("A page action has unknown member notify")
        }
        // A page action takes what a request takes, by the IDs this
        // candidate offers as page actions.
        let operation: RequestedHostOperation
        do {
            operation = try RequestedHostOperation(parsing: .object(members), permits: { member in
                member.kind == .request ? permits(.standardAction(member.name)) : permits(member)
            })
        } catch PluginRuntimeError.protocolViolation(let message) {
            throw PluginPage.violation(message.replacingOccurrences(of: "The script's operation", with: "A page action")
                .replacingOccurrences(of: "lets an answer request", with: "offers as a page action")
                .replacingOccurrences(of: "cannot be requested in an answer", with: "is not a page action"))
        }
        title = try declaredTitle.map { try PluginPage.text($0, "The page action \(operation.perform)'s title") }
            ?? CollectionsContract.defaultTitle(of: operation.perform)
        kind = .perform(operation)
    }
}

// MARK: - Collections

/// A List or Grid: items the Host draws, selects, scrolls and asks for more
/// of, whose data, search, order and batches are the Plugin's.
///
/// A collection is whole, every item given at once, or windowed, when it
/// gives `total`: the answer gives `total` positions and the items of one slice of them from
/// `start`, and sections only as headers with their `count`. Positions are
/// always counted from the collection's first item.
public struct PluginPageCollection: Equatable {
    public enum Style: Equatable { case list, grid }

    public let id: String
    public let style: Style
    /// The collection's sections in order; a collection with plain `items`
    /// has one untitled section whose `id` is nil. Each section's `items`
    /// are those of the answer's slice that fall within it.
    public let sections: [PluginPageSection]
    public let selected: String?
    public let emptyText: String
    public let actions: [PluginPageItemAction]
    /// Cells across; 1 for a list.
    public let columns: Int
    /// Rows visible initially.
    public let rows: Int
    /// How many items the collection has, given or not.
    public let total: Int
    /// The position of the first given item.
    public let start: Int
    /// The answer gave `total` and one slice of the items.
    public let isWindowed: Bool
    /// The given items, in order, sections included: positions `start`
    /// onwards.
    public let items: [PluginPageItem]
    /// Each given item's position.
    public let positions: [String: Int]

    init(parsing value: JSONValue, style: Style, permits: (PluginInterfaceMember) -> Bool) throws {
        let kind = style == .grid ? "grid" : "list"
        var allowed: Set<String> = ["kind", "id", "items", "sections", "selected", "empty_text", "actions", "rows"]
        if style == .grid { allowed.insert("columns") }
        if permits(CollectionsContract.collectionWindow) { allowed.formUnion(["total", "start"]) }
        let members = try PluginPage.object(value, "A \(kind)", allowed: allowed)
        let id = try PluginPage.identifier(members["id"], "A \(kind)'s id")
        self.id = id
        self.style = style
        actions = try members["actions"].map {
            try PluginPage.array($0, "The \(kind) \(id)'s actions", minimum: 1, maximum: CollectionsContract.maximumItemActions)
                .map { try PluginPageItemAction(parsing: $0, permits: permits) }
        } ?? []
        var actionIDs: Set<String> = []
        for action in actions where !actionIDs.insert(action.id).inserted {
            throw PluginPage.violation("The \(kind) \(id) has two item actions with the ID \(action.id)")
        }
        guard actions.filter(\.isDefault).count <= 1 else {
            throw PluginPage.violation("The \(kind) \(id) has more than one default item action")
        }
        var marks: Set<String> = []
        for case let mark? in actions.map(\.toggle) where !marks.insert(mark).inserted {
            throw PluginPage.violation("The \(kind) \(id) has two item actions toggling the mark \(mark)")
        }
        let offering = PluginPageItem.Offering(actions: actionIDs, marks: marks, allowsMarks: permits(CollectionsContract.toggleItemActions))
        isWindowed = members["total"] != nil
        if isWindowed {
            let total = try PluginPage.integer(members["total"], "The \(kind) \(id)'s total",
                                               in: 0...CollectionsContract.maximumItems, default: 0)
            let start = try PluginPage.integer(members["start"], "The \(kind) \(id)'s start", in: 0...total, default: 0)
            let items = try PluginPage.array(members["items"] ?? .array([]), "The \(kind) \(id)'s items",
                                             maximum: CollectionsContract.maximumItems)
                .map { try PluginPageItem(parsing: $0, offering: offering) }
            guard start + items.count <= total else {
                throw PluginPage.violation("The \(kind) \(id) gives items past its total of \(total)")
            }
            var sections: [PluginPageSection] = []
            if let declared = members["sections"] {
                var next = 0
                for value in try PluginPage.array(declared, "The \(kind) \(id)'s sections", minimum: 1,
                                                  maximum: CollectionsContract.maximumSections) {
                    let header = try PluginPageSection(parsingHeader: value, at: next)
                    next += header.count
                    let slice = items.indices.filter { (header.start..<next).contains(start + $0) }.map { items[$0] }
                    sections.append(PluginPageSection(id: header.id, title: header.title, items: slice,
                                                      start: header.start, count: header.count))
                }
                guard next == total else {
                    throw PluginPage.violation("The \(kind) \(id)'s sections count \(next) items, not its total of \(total)")
                }
            } else {
                sections = [PluginPageSection(id: nil, title: nil, items: items, start: 0, count: total)]
            }
            self.sections = sections
            self.items = items
            self.total = total
            self.start = start
        } else {
            guard members["start"] == nil else {
                throw PluginPage.violation("The \(kind) \(id) gives a start without a total")
            }
            switch (members["items"], members["sections"]) {
            case (let items?, nil):
                let parsed = try PluginPage.array(items, "The \(kind) \(id)'s items", maximum: CollectionsContract.maximumItems)
                    .map { try PluginPageItem(parsing: $0, offering: offering) }
                sections = [PluginPageSection(id: nil, title: nil, items: parsed, start: 0, count: parsed.count)]
            case (nil, let declared?):
                var next = 0
                sections = try PluginPage.array(declared, "The \(kind) \(id)'s sections", minimum: 1,
                                                maximum: CollectionsContract.maximumSections)
                    .map { value in
                        let section = try PluginPageSection(parsing: value, offering: offering, at: next)
                        next += section.count
                        return section
                    }
            default:
                throw PluginPage.violation("The \(kind) \(id) needs either items or sections, not both")
            }
            items = sections.flatMap(\.items)
            guard items.count <= CollectionsContract.maximumItems else {
                throw PluginPage.violation("The \(kind) \(id) has more than \(CollectionsContract.maximumItems) items")
            }
            total = items.count
            start = 0
        }
        var sectionIDs: Set<String> = []
        for section in sections where section.id != nil && !sectionIDs.insert(section.id ?? "").inserted {
            throw PluginPage.violation("The \(kind) \(id) has two sections with the ID \(section.id ?? "")")
        }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where positions.updateValue(start + index, forKey: item.id) != nil {
            throw PluginPage.violation("The \(kind) \(id) has two items with the ID \(item.id)")
        }
        self.positions = positions
        selected = try members["selected"].map { try PluginPage.identifier($0, "The \(kind) \(id)'s selected") }
        if let selected, positions[selected] == nil {
            throw PluginPage.violation("The \(kind) \(id)'s selected names \(selected), which is not one of its items")
        }
        emptyText = try members["empty_text"].map { try PluginPage.text($0, "The \(kind) \(id)'s empty_text") } ?? "No items"
        columns = style == .grid
            ? try PluginPage.integer(members["columns"], "The grid \(id)'s columns", in: CollectionsContract.columns,
                                     default: CollectionsContract.defaultColumns)
            : 1
        rows = try PluginPage.integer(members["rows"], "The \(kind) \(id)'s rows", in: CollectionsContract.visibleRows,
                                      default: style == .grid ? CollectionsContract.defaultGridRows : CollectionsContract.defaultListRows)
    }

    /// The given item at position `position`.
    public func item(at position: Int) -> PluginPageItem? {
        items.indices.contains(position - start) ? items[position - start] : nil
    }

    public func item(_ id: String) -> PluginPageItem? { positions[id].flatMap(item(at:)) }

    /// The positions the answer gave items for.
    public var slice: Range<Int> { start..<(start + items.count) }

    /// The index in `sections` of the section holding `position`.
    public func sectionIndex(at position: Int) -> Int? {
        sections.firstIndex { ($0.start..<($0.start + $0.count)).contains(position) }
    }

    /// The section of the item with `id`: its ID, or nil for a collection of
    /// plain items.
    public func section(of id: String) -> String? {
        positions[id].flatMap(sectionIndex(at:)).flatMap { sections[$0].id }
    }

    public var defaultAction: PluginPageItemAction? { actions.first(where: \.isDefault) }

    /// The item actions `item` offers: the default first, then the others in
    /// the order declared, as its context menu lists them.
    public func actions(of item: PluginPageItem) -> [PluginPageItemAction] {
        let offered = actions.filter { item.actions?.contains($0.id) ?? true }
        return offered.filter(\.isDefault) + offered.filter { !$0.isDefault }
    }

    /// The `clipboard.write` item action ⌘C performs: only when the
    /// collection has exactly one.
    public var copyAction: PluginPageItemAction? {
        let copies = actions.filter { $0.perform == "clipboard.write" }
        return copies.count == 1 ? copies[0] : nil
    }

    /// What the gesture on `item` carries.
    public func snapshot(of item: PluginPageItem) -> PluginPageItemSnapshot {
        PluginPageItemSnapshot(id: item.id, section: section(of: item.id), text: item.resolvedText, marks: item.marks)
    }
}

public struct PluginPageSection: Equatable {
    /// Nil for the one section of a collection with plain `items`.
    public let id: String?
    public let title: String?
    /// The given items within it.
    public let items: [PluginPageItem]
    /// The position of its first item, and how many it holds, given or not.
    public let start: Int
    public let count: Int

    init(id: String?, title: String?, items: [PluginPageItem], start: Int, count: Int) {
        self.id = id
        self.title = title
        self.items = items
        self.start = start
        self.count = count
    }

    /// A section of a whole collection, its items given.
    init(parsing value: JSONValue, offering: PluginPageItem.Offering, at start: Int) throws {
        let members = try PluginPage.object(value, "A section", allowed: ["id", "title", "items"])
        let id = try PluginPage.identifier(members["id"], "A section's id")
        self.id = id
        title = try members["title"].map { try PluginPage.text($0, "The section \(id)'s title") }
        items = try PluginPage.array(members["items"] ?? .null, "The section \(id)'s items",
                                     maximum: CollectionsContract.maximumItems)
            .map { try PluginPageItem(parsing: $0, offering: offering) }
        self.start = start
        count = items.count
    }

    /// A section header of a windowed collection: its `count` of items,
    /// which come in the collection's slice.
    init(parsingHeader value: JSONValue, at start: Int) throws {
        let members = try PluginPage.object(value, "A section of a collection with a total", allowed: ["id", "title", "count"])
        let id = try PluginPage.identifier(members["id"], "A section's id")
        self.id = id
        title = try members["title"].map { try PluginPage.text($0, "The section \(id)'s title") }
        guard members["count"] != nil else {
            throw PluginPage.violation("The section \(id) gives no count: a collection with a total gives its items apart")
        }
        count = try PluginPage.integer(members["count"], "The section \(id)'s count", in: 0...CollectionsContract.maximumItems,
                                       default: 0)
        items = []
        self.start = start
    }
}

public struct PluginPageItem: Equatable, Identifiable {
    /// What an item may name: its collection's item actions and the marks
    /// its toggle actions declare.
    struct Offering {
        let actions: Set<String>
        let marks: Set<String>
        let allowsMarks: Bool
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String?
    public let accessory: String?
    public let text: String?
    /// The item actions it offers by ID; all of the collection's when nil.
    public let actions: [String]?
    /// Revision 3: the marks it carries, each one a toggle item action of its
    /// collection names; such an action shows checked for it.
    public let marks: [String]

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, accessory: String? = nil,
                text: String? = nil, actions: [String]? = nil, marks: [String] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accessory = accessory
        self.text = text
        self.actions = actions
        self.marks = marks
    }

    init(parsing value: JSONValue, offering declared: Offering) throws {
        var allowed: Set<String> = ["id", "title", "subtitle", "symbol", "accessory", "text", "actions"]
        if declared.allowsMarks { allowed.insert("marks") }
        let members = try PluginPage.object(value, "An item", allowed: allowed)
        let id = try PluginPage.identifier(members["id"], "An item's id")
        self.id = id
        title = try PluginPage.text(members["title"], "The item \(id)'s title", maximum: CollectionsContract.maximumTitleLength)
        subtitle = try members["subtitle"].map {
            try PluginPage.text($0, "The item \(id)'s subtitle", allowsBlank: true, maximum: CollectionsContract.maximumTitleLength)
        }
        symbol = try members["symbol"].map {
            try PluginPage.text($0, "The item \(id)'s symbol", maximum: CollectionsContract.maximumSymbolLength)
        }
        accessory = try members["accessory"].map {
            try PluginPage.text($0, "The item \(id)'s accessory", allowsBlank: true, maximum: CollectionsContract.maximumAccessoryLength)
        }
        text = try members["text"].map {
            try PluginPage.text($0, "The item \(id)'s text", allowsBlank: true, maximum: CollectionsContract.maximumItemTextLength)
        }
        if let listed = members["actions"] {
            let names = try PluginPage.array(listed, "The item \(id)'s actions", maximum: CollectionsContract.maximumItemActions)
                .map { try PluginPage.identifier($0, "An item action of \(id)") }
            guard Set(names).count == names.count else { throw PluginPage.violation("The item \(id) offers an action twice") }
            if let unknown = names.first(where: { !declared.actions.contains($0) }) {
                throw PluginPage.violation("The item \(id) offers \(unknown), which its collection does not declare")
            }
            actions = names
        } else {
            actions = nil
        }
        if let listed = members["marks"] {
            let names = try PluginPage.array(listed, "The item \(id)'s marks", maximum: CollectionsContract.maximumItemActions)
                .map { try PluginPage.identifier($0, "A mark of \(id)") }
            guard Set(names).count == names.count else { throw PluginPage.violation("The item \(id) carries a mark twice") }
            if let unknown = names.first(where: { !declared.marks.contains($0) }) {
                throw PluginPage.violation("The item \(id) carries the mark \(unknown), which no toggle item action of its collection names")
            }
            marks = names
        } else {
            marks = []
        }
    }

    /// The text item actions use: `text`, else `symbol`, else `title`.
    public var resolvedText: String { text ?? symbol ?? title }
}

/// An action offered on items: one delivering `item_action`, one toggling a
/// mark (revision 3), which delivers `item_action` too and shows checked
/// for an item carrying its mark, or one the Host performs on the item's
/// text by catalogue ID.
public struct PluginPageItemAction: Equatable {
    public let id: String
    public let title: String
    public let isDefault: Bool
    /// `selection.replace` or `clipboard.write`, performed by the Host.
    public let perform: String?
    public let closesView: Bool
    /// Revision 3: the mark this action toggles.
    public let toggle: String?
    /// Revision 3: a performed action's outcome reaches the Plugin.
    public let notify: Bool

    init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        var allowed: Set<String> = ["id", "title", "default", "perform", "closes_view"]
        if permits(CollectionsContract.toggleItemActions) { allowed.insert("toggle") }
        if permits(CollectionsContract.performedActionOutcomes) { allowed.insert("notify") }
        let members = try PluginPage.object(value, "An item action", allowed: allowed)
        let id = try PluginPage.identifier(members["id"], "An item action's id")
        self.id = id
        title = try PluginPage.text(members["title"], "The item action \(id)'s title")
        switch members["default"] {
        case nil: isDefault = false
        case .bool(true)?: isDefault = true
        default: throw PluginPage.violation("The item action \(id)'s default is not true")
        }
        toggle = try members["toggle"].map { mark in
            let name = try PluginPage.identifier(mark, "The item action \(id)'s toggle")
            guard name.count <= CollectionsContract.maximumMarkLength else {
                throw PluginPage.violation("The item action \(id)'s toggle is longer than \(CollectionsContract.maximumMarkLength) characters")
            }
            return name
        }
        switch members["perform"] {
        case nil:
            perform = nil
            guard members["closes_view"] == nil else {
                throw PluginPage.violation("The item action \(id) delivers an event, so it has no closes_view; its answer closes the view")
            }
            guard members["notify"] == nil else {
                throw PluginPage.violation("The item action \(id) delivers an event, so it has no notify: the Plugin hears it anyway")
            }
            closesView = false
            notify = false
        case .string(let name)? where CollectionsContract.itemActionIDs.contains(name):
            guard permits(.standardAction(name)) else {
                throw PluginPage.violation("The item action \(id) performs \(name), which is not offered to this Plugin")
            }
            guard toggle == nil else {
                throw PluginPage.violation("The item action \(id) toggles a mark, which only the Plugin can do, so it performs nothing")
            }
            perform = name
            closesView = try PluginPage.flag(members["closes_view"], "The item action \(id)'s closes_view")
            notify = try PluginPage.flag(members["notify"], "The item action \(id)'s notify")
        default:
            throw PluginPage.violation("The item action \(id) may perform only "
                + CollectionsContract.itemActionIDs.joined(separator: " or "))
        }
    }

    /// The operation the Host performs for `item`, for one that performs;
    /// `snapshot` is the item as shown, which its outcome carries.
    public func operation(on item: PluginPageItem, snapshot: PluginPageItemSnapshot? = nil) -> RequestedHostOperation? {
        perform.map { RequestedHostOperation(perform: $0, input: .object(["text": .string(item.resolvedText)]), id: id,
                                             closesView: closesView, notify: notify, item: notify ? snapshot : nil) }
    }

    /// Whether this action shows checked for `item`: it toggles a mark the
    /// item carries.
    public func isChecked(for item: PluginPageItem) -> Bool {
        toggle.map(item.marks.contains) ?? false
    }
}

/// The item as shown when the user acted, as `item_action` carries it.
public struct PluginPageItemSnapshot: Equatable, Hashable {
    public let id: String
    public let section: String?
    /// The item's resolved text.
    public let text: String
    /// Revision 3: the marks it carried.
    public let marks: [String]

    public init(id: String, section: String?, text: String, marks: [String] = []) {
        self.id = id
        self.section = section
        self.text = text
        self.marks = marks
    }

    /// Its JSON: the resolved text only where it differs from the ID, and
    /// marks only when it carried any.
    public var json: JSONValue {
        var members: [String: JSONValue] = ["id": .string(id)]
        if let section { members["section"] = .string(section) }
        if text != id { members["text"] = .string(text) }
        if !marks.isEmpty { members["marks"] = .array(marks.map(JSONValue.string)) }
        return .object(members)
    }
}
