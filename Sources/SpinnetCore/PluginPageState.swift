import Foundation

/// The caret and selected range of a text field, in UTF-16 units as AppKit
/// counts them.
public struct PluginPageCaret: Equatable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int = 0) {
        self.location = location
        self.length = length
    }

    /// After the last character of `text`.
    public static func end(of text: String) -> PluginPageCaret { PluginPageCaret(location: text.utf16.count) }
}

/// The Immediate State of one View Page (ADR 0019): what the user is doing in
/// it, which the Host keeps across the Plugin's answers. It is never part of
/// the Plugin's `state`; events carry snapshots of it.
public struct PluginPageImmediateState: Equatable {
    /// Each text field's committed text, by component ID.
    public var texts: [String: String] = [:]
    /// Each text field's caret.
    public var carets: [String: PluginPageCaret] = [:]
    /// Each choice field's choice.
    public var choices: [String: String] = [:]
    /// The collection's selected item, by collection ID; absent for none.
    public var selections: [String: String] = [:]
    /// Where the selected item was, so another item can take its place when
    /// it leaves.
    public var selectionPositions: [String: Int] = [:]
    /// The first visible item of each collection, which scrolling keeps in
    /// place; absent at the top.
    public var scrollAnchors: [String: String] = [:]
    /// The focused component.
    public var focus: String?

    public init() {}
}

/// What the Host keeps of the pages of one View Session: the page on screen
/// with its immediate state, and up to `CollectionsContract.pageMemory`
/// earlier pages' immediate state by page ID, most recent first. It is not a
/// stack: nothing goes back by itself, and a page comes back only when the
/// Plugin answers with its ID again.
///
/// The Host's renderer and the Plugin test kit both apply answers through it,
/// so the rules are the same in both.
public struct PluginPageMemory: Equatable {
    /// What applying an answer did, for whatever draws the page.
    public struct Applied: Equatable {
        /// Another page, or the first, is shown.
        public var pageChanged = false
        /// It is shown with the state it had when it was last left.
        public var restored = false
        /// Components that start again from their description: new, of
        /// another kind, or reset.
        public var renewed: Set<String> = []
        /// Text fields whose reset was dropped because a composition was
        /// open in them.
        public var keptComposing: Set<String> = []
    }

    public private(set) var page: PluginPage?
    public var state = PluginPageImmediateState()
    /// Pages left, most recent first.
    public private(set) var remembered: [(page: PluginPage, state: PluginPageImmediateState)] = []

    public init() {}

    public static func == (lhs: PluginPageMemory, rhs: PluginPageMemory) -> Bool {
        lhs.page == rhs.page && lhs.state == rhs.state
            && lhs.remembered.map(\.page.id) == rhs.remembered.map(\.page.id)
            && lhs.remembered.map(\.state) == rhs.remembered.map(\.state)
    }

    /// The IDs of the remembered pages, most recent first.
    public var rememberedPages: [String] { remembered.map(\.page.id) }

    /// Applies an answer's page. `composing` names the text fields in which
    /// an input-method composition is open now: their reset is dropped, so
    /// no answer interrupts a composition.
    @discardableResult
    public mutating func show(_ next: PluginPage, composing: Set<String> = []) -> Applied {
        var applied = Applied()
        var composing = composing
        if page?.id != next.id {
            if let current = page { remember(current, state) }
            composing = []
            applied.pageChanged = true
            if let index = remembered.firstIndex(where: { $0.page.id == next.id }) {
                let restored = remembered.remove(at: index)
                page = restored.page
                state = restored.state
                applied.restored = true
            } else {
                page = nil
                state = PluginPageImmediateState()
            }
        }
        if next.reset == .page {
            remembered.removeAll()
            applied.restored = false
        }
        let previous = page
        var kept = PluginPageImmediateState()
        for component in next.components {
            let id = component.id
            let resets = next.reset?.resets(id) == true
            let sameKind = previous?.component(id)?.kind == component.kind
            let keepsComposition = resets && sameKind && component.kind == .textField && composing.contains(id)
            if keepsComposition { applied.keptComposing.insert(id) }
            if sameKind, !resets || keepsComposition {
                carry(id, from: state, to: &kept, reconciling: component.collection, previous: previous?.component(id)?.collection)
            } else {
                applied.renewed.insert(id)
                start(component, in: &kept)
            }
        }
        // Focus is the Host's: it stays where it is unless its component
        // went away, and a new or reset page starts it from `focus`.
        let startsAnew = (applied.pageChanged && !applied.restored) || next.reset == .page
        if startsAnew {
            kept.focus = Self.initialFocus(of: next)
        } else if let focus = state.focus, next.component(focus) != nil {
            kept.focus = focus
        } else {
            kept.focus = Self.fallbackFocus(of: next)
        }
        page = next
        state = kept
        return applied
    }

