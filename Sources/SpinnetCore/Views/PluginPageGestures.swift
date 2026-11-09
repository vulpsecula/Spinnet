import Foundation

/// The user's gestures on the page's Collection, handled once for the Host's
/// renderer and the Plugin test kit alike: how each changes the Selection,
/// what drawing it should follow, the item action it delivers or performs,
/// and when `selection_changed` is due (ADR 0025). The Host adapts them to
/// AppKit and its View Session; the test kit to its recorded runner.
extension PluginPageMemory {
    /// The modifier a click in the Collection carries.
    public enum ClickModifier: Equatable {
        case none
        /// ⌘-click: adds the item to a multiple Collection's selection or
        /// removes it.
        case command
        /// Shift-click: selects the range from the anchor to the item.
        case shift
    }

    /// One entry of a context menu.
    public struct MenuEntry: Equatable {
        public let action: PluginPageItemAction
        /// A toggle item action whose mark the item carries, or for a
        /// multiple Collection's selection, every selected item.
        public let isChecked: Bool
        /// It can be chosen: a single item action is not while several items
        /// are selected (ADR 0025).
        public let isEnabled: Bool
    }

    /// What handling a gesture did, for whatever draws the page and runs
    /// the View Session.
    public struct Handled: Equatable {
        /// What the Collection should redraw.
        public enum Redraw: Equatable {
            case none
            /// The selection moved between two positions; only their cells
            /// change.
            case moved(from: Int?, to: Int?)
            /// A multiple Collection's selection changed: any cell may.
            case all
        }

        public var redraw = Redraw.none
        /// The component that takes the keyboard.
        public var focus: String?
        /// The position to keep in view.
        public var reveal: Int?
        /// The selection moved: what the screen lacks, once `reveal` is in
        /// view, is asked for with `load_range` (`missingRange`).
        public var asksForRange = false
        /// The user changed the selection of a Collection declaring
        /// `selection_events`: it settles from now (`settleSelection()`).
        public var settling = false
        /// The settled selection, delivered before `gesture` or `submitted`.
        public var selectionChanged: PluginViewEvent?
        /// The item action on the selection, as the Host performs or
        /// delivers it.
        public var gesture: ItemGesture?
        /// The `submitted` Return delivers in a field.
        public var submitted: PluginViewEvent?

        public init() {}
    }

    // MARK: Pointer

    /// A click on the cell at `position`, an item or a placeholder. In a
    /// multiple Collection ⌘ adds or removes the item and Shift selects the
    /// range from the anchor; in a single one a modifier changes nothing.
    @discardableResult
    public mutating func click(at position: Int, modifier: ClickModifier = .none) -> Handled {
        guard let (collection, window, selection) = current, (0..<window.total).contains(position) else { return Handled() }
        var handled = Handled()
        clickedFrom = nil
        if selectsMultiple, let item = window.item(at: position) {
            switch modifier {
            case .command:
                changeSelection { $0.toggle(item.id, in: $1) }
            case .shift:
                changeSelection { $0.extend(to: item.id, in: $1) }
            case .none:
                if selectedItems.count > 1, isSelected(position) { clickedFrom = (position, selection) }
                select(position: position)
            }
            handled.redraw = .all
        } else {
            select(position: position)
            handled.redraw = .moved(from: selection.position, to: position)
        }
        handled.focus = collection.id
        handled.asksForRange = true
        userChangedSelection(&handled)
        return finished(handled)
    }

    /// The second click of a double-click, whose first click selected the
    /// item: the default item action runs on it, or, when the first click
    /// reduced a multiple Collection's selection to it, on that selection.
    @discardableResult
    public mutating func doubleClick(at position: Int) -> Handled {
        var handled = Handled()
        if let clicked = clickedFrom, clicked.position == position, let collection = page?.collection,
           let window = state.windows[collection.id], let item = window.item(at: position) {
            var restored = clicked.selection.carried(into: window, of: collection)
            restored.focus(within: item.id, in: window)
            state.selections[collection.id] = restored
            handled.redraw = .all
            userChangedSelection(&handled)
        } else if !isSelected(position) || selectedPosition != position {
            handled = click(at: position)
        }
        clickedFrom = nil
        perform(page?.collection?.defaultAction, &handled)
        return finished(handled)
    }

