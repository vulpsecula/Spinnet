import Foundation
import SpinnetCore

/// One View Session of a Plugin API Level 2 Plugin's pages, driven by recorded gestures the way the Host drives it: answers are read
/// and applied as the Host applies them, through the same page memory, so
/// typed text, choices, selection and focus survive refreshes and come back
/// with a remembered page; gestures produce the events, with their
/// snapshots, the Host would deliver; and page and item actions that name a
/// Host Service are performed by the Host without running the script.
///
/// Every event runs the Command once in the real helper, in order. Nothing is
/// debounced: each `type` stands for a pause in typing. For a windowed
/// collection the screen is the rows around the selection, or
/// where the test scrolled, and the kit asks for what it lacks with
/// `load_range` after every gesture and answer, as the Host does.
public final class PluginTestPage {
    /// What the Host keeps: the page on screen with its immediate state, and
    /// the pages remembered.
    public private(set) var memory = PluginPageMemory()
    /// The state the script returned with its last page or view.
    public private(set) var state: JSONValue = .null
    /// The Level 1 view on screen instead of a page, if the script answered one.
    public private(set) var levelOneView: JSONValue?
    /// The page as the script last wrote it.
    public private(set) var pageJSON: JSONValue?
    /// Every event delivered to the script in the session, in order.
    public private(set) var events: [PluginViewEvent] = []
    /// Every run, in order, the Action's start first, and those after the
    /// view closed.
    public private(set) var runs: [PluginTestRun] = []
    /// What the Host performed: page and item actions naming a Host
    /// Service, and operations the script's answers requested, in order.
    public private(set) var performed: [RequestedHostOperation] = []
    /// The outcome of each, in the same order.
    public private(set) var outcomes: [HostOperationOutcome] = []
    /// The toasts the answers carried, those shown near the pointer after
    /// the view closed included.
    public private(set) var toasts: [String] = []
    public private(set) var isClosed = false
    /// `operation_finished` events delivered after the view closed
    /// (`host_operations` r2), each to a viewless invocation.
    public private(set) var afterClose: [PluginViewEvent] = []
    /// Text fields in which the test says an input-method composition is
    /// open: a reset of one of them is dropped, as the Host drops it.
    public var composing: Set<String> = []
    /// Whether the user pinned the panel: a pinned view stays open when an
    /// operation or action with `closes_view` succeeds.
    public var isPinned = false
    /// The outcome the Host reaches for each catalogue ID, when not success.
    /// An insertion after a gesture with no target shown is refused with
    /// `target_not_shown` whatever is recorded, as in the Host.
    public var operationOutcomes: [String: HostOperationOutcome] = [:]

    /// The Command and input of the Action handling the session: the one
    /// that opened it, or the last call whose answer committed a page or
    /// view (Candidate Contract `collections` r2).
    public private(set) var handler: (commandID: String, input: JSONValue)

    private let helper: PluginTestHelper
    private let plugin: PluginUnderTest
    private let services: PluginHostServiceBroker
    private let permits: (PluginInterfaceMember) -> Bool

    public init(_ commandID: String, of plugin: PluginUnderTest, helper: PluginTestHelper,
                answering services: PluginHostServiceBroker = RecordedHostServices(), input: JSONValue = .null) {
        handler = (commandID, input)
        self.plugin = plugin
        self.helper = helper
        self.services = services
        permits = helper.contracts.permitting(plugin.manifest)
    }

    // MARK: What the Host shows

    public var page: PluginPage? { memory.page }
    /// The collection as the last answer described it; its items are that
    /// answer's slice. `window` holds what the Host keeps.
    public var collection: PluginPageCollection? { page?.collection }
    /// The items the Host holds of the collection, by position.
    public var window: PluginCollectionWindow? { memory.window }
    public var values: JSONValue { memory.values }
    public var selectedItem: PluginPageItem? { memory.selectedItem }
    /// Where the selection is, its item held or not.
    public var selectedPosition: Int? { memory.selectedPosition }
    public var focus: String? { memory.state.focus }