    /// A Level 1 view replaced the page, which counts as a page change: the
    /// page is remembered and none is shown.
    public mutating func showLevelOneView() {
        if let current = page { remember(current, state) }
        page = nil
        state = PluginPageImmediateState()
    }

    private mutating func remember(_ page: PluginPage, _ state: PluginPageImmediateState) {
        remembered.removeAll { $0.page.id == page.id }
        remembered.insert((page, state), at: 0)
        if remembered.count > CollectionsContract.pageMemory { remembered.removeLast(remembered.count - CollectionsContract.pageMemory) }
    }

    private func carry(_ id: String, from old: PluginPageImmediateState, to kept: inout PluginPageImmediateState,
                       reconciling collection: PluginPageCollection?, previous: PluginPageCollection?) {
        if let text = old.texts[id] { kept.texts[id] = text }
        if let caret = old.carets[id] { kept.carets[id] = caret }
        if let choice = old.choices[id] { kept.choices[id] = choice }
        if let anchor = old.scrollAnchors[id] { kept.scrollAnchors[id] = anchor }
        guard let collection else { return }
        // The selected item stays selected wherever it moved; else the item
        // now at its place, clamped to the last; else the first.
        if let selected = old.selections[id], let position = collection.positions[selected] {
            kept.selections[id] = selected
            kept.selectionPositions[id] = position
        } else if !collection.items.isEmpty {
            let position = old.selections[id] != nil ? min(old.selectionPositions[id] ?? 0, collection.items.count - 1) : 0
            kept.selections[id] = collection.items[position].id
            kept.selectionPositions[id] = position
        }
    }

    private func start(_ component: PluginPageComponent, in kept: inout PluginPageImmediateState) {
        switch component {
        case .textField(let field):
            kept.texts[field.id] = field.value
            kept.carets[field.id] = .end(of: field.value)
        case .choiceField(let field):
            kept.choices[field.id] = field.value
        case .collection(let collection):
            if let first = collection.selected ?? collection.items.first?.id {
                kept.selections[collection.id] = first
                kept.selectionPositions[collection.id] = collection.positions[first]
            }
        default:
            break
        }
    }

    /// `page.focus`, else the first text field, else the collection.
    public static func initialFocus(of page: PluginPage) -> String? { page.focus ?? fallbackFocus(of: page) }

    static func fallbackFocus(of page: PluginPage) -> String? {
        page.components.first { $0.kind == .textField }?.id ?? page.collection?.id
    }

    // MARK: The user's input

    /// The user changed a text field's committed text.
    public mutating func setText(_ text: String, of field: String, caret: PluginPageCaret? = nil) {
        guard state.texts[field] != nil else { return }
        state.texts[field] = text
        state.carets[field] = caret ?? .end(of: text)
    }

    public mutating func setChoice(_ value: String, of field: String) {
        guard case .choiceField(let declared)? = page?.component(field),
              declared.choices.contains(where: { $0.value == value }) else { return }
        state.choices[field] = value
    }

