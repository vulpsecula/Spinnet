import AppKit
import Combine
import SpinnetCore

/// One drawn page of a compatible Plugin (ADR 0019): the page the session shows with the immediate state the Host
/// keeps for it, the keyboard roles of its search field and collection, and
/// the Host's own chrome (target line, empty, loading and failure states).
/// It turns the user's input into page events for its session, and page and
/// item actions naming a Host Service into operations the Host performs.
///
/// What the user types never republishes the page: the field already shows
/// it, so typing costs no redraw until the Plugin answers.
final class PluginPageModel: ObservableObject {
    /// Asks the views to move the keyboard focus. Each request is new, so
    /// asking twice for the same component is honoured twice.
    struct FocusRequest: Equatable {
        let component: String
        let serial: Int
    }

    /// Asks the collection to scroll: to a position, or to the top when nil.
    struct ScrollRequest: Equatable {
        let position: Int?
        /// The item at that position, if the Host holds it.
        let item: String?
        /// Keep the item at the top, rather than just in view.
        let atTop: Bool
        let serial: Int
    }

    /// One entry of an item's context menu.
    struct MenuEntry: Equatable {
        let action: PluginPageItemAction
        /// The title with the App an insert action inserts into.
        let title: String
        /// A toggle item action whose mark the item carries, or for a
        /// multiple collection's selection, every selected item.
        let isChecked: Bool
        /// It can be chosen: a single item action is not, while several
        /// items are selected (ADR 0025).
        var isEnabled = true
    }

    /// The modifier a click in the collection carries.
    enum ClickModifier: Equatable {
        case none
        /// ⌘-click: adds the item to a multiple collection's selection or removes it.
        case command
        /// Shift-click: selects the range from the anchor to the item.
        case shift
    }

    let activityList: HostActivityListModel
    func setActivityListVisible(_ visible: Bool) { activityList.setVisible(visible) }
    let session: PluginViewSession
    @Published private(set) var page: PluginPage
    /// The AppKit collection drawing the page's List or Grid, which the
    /// model tells what changed rather than republishing the page: a
    /// selection move redraws two cells, not the page.
    weak var collectionDisplay: PageCollectionDisplay?
    /// Whether the collection has the keyboard, which tints its selection.
    private(set) var collectionIsFocused = false
    /// The collection's selected item: of a multiple collection, the
    /// focused one.
    var selectedItem: String? { memory.selectedItem?.id }
    /// Every selected item, in Collection order.
    var selectedItems: [String] { memory.selectedItems.map(\.id) }
    /// Whether the collection selects several items (ADR 0025).
    var selectsMultiple: Bool { memory.selectsMultiple }
    /// Whether the item at `position` is drawn selected.
    func isSelected(_ position: Int) -> Bool { memory.isSelected(position) }
    /// Where the collection's selection is, its item held or not.
    var selectedPosition: Int? { memory.selectedPosition }
    /// A pinned page stays open when it loses focus and when an action or
    /// operation with `closes_view` succeeds.
    @Published var isPinned = false
    @Published private(set) var isBusy = false
    @Published private(set) var isPerformingOperation = false
    @Published private(set) var operationProgress: String?
    @Published private(set) var eventError: ActionFailure?
    @Published private(set) var toast: String?
    private(set) var focusRequest: FocusRequest?
    /// The last scroll the model asked the collection for.
    private(set) var scrollRequest: ScrollRequest?
    /// Counts, per text field, the times the Host replaced its text: a new
    /// or reset field. The field view writes the text only then.
    @Published private(set) var textRevisions: [String: Int] = [:]
    /// Which component has the keyboard, as the views report it.
    @Published private(set) var focused: String?

    /// What the Host keeps for this page and the pages it remembers.
    private(set) var memory = PluginPageMemory()
    /// Text fields with an open input-method composition.
    private(set) var composing: Set<String> = []
    /// A plain click that reduced a multiple collection's selection to one
    /// of its items: the selection it had, which the double-click that may
    /// follow acts on.
    private var selectionBeforeClick: (position: Int, items: Set<String>, anchor: String?)?
    /// The `load_range` the Host sent last and has not settled, with the
    /// collection's layout it was asked under.
    private var requestedRange: (range: Range<Int>, layout: Int)?
    /// A Return in the search field waiting for the answer to the typing
    /// before it (C1), with what the Host showed when it was pressed.
    private var pendingReturn: InsertionTargetCapture?
    private var serial = 0
    private var toastCount = 0
    private var targetChanges: AnyCancellable?
    private let environment: PluginViewEnvironment
    func sourcesChanged() { objectWillChange.send() }
    func sourceText(_ id: String) -> HostSourceShown? {
        environment.sources?.shown(component: id, pluginID: session.pluginID)
    }
    /// Reads a text field's caret where it is being edited.
    private var carets: [String: () -> PluginPageCaret?] = [:]
    /// The views that take the keyboard, by component.
    private var focusTargets: [String: WeakFocusTarget] = [:]
    /// The focus request the views have yet to honour.
    private var unhonouredFocus: String?