    public func text(of field: String) -> String? { memory.state.texts[field] }
    public func choice(of field: String) -> String? { memory.state.choices[field] }

    /// The item the Host holds at `position` of the collection.
    public func item(at position: Int) -> PluginPageItem? { window?.item(at: position) }

    /// The script's last answer, as the Host read it.
    public func lastAnswer() throws -> PluginScriptAnswer {
        guard let run = runs.last else { throw PluginTestKitError.unknownCommand(handler.commandID) }
        return try run.answer()
    }

    /// What the Host would show for each `image` component of the page
    /// (Plugin API Level 2, #81), by component ID, without the network: a
    /// package resource is read and decoded within the Host's budgets, to
    /// its pixel size; an HTTPS source is checked against what the
    /// handler's Command declares and the hosts the user added, and
    /// reported as `.loading`, which the Host would fetch once
    /// `contact_https` is granted. A refusal is `.failed` with the reason
    /// the image shows.
    public func images(consentedHosts: [String] = []) -> [String: PageImageState] {
        var states: [String: PageImageState] = [:]
        for case .image(let image) in page?.components ?? [] {
            switch image.source {
            case .resource(let path):
                do {
                    let data = try PluginPackageResource.read(path, in: plugin.package.rootURL)
                    states[image.id] = .loaded(try PageImageDecoder.decode(data, maximumPixelSize: image.request.maximumPixelSize))
                } catch {
                    states[image.id] = .failed((error as? PluginHostServiceError)?.description ?? "\(error)")
                }
            case .url:
                states[image.id] = plugin.manifest.refusal(toLoad: image.source, for: CommandID(handler.commandID),
                                                           consentedHosts: consentedHosts).map(PageImageState.failed) ?? .loading
            }
        }
        return states
    }

    // MARK: Gestures

    /// Starts the Action, as a Menu Item does.
    @discardableResult
    public func open() throws -> PluginScriptAnswer {
        try run(nil)
    }

    /// The user calls an Action of the Plugin while this session is open, as
    /// a Menu Item does: the Action of `commandID` with `input`, the Plugin
    /// Settings and the Menu Item's overrides already merged, by default the
    /// handler's own.
    ///
    /// For a Level 2 Plugin the call runs in the session as `called`, from the last good state, as a gesture with no
    /// insertion target shown; only an answer with a page or view makes it
    /// the handler, and a failure throws and keeps the handler, page and
    /// state. For any other Plugin, Level 1's rule: the Action starts again
    /// with no event and no state, and an answer with a view replaces the
    /// session's.
    @discardableResult
    public func call(_ commandID: String? = nil, input: JSONValue? = nil) throws -> PluginScriptAnswer {
        let called = (commandID ?? handler.commandID, input ?? handler.input)
        let intoSession = permits(CollectionsContract.repeatedCallsIntoSession)
        let answer = try intoSession ? run(.called, as: called) : run(nil, as: called, state: .null)
        if answer.description != nil { handler = called }
        return answer
    }

    /// The user typed until `field` holds `text` and paused.
    @discardableResult
    public func type(_ text: String, into field: String) throws -> PluginScriptAnswer? {
        guard let page, memory.state.texts[field] != nil else { throw PluginTestPageError.noComponent(field) }
        memory.setText(text, of: field)
        memory.state.focus = field
        return try run(.pageFieldChanged(page: page.id, field: field, values: memory.values))
    }

    /// The user chose `value` in choice field `field`.
    @discardableResult
    public func choose(_ value: String, in field: String) throws -> PluginScriptAnswer? {
        guard let page, memory.state.choices[field] != nil else { throw PluginTestPageError.noComponent(field) }
        memory.setChoice(value, of: field)
        return try run(.pageFieldChanged(page: page.id, field: field, values: memory.values))
    }

    /// The user clicked `item`, which selects it. The Host must hold it.
    public func select(_ item: String) throws {
        guard let position = window?.position(of: item) else { throw PluginTestPageError.noItem(item) }
        try select(at: position)
    }