    /// A right click on the cell at `position`: within a multiple
    /// Collection's selection it keeps the selection and focuses the item;
    /// elsewhere it selects the item, as a click does.
    @discardableResult
    public mutating func rightClick(at position: Int) -> Handled {
        guard selectsMultiple, isSelected(position), let item = window?.item(at: position) else { return click(at: position) }
        changeSelection { $0.focus(within: item.id, in: $1) }
        var handled = Handled()
        handled.focus = page?.collection?.id
        handled.redraw = .all
        return finished(handled)
    }

    /// The context menu of the cell at `position`: on an item of a multiple
    /// Collection's selection of several items, the selection's: what every
    /// selected item offers, a toggle checked when all carry its mark, a
    /// single item action disabled. Elsewhere the item's own.
    public func contextMenu(at position: Int) -> [MenuEntry] {
        guard selectsMultiple, isSelected(position), selectedItems.count > 1 else { return itemMenu(at: position) }
        return selectionActions.map { MenuEntry(action: $0, isChecked: isChecked($0), isEnabled: isAvailable($0)) }
    }

    /// What the item at `position` offers on its own, the default first, a
    /// toggle checked when it carries the mark; nothing for a placeholder.
    public func itemMenu(at position: Int) -> [MenuEntry] {
        guard let collection = page?.collection, let item = window?.item(at: position) else { return [] }
        return collection.actions(of: item).map { MenuEntry(action: $0, isChecked: $0.isChecked(for: item), isEnabled: true) }
    }

    /// The user chose `action` from the context menu of the item at
    /// `position`, which the right click selected: on an item of a multiple
    /// Collection's selection it acts on the whole selection.
    @discardableResult
    public mutating func choose(_ action: PluginPageItemAction, at position: Int) -> Handled {
        var handled = Handled()
        if !(selectsMultiple && isSelected(position)), selectedPosition != position {
            let before = selectedPosition
            select(position: position)
            handled.redraw = .moved(from: before, to: position)
            userChangedSelection(&handled)
        } else if let item = window?.item(at: position), selectedPosition != position {
            changeSelection { $0.focus(within: item.id, in: $1) }
            handled.redraw = .all
        }
        perform(action, &handled)
        return finished(handled)
    }

    /// A row's toggle checkbox: its item action on that row alone, which it
    /// selects.
    @discardableResult
    public mutating func chooseAlone(_ action: PluginPageItemAction, at position: Int) -> Handled {
        var handled = Handled()
        if selectedPosition != position || selectedItems.count > 1 {
            let before = selectedPosition
            let wasGroup = selectedItems.count > 1
            select(position: position)
            handled.redraw = wasGroup ? .all : .moved(from: before, to: position)
            userChangedSelection(&handled)
        }
        perform(action, &handled)
        return finished(handled)
    }

    // MARK: Keys

    /// An arrow, Page or Home/End key: moves the selection and keeps it in
    /// view; `extending`, Shift, selects from the anchor to where the key
    /// moves in a multiple Collection. Nil when nothing moves. A position
    /// whose item the Host does not hold yet is asked for.
    @discardableResult
    public mutating func press(_ move: PluginPageCollection.Move, extending: Bool = false) -> Handled? {
        guard let window, let position = window.index(moving: move, from: selectedPosition) else { return nil }
        var handled = Handled()
        if extending, selectsMultiple {
            guard let item = window.item(at: position) else { return nil }
            changeSelection { $0.extend(to: item.id, in: $1) }
            handled.redraw = .all
        } else {
            let before = selectedPosition
            let wasGroup = selectedItems.count > 1
            select(position: position)
            handled.redraw = wasGroup ? .all : .moved(from: before, to: position)
        }
        handled.reveal = position
        handled.asksForRange = true
        userChangedSelection(&handled)
        return finished(handled)
    }

    /// ⌘A: a multiple Collection selects every item; nil for a single one,
    /// which has nothing to select all of.
    @discardableResult
    public mutating func selectAll() -> Handled? {
        guard selectsMultiple else { return nil }
        changeSelection { $0.selectAll(in: $1) }
        var handled = Handled()
        handled.redraw = .all
        userChangedSelection(&handled)
        return finished(handled)
    }

