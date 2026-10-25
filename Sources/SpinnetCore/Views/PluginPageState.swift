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

/// The items the Host holds of one collection, by position, and the layout
/// they sit in: `total` positions in sections, `columns` across.
///
/// A whole collection (revisions 1 and 2, or revision 3 without `total`) is
/// held entire, every answer replacing it. A windowed one (revision 3) is
/// held only around what the user sees: each answer's slice is merged in,
/// items further than `CollectionsContract.windowScreens` screens from the
/// screen are dropped, at most `CollectionsContract.maximumWindowItems` are
/// kept, and the positions the screen needs that are missing, or were
/// outdated by an answer to something else, are what the Host asks for next
/// with `load_range`.
public struct PluginCollectionWindow: Equatable {
    /// A section header as the window lays it out.
    public struct Section: Equatable {
        public let id: String?
        public let title: String?
        public let start: Int
        public let count: Int

        public var range: Range<Int> { start..<(start + count) }
    }

    public private(set) var total = 0
    public private(set) var sections: [Section] = []
    /// Cells across: the Grid's fixed columns, or for an adaptive one
    /// (#80) those the width the Host measured holds.
    public var columns: Int { fittedColumns ?? declaredColumns }
    /// Rows on screen: those the Host measured, else the answer's `rows`.
    public var rows: Int { fittedRows ?? declaredRows }
    private var declaredColumns = 1
    private var declaredRows = 1
    /// An adaptive Grid's smallest cell side; nil for fixed columns.
    private var minimumCellSize: Double?
    private var fittedColumns: Int?
    private var fittedRows: Int?
    /// The items' width the Host last measured.
    private var measuredWidth: Double?
    public private(set) var isWindowed = false
    /// Counts the times positions stopped meaning what they meant: a new
    /// collection, or an answer with another total or other sections.
    public private(set) var layoutRevision = 0
    private var items: [Int: PluginPageItem] = [:]
    private var positions: [String: Int] = [:]
    /// Held items an answer to something other than `load_range` did not
    /// give again: they stay shown until the Host has them again.
    private var stale: Set<Int> = []
    /// Positions the Host asked for that did not come; asked again only
    /// after the layout changes or the user moves onto one.
    private var declined: Set<Int> = []

    public init() {}

    public init(_ collection: PluginPageCollection) {
        replace(with: collection)
    }

    /// One screenful of positions.
    public var screen: Int { max(columns * rows, 1) }

    /// How many items are held.
    public var heldCount: Int { items.count }

    public func item(at position: Int) -> PluginPageItem? { items[position] }

    public func position(of id: String) -> Int? { positions[id] }

    public func isHeld(_ position: Int) -> Bool { items[position] != nil }

    public func isStale(_ position: Int) -> Bool { stale.contains(position) }

    /// The positions held, in order.
    public var heldPositions: [Int] { items.keys.sorted() }

    /// The index in `sections` of the section holding `position`.
    public func sectionIndex(at position: Int) -> Int? {
        sections.firstIndex { $0.range.contains(position) }
    }

    /// The item at `position` as a gesture carries it.
    public func snapshot(at position: Int) -> PluginPageItemSnapshot? {
        guard let item = items[position] else { return nil }
        return PluginPageItemSnapshot(id: item.id, section: sectionIndex(at: position).flatMap { sections[$0].id },
                                      text: item.resolvedText, marks: item.marks)
    }

    // MARK: Answers

    private static func layout(of collection: PluginPageCollection) -> [Section] {
        collection.sections.map { Section(id: $0.id, title: $0.title, start: $0.start, count: $0.count) }
    }

    /// A new or reset collection: only what the answer gave.
    mutating func replace(with collection: PluginPageCollection) {
        total = collection.total
        sections = Self.layout(of: collection)
        declare(collection)
        isWindowed = collection.isWindowed
        items = [:]
        positions = [:]
        stale = []
        declined = []
        layoutRevision += 1
        hold(collection)
    }