    /// The user clicked the cell at `position`, held or still a placeholder.
    public func select(at position: Int) throws {
        guard let total = window?.total, (0..<total).contains(position) else { throw PluginTestPageError.noItem("\(position)") }
        memory.select(position: position)
        if let collection { memory.state.focus = collection.id }
        try selectionMoved()
    }

    /// An arrow, Page or Home/End key that moves the selection, in the
    /// search field (Up and Down, and Left and Right when it searches a
    /// grid) or the collection. The selection is kept
    /// on screen; reaching within a screenful of the end asks for more, and
    /// reaching positions the Host does not hold asks for them, as the Host
    /// does.
    public func press(_ move: PluginPageCollection.Move) throws {
        memory.moveSelection(move)
        try selectionMoved()
    }

    /// The user scrolled the collection so that `position`'s row is the
    /// first on screen, leaving the selection where it was.
    public func scroll(to position: Int) throws {
        guard let window else { return }
        let first = max(min(position, window.total - window.screen), 0) / window.columns * window.columns
        memory.setViewport(first..<min(first + window.screen, window.total))
        try loadRanges()
    }

    /// The user resized a resizable page's panel (#80) so that the
    /// collection's items are `itemsWidth` points wide with `visibleRows`
    /// rows on screen: an adaptive grid takes the columns that width holds,
    /// and what the larger screen lacks is asked for with `load_range`, as
    /// the Host does. Nothing is sent to the Plugin otherwise.
    public func resize(itemsWidth: Double, visibleRows: Int) throws {
        guard page?.resizing != nil, let viewport = window.flatMap({ window in
            collection.flatMap { memory.state.viewports[$0.id] } ?? 0..<min(window.screen, window.total)
        }) else { return }
        memory.fitCollection(itemsWidth: itemsWidth, visibleRows: visibleRows)
        guard let window else { return }
        let first = viewport.lowerBound / window.columns * window.columns
        memory.setViewport(first..<min(first + window.screen, window.total))
        try loadRanges()
    }

    /// The user scrolled to the end of a windowed collection.
    public func scrollToEnd() throws {
        guard let window, window.isWindowed else { return }
        try scroll(to: window.total - 1)
    }

    /// Return: in a search field or the collection, the default item action
    /// on the selection; in a text field that searches nothing, `submitted`.
    /// Nothing happens while the selection waits for its item.
    @discardableResult
    public func pressReturn(in field: String? = nil) throws -> PluginScriptAnswer? {
        guard let page else { return nil }
        if let field, case .textField(let declared)? = page.component(field), declared.collection == nil {
            return try run(.pageSubmitted(page: page.id, field: field, values: memory.values, selection: memory.selection))
        }
        guard let item = memory.selectedItem, let action = collection?.defaultAction,
              offers(action, on: item) else { return nil }
        return try perform(action, on: item)
    }

    /// A double-click on `item`: it is selected and its default item action runs.
    @discardableResult
    public func doubleClick(_ item: String) throws -> PluginScriptAnswer? {
        try select(item)
        guard let found = memory.selectedItem, let action = collection?.defaultAction, offers(action, on: found) else {
            return nil
        }
        return try perform(action, on: found)
    }

    /// The titles `item`'s context menu offers, the default first; a toggle
    /// item action the item's marks check reads "✓ title".
    public func menu(of item: String) throws -> [String] {
        guard let collection, let found = window?.position(of: item).flatMap({ window?.item(at: $0) }) else {
            throw PluginTestPageError.noItem(item)
        }
        return collection.actions(of: found).map { $0.isChecked(for: found) ? "✓ \($0.title)" : $0.title }
    }

    /// The user chose the item action `action` from `item`'s context menu.
    @discardableResult
    public func choose(itemAction action: String, on item: String) throws -> PluginScriptAnswer? {
        guard let collection, let position = window?.position(of: item) else { throw PluginTestPageError.noItem(item) }
        memory.select(position: position)
        guard let found = memory.selectedItem else { throw PluginTestPageError.noItem(item) }
        guard let chosen = collection.actions(of: found).first(where: { $0.id == action }) else {
            throw PluginTestPageError.noAction(action)
        }
        return try perform(chosen, on: found)
    }

