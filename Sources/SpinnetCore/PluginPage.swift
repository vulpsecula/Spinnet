import Foundation

/// Candidate Contract `collections` revision 1 (ADR 0019): a declaring
/// Plugin may answer with a page, a tree of identified View Components with
/// at most one List or Grid, whose immediate state the Host keeps across
/// answers until the Plugin resets it. Its `candidate.json` under
/// `PluginAPI/candidates/collections/r1/` is `candidate` as JSON.
public enum CollectionsContract {
    public static let name = "collections"
    public static let revision = 1

    public static var declaration: CandidateContractRevision {
        CandidateContractRevision(name: name, revision: revision)
    }

    /// An answer may carry `page` in place of a Level 1 `view`.
    public static let answerPage = PluginInterfaceMember.behaviour("answer_page")

    /// The rules a declaring Plugin gets, as `candidate.json` lists them.
    public static let behaviours = [
        "answer_page", "page_identity", "page_memory", "component_identity", "immediate_state_kept",
        "explicit_reset", "composition_priority", "page_event_provenance", "gesture_snapshots",
        "collection_keyboard_roles", "collection_selection", "item_standard_actions"
    ]

    public static let componentKinds = PluginPageComponent.Kind.allCases.map(\.rawValue)
    public static let events = ["item_action", "load_more"]

    /// The catalogue IDs a page action may perform, in the catalogue's order.
    public static var viewActionIDs: [String] {
        HostServiceCatalogue.operations
            .filter { $0.offering(at: .viewAction) == .offered(candidate: name, level1: true)
                || $0.offering(at: .viewAction) == .offered(candidate: name, level1: false) }
            .map(\.id)
    }

    /// The catalogue IDs an item action may perform on the item's text.
    public static let itemActionIDs = ["selection.replace", "clipboard.write"]

    /// The revision as its `candidate.json` publishes it.
    public static let candidate = CandidateContract(
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
        guard members["notify"] == nil else { throw PluginPage.violation("A page action has unknown member notify") }
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
public struct PluginPageCollection: Equatable {
    public enum Style: Equatable { case list, grid }

    public let id: String
    public let style: Style
    /// The collection's sections in order; a collection with `items` has one
    /// untitled section whose `id` is nil.
    public let sections: [PluginPageSection]
    public let hasMore: Bool
    public let selected: String?
    public let emptyText: String
    public let actions: [PluginPageItemAction]
    /// Cells across; 1 for a list.
    public let columns: Int
    /// Rows visible initially.
    public let rows: Int
    /// Every item, in order, sections included.
    public let items: [PluginPageItem]
    /// Each item's position in `items`.
    public let positions: [String: Int]
    /// The section each item is in, by position: an index into `sections`.
    public let sectionOfItem: [Int]

    init(parsing value: JSONValue, style: Style, permits: (PluginInterfaceMember) -> Bool) throws {
        let kind = style == .grid ? "grid" : "list"
        var allowed: Set<String> = ["kind", "id", "items", "sections", "has_more", "selected", "empty_text", "actions", "rows"]
        if style == .grid { allowed.insert("columns") }
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
        switch (members["items"], members["sections"]) {
        case (let items?, nil):
            sections = [PluginPageSection(id: nil, title: nil, items: try PluginPage.array(
                items, "The \(kind) \(id)'s items", maximum: CollectionsContract.maximumItems
            ).map { try PluginPageItem(parsing: $0, offering: actionIDs) })]
        case (nil, let declared?):
            sections = try PluginPage.array(declared, "The \(kind) \(id)'s sections", minimum: 1,
                                            maximum: CollectionsContract.maximumSections)
                .map { try PluginPageSection(parsing: $0, offering: actionIDs) }
            var sectionIDs: Set<String> = []
            for section in sections where !sectionIDs.insert(section.id ?? "").inserted {
                throw PluginPage.violation("The \(kind) \(id) has two sections with the ID \(section.id ?? "")")
            }
        default:
            throw PluginPage.violation("The \(kind) \(id) needs either items or sections, not both")
        }
        var items: [PluginPageItem] = []
        var sectionOfItem: [Int] = []
        for (index, section) in sections.enumerated() {
            items += section.items
            sectionOfItem += Array(repeating: index, count: section.items.count)
        }
        guard items.count <= CollectionsContract.maximumItems else {
            throw PluginPage.violation("The \(kind) \(id) has more than \(CollectionsContract.maximumItems) items")
        }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where positions.updateValue(index, forKey: item.id) != nil {
            throw PluginPage.violation("The \(kind) \(id) has two items with the ID \(item.id)")
        }
        self.items = items
        self.positions = positions
        self.sectionOfItem = sectionOfItem
        hasMore = try PluginPage.flag(members["has_more"], "The \(kind) \(id)'s has_more")
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

    /// The item at `index`.
    public func item(at index: Int) -> PluginPageItem? { items.indices.contains(index) ? items[index] : nil }

    public func item(_ id: String) -> PluginPageItem? { positions[id].map { items[$0] } }

    /// The section of the item with `id`: its ID, or nil for a collection of
    /// plain items.
    public func section(of id: String) -> String? {
        positions[id].flatMap { sections[sectionOfItem[$0]].id }
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
        PluginPageItemSnapshot(id: item.id, section: section(of: item.id), text: item.resolvedText)
    }
}

public struct PluginPageSection: Equatable {
    /// Nil for the one section of a collection with plain `items`.
    public let id: String?
    public let title: String?
    public let items: [PluginPageItem]

    init(id: String?, title: String?, items: [PluginPageItem]) {
        self.id = id
        self.title = title
        self.items = items
    }

    init(parsing value: JSONValue, offering actions: Set<String>) throws {
        let members = try PluginPage.object(value, "A section", allowed: ["id", "title", "items"])
        let id = try PluginPage.identifier(members["id"], "A section's id")
        self.id = id
        title = try members["title"].map { try PluginPage.text($0, "The section \(id)'s title") }
        items = try PluginPage.array(members["items"] ?? .null, "The section \(id)'s items",
                                     maximum: CollectionsContract.maximumItems)
            .map { try PluginPageItem(parsing: $0, offering: actions) }
    }
}

public struct PluginPageItem: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String?
    public let accessory: String?
    public let text: String?
    /// The item actions it offers by ID; all of the collection's when nil.
    public let actions: [String]?

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, accessory: String? = nil,
                text: String? = nil, actions: [String]? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accessory = accessory
        self.text = text
        self.actions = actions
    }

    init(parsing value: JSONValue, offering declared: Set<String>) throws {
        let members = try PluginPage.object(value, "An item", allowed: [
            "id", "title", "subtitle", "symbol", "accessory", "text", "actions"
        ])
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
            if let unknown = names.first(where: { !declared.contains($0) }) {
                throw PluginPage.violation("The item \(id) offers \(unknown), which its collection does not declare")
            }
            actions = names
        } else {
            actions = nil
        }
    }

