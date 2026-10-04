import AppKit
import Combine
import SpinnetCore

/// One drawn page of a Plugin declaring Candidate Contract `collections`
/// (ADR 0019): the page the session shows with the immediate state the Host
/// keeps for it, the keyboard roles of its search field and collection, and
/// the Host's own chrome (target line, empty, loading and failure states).
/// It turns the user's input into page events for its session, and page and
/// item actions naming a Host Service into operations the Host performs.
///
/// What the user types never republishes the page: the field already shows
/// it, so typing costs no redraw until the Plugin answers.
final class PluginPageModel: ObservableObject {
    /// Whether the last `load_more` is running or failed.
    enum LoadingMore: Equatable { case idle, loading, failed }

    /// Asks the views to move the keyboard focus. Each request is new, so
    /// asking twice for the same component is honoured twice.
    struct FocusRequest: Equatable {
        let component: String
        let serial: Int
    }

    /// Asks the collection to scroll: to an item, or to the top when nil.
    struct ScrollRequest: Equatable {
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
    }

    let session: PluginViewSession
    @Published private(set) var page: PluginPage
    /// What only the collection's items and scrolling read: the selection,
    /// whether the collection has the keyboard, and where to scroll. Kept
    /// apart so a selection move redraws the visible items, not the page.
    let collectionState = PageCollectionState()
    /// The grid cell under the pointer, whose title is the grid's tooltip.
    let hoverState = PageHoverState()
    /// The collection's selected item.
    var selectedItem: String? { collectionState.selectedItem }
    /// A pinned page stays open when it loses focus and when an action or
    /// operation with `closes_view` succeeds.
    @Published var isPinned = false
    @Published private(set) var isBusy = false
    @Published private(set) var isPerformingOperation = false
    @Published private(set) var eventError: ActionFailure?
    @Published private(set) var toast: String?
    @Published private(set) var loadingMore = LoadingMore.idle
    private(set) var focusRequest: FocusRequest?
    var scrollRequest: ScrollRequest? { collectionState.scrollRequest }
    /// Counts, per text field, the times the Host replaced its text: a new
    /// or reset field. The field view writes the text only then.
    @Published private(set) var textRevisions: [String: Int] = [:]
    /// Which component has the keyboard, as the views report it.
    @Published private(set) var focused: String?

    /// What the Host keeps for this page and the pages it remembers.
    private(set) var memory = PluginPageMemory()
    /// Text fields with an open input-method composition.
    private(set) var composing: Set<String> = []
    /// The items on screen in the collection, by position.
    private var visible: Set<Int> = []
    private var askedAt: Int?
    /// A Return in the search field waiting for the answer to the typing
    /// before it (C1), with what the Host showed when it was pressed.
    private var pendingReturn: InsertionTargetCapture?
    private var serial = 0
    private var toastCount = 0
    private var targetChanges: AnyCancellable?
    private let environment: PluginViewEnvironment
    /// Reads a text field's caret where it is being edited.
    private var carets: [String: () -> PluginPageCaret?] = [:]
    /// The views that take the keyboard, by component.
    private var focusTargets: [String: WeakFocusTarget] = [:]
    /// The focus request the views have yet to honour.
    private var unhonouredFocus: String?

    private struct WeakFocusTarget {
        weak var view: PluginPageFocusTarget?
    }
    /// Whether an input method rather than a keyboard layout is selected,
    /// so a key typed in the collection cannot safely go to the field.
    var inputMethodIsSelected: () -> Bool = PluginPageModel.liveInputMethodIsSelected