    /// ⌘C with the collection focused: the selected item's `clipboard.write`
    /// item action, when the collection has exactly one; else nothing.
    public func copySelection() throws {
        guard let item = memory.selectedItem, let copy = collection?.copyAction, offers(copy, on: item) else { return }
        try perform(copy, on: item)
    }

    /// The user clicked the button whose event ID or title is `button`.
    @discardableResult
    public func click(_ button: String) throws -> PluginScriptAnswer? {
        guard let page else { return nil }
        // A progress component's cancel, which the Host draws only while
        // its task runs (#81).
        for case .progress(let progress) in page.components {
            guard let cancel = progress.cancel, cancel.id == button || cancel.title == button else { continue }
            guard progress.offersCancel else { throw PluginTestPageError.noAction(button) }
            return try run(.pageActionChosen(page: page.id, action: cancel.id, values: memory.values,
                                             selection: memory.selection))
        }
        for case .actions(_, let actions) in page.components {
            for action in actions {
                switch action.kind {
                case .event(let id, _) where id == button || action.title == button:
                    return try run(.pageActionChosen(page: page.id, action: id, values: memory.values,
                                                     selection: memory.selection))
                case .perform(let operation) where action.title == button || operation.id == button:
                    // An insert button names its App itself.
                    try hostPerforms(operation, targetShown: true)
                    return nil
                default:
                    continue
                }
            }
        }
        throw PluginTestPageError.noAction(button)
    }

    // MARK: Running

    private func offers(_ action: PluginPageItemAction, on item: PluginPageItem) -> Bool {
        collection?.actions(of: item).contains(action) ?? false
    }

    private func perform(_ action: PluginPageItemAction, on item: PluginPageItem) throws -> PluginScriptAnswer? {
        let snapshot = memory.selectedSnapshot ?? collection?.snapshot(of: item)
        if let operation = action.operation(on: item, snapshot: snapshot) {
            try hostPerforms(operation, targetShown: page?.drawsInsertionTarget == true)
            return nil
        }
        guard let page, let collection, let snapshot else { return nil }
        return try run(.itemAction(page: page.id, collection: collection.id, action: action.id, item: snapshot,
                                   values: memory.values))
    }

    /// The Host performs `operation`, reaching its recorded outcome, closes
    /// the view on success when asked and the user did not pin it, and
    /// tells the Plugin when it asked: in the session, or after the view
    /// closed.
    private func hostPerforms(_ operation: RequestedHostOperation, targetShown: Bool) throws {
        let outcome: HostOperationOutcome = operation.perform == "selection.replace" && !targetShown
            ? .refused(.targetNotShown)
            : operationOutcomes[operation.perform] ?? .succeeded
        performed.append(operation)
        outcomes.append(outcome)
        if operation.closesView, outcome == .succeeded, !isPinned { isClosed = true }
        guard operation.notify else { return }
        if !isClosed {
            try run(.operationFinished(id: operation.id, perform: operation.perform, outcome: outcome, item: operation.item))
        } else if permits(HostOperationsContract.outcomeAfterClose) {
            try runAfterClose(.operationFinished(id: operation.id, perform: operation.perform, outcome: outcome,
                                                 viewClosed: true, item: operation.item))
        }
    }

    /// The viewless invocation that hears an outcome after the view closed:
    /// the handler, from the last good state; its answer may show a toast
    /// and nothing else.
    private func runAfterClose(_ event: PluginViewEvent) throws {
        afterClose.append(event)
        let invocation = PluginTestInvocation(handler.commandID, input: handler.input, event: event, state: state)
        let run = helper.run(invocation, of: plugin, answering: services)
        runs.append(run)
        let answer = try run.answer()
        guard answer.description == nil, !answer.close else {
            throw PluginRuntimeError.protocolViolation(
                "The script's answer to operation_finished after its view closed shows a view or closes one; there is no view")
        }
        if let toast = answer.toast { toasts.append(toast) }
    }

