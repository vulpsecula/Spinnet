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
    typealias ClickModifier = PluginPageMemory.ClickModifier

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
    /// Where each multi-line field was scrolled, by page and field ID.
    private var scrollOffsets: [String: CGFloat] = [:]
    /// Reads a text field's caret where it is being edited.
    private var carets: [String: () -> PluginPageCaret?] = [:]
    /// The views that take the keyboard, by component.
    private var focusTargets: [String: WeakFocusTarget] = [:]
    /// The focus request the views have yet to honour.
    private var unhonouredFocus: String?

    private struct WeakFocusTarget {
        weak var view: PluginPageFocusTarget?
    }
    /// Counts the user's changes to the selection, so only the pause after
    /// the last one settles it.
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
        let applied = memory.show(next, composing: composing, answersRange: answersRange)
        page = next
        // A selection the user made that waited for its item settles once
        // the item comes.
        if applied.selectionSettlesAgain { scheduleSelectionSettle(selectionSerial) }
        activityList.setAvailable(next.components.contains { if case .activityList = $0 { return true }; return false })
        let textFields = next.components.filter(\.kind.holdsText).map(\.id)
        for field in textFields where applied.renewed.contains(field) {
            textRevisions[field, default: 0] += 1
        }
        if applied.pageChanged {
            // Every field of another page is drawn anew from the memory.
            for field in textFields { textRevisions[field, default: 0] += 1 }
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

    func isOn(_ field: String) -> Bool { memory.state.toggles[field] ?? false }

    /// Whether `field` takes `text`: a multi-line field takes no more than
    /// `CollectionsContract.maximumMultilineTextBytes`.
    func takes(_ text: String, in field: String) -> Bool {
        page.component(field)?.kind != .multilineTextField
            || text.utf8.count <= CollectionsContract.maximumMultilineTextBytes
    }

    /// The field's committed text changed. Composing text is never sent.
    func textChanged(_ field: String, to text: String, caret: PluginPageCaret?) {
        composing.remove(field)
        guard memory.state.texts[field] != nil, memory.state.texts[field] != text else {
            if let caret { memory.state.carets[field] = caret }
            return
        }
        guard memory.setText(text, of: field, caret: caret) else { return }
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

    /// A click on a toggle field, or Space in it: `field_changed` goes at
    /// once, after any typing still waiting out its pause.
    func setToggle(_ on: Bool, in field: String) {
        guard memory.state.toggles[field] != nil, memory.state.toggles[field] != on else { return }
        memory.setToggle(on, of: field)
        objectWillChange.send()
        eventError = nil
        session.flushFieldChanges()
        session.send(.pageFieldChanged(page: page.id, field: field, values: memory.values))
        session.flushFieldChanges()
    }

    /// Where the user scrolled a multi-line field of this page, so a field
    /// drawn anew comes back there.
    func scrollOffset(of field: String) -> CGFloat? { scrollOffsets["\(page.id)/\(field)"] }

    func scrolled(_ field: String, to offset: CGFloat) { scrollOffsets["\(page.id)/\(field)"] = offset }

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
        page.components.filter { $0.kind.isInput || [.list, .grid].contains($0.kind) }.map(\.id)
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
        guard let handled = memory.press(move) else { return false }
        handle(handled)
        return true
    }

    /// Shift with an arrow, Page or Home/End key in a multiple collection:
    /// extends the selection from the anchor to where the key moves the
    /// focus. In a single collection the key moves the selection.
    @discardableResult
    func extendSelection(_ move: PluginPageCollection.Move) -> Bool {
        guard let handled = memory.press(move, extending: true) else { return false }
        handle(handled)
        return true
    }

    /// ⌘A in a multiple collection: selects every item. Returns false for a
    /// single collection, which has nothing to select all of.
    @discardableResult
    func selectAll() -> Bool {
        guard let handled = memory.selectAll() else { return false }
        handle(handled)
        return true
    }

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

    /// Whether `field` searches the page's collection, so Up, Down and
    /// Return act on it.
    func searchesCollection(_ field: String) -> Bool { memory.searches(field) }

    /// Return in a text field. In a search field it performs the default
    /// item action on the selection once the answer to the typing before it
    /// has come (C1); in another field it sends `submitted`.
    func returnPressed(in field: String) {
        let shown = shownTarget()
        if searchesCollection(field), session.hasPendingFieldChange {
            pendingReturn = shown
            session.flushFieldChanges()
            return
        }
        handle(memory.pressReturn(in: field), shown: shown)
    }

    /// Return in the collection.
    func returnPressedInCollection() { handle(memory.pressReturn(), shown: shownTarget()) }

    private func settlePendingReturn() {
        guard let shown = pendingReturn, !session.hasPendingFieldChange else { return }
        pendingReturn = nil
        // A search that failed gives nothing to act on.
        if let failed = session.errorEvent, failed.coalesces { return }
        handle(memory.pressReturn(), shown: shown)
    }

    /// ⌘C with the collection focused: the sole `clipboard.write` item
    /// action, on every selected item of a multiple collection, their texts
    /// one per line.
    func copySelection() -> Bool {
        guard let handled = memory.copySelection() else { return false }
        handle(handled, shown: shownTarget())
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
        handle(memory.click(at: position, modifier: modifier))
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
        handle(memory.doubleClick(at: position), shown: shownTarget())
    }

    /// A right click on the cell at `position`: within a multiple
    /// collection's selection it keeps the selection and focuses the item;
    /// elsewhere it selects the item, as a click does.
    func rightClick(at position: Int) {
        handle(memory.rightClick(at: position))
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
        memory.contextMenu(at: position).map(entry)
    }

    /// What the context menu of the item at `position` offers; nothing for
    /// a placeholder.
    func menu(at position: Int) -> [MenuEntry] {
        memory.itemMenu(at: position).map(entry)
    }

    private func entry(_ entry: PluginPageMemory.MenuEntry) -> MenuEntry {
        MenuEntry(action: entry.action, title: title(of: entry.action), isChecked: entry.isChecked, isEnabled: entry.isEnabled)
    }

    private func title(of action: PluginPageItemAction) -> String {
        action.perform == "selection.replace"
            ? "\(action.title) \(insertionTargetName.map { localized("into \($0)") } ?? Self.noInsertionTarget)"
            : action.title
    }

    func choose(_ action: PluginPageItemAction, on item: String) {
        guard let position = memory.window?.position(of: item) else { return }
        choose(action, at: position)
    }

    /// The user chose `action` from the context menu of the item at
    /// `position`, which the menu selected: on an item of a multiple
    /// collection's selection it acts on the whole selection.
    func choose(_ action: PluginPageItemAction, at position: Int) {
        handle(memory.choose(action, at: position), shown: shownTarget())
    }

    /// A row's toggle checkbox: its item action on that row alone, which it
    /// selects.
    func chooseAlone(_ action: PluginPageItemAction, at position: Int) {
        handle(memory.chooseAlone(action, at: position), shown: shownTarget())
    }

    /// What a gesture did, adapted to AppKit and the View Session: the
    /// keyboard, drawing and scrolling follow it, what the screen lacks is
    /// asked for, the selection starts settling, and its events go in order,
    /// an item action as the Host performs or delivers it with `shown` as
    /// the target the user could see.
    private func handle(_ handled: PluginPageMemory.Handled, shown: InsertionTargetCapture = .notShown) {
        if let focus = handled.focus { requestFocus(focus) }
        switch handled.redraw {
        case .none: break
        case .moved(let from, let to): collectionDisplay?.selectionMoved(from: from, to: to)
        case .all: collectionDisplay?.selectionChanged()
        }
        if let position = handled.reveal {
            requestScroll(to: position, atTop: false)
            // Nothing draws the collection: the selection's row is on screen.
            if collectionDisplay == nil { memory.reveal(position) }
        }
        if handled.asksForRange { requestRangeIfNeeded() }
        if handled.settling {
            selectionSerial += 1
            scheduleSelectionSettle(selectionSerial)
        }
        if let gesture = handled.gesture {
            eventError = nil
            if let settled = handled.selectionChanged { session.send(settled) }
            switch gesture {
            case .perform(let operation):
                session.perform(operation, insertionTarget: operation.perform == "selection.replace" ? shown : .notShown)
            case .deliver(let event):
                session.send(event, insertionTarget: shown)
            }
        } else if let submitted = handled.submitted {
            if let settled = handled.selectionChanged { session.send(settled) }
            session.send(submitted, insertionTarget: shown)
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

    /// A Collection declaring `selection_events` hears where the user's
    /// selection settles once it has been stable for
    /// `ScriptedActionBudgets.selectionChangeSettle` and no move key is held.
    private func scheduleSelectionSettle(_ serial: Int) {
        environment.schedule(ScriptedActionBudgets.selectionChangeSettle) { [weak self] in
            guard let self, self.selectionSerial == serial, self.memory.isSettlingSelection else { return }
            // A held key keeps moving the selection: it settles after release.
            if self.moveKeyIsHeld() { return self.scheduleSelectionSettle(serial) }
            self.settleSelectionNow()
        }
    }

    /// Sends the selection still settling, if it is somewhere the Plugin
    /// has not heard of, as before a gesture made on it.
    private func settleSelectionNow() {
        if let event = memory.settleSelection() { session.send(event) }
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