    /// Merges an answer for a collection the Host keeps. A whole collection,
    /// or a windowed one whose total or sections changed, is replaced: its
    /// positions mean something else now. Otherwise the slice replaces what
    /// is held at its positions, and, unless the answer answers
    /// `load_range`, whatever else is held may be outdated: it stays shown
    /// and the Host asks for it again where the user sees it. Returns
    /// whether the layout changed.
    @discardableResult
    mutating func merge(_ collection: PluginPageCollection, answersRange: Bool) -> Bool {
        let layout = Self.layout(of: collection)
        let sameLayout = collection.isWindowed && isWindowed && total == collection.total
            && layout.map(\.id) == sections.map(\.id) && layout.map(\.count) == sections.map(\.count)
        guard sameLayout else {
            replace(with: collection)
            return true
        }
        sections = layout
        declare(collection)
        if !answersRange {
            stale.formUnion(items.keys.filter { !collection.slice.contains($0) })
        }
        hold(collection)
        return false
    }

    /// Takes the answer's columns and rows. An adaptive Grid keeps the
    /// columns its measured width holds, and any collection the rows the
    /// Host measured, until the Host measures again.
    private mutating func declare(_ collection: PluginPageCollection) {
        declaredColumns = collection.columns
        declaredRows = collection.rows
        if collection.minimumCellSize != minimumCellSize {
            minimumCellSize = collection.minimumCellSize
            fittedColumns = measuredWidth.flatMap { width in
                minimumCellSize.map { PageSizing.columns(fitting: width, minimumCellSize: $0) }
            }
        }
    }

    /// The columns the collection would take with items `itemsWidth` points
    /// wide: an adaptive Grid's from its minimum cell size, else its own.
    public func columns(fitting itemsWidth: Double) -> Int {
        guard let minimumCellSize else { return declaredColumns }
        return PageSizing.columns(fitting: itemsWidth, minimumCellSize: minimumCellSize)
    }

    /// The Host measured the collection: its items are `itemsWidth` points
    /// wide and `visibleRows` rows are on screen. An adaptive Grid takes the
    /// columns that width holds; a fixed one keeps its own. A screen never
    /// holds more than a window, so the rows are at most what
    /// `CollectionsContract.maximumWindowItems` holds. Returns whether the
    /// columns or rows changed.
    @discardableResult
    public mutating func fit(itemsWidth: Double, visibleRows: Int) -> Bool {
        let before = (columns, rows)
        measuredWidth = itemsWidth
        if minimumCellSize != nil { fittedColumns = columns(fitting: itemsWidth) }
        fittedRows = min(max(visibleRows, 1), max(CollectionsContract.maximumWindowItems / columns, 1))
        return before != (columns, rows)
    }

    private mutating func hold(_ collection: PluginPageCollection) {
        for (offset, item) in collection.items.enumerated() {
            let position = collection.start + offset
            if let previous = items[position], positions[previous.id] == position { positions[previous.id] = nil }
            items[position] = item
            positions[item.id] = position
            stale.remove(position)
            declined.remove(position)
        }
    }

    // MARK: The window

    /// The positions within `screens` screens of `viewport`.
    private func zone(around viewport: Range<Int>, screens: Int) -> Range<Int> {
        let lower = max(viewport.lowerBound - screens * screen, 0)
        let upper = min(viewport.upperBound + screens * screen, total)
        return lower..<max(lower, upper)
    }

    /// The positions a windowed collection keeps around `viewport`: two
    /// screens either side, at most the window's maximum, centred on it.
    public func keptRange(around viewport: Range<Int>) -> Range<Int> {
        let zone = zone(around: viewport, screens: CollectionsContract.windowScreens)
        guard zone.count > CollectionsContract.maximumWindowItems else { return zone }
        let centre = (viewport.lowerBound + viewport.upperBound) / 2
        let lower = min(max(centre - CollectionsContract.maximumWindowItems / 2, 0), total - CollectionsContract.maximumWindowItems)
        return lower..<(lower + CollectionsContract.maximumWindowItems)
    }