    /// The selection moved: it is kept on screen, and the Host asks for
    /// what it needs.
    private func selectionMoved() throws {
        if let window, let position = memory.selectedPosition, let viewport = memory.state.viewports[collection?.id ?? ""],
           !viewport.contains(position) {
            let row = position / window.columns * window.columns
            let first = position < viewport.lowerBound ? row : max(row - (window.rows - 1) * window.columns, 0)
            memory.setViewport(first..<min(first + window.screen, window.total))
        }
        try loadRanges()
    }

    /// Asks for what the screen lacks, one range at a time, until nothing
    /// is missing or what is missing was asked for and did not come.
    private func loadRanges() throws {
        var asked = 0
        while !isClosed, let page, let collection, let range = memory.missingRange {
            asked += 1
            guard asked <= 64 else { throw PluginTestPageError.rangesKeepChanging }
            let revision = memory.window?.layoutRevision
            do {
                try run(.loadRange(page: page.id, collection: collection.id, start: range.lowerBound, count: range.count))
            } catch let error as PluginRuntimeError where error.failureCategory == .runtimeProtocolFailed {
                throw error
            } catch {
                // A failed range is shown inline; the Host asks again only
                // when the user moves onto it.
                if memory.window?.layoutRevision == revision { memory.settleRange(range) }
                throw error
            }
            if memory.window?.layoutRevision == revision { memory.settleRange(range) }
        }
    }

    /// Runs the handler, or for a call the Action called, once for `event`
    /// from the last good state, and applies its answer. An answer the Host
    /// would end the session for closes it.
    @discardableResult
    private func run(_ event: PluginViewEvent?, as action: (commandID: String, input: JSONValue)? = nil,
                     state: JSONValue? = nil) throws -> PluginScriptAnswer {
        guard !isClosed else { throw PluginTestPageError.closed }
        if let event { events.append(event) }
        let runner = action ?? handler
        let invocation = PluginTestInvocation(runner.commandID, input: runner.input, event: event,
                                              state: state ?? self.state, view: pageJSON ?? levelOneView)
        let run = helper.run(invocation, of: plugin, answering: services)
        runs.append(run)
        let answer: PluginScriptAnswer
        do {
            answer = try run.answer()
        } catch let error as PluginRuntimeError where error.failureCategory == .runtimeProtocolFailed {
            isClosed = true
            throw error
        }
        let answersRange: Bool
        if case .loadRange? = event { answersRange = true } else { answersRange = false }
        try apply(answer, answersRange: answersRange,
                  targetShown: invocation.delivery(permits: permits).insertionTarget.isShown)
        return answer
    }

    private func apply(_ answer: PluginScriptAnswer, answersRange: Bool, targetShown: Bool) throws {
        if let toast = answer.toast { toasts.append(toast) }
        if answer.close {
            isClosed = true
            return
        }
        if let page = answer.page {
            memory.show(page, composing: composing, answersRange: answersRange)
            pageJSON = answer.pageJSON
            levelOneView = nil
            state = answer.state
        } else if let view = answer.view {
            memory.showLevelOneView()
            levelOneView = view
            pageJSON = nil
            state = answer.state
        }
        if let operation = answer.operation { try hostPerforms(operation, targetShown: targetShown) }
        // A range's own answer is settled by whoever asked for it.
        if !answersRange, answer.page != nil { try loadRanges() }
    }
}

public enum PluginTestPageError: Error, Equatable, CustomStringConvertible {
    case noComponent(String)
    case noItem(String)
    case noAction(String)
    case closed
    /// Every answer to `load_range` changed the collection's total or
    /// sections again, so the Host would never hold what it shows.
    case rangesKeepChanging

    public var description: String {
        switch self {
        case .noComponent(let id): return "The page has no input \(id)"
        case .noItem(let id): return "The collection has no item \(id)"
        case .noAction(let id): return "There is no action \(id) to choose"
        case .closed: return "The view is closed"
        case .rangesKeepChanging: return "Every answer to load_range changed the collection's total or sections"
        }
    }
}