    private struct WeakFocusTarget {
        weak var view: PluginPageFocusTarget?
    }
    /// The selected items' IDs the Plugin last knew of, for a Collection
    /// declaring `selection_events`: what an answer left, or the last
    /// `selection_changed` sent (ADR 0025).
    private var knownSelection: [String] = []
    /// A change the user made to the selection, still settling: the page
    /// and Collection it was made in, and which change it is.
    private var settlingSelection: (page: String, collection: String, serial: Int)?
    private var selectionSerial = 0
    /// Whether an arrow, Page or Home/End key is held down, so the
    /// selection it moves has not settled yet.
    var moveKeyIsHeld: () -> Bool = PluginPageModel.liveMoveKeyIsHeld

    /// Whether an input method rather than a keyboard layout is selected,
    /// so a key typed in the collection cannot safely go to the field.
    var inputMethodIsSelected: () -> Bool = PluginPageModel.liveInputMethodIsSelected

    init(session: PluginViewSession, presentation: PluginViewPresentation, page: PluginPage,
         environment: PluginViewEnvironment) {
        self.session = session
        self.page = page
        self.environment = environment
        self.activityList = HostActivityListModel(activities: environment.activities, owner: session.pluginID)
        update(presentation, page: page, newView: true, presentedAnew: true)
        if session.showsInsertionTargets {
            targetChanges = environment.insertionTargets?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var title: String { page.title }
    var pluginName: String { environment.pluginName(session.pluginID) }
    /// The failure shown inline.
    var error: ActionFailure? { eventError }
    var repairRoute: PluginViewRepairRoute? { error.flatMap(PluginViewRepairRoute.init) }
    /// The collection as the last answer described it.
    var collection: PluginPageCollection? { page.collection }
    /// The items the Host holds of the collection, and their layout.
    var window: PluginCollectionWindow? { memory.window }

    /// The item the Host holds at `position`, or nil for a placeholder.
    func item(at position: Int) -> PluginPageItem? { memory.window?.item(at: position) }

    // MARK: - Answers

    /// Shows what the session presents. A new page, or a new answer to this
    /// one, is applied through the page memory: what the user is doing is
    /// kept unless the Plugin reset it.
    func update(_ presentation: PluginViewPresentation, page next: PluginPage, newView: Bool, presentedAnew: Bool) {
        isBusy = presentation.isBusy
        isPerformingOperation = presentation.isPerformingOperation
        operationProgress = presentation.operationProgress
        eventError = presentation.error
        if newView { apply(next, presentedAnew: presentedAnew) }
        settleRange()
        // An answer to anything else may have outdated what is on screen.
        if newView { requestRangeIfNeeded() }
        settlePendingReturn()
    }

    private func apply(_ next: PluginPage, presentedAnew: Bool) {
        let previous = memory.window
        let id = next.collection?.id
        let anchor = id.flatMap { memory.state.viewports[$0] }.flatMap { viewport in
            previous?.item(at: viewport.lowerBound).map { (id: $0.id, position: viewport.lowerBound) }
        }
        if let id, let anchor { memory.state.scrollAnchors[id] = anchor.id }
        saveCarets()
        let answersRange: Bool
        if case .loadRange? = session.answeredEvent { answersRange = true } else { answersRange = false }
        let selectedBefore = memory.selectedPosition
        let waitedForItem = memory.selectedPosition != nil && memory.selectedItem == nil
        let itemsBefore = memory.selectedItems.map(\.id)
        let applied = memory.show(next, composing: composing, answersRange: answersRange)
        page = next
        reconcileSettlingSelection(before: itemsBefore, waitedForItem: waitedForItem, applied: applied)
        activityList.setAvailable(next.components.contains { if case .activityList = $0 { return true }; return false })
        for case .textField(let field) in next.components where applied.renewed.contains(field.id) {
            textRevisions[field.id, default: 0] += 1
        }
        if applied.pageChanged {
            // Every field of another page is drawn anew from the memory.
            for case .textField(let field) in next.components { textRevisions[field.id, default: 0] += 1 }
            composing = []
        }
        if let collection = next.collection {
            if applied.pageChanged || applied.renewed.contains(collection.id) {
                requestedRange = nil
                collectionDisplay?.reloadCollection()
                if applied.restored, let anchor = memory.state.scrollAnchors[collection.id],
                   let position = memory.window?.position(of: anchor) {
                    requestScroll(to: position, atTop: true)
                } else {
                    requestScroll(to: nil, atTop: true)
                }
            } else {
                collectionDisplay?.reloadCollection()
                // Items arrived above what the user is looking at: keep it
                // in place.
                if let anchor, let now = memory.window?.position(of: anchor.id), now != anchor.position {
                    requestScroll(to: now, atTop: true)
                } else if selectedBefore != memory.selectedPosition {
                    collectionDisplay?.selectionMoved(from: selectedBefore, to: memory.selectedPosition)
                }
            }
        } else {
            collectionDisplay?.reloadCollection()
        }
        if applied.pageChanged || next.reset == .page || presentedAnew, let focus = memory.state.focus {
            requestFocus(focus)
        } else if let focused, next.component(focused) == nil, let fallback = memory.state.focus {
            requestFocus(fallback)
        }
    }

    private func saveCarets() {
        for (id, read) in carets {
            if let caret = read() { memory.state.carets[id] = caret }
        }
    }

    // MARK: - Text and choices

    /// The text the Host keeps for a field: what the user typed, or its
    /// value when new or reset.
    func text(of field: String) -> String { memory.state.texts[field] ?? "" }

    func caret(of field: String) -> PluginPageCaret? { memory.state.carets[field] }

    func choice(of field: String) -> String { memory.state.choices[field] ?? "" }

    /// The field's committed text changed. Composing text is never sent.
    func textChanged(_ field: String, to text: String, caret: PluginPageCaret?) {
        composing.remove(field)
        guard memory.state.texts[field] != nil, memory.state.texts[field] != text else {
            if let caret { memory.state.carets[field] = caret }
            return
        }
        memory.setText(text, of: field, caret: caret)
        eventError = nil
        session.send(.pageFieldChanged(page: page.id, field: field, values: memory.values))
    }

    /// An input-method composition opened or closed in the field.
    func compositionChanged(_ field: String, isComposing: Bool) {
        if isComposing { composing.insert(field) } else { composing.remove(field) }
    }

    func choose(_ value: String, in field: String) {
        guard memory.state.choices[field] != value else { return }
        memory.setChoice(value, of: field)
        objectWillChange.send()
        session.send(.pageFieldChanged(page: page.id, field: field, values: memory.values))
    }

    /// A field view reports how to read its caret while it is edited.
    func registerCaret(of field: String, _ read: @escaping () -> PluginPageCaret?) { carets[field] = read }

    // MARK: - Focus and keys

    /// The component a view reports as having the keyboard.
    func didFocus(_ component: String) {
        guard focused != component else { return }
        focused = component
        memory.state.focus = component
        let collectionFocused = component == collection?.id
        if collectionIsFocused != collectionFocused {
            collectionIsFocused = collectionFocused
            collectionDisplay?.focusChanged()
        }
    }

    private func requestFocus(_ component: String) {
        serial += 1
        focusRequest = FocusRequest(component: component, serial: serial)
        didFocus(component)
        unhonouredFocus = component
        if let view = focusTarget(component), view.window != nil {
            unhonouredFocus = nil
            Self.focus(view)
        }
    }

    /// A view that takes the keyboard was made for `component`.
    func register(_ view: PluginPageFocusTarget) {
        focusTargets[view.component] = WeakFocusTarget(view: view)
        focusTargets = focusTargets.filter { $0.value.view != nil }
    }

    func focusTarget(_ component: String) -> NSView? {
        guard let view = focusTargets[component]?.view, view.component == component else { return nil }
        return view
    }

    /// A view reached its window: it takes the keyboard if a request for it
    /// was waiting.
    /// One that had the keyboard and was drawn anew, as when the Plugin
    /// moved it into or out of a row, takes it back with its caret.
    func viewAppeared(_ view: PluginPageFocusTarget) {
        guard view.window != nil, unhonouredFocus == view.component || focused == view.component else { return }
        unhonouredFocus = nil
        DispatchQueue.main.async { [weak self] in
            guard self?.focused == view.component else { return }
            Self.focus(view)
        }
    }

    /// The fields and the collection, in page order: the stops Tab moves
    /// between. Buttons and the target line are not among them.
    var focusStops: [String] {
        page.components.filter { [.textField, .choiceField, .list, .grid].contains($0.kind) }.map(\.id)
    }

    /// Tab or Shift-Tab from `component`, wrapping.
    func moveFocus(from component: String, forward: Bool) {
        let stops = focusStops
        guard !stops.isEmpty else { return }
        let index = stops.firstIndex(of: component) ?? (forward ? -1 : 0)
        let next = (index + (forward ? 1 : stops.count - 1)) % stops.count
        requestFocus(stops[next])
    }

    /// Up or Down in a search field, or any arrow, Page or Home/End key in
    /// the collection: moves the selection and keeps it in view. A position
    /// whose item the Host does not hold yet is asked for.
    @discardableResult
    func moveSelection(_ move: PluginPageCollection.Move) -> Bool {
        let before = memory.selectedPosition
        let wasGroup = memory.selectedItems.count > 1
        guard let position = memory.moveSelection(move) else { return false }
        selectionMoved(from: before, to: position, redrawingAll: wasGroup)
        userChangedSelection()
        return true
    }

    /// Shift with an arrow, Page or Home/End key in a multiple collection:
    /// extends the selection from the anchor to where the key moves the
    /// focus. In a single collection the key moves the selection.
    @discardableResult
    func extendSelection(_ move: PluginPageCollection.Move) -> Bool {
        guard memory.selectsMultiple else { return moveSelection(move) }
        let before = memory.selectedPosition
        guard let position = memory.extendSelection(move) else { return false }
        selectionMoved(from: before, to: position, redrawingAll: true)
        userChangedSelection()
        return true
    }

    /// ⌘A in a multiple collection: selects every item. Returns false for a
    /// single collection, which has nothing to select all of.
    @discardableResult
    func selectAll() -> Bool {
        guard memory.selectsMultiple else { return false }
        memory.selectAll()
        collectionDisplay?.selectionChanged()
        userChangedSelection()
        return true
    }

    private func selectionMoved(from before: Int?, to position: Int, redrawingAll: Bool = false) {
        if redrawingAll { collectionDisplay?.selectionChanged() } else { collectionDisplay?.selectionMoved(from: before, to: position) }
        requestScroll(to: position, atTop: false)
        if collectionDisplay == nil, let window = memory.window, let viewport = memory.state.viewports[collection?.id ?? ""],
           !viewport.contains(position) {
            // Nothing draws the collection: the selection's row is on screen.
            let row = position / window.columns * window.columns
            let first = position < viewport.lowerBound ? row : max(row - (window.rows - 1) * window.columns, 0)
            viewportChanged(first..<min(first + window.screen, window.total))
        }
        requestRangeIfNeeded()
    }

    /// Whether `field` searches the page's collection, so Up, Down and
    /// Return act on it.
    /// An arrow key in a text field, with no modifier and no input-method
    /// composition. A field searching the page's collection moves its
    /// selection with Up and Down, and, searching a Grid, with Left and
    /// Right too (user decision 2026-10-08), the caret moving with Option-
    /// or Command-arrows. Returns false for a key the field keeps.
    func searchFieldKey(_ move: PluginPageCollection.Move, in field: String) -> Bool {
        guard searchesCollection(field) else { return false }
        switch move {
        case .up, .down: return moveSelection(move)
        case .left where collection?.style == .grid,
             .right where collection?.style == .grid: return moveSelection(move)
        default: return false
        }
    }

    func searchesCollection(_ field: String) -> Bool {
        guard case .textField(let declared)? = page.component(field) else { return false }
        return declared.collection != nil && declared.collection == collection?.id
    }

    /// Return in a text field. In a search field it performs the default
    /// item action on the selection once the answer to the typing before it
    /// has come (C1); in another field it sends `submitted`.
    func returnPressed(in field: String) {
        let shown = shownTarget()
        guard searchesCollection(field) else {
            settleSelectionNow()
            session.send(.pageSubmitted(page: page.id, field: field, values: memory.values, selection: memory.selection),
                         insertionTarget: shown)
            return
        }
        if session.hasPendingFieldChange {
            pendingReturn = shown
            session.flushFieldChanges()
            return
        }
        performDefaultOnSelection(shown: shown)
    }

    /// Return in the collection.
    func returnPressedInCollection() { performDefaultOnSelection(shown: shownTarget()) }

    private func settlePendingReturn() {
        guard let shown = pendingReturn, !session.hasPendingFieldChange else { return }
        pendingReturn = nil
        // A search that failed gives nothing to act on.
        if let failed = session.errorEvent, failed.coalesces { return }
        performDefaultOnSelection(shown: shown)
    }

    /// The default item action on the selection; nothing while the
    /// selection waits for its item.
    private func performDefaultOnSelection(shown: InsertionTargetCapture) {
        guard let action = collection?.defaultAction else { return }
        perform(action, shown: shown)
    }

    /// ⌘C with the collection focused: the sole `clipboard.write` item
    /// action, on every selected item of a multiple collection, their texts
    /// one per line.
    func copySelection() -> Bool {
        guard let copy = collection?.copyAction, memory.isAvailable(copy) else { return false }
        perform(copy, shown: shownTarget())
        return true
    }

    /// A key typed while the collection has the keyboard goes to the
    /// search field, with a keyboard layout selected (C3). With an input
    /// method selected it is ignored, so no composition starts half-way.
    /// Returns the field that should take the key, if any.
    func fieldForTypedKey() -> String? {
        guard !inputMethodIsSelected(), let field = searchField else { return nil }
        requestFocus(field)
        return field
    }

    /// The text field searching the collection.
    var searchField: String? {
        for case .textField(let field) in page.components where searchesCollection(field.id) { return field.id }
        return nil
    }

    // MARK: - Pointer

    /// A click on the item with `item`, which the Host holds.
    func click(_ item: String) {
        guard let position = memory.window?.position(of: item) else { return }
        click(at: position)
    }

    /// A click on the cell at `position`, an item or a placeholder. In a
    /// multiple collection ⌘ adds or removes the item and Shift selects the
    /// range from the anchor; in a single one a modifier changes nothing.
    func click(at position: Int, modifier: ClickModifier = .none) {
        guard let window = memory.window, (0..<window.total).contains(position) else { return }
        let before = memory.selectedPosition
        selectionBeforeClick = nil
        if memory.selectsMultiple, let item = window.item(at: position) {
            switch modifier {
            case .command:
                memory.toggleSelection(of: item.id)
            case .shift:
                memory.extendSelection(to: item.id)
            case .none:
                if memory.selectedItems.count > 1, memory.isSelected(position), let id = collection?.id {
                    selectionBeforeClick = (position, memory.state.groupSelections[id] ?? [], memory.state.selectionAnchors[id])
                }
                memory.select(position: position)
            }
            if let collection { requestFocus(collection.id) }
            collectionDisplay?.selectionChanged()
        } else {
            memory.select(position: position)
            if let collection { requestFocus(collection.id) }
            collectionDisplay?.selectionMoved(from: before, to: position)
        }
        requestRangeIfNeeded()
        userChangedSelection()
    }

    func click(_ item: String, modifier: ClickModifier) {
        guard let position = memory.window?.position(of: item) else { return }
        click(at: position, modifier: modifier)
    }

    func doubleClick(_ item: String) {
        guard let position = memory.window?.position(of: item) else { return }
        doubleClick(at: position)
    }

    /// The second click of a double-click, whose first click selected the
    /// item: the default item action runs on it, or, when the first click
    /// reduced a multiple collection's selection to it, on that selection.
    func doubleClick(at position: Int) {
        if let before = selectionBeforeClick, before.position == position, let id = collection?.id,
           let item = memory.window?.item(at: position) {
            memory.state.groupSelections[id] = before.items
            memory.state.selectionAnchors[id] = before.anchor
            memory.focusWithinSelection(item.id)
            collectionDisplay?.selectionChanged()
            userChangedSelection()
        } else if !memory.isSelected(position) || memory.selectedPosition != position {
            click(at: position)
        }
        selectionBeforeClick = nil
        guard let action = collection?.defaultAction else { return }
        perform(action, shown: shownTarget())
    }

    /// A right click on the cell at `position`: within a multiple
    /// collection's selection it keeps the selection and focuses the item;
    /// elsewhere it selects the item, as a click does.
    func rightClick(at position: Int) {
        guard let item = memory.window?.item(at: position) else { return click(at: position) }
        guard memory.selectsMultiple, memory.isSelected(position) else { return click(at: position) }
        memory.focusWithinSelection(item.id)
        if let collection { requestFocus(collection.id) }
        collectionDisplay?.selectionChanged()
    }

    /// What `item`'s context menu offers: the default first.
    func menu(of item: String) -> [MenuEntry] {
        guard let position = memory.window?.position(of: item) else { return [] }
        return menu(at: position)
    }

    /// The context menu a right click on `item` opens.
    func contextMenu(of item: String) -> [MenuEntry] {
        guard let position = memory.window?.position(of: item) else { return [] }
        return contextMenu(at: position)
    }

    /// The context menu of the cell at `position`: on an item of a multiple
    /// collection's selection, the selection's: what every selected item
    /// offers, a toggle checked when all carry its mark, a single item
    /// action disabled while several are selected. Elsewhere the item's.
    func contextMenu(at position: Int) -> [MenuEntry] {
        guard memory.selectsMultiple, memory.isSelected(position), memory.selectedItems.count > 1 else {
            return menu(at: position)
        }
        return memory.selectionActions.map { action in
            MenuEntry(action: action, title: title(of: action), isChecked: memory.isChecked(action),
                      isEnabled: memory.isAvailable(action))
        }
    }

    private func title(of action: PluginPageItemAction) -> String {
        action.perform == "selection.replace"
            ? "\(action.title) \(insertionTargetName.map { localized("into \($0)") } ?? Self.noInsertionTarget)"
            : action.title
    }

    /// What the context menu of the item at `position` offers; nothing for
    /// a placeholder.
    func menu(at position: Int) -> [MenuEntry] {
        guard let collection, let found = memory.window?.item(at: position) else { return [] }
        return collection.actions(of: found).map { action in
            MenuEntry(action: action, title: title(of: action), isChecked: action.isChecked(for: found))
        }
    }

    func choose(_ action: PluginPageItemAction, on item: String) {
        guard let position = memory.window?.position(of: item) else { return }
        choose(action, at: position)
    }

    /// The user chose `action` from the context menu of the item at
    /// `position`, which the menu selected: on an item of a multiple
    /// collection's selection it acts on the whole selection.
    func choose(_ action: PluginPageItemAction, at position: Int) {
        if !(memory.selectsMultiple && memory.isSelected(position)), memory.selectedPosition != position {
            let before = memory.selectedPosition
            memory.select(position: position)
            collectionDisplay?.selectionMoved(from: before, to: position)
            userChangedSelection()
        } else if let item = memory.window?.item(at: position), memory.selectedPosition != position {
            memory.focusWithinSelection(item.id)
            collectionDisplay?.selectionChanged()
        }
        perform(action, shown: shownTarget())
    }

    /// A row's toggle checkbox: its item action on that row alone, which it
    /// selects.
    func chooseAlone(_ action: PluginPageItemAction, at position: Int) {
        if memory.selectedPosition != position || memory.selectedItems.count > 1 {
            let before = memory.selectedPosition
            let wasGroup = memory.selectedItems.count > 1
            memory.select(position: position)
            if wasGroup { collectionDisplay?.selectionChanged() } else { collectionDisplay?.selectionMoved(from: before, to: position) }
            userChangedSelection()
        }
        perform(action, shown: shownTarget())
    }

    /// `action` on the selection, as the Host performs or delivers it;
    /// nothing when it is not available, as a single item action is not
    /// while several items are selected.
    private func perform(_ action: PluginPageItemAction, shown: InsertionTargetCapture) {
        guard let gesture = memory.gesture(action) else { return }
        eventError = nil
        settleSelectionNow()
        switch gesture {
        case .perform(let operation):
            session.perform(operation, insertionTarget: operation.perform == "selection.replace" ? shown : .notShown)
        case .deliver(let event):
            session.send(event, insertionTarget: shown)
        }
    }

    // MARK: - Buttons

    func choose(_ action: PluginPageAction) {
        eventError = nil
        settleSelectionNow()
        switch action.kind {
        case .event(let id, _):
            session.send(.pageActionChosen(page: page.id, action: id, values: memory.values, selection: memory.selection),
                         insertionTarget: shownTarget())
        case .perform(let operation):
            // An insert button names its App itself, so pressing it is a
            // gesture made with that App shown.
            let shown = operation.perform == "selection.replace" ? capture() : .notShown
            session.perform(operation, insertionTarget: shown)
        }
    }

    /// The cancel View Action of a `progress` component: `action_chosen`
    /// with its ID, as a button's, while the task still runs.
    func chooseCancel(of progress: PluginPageProgress) {
        guard let cancel = progress.cancel, progress.offersCancel else { return }
        eventError = nil
        session.send(.pageActionChosen(page: page.id, action: cancel.id, values: memory.values, selection: memory.selection),
                     insertionTarget: shownTarget())
    }

    // MARK: - Images

    /// What an `image` component shows now.
    func imageState(of request: PageImageRequest) -> PageImageState {
        guard let images = environment.images else { return .failed(localized("Images are not available")) }
        return images.state(of: request, in: session)
    }

    func retryImage(_ request: PageImageRequest) {
        environment.images?.retry(request, in: session)
    }

    /// A picture of the page changed state.
    func imagesChanged() { objectWillChange.send() }

    /// Opens a link from page text, as a page action for `open.url` would.
    func open(_ url: URL) {
        session.perform(RequestedHostOperation(perform: "open.url", input: .string(url.absoluteString)),
                        insertionTarget: .notShown)
    }

    // MARK: - Scrolling and windows

    /// The collection view measured its items' width and the rows on
    /// screen: an adaptive Grid takes the columns that width holds (#80).
    /// Returns whether the columns or rows changed.
    @discardableResult
    func collectionMeasured(itemsWidth: CGFloat, visibleRows: Int) -> Bool {
        guard memory.window != nil else { return false }
        return memory.fitCollection(itemsWidth: Double(itemsWidth), visibleRows: visibleRows)
    }

    /// The collection shows `viewport` now: the window lets go of what is
    /// far from it, and the Host asks for what it lacks.
    func viewportChanged(_ viewport: Range<Int>) {
        guard memory.window != nil else { return }
        memory.setViewport(viewport)
        requestRangeIfNeeded()
    }

    private func requestScroll(to position: Int?, atTop: Bool) {
        serial += 1
        let request = ScrollRequest(position: position, item: position.flatMap { memory.window?.item(at: $0)?.id },
                                    atTop: atTop, serial: serial)
        scrollRequest = request
        collectionDisplay?.scroll(to: request)
    }

    /// Asks for the range the screen lacks with `load_range`: at most one
    /// running per collection, a newer one replacing one still waiting.
    private func requestRangeIfNeeded() {
        guard let collection, let window = memory.window, window.isWindowed, let range = memory.missingRange else { return }
        if session.isDispatched(where: Self.isLoadRange) { return }
        if requestedRange?.range == range, session.isPending(where: Self.isLoadRange) { return }
        requestedRange = (range, window.layoutRevision)
        session.send(.loadRange(page: page.id, collection: collection.id, start: range.lowerBound, count: range.count))
    }

    /// The `load_range` asked for is answered, failed or was dropped: what
    /// did not come is not asked for again, and the Host asks for what the
    /// screen still lacks.
    private func settleRange() {
        guard let requested = requestedRange, !session.isPending(where: Self.isLoadRange) else { return }
        requestedRange = nil
        if memory.window?.layoutRevision == requested.layout { memory.settleRange(requested.range) }
        requestRangeIfNeeded()
    }

    private static func isLoadRange(_ event: PluginViewEvent) -> Bool {
        if case .loadRange = event { return true }
        return false
    }

    // MARK: - Selection changes

    /// The user moved the selection, or may have: a Collection declaring
    /// `selection_events` hears where it settles once it has been stable for
    /// `ScriptedActionBudgets.selectionChangeSettle` and no move key is held.
    private func userChangedSelection() {
        guard let collection, collection.selectionEvents else { return }
        selectionSerial += 1
        settlingSelection = (page.id, collection.id, selectionSerial)
        scheduleSelectionSettle(selectionSerial)
    }

    private func scheduleSelectionSettle(_ serial: Int) {
        environment.schedule(ScriptedActionBudgets.selectionChangeSettle) { [weak self] in
            guard let self, self.settlingSelection?.serial == serial else { return }
            // A held key keeps moving the selection: it settles after release.
            if self.moveKeyIsHeld() { return self.scheduleSelectionSettle(serial) }
            self.settleSelectionNow()
        }
    }

    /// Sends the selection still settling, if it is somewhere the Plugin
    /// has not heard of, as before a gesture made on it. One waiting for its
    /// item is sent when the item comes.
    private func settleSelectionNow() {
        guard let settling = settlingSelection else { return }
        guard settling.page == page.id, settling.collection == collection?.id,
              let event = memory.selectionChangedEvent,
              case .selectionChanged(_, _, let items, _) = event else {
            settlingSelection = nil
            return
        }
        guard !items.isEmpty else { return }
        settlingSelection = nil
        let ids = items.map(\.id)
        guard ids != knownSelection else { return }
        knownSelection = ids
        session.send(event)
    }

    /// An answer was applied. What it did to the selection is the Plugin's
    /// own and is never sent back: another page or a renewed Collection
    /// drops a change still settling, and so does an answer that moved the
    /// selection; a selection the user made that waited for its item settles
    /// once it comes.
    private func reconcileSettlingSelection(before: [String], waitedForItem: Bool, applied: PluginPageMemory.Applied) {
        let now = memory.selectedItems.map(\.id)
        let renewed = applied.pageChanged || page.collection.map { applied.renewed.contains($0.id) } ?? true
        if let settling = settlingSelection, !renewed {
            if waitedForItem, !now.isEmpty {
                scheduleSelectionSettle(settling.serial)
                return
            }
            if before == now { return }
        }
        settlingSelection = nil
        knownSelection = now
    }

    /// The keys that move the selection: arrows, Page Up/Down, Home and End.
    private static let moveKeys: [CGKeyCode] = [123, 124, 125, 126, 116, 121, 115, 119]

    static func liveMoveKeyIsHeld() -> Bool {
        moveKeys.contains { CGEventSource.keyState(.combinedSessionState, key: $0) }
    }

    // MARK: - Insertion target

    var showsInsertionTargets: Bool { session.showsInsertionTargets && environment.insertionTargets != nil }
    var insertionTargetName: String? { environment.insertionTargets?.current?.name }

    /// The Host's line at the foot of a page that can insert.
    var insertionTargetLine: String? {
        guard showsInsertionTargets, page.drawsInsertionTarget else { return nil }
        return insertionTargetName.map { localized("Inserts into \($0)") } ?? Self.noInsertionTarget
    }

    /// The label an insert button carries beside its title.
    func insertionTargetLabel(of action: PluginPageAction) -> String? {
        guard showsInsertionTargets, case .perform(let operation) = action.kind, operation.perform == "selection.replace" else {
            return nil
        }
        return insertionTargetName.map { localized("into \($0)") } ?? Self.noInsertionTarget
    }

    static let noInsertionTarget = PluginViewModel.noInsertionTarget

    private func capture() -> InsertionTargetCapture {
        guard showsInsertionTargets, let targets = environment.insertionTargets else { return .notShown }
        return targets.capture()
    }

    /// What the user could see as where text would go: the target line.
    private func shownTarget() -> InsertionTargetCapture {
        page.drawsInsertionTarget ? capture() : .notShown
    }

    // MARK: - Chrome

    func showToast(_ text: String) {
        toast = text
        toastCount += 1
        let shown = toastCount
        environment.schedule(PluginViewModel.toastDuration) { [weak self] in
            guard let self, self.toastCount == shown else { return }
            self.toast = nil
        }
    }

    func repair() {
        guard let route = repairRoute else { return }
        environment.repair(route, session.pluginID)
    }

    func close() { session.close() }

    // MARK: - Accessibility

    /// What VoiceOver reads for an item: its title, subtitle and accessory.
    func accessibilityLabel(of item: PluginPageItem) -> String {
        [item.title, item.subtitle, item.accessory].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The custom actions VoiceOver offers on an item: the context menu's,
    /// a toggle's saying whether it is checked.
    func accessibilityActions(of item: String) -> [String] {
        menu(of: item).map(Self.accessibilityName)
    }

    static func accessibilityName(of entry: MenuEntry) -> String {
        guard entry.action.toggle != nil else { return entry.title }
        return "\(entry.title), \(entry.isChecked ? localized("checked") : localized("not checked"))"
    }

    /// What VoiceOver reads for a position whose item is still to come.
    static var placeholderLabel: String { localized("Loading") }

    /// What VoiceOver reads as the collection's selection: how many items
    /// a multiple collection has selected; nil for a single one.
    var selectionAccessibilityValue: String? {
        guard memory.selectsMultiple else { return nil }
        let count = memory.selectedItems.count
        return count == 1 ? localized("1 item selected") : localized("\(count) items selected")
    }

    /// The collection's label: its search field's title, else the page's.
    var collectionLabel: String {
        if let field = searchField, case .textField(let declared)? = page.component(field) {
            return localized("\(declared.title) results")
        }
        return page.title
    }

    static func liveInputMethodIsSelected() -> Bool { HostInputSource.isInputMethodSelected() }
}

/// What draws a page's collection: the model tells it what changed.
protocol PageCollectionDisplay: AnyObject {
    /// The items, their layout or the footer changed.
    func reloadCollection()
    /// The selection moved between two positions; only their cells change.
    func selectionMoved(from: Int?, to: Int?)
    /// A multiple collection's selection changed: every cell on screen may.
    func selectionChanged()
    /// Scroll to a position, or to the top.
    func scroll(to request: PluginPageModel.ScrollRequest)
    /// The collection gained or lost the keyboard.
    func focusChanged()
}