    /// Drops what lies outside the window around `viewport`. A whole
    /// collection keeps everything.
    mutating func evict(around viewport: Range<Int>) {
        guard isWindowed else { return }
        let kept = keptRange(around: viewport)
        for position in items.keys where !kept.contains(position) {
            if let item = items.removeValue(forKey: position), positions[item.id] == position { positions[item.id] = nil }
        }
        stale = stale.filter(kept.contains)
        declined = declined.filter(kept.contains)
    }

    /// The range of positions the Host should ask for, if any: when a
    /// position within a screen of `viewport` is missing or outdated, every
    /// such position within the window around it, at most the window's
    /// maximum.
    public func missingRange(around viewport: Range<Int>) -> Range<Int>? {
        guard isWindowed, total > 0 else { return nil }
        func needed(_ position: Int) -> Bool {
            (items[position] == nil && !declined.contains(position)) || stale.contains(position)
        }
        let near = zone(around: viewport, screens: CollectionsContract.prefetchScreens)
        guard near.contains(where: needed) else { return nil }
        let kept = keptRange(around: viewport)
        guard let first = kept.first(where: needed), let last = kept.last(where: needed) else { return nil }
        return first..<min(last + 1, first + CollectionsContract.maximumWindowItems)
    }

    /// The Host asked for `range` and the answer, if any, has come: what did
    /// not come is not asked for again until the layout changes or the user
    /// moves onto it.
    mutating func settle(_ range: Range<Int>) {
        for position in range where items[position] == nil || stale.contains(position) {
            declined.insert(position)
        }
    }