    init(session: PluginViewSession, presentation: PluginViewPresentation, page: PluginPage,
         environment: PluginViewEnvironment) {
        self.session = session
        self.page = page
        self.environment = environment
        update(presentation, page: page, newView: true, presentedAnew: true)
        if session.showsInsertionTargets {
            targetChanges = environment.insertionTargets?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var title: String { page.title }
    var pluginName: String { environment.pluginName(session.pluginID) }
    /// The failure shown inline: a failed `load_more` shows in the
    /// collection's own row, with Retry, instead.
    var error: ActionFailure? {
        if loadingMore == .failed, case .loadMore? = session.errorEvent { return nil }
        return eventError
    }
    var repairRoute: PluginViewRepairRoute? { error.flatMap(PluginViewRepairRoute.init) }
    var collection: PluginPageCollection? { page.collection }

    // MARK: - Answers

    /// Shows what the session presents. A new page, or a new answer to this
    /// one, is applied through the page memory: what the user is doing is
    /// kept unless the Plugin reset it.
    func update(_ presentation: PluginViewPresentation, page next: PluginPage, newView: Bool, presentedAnew: Bool) {
        isBusy = presentation.isBusy
        isPerformingOperation = presentation.isPerformingOperation
        eventError = presentation.error
        if newView { apply(next, presentedAnew: presentedAnew) }
        settleLoadingMore()
        settlePendingReturn()
    }

    private func apply(_ next: PluginPage, presentedAnew: Bool) {
        let previous = memory.page
        if let previous, let id = previous.collection?.id { memory.state.scrollAnchors[id] = firstVisibleItem(of: previous) }
        saveCarets()
        let applied = memory.show(next, composing: composing)
        page = next
        collectionState.select(memory.selectedItem?.id)
        for case .textField(let field) in next.components where applied.renewed.contains(field.id) {
            textRevisions[field.id, default: 0] += 1
        }
        if applied.pageChanged {
            // Every field of another page is drawn anew from the memory.
            for case .textField(let field) in next.components { textRevisions[field.id, default: 0] += 1 }
            composing = []
            visible = []
        }
        if let collection = next.collection {
            if applied.pageChanged || applied.renewed.contains(collection.id) {
                askedAt = nil
                loadingMore = .idle
                let anchor = memory.state.scrollAnchors[collection.id]
                requestScroll(to: applied.restored ? anchor : nil, atTop: true)
            } else if let anchor = previous?.collection.flatMap({ firstVisibleItem(of: $0) }),
                      let before = previous?.collection?.positions[anchor], let after = collection.positions[anchor],
                      before != after {
                // Items arrived above what the user is looking at: keep it in place.
                requestScroll(to: anchor, atTop: true)
            }
        }
        if applied.pageChanged || next.reset == .page || presentedAnew, let focus = memory.state.focus {
            requestFocus(focus)
        } else if let focused, next.component(focused) == nil, let fallback = memory.state.focus {
            requestFocus(fallback)
        }
    }

    private func firstVisibleItem(of page: PluginPage) -> String? {
        firstVisibleItem(of: page.collection)
    }

    private func firstVisibleItem(of collection: PluginPageCollection?) -> String? {
        guard let collection, let first = visible.min(), collection.items.indices.contains(first) else { return nil }
        return collection.items[first].id
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
        if collectionState.isFocused != collectionFocused { collectionState.isFocused = collectionFocused }
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
    /// the collection: moves the selection and keeps it in view.
    @discardableResult
    func moveSelection(_ move: PluginPageCollection.Move) -> Bool {
        guard let item = memory.moveSelection(move) else { return false }
        collectionState.select(item.id)
        requestScroll(to: item.id, atTop: false)
        askForMoreIfNeeded(at: memory.selectedPosition)
        return true
    }

    /// Whether `field` searches the page's collection, so Up, Down and
    /// Return act on it.
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

    private func performDefaultOnSelection(shown: InsertionTargetCapture) {
        guard let collection, let id = memory.selectedItem?.id, let item = collection.item(id),
              let action = collection.defaultAction, collection.actions(of: item).contains(action) else { return }
        perform(action, on: item, shown: shown)
    }

    /// ⌘C with the collection focused: the sole `clipboard.write` item action.
    func copySelection() -> Bool {
        guard let collection, let copy = collection.copyAction, let id = memory.selectedItem?.id,
              let item = collection.item(id), collection.actions(of: item).contains(copy) else { return false }
        perform(copy, on: item, shown: shownTarget())
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

    func click(_ item: String) {
        guard collection?.positions[item] != nil else { return }
        memory.select(item)
        collectionState.select(item)
        if let collection { requestFocus(collection.id) }
        askForMoreIfNeeded(at: memory.selectedPosition)
    }

    func doubleClick(_ item: String) {
        click(item)
        guard let collection, let found = collection.item(item), let action = collection.defaultAction,
              collection.actions(of: found).contains(action) else { return }
        perform(action, on: found, shown: shownTarget())
    }

    /// What `item`'s context menu offers: the default first.
    func menu(of item: String) -> [MenuEntry] {
        guard let collection, let found = collection.item(item) else { return [] }
        return collection.actions(of: found).map { action in
            MenuEntry(action: action, title: action.perform == "selection.replace"
                      ? "\(action.title) \(insertionTargetName.map { "into \($0)" } ?? Self.noInsertionTarget)"
                      : action.title)
        }
    }

    func choose(_ action: PluginPageItemAction, on item: String) {
        guard let found = collection?.item(item) else { return }
        perform(action, on: found, shown: shownTarget())
    }

    private func perform(_ action: PluginPageItemAction, on item: PluginPageItem, shown: InsertionTargetCapture) {
        guard let collection else { return }
        eventError = nil
        if let operation = action.operation(on: item) {
            session.perform(operation, insertionTarget: operation.perform == "selection.replace" ? shown : .notShown)
            return
        }
        session.send(.itemAction(page: page.id, collection: collection.id, action: action.id,
                                 item: collection.snapshot(of: item), values: memory.values),
                     insertionTarget: shown)
    }

    // MARK: - Buttons

    func choose(_ action: PluginPageAction) {
        eventError = nil
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

    /// Opens a link from page text, as a page action for `open.url` would.
    func open(_ url: URL) {
        session.perform(RequestedHostOperation(perform: "open.url", input: .string(url.absoluteString)),
                        insertionTarget: .notShown)
    }

    // MARK: - Scrolling and more items

    func itemAppeared(at index: Int) {
        visible.insert(index)
        if let collection, index >= collection.items.count - collection.columns { askForMoreIfNeeded(atEnd: true) }
    }

    func itemDisappeared(at index: Int) { visible.remove(index) }

    private func requestScroll(to item: String?, atTop: Bool) {
        serial += 1
        collectionState.scrollRequest = ScrollRequest(item: item, atTop: atTop, serial: serial)
    }

    private func askForMoreIfNeeded(at position: Int?) {
        guard let collection, collection.isNearEnd(position) else { return }
        askForMoreIfNeeded(atEnd: true)
    }

    private func askForMoreIfNeeded(atEnd: Bool) {
        guard atEnd, let collection, collection.hasMore, loadingMore == .idle,
              askedAt != collection.items.count else { return }
        askedAt = collection.items.count
        loadingMore = .loading
        session.send(.loadMore(page: page.id, collection: collection.id, loaded: collection.items.count))
    }

    /// Retry after a failed `load_more`.
    func retryLoadingMore() {
        askedAt = nil
        loadingMore = .idle
        eventError = nil
        askForMoreIfNeeded(atEnd: true)
    }

    private func settleLoadingMore() {
        guard loadingMore == .loading else { return }
        let isLoadMore: (PluginViewEvent) -> Bool = { if case .loadMore = $0 { return true } else { return false } }
        guard !session.isPending(where: isLoadMore) else { return }
        if let failed = session.errorEvent, isLoadMore(failed) {
            loadingMore = .failed
        } else {
            loadingMore = .idle
        }
    }

    // MARK: - Insertion target

    var showsInsertionTargets: Bool { session.showsInsertionTargets && environment.insertionTargets != nil }
    var insertionTargetName: String? { environment.insertionTargets?.current?.name }

    /// The Host's line at the foot of a page that can insert.
    var insertionTargetLine: String? {
        guard showsInsertionTargets, page.drawsInsertionTarget else { return nil }
        return insertionTargetName.map { "Inserts into \($0)" } ?? Self.noInsertionTarget
    }

    /// The label an insert button carries beside its title.
    func insertionTargetLabel(of action: PluginPageAction) -> String? {
        guard showsInsertionTargets, case .perform(let operation) = action.kind, operation.perform == "selection.replace" else {
            return nil
        }
        return insertionTargetName.map { "into \($0)" } ?? Self.noInsertionTarget
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

    /// What VoiceOver reads for an item: its title, and whether it is selected.
    func accessibilityLabel(of item: PluginPageItem) -> String {
        [item.title, item.subtitle, item.accessory].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The custom actions VoiceOver offers on an item: the context menu's.
    func accessibilityActions(of item: String) -> [String] { menu(of: item).map(\.title) }

    /// The collection's label: its search field's title, else the page's.
    var collectionLabel: String {
        if let field = searchField, case .textField(let declared)? = page.component(field) {
            return "\(declared.title) results"
        }
        return page.title
    }

    static func liveInputMethodIsSelected() -> Bool { HostInputSource.isInputMethodSelected() }
}

/// The collection's selection, keyboard focus and scroll requests, which its
/// items and scroll view observe without the rest of the page.
final class PageCollectionState: ObservableObject {
    @Published private(set) var selectedItem: String?
    @Published var isFocused = false
    @Published var scrollRequest: PluginPageModel.ScrollRequest?

    func select(_ item: String?) {
        if selectedItem != item { selectedItem = item }
    }
}

/// The title of the grid cell under the pointer.
final class PageHoverState: ObservableObject {
    @Published var title: String?
}