    /// The text item actions use: `text`, else `symbol`, else `title`.
    public var resolvedText: String { text ?? symbol ?? title }
}

/// An action offered on items: one delivering `item_action`, or one the Host
/// performs on the item's text by catalogue ID.
public struct PluginPageItemAction: Equatable {
    public let id: String
    public let title: String
    public let isDefault: Bool
    /// `selection.replace` or `clipboard.write`, performed by the Host.
    public let perform: String?
    public let closesView: Bool

    init(parsing value: JSONValue, permits: (PluginInterfaceMember) -> Bool) throws {
        let members = try PluginPage.object(value, "An item action", allowed: ["id", "title", "default", "perform", "closes_view"])
        let id = try PluginPage.identifier(members["id"], "An item action's id")
        self.id = id
        title = try PluginPage.text(members["title"], "The item action \(id)'s title")
        switch members["default"] {
        case nil: isDefault = false
        case .bool(true)?: isDefault = true
        default: throw PluginPage.violation("The item action \(id)'s default is not true")
        }
        switch members["perform"] {
        case nil:
            perform = nil
            guard members["closes_view"] == nil else {
                throw PluginPage.violation("The item action \(id) delivers an event, so it has no closes_view; its answer closes the view")
            }
            closesView = false
        case .string(let name)? where CollectionsContract.itemActionIDs.contains(name):
            guard permits(.standardAction(name)) else {
                throw PluginPage.violation("The item action \(id) performs \(name), which is not offered to this Plugin")
            }
            perform = name
            closesView = try PluginPage.flag(members["closes_view"], "The item action \(id)'s closes_view")
        default:
            throw PluginPage.violation("The item action \(id) may perform only "
                + CollectionsContract.itemActionIDs.joined(separator: " or "))
        }
    }

    /// The operation the Host performs for `item`, for one that performs.
    public func operation(on item: PluginPageItem) -> RequestedHostOperation? {
        perform.map { RequestedHostOperation(perform: $0, input: .object(["text": .string(item.resolvedText)]), id: id,
                                             closesView: closesView) }
    }
}

/// The item as shown when the user acted, as `item_action` carries it.
public struct PluginPageItemSnapshot: Equatable, Hashable {
    public let id: String
    public let section: String?
    /// The item's resolved text.
    public let text: String

    public init(id: String, section: String?, text: String) {
        self.id = id
        self.section = section
        self.text = text
    }

    /// Its JSON: the resolved text only where it differs from the ID.
    public var json: JSONValue {
        var members: [String: JSONValue] = ["id": .string(id)]
        if let section { members["section"] = .string(section) }
        if text != id { members["text"] = .string(text) }
        return .object(members)
    }
}