    /// The user moved onto `position`: it may be asked for again.
    mutating func reconsider(_ position: Int) {
        declined.remove(position)
    }
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
    /// The collection's selected item, by collection ID; absent for none,
    /// and while the selection is on a position whose item the Host does not
    /// hold yet.
    public var selections: [String: String] = [:]
    /// Where the selected item is, so another item can take its place when
    /// it leaves, and where a selection waiting for its item is.
    public var selectionPositions: [String: Int] = [:]
    /// The selected item as last held, so it can be acted on after the
    /// window let it go.
    public var selectedItems: [String: PluginPageItem] = [:]
    /// The first visible item of each collection, which scrolling keeps in
    /// place; absent at the top.
    public var scrollAnchors: [String: String] = [:]
    /// The positions on screen in each collection, as the Host last saw
    /// them.
    public var viewports: [String: Range<Int>] = [:]
    /// The items held of each collection.
    public var windows: [String: PluginCollectionWindow] = [:]
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
        /// A kept collection's positions changed meaning: its total or
        /// sections changed.
        public var layoutChanged = false
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
    /// no answer interrupts a composition. `answersRange` says the answer
    /// answers `load_range`, so the items it does not give again are as
    /// they were.
    @discardableResult
    public mutating func show(_ next: PluginPage, composing: Set<String> = [], answersRange: Bool = false) -> Applied {
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
                let changed = carry(id, from: state, to: &kept, reconciling: component.collection, answersRange: answersRange)
                if changed { applied.layoutChanged = true }
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

    /// Carries a kept component's state into the new answer, and for a
    /// collection merges the answer into its window and reconciles the
    /// selection. Returns whether the collection's layout changed.
    private func carry(_ id: String, from old: PluginPageImmediateState, to kept: inout PluginPageImmediateState,
                       reconciling collection: PluginPageCollection?, answersRange: Bool) -> Bool {
        if let text = old.texts[id] { kept.texts[id] = text }
        if let caret = old.carets[id] { kept.carets[id] = caret }
        if let choice = old.choices[id] { kept.choices[id] = choice }
        if let anchor = old.scrollAnchors[id] { kept.scrollAnchors[id] = anchor }
        guard let collection else { return false }
        var window = old.windows[id] ?? PluginCollectionWindow(collection)
        let layoutChanged = old.windows[id] == nil ? false : window.merge(collection, answersRange: answersRange)
        let viewport = Self.clamp(old.viewports[id] ?? 0..<window.screen, to: window.total)
        kept.viewports[id] = viewport
        // The selected item stays selected wherever it moved; else the item
        // now at its place, clamped to the last; else the first. A windowed
        // collection keeps the selected item by ID while it is not held,
        // until an answer shows what is at its place.
        if window.total == 0 {
            // Nothing to select.
        } else if let selected = old.selections[id] {
            let place = min(old.selectionPositions[id] ?? 0, window.total - 1)
            if let position = window.position(of: selected), let item = window.item(at: position) {
                Self.select(item, at: position, of: id, in: &kept)
            } else if collection.slice.contains(place) || !window.isWindowed, let item = window.item(at: place) {
                Self.select(item, at: place, of: id, in: &kept)
            } else {
                kept.selections[id] = selected
                kept.selectionPositions[id] = place
                kept.selectedItems[id] = old.selectedItems[id]
            }
        } else {
            let place = min(old.selectionPositions[id] ?? 0, window.total - 1)
            if let item = window.item(at: place) {
                Self.select(item, at: place, of: id, in: &kept)
            } else {
                kept.selectionPositions[id] = place
            }
        }
        window.evict(around: viewport)
        kept.windows[id] = window
        return layoutChanged
    }

    private static func select(_ item: PluginPageItem, at position: Int, of collection: String,
                               in state: inout PluginPageImmediateState) {
        state.selections[collection] = item.id
        state.selectionPositions[collection] = position
        state.selectedItems[collection] = item
    }

    private static func clamp(_ viewport: Range<Int>, to total: Int) -> Range<Int> {
        let lower = min(viewport.lowerBound, max(total - viewport.count, 0))
        return lower..<min(lower + viewport.count, total)
    }

    private func start(_ component: PluginPageComponent, in kept: inout PluginPageImmediateState) {
        switch component {
        case .textField(let field):
            kept.texts[field.id] = field.value
            kept.carets[field.id] = .end(of: field.value)
        case .choiceField(let field):
            kept.choices[field.id] = field.value
        case .collection(let collection):
            var window = PluginCollectionWindow(collection)
            let viewport = Self.clamp(0..<window.screen, to: window.total)
            window.evict(around: viewport)
            kept.windows[collection.id] = window
            kept.viewports[collection.id] = viewport
            if let selected = collection.selected, let position = collection.positions[selected],
               let item = collection.item(at: position) {
                Self.select(item, at: position, of: collection.id, in: &kept)
            } else if window.total > 0 {
                if let item = window.item(at: 0) {
                    Self.select(item, at: 0, of: collection.id, in: &kept)
                } else {
                    kept.selectionPositions[collection.id] = 0
                }
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

    /// The page's collection's window: the items the Host holds.
    public var window: PluginCollectionWindow? {
        page?.collection.flatMap { state.windows[$0.id] }
    }

    /// Selects `item` of the page's collection, if the Host holds it.
    public mutating func select(_ item: String) {
        guard let collection = page?.collection, let window = state.windows[collection.id],
              let position = window.position(of: item) else { return }
        select(position: position)
    }

    /// Selects whatever is at `position`, held or not: a selection waiting
    /// for its item takes it when it comes.
    public mutating func select(position: Int) {
        guard let collection = page?.collection, var window = state.windows[collection.id],
              (0..<window.total).contains(position) else { return }
        if let item = window.item(at: position) {
            Self.select(item, at: position, of: collection.id, in: &state)
        } else {
            state.selections[collection.id] = nil
            state.selectedItems[collection.id] = nil
            state.selectionPositions[collection.id] = position
            window.reconsider(position)
            state.windows[collection.id] = window
        }
    }

    /// Moves the collection's selection as an arrow, Page or Home/End key
    /// does, and returns the position now selected, whose item the Host may
    /// not hold yet.
    @discardableResult
    public mutating func moveSelection(_ move: PluginPageCollection.Move) -> Int? {
        guard let window,
              let position = window.index(moving: move, from: selectedPosition) else { return nil }
        select(position: position)
        return position
    }

    /// The user scrolled: `viewport` is on screen now. A windowed collection
    /// lets go of what is far from it.
    public mutating func setViewport(_ viewport: Range<Int>) {
        guard let collection = page?.collection, var window = state.windows[collection.id] else { return }
        let clamped = Self.clamp(viewport, to: window.total)
        state.viewports[collection.id] = clamped
        window.evict(around: clamped)
        state.windows[collection.id] = window
    }

    /// The Host measured the page's collection (`PluginCollectionWindow.fit`).
    /// Returns whether its columns or rows changed.
    @discardableResult
    public mutating func fitCollection(itemsWidth: Double, visibleRows: Int) -> Bool {
        guard let collection = page?.collection, var window = state.windows[collection.id] else { return false }
        let changed = window.fit(itemsWidth: itemsWidth, visibleRows: visibleRows)
        state.windows[collection.id] = window
        return changed
    }

    /// The range the Host should ask for with `load_range`, if any.
    public var missingRange: Range<Int>? {
        guard let collection = page?.collection, let window = state.windows[collection.id],
              let viewport = state.viewports[collection.id] else { return nil }
        // The selection is on screen whenever the user moves it, so a
        // selection waiting for its item is covered too.
        return window.missingRange(around: viewport)
    }

    /// The `load_range` for `range` was answered, failed or dropped.
    public mutating func settleRange(_ range: Range<Int>) {
        guard let collection = page?.collection, var window = state.windows[collection.id] else { return }
        window.settle(range)
        state.windows[collection.id] = window
    }

    // MARK: Snapshots

    /// The page's collection's selected item, as last held.
    public var selectedItem: PluginPageItem? {
        guard let collection = page?.collection, state.selections[collection.id] != nil else { return nil }
        return state.selectedItems[collection.id]
    }

    /// Where the selection is, its item held or not.
    public var selectedPosition: Int? {
        guard let collection = page?.collection else { return nil }
        return state.selectionPositions[collection.id]
    }

    /// The selected item as a gesture carries it.
    public var selectedSnapshot: PluginPageItemSnapshot? {
        guard let item = selectedItem, let position = selectedPosition else { return nil }
        let section = window?.sectionIndex(at: position).flatMap { window?.sections[$0].id }
        return PluginPageItemSnapshot(id: item.id, section: section, text: item.resolvedText, marks: item.marks)
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
        /// The first or last item.
        case home, end
    }
}

public extension PluginCollectionWindow {
    /// Where `move` takes the selection from `index`: from no selection,
    /// any move selects the first item. Nil when there are no items.
    func index(moving move: PluginPageCollection.Move, from index: Int?) -> Int? {
        guard total > 0 else { return nil }
        guard let index, (0..<total).contains(index) else { return 0 }
        switch move {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, total - 1)
        case .home: return 0
        case .end: return total - 1
        case .up: return row(from: index, by: -1)
        case .down: return row(from: index, by: 1)
        case .pageUp, .pageDown:
            var moved = index
            for _ in 0..<rows { moved = row(from: moved, by: move == .pageUp ? -1 : 1) }
            return moved
        }
    }

    private func row(from index: Int, by step: Int) -> Int {
        guard let section = sectionIndex(at: index) else { return index }
        let start = sections[section].start
        let count = sections[section].count
        let local = index - start
        let row = local / columns
        let column = local % columns
        let next = row + step
        if next >= 0, next * columns < count {
            return start + min(next * columns + column, count - 1)
        }
        // Into the nearest section with items in that direction.
        var other = section + step
        while sections.indices.contains(other), sections[other].count == 0 { other += step }
        guard sections.indices.contains(other) else { return index }
        let otherCount = sections[other].count
        let targetRow = step > 0 ? 0 : (otherCount - 1) / columns
        return sections[other].start + min(targetRow * columns + column, otherCount - 1)
    }
}