    /// Whether `field` searches the page's Collection, so Up, Down and
    /// Return act on it.
    public func searches(_ field: String) -> Bool {
        guard case .textField(let declared)? = page?.component(field) else { return false }
        return declared.collection != nil && declared.collection == page?.collection?.id
    }

    /// Return: in a field that searches nothing, `submitted`; in a search
    /// field or the Collection (`field` nil), the default item action on the
    /// selection, nothing while the selection waits for its item.
    public mutating func pressReturn(in field: String? = nil) -> Handled {
        var handled = Handled()
        if let field, !searches(field) {
            guard let page else { return handled }
            handled.selectionChanged = settleSelection()
            handled.submitted = .pageSubmitted(page: page.id, field: field, values: values, selection: selection)
            return handled
        }
        perform(page?.collection?.defaultAction, &handled)
        return finished(handled)
    }

    /// ⌘C with the Collection focused: the sole `clipboard.write` item
    /// action, on every selected item of a multiple Collection, their texts
    /// one per line. Nil when there is none to perform.
    public mutating func copySelection() -> Handled? {
        guard let copy = page?.collection?.copyAction, isAvailable(copy) else { return nil }
        var handled = Handled()
        perform(copy, &handled)
        return finished(handled)
    }

    // MARK: The screen

    /// Scrolls so that `position`'s row is on screen, as the Host's
    /// collection does when the selection moves out of view.
    public mutating func reveal(_ position: Int) {
        guard let collection = page?.collection, let window = state.windows[collection.id],
              let viewport = state.viewports[collection.id], !viewport.contains(position) else { return }
        let row = position / window.columns * window.columns
        let first = position < viewport.lowerBound ? row : max(row - (window.rows - 1) * window.columns, 0)
        setViewport(first..<min(first + window.screen, window.total))
    }

    // MARK: selection_changed

    /// Whether a change the user made to the selection is still settling.
    public var isSettlingSelection: Bool { settlingSelection != nil }

    /// The selection settled: its `selection_changed`, if it is somewhere
    /// the Plugin has not heard of. One waiting for its item settles once
    /// the item comes (`Applied.selectionSettlesAgain`).
    public mutating func settleSelection() -> PluginViewEvent? {
        guard let settling = settlingSelection else { return nil }
        guard settling.page == page?.id, settling.collection == page?.collection?.id,
              let event = selectionChangedEvent, case .selectionChanged(_, _, let items, _) = event else {
            settlingSelection = nil
            return nil
        }
        guard !items.isEmpty else { return nil }
        settlingSelection = nil
        let ids = items.map(\.id)
        guard ids != heardSelection else { return nil }
        heardSelection = ids
        return event
    }

    /// An answer was applied. What it did to the selection is the Plugin's
    /// own and is never sent back: another page or a renewed Collection
    /// drops a change still settling, and so does an answer that moved the
    /// selection. Returns whether a selection the user made that waited for
    /// its item has it now, and settles from here.
    mutating func reconcileSettlingSelection(before: [String], waitedForItem: Bool, applied: Applied) -> Bool {
        let now = selectedItems.map(\.id)
        let renewed = applied.pageChanged || page?.collection.map { applied.renewed.contains($0.id) } ?? true
        if renewed { clickedFrom = nil }
        if settlingSelection != nil, !renewed {
            if waitedForItem, !now.isEmpty { return true }
            if before == now { return false }
        }
        settlingSelection = nil
        heardSelection = now
        return false
    }

    // MARK: Helpers

    private mutating func userChangedSelection(_ handled: inout Handled) {
        guard let page, let collection = page.collection, collection.selectionEvents else { return }
        settlingSelection = (page.id, collection.id)
        handled.settling = true
    }

    /// `action` on the selection, after the selection still settling.
    private mutating func perform(_ action: PluginPageItemAction?, _ handled: inout Handled) {
        guard let action, let gesture = gesture(action) else { return }
        handled.selectionChanged = settleSelection()
        handled.gesture = gesture
    }

    private func finished(_ handled: Handled) -> Handled {
        var handled = handled
        handled.settling = handled.settling && isSettlingSelection
        return handled
    }
}