    /// Selects `item` of the page's collection.
    public mutating func select(_ item: String) {
        guard let collection = page?.collection, let position = collection.positions[item] else { return }
        state.selections[collection.id] = item
        state.selectionPositions[collection.id] = position
    }

    /// Moves the collection's selection as an arrow, Page or Home/End key
    /// does, and returns the item now selected.
    @discardableResult
    public mutating func moveSelection(_ move: PluginPageCollection.Move) -> PluginPageItem? {
        guard let collection = page?.collection,
              let index = collection.index(moving: move, from: selectedPosition) else { return nil }
        select(collection.items[index].id)
        return collection.items[index]
    }

    // MARK: Snapshots

    /// The page's collection's selected item.
    public var selectedItem: PluginPageItem? {
        guard let collection = page?.collection, let id = state.selections[collection.id] else { return nil }
        return collection.item(id)
    }

    public var selectedPosition: Int? {
        guard let collection = page?.collection, let id = state.selections[collection.id] else { return nil }
        return collection.positions[id]
    }

    /// Every input of the page, as `values` carries it.
    public var values: JSONValue {
        var values: [String: JSONValue] = [:]
        for input in page?.inputs ?? [] {
            switch input {
            case .textField(let field): values[field.id] = .string(state.texts[field.id] ?? field.value)
            case .choiceField(let field): values[field.id] = .string(state.choices[field.id] ?? field.value)
            default: break
            }
        }
        return .object(values)
    }

    /// The page's collection mapped to its selected item, or empty without one.
    public var selection: JSONValue {
        guard let collection = page?.collection else { return .object([:]) }
        return .object([collection.id: selectedItem.map { .string($0.id) } ?? .null])
    }
}

// MARK: - Navigation

public extension PluginPageCollection {
    /// A key that moves the selection.
    enum Move: Equatable {
        /// One row: one item in a list, one grid row in the same column,
        /// crossing into the next or previous section with the column
        /// clamped.
        case up, down
        /// One item, wrapping to the previous or next row.
        case left, right
        /// A screenful of rows.
        case pageUp, pageDown
        /// The first or last loaded item.
        case home, end
    }

    /// Where `move` takes the selection from `index`: from no selection,
    /// any move selects the first item. Nil when there are no items.
    func index(moving move: Move, from index: Int?) -> Int? {
        guard !items.isEmpty else { return nil }
        guard let index, items.indices.contains(index) else { return 0 }
        switch move {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, items.count - 1)
        case .home: return 0
        case .end: return items.count - 1
        case .up: return row(from: index, by: -1)
        case .down: return row(from: index, by: 1)
        case .pageUp, .pageDown:
            var moved = index
            for _ in 0..<rows { moved = row(from: moved, by: move == .pageUp ? -1 : 1) }
            return moved
        }
    }

    /// Whether the user, at `index`, is within a screenful of the last
    /// loaded item of a collection with more.
    func isNearEnd(_ index: Int?) -> Bool {
        hasMore && items.count - 1 - (index ?? 0) < columns * rows
    }

    private func sectionStart(_ section: Int) -> Int {
        sections[..<section].reduce(0) { $0 + $1.items.count }
    }

    private func row(from index: Int, by step: Int) -> Int {
        let section = sectionOfItem[index]
        let start = sectionStart(section)
        let count = sections[section].items.count
        let local = index - start
        let row = local / columns
        let column = local % columns
        let next = row + step
        if next >= 0, next * columns < count {
            return start + min(next * columns + column, count - 1)
        }
        // Into the nearest section with items in that direction.
        var other = section + step
        while sections.indices.contains(other), sections[other].items.isEmpty { other += step }
        guard sections.indices.contains(other) else { return index }
        let otherStart = sectionStart(other)
        let otherCount = sections[other].items.count
        let targetRow = step > 0 ? 0 : (otherCount - 1) / columns
        return otherStart + min(targetRow * columns + column, otherCount - 1)
    }
}
