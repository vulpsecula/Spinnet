import Foundation
import SpinnetCore

/// One View Session of a compatible Plugin's pages, driven by recorded gestures the way the Host drives it: answers are read
/// and applied as the Host applies them, through the same page memory, so
/// typed text, choices, selection and focus survive refreshes and come back
/// with a remembered page; gestures produce the events, with their
/// snapshots, the Host would deliver; and page and item actions that name a
/// Host Service are performed by the Host without running the script.
///
/// Every event runs the Command once in the real helper, in order. Nothing is
/// debounced: each `type` stands for a pause in typing, and each gesture
/// that moves the selection of a Collection declaring `selection_events`
/// for a settled selection, which delivers `selection_changed` when the
/// selection is somewhere the Plugin has not heard of (ADR 0025); `hold`
/// stands for an arrow key held down. For a windowed
/// collection the screen is the rows around the selection, or
/// where the test scrolled, and the kit asks for what it lacks with
/// `load_range` after every gesture and answer, as the Host does.
public final class PluginTestPage {
    /// What the Host keeps: the page on screen with its immediate state, and
    /// the pages remembered.
    public private(set) var memory = PluginPageMemory()
    /// The state the script returned with its last page or view.
    public private(set) var state: JSONValue = .null
    /// The form/detail view on screen instead of a page, if the script answered one.
    public private(set) var viewJSON: JSONValue?
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
    /// view.
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
    /// Every selected item in Collection order: several in a multiple
    /// collection (ADR 0025), else the selected item, if any.
    public var selectedItems: [PluginPageItem] { memory.selectedItems }
    /// Where the selection is, its item held or not.
    public var selectedPosition: Int? { memory.selectedPosition }
    public var focus: String? { memory.state.focus }

    /// Current own Host-generated rows when this page contains activity_list.
    /// No helper runs, matching the native resource control.
    public func activityRows() throws -> JSONValue {
        guard page?.components.contains(where: { if case .activityList = $0 { return true }; return false }) == true else {
            return .array([])
        }
        return try activityService(.listActivities, input: .null)
    }

    /// Presses the Host's native Stop without a Plugin View Event.
    public func stopActivity(_ id: String) throws {
        guard page?.components.contains(where: { if case .activityList = $0 { return true }; return false }) == true else {
            throw PluginTestKitError.unknownCommand("activity_list")
        }
        _ = try activityService(.stopActivity, input: .object(["id": .string(id)]))
    }

    private func activityService(_ service: PluginHostService, input: JSONValue) throws -> JSONValue {
        let action = try plugin.action(for: PluginTestInvocation(handler.commandID, input: handler.input))
        return try services.execute(request: PluginRuntimeHostServiceRequest(invocationID: UUID().uuidString,
            actionID: action.id, service: service, input: input), for: plugin.package, action: action)
    }

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
    /// (the current interface, #81), by component ID, without the network: a
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
    /// Calls run as `called` from the last good state with no insertion
    /// target shown. Only an answer with a page or view replaces the handler;
    /// a failure preserves the previous handler, page and state.
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
        guard memory.setText(text, of: field) else { throw PluginTestPageError.tooLong(field) }
        memory.state.focus = field
        return try run(.pageFieldChanged(page: page.id, field: field, values: memory.values))
    }

    /// The user clicked toggle field `field`, or pressed Space in it: it
    /// switches, and `field_changed` follows at once.
    @discardableResult
    public func flip(_ field: String) throws -> PluginScriptAnswer? {
        guard let page, let on = memory.state.toggles[field] else { throw PluginTestPageError.noComponent(field) }
        memory.setToggle(!on, of: field)
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
        try select(at: try position(of: item))
    }

    /// The user clicked the cell at `position`, held or still a placeholder,
    /// scrolled into view first.
    public func select(at position: Int) throws {
        guard let total = window?.total, (0..<total).contains(position) else { throw PluginTestPageError.noItem("\(position)") }
        try click(at: position, modifier: .none)
    }

    /// ⌘-click on `item` of a multiple collection: adds it to the selection,
    /// or removes it; the last selected item stays. In a single collection,
    /// a click.
    public func commandClick(_ item: String) throws {
        try click(at: try position(of: item), modifier: .command)
    }

    /// Shift-click on `item` of a multiple collection: selects the items from
    /// the anchor, the last item clicked, to it. In a single collection, a
    /// click.
    public func shiftClick(_ item: String) throws {
        try click(at: try position(of: item), modifier: .shift)
    }

    private func click(at position: Int, modifier: PluginPageMemory.ClickModifier) throws {
        memory.reveal(position)
        try handle(memory.click(at: position, modifier: modifier))
    }

    /// Where `item` is; the Host must hold it.
    private func position(of item: String) throws -> Int {
        guard let position = window?.position(of: item), window?.item(at: position) != nil else {
            throw PluginTestPageError.noItem(item)
        }
        return position
    }

    /// Shift with an arrow, Page or Home/End key in a multiple collection:
    /// extends the selection from the anchor to where the key moves. In a
    /// single collection the key moves the selection.
    public func extendSelection(_ move: PluginPageCollection.Move) throws {
        guard let handled = memory.press(move, extending: true) else { return try settle() }
        try handle(handled)
    }

    /// ⌘A in a multiple collection: selects every item.
    public func selectAll() throws {
        guard let handled = memory.selectAll() else { return }
        try handle(handled)
    }

    /// An arrow, Page or Home/End key that moves the selection, in the
    /// search field (Up and Down, and Left and Right when it searches a
    /// grid) or the collection. The selection is kept
    /// on screen; reaching within a screenful of the end asks for more, and
    /// reaching positions the Host does not hold asks for them, as the Host
    /// does.
    public func press(_ move: PluginPageCollection.Move) throws {
        try hold(move, steps: 1)
    }

    /// An arrow, Page or Home/End key held down until the selection has
    /// moved `steps` times, then released: what the screen lacks is asked for
    /// on the way, and one `selection_changed`, if any, follows the release.
    public func hold(_ move: PluginPageCollection.Move, steps: Int) throws {
        for _ in 0..<max(steps, 0) {
            guard let handled = memory.press(move) else { continue }
            try handle(handled, settles: false)
        }
        try settle()
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
        guard page != nil else { return nil }
        return try handle(memory.pressReturn(in: field))
    }

    /// A double-click on `item`: its first click selects it, as a click
    /// does, and its default item action runs. On an item of a multiple
    /// collection's selection of several items, the first click reduces the
    /// selection to it and the second runs the default for the whole
    /// selection, as in the Host.
    @discardableResult
    public func doubleClick(_ item: String) throws -> PluginScriptAnswer? {
        let position = try position(of: item)
        memory.reveal(position)
        // The selection does not settle between the two clicks.
        try handle(memory.click(at: position), settles: false)
        return try handle(memory.doubleClick(at: position))
    }

    /// The titles `item`'s context menu offers, the default first; a toggle
    /// item action the item's marks check reads "✓ title". On an item of a
    /// multiple collection's selection of several items the menu is the
    /// selection's: the actions every selected item offers, a toggle checked
    /// when all carry its mark, and a single item action read
    /// "title (unavailable)".
    public func menu(of item: String) throws -> [String] {
        memory.contextMenu(at: try position(of: item)).map { entry in
            let title = entry.isChecked ? "✓ \(entry.action.title)" : entry.action.title
            return entry.isEnabled ? title : "\(title) (unavailable)"
        }
    }

    /// The user right-clicked `item` and chose the item action `action` from
    /// its context menu. On an item of a multiple collection's selection it
    /// acts on the whole selection; otherwise the item is selected first.
    @discardableResult
    public func choose(itemAction action: String, on item: String) throws -> PluginScriptAnswer? {
        let position = try position(of: item)
        try handle(memory.rightClick(at: position), settles: false)
        guard let entry = memory.contextMenu(at: position).first(where: { $0.action.id == action }), entry.isEnabled else {
            try settle()
            throw PluginTestPageError.noAction(action)
        }
        return try handle(memory.choose(entry.action, at: position))
    }

    /// ⌘C with the collection focused: the selection's `clipboard.write`
    /// item action, when the collection has exactly one; else nothing. On a
    /// multiple collection's selection it copies every selected item's text,
    /// one per line, in Collection order.
    public func copySelection() throws {
        guard let handled = memory.copySelection() else { return }
        try handle(handled)
    }

    /// The user clicked the button whose event ID or title is `button`.
    @discardableResult
    public func click(_ button: String) throws -> PluginScriptAnswer? {
        guard let page else { return nil }
        // A button acts after the selection still settling.
        try settle()
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

    /// What a gesture did, adapted to the recorded runner: the keyboard and
    /// screen follow it, what the screen lacks is asked for, and its events
    /// run in the Host's order. Each gesture stands for a settled selection
    /// unless `settles` is false, as between the clicks of a double-click.
    /// Returns the answer to the gesture's own event, if any.
    @discardableResult
    private func handle(_ handled: PluginPageMemory.Handled, settles: Bool = true) throws -> PluginScriptAnswer? {
        if let focus = handled.focus { memory.state.focus = focus }
        if let position = handled.reveal { memory.reveal(position) }
        if handled.asksForRange { try loadRanges() }
        if let event = handled.selectionChanged { try run(event) }
        var answer: PluginScriptAnswer?
        if let submitted = handled.submitted { answer = try run(submitted) }
        switch handled.gesture {
        case .perform(let operation)?:
            try hostPerforms(operation, targetShown: page?.drawsInsertionTarget == true)
        case .deliver(let event)?:
            answer = try run(event)
        case nil:
            break
        }
        if settles { try settle() }
        return answer
    }

    /// The selection settled where the user left it: a Collection declaring
    /// `selection_events` hears of it when it is somewhere the Plugin has not
    /// heard of. A selection waiting for its item is heard of once it comes.
    private func settle() throws {
        guard !isClosed, let event = memory.settleSelection() else { return }
        try run(event)
    }

    /// The Host performs `operation`, reaching its recorded outcome, closes
    /// the view on success when asked and the user did not pin it, and
    /// tells the Plugin when it asked: in the session, or after the view
    /// closed.
    private func hostPerforms(_ operation: RequestedHostOperation, targetShown: Bool) throws {
        if operation.perform == "apps.perform", operation.input.value(atPointer: "/bundle_id") == .string(TerminalHomebrew.bundleID) {
            let action = try plugin.action(for: PluginTestInvocation(handler.commandID, input: handler.input))
            try RecordedHostServices.validateTerminalHandoff(input: operation.input, package: plugin.package, action: action)
        }
        if operation.perform == ReviewedServicesAddition.id {
            guard plugin.manifest.declares(.readReviewedTools, for: CommandID(handler.commandID)) else { throw PluginHostServiceError.capabilityDenied(.readReviewedTools) }
            try ReviewedServicesAddition.authorize(in: plugin.manifest.scope(for: .readReviewedTools))
        }
        let outcome: HostOperationOutcome = operation.perform == "selection.replace" && !targetShown
            ? .refused(.targetNotShown)
            : operationOutcomes[operation.perform] ?? .succeeded
        performed.append(operation)
        outcomes.append(outcome)
        if operation.closesView, outcome == .succeeded, !isPinned { isClosed = true }
        guard operation.notify else { return }
        if !isClosed {
            try run(.operationFinished(id: operation.id, perform: operation.perform, outcome: outcome, item: operation.item,
                                       items: operation.items))
        } else if permits(HostOperationsContract.outcomeAfterClose) {
            try runAfterClose(.operationFinished(id: operation.id, perform: operation.perform, outcome: outcome,
                                                 viewClosed: true, item: operation.item, items: operation.items))
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
                                              state: state ?? self.state, view: pageJSON ?? viewJSON)
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
            // What an answer does to the selection is the Plugin's own and is
            // never sent back; a selection the user made that waited for its
            // item is the user's, and the gesture settles it.
            memory.show(page, composing: composing, answersRange: answersRange)
            pageJSON = answer.pageJSON
            viewJSON = nil
            state = answer.state
        } else if let view = answer.view {
            memory.showViewPayload()
            viewJSON = view
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
    /// The text is longer than a `multiline_text_field` takes.
    case tooLong(String)

    public var description: String {
        switch self {
        case .noComponent(let id): return "The page has no input \(id)"
        case .noItem(let id): return "The collection has no item \(id)"
        case .noAction(let id): return "There is no action \(id) to choose"
        case .closed: return "The view is closed"
        case .rangesKeepChanging: return "Every answer to load_range changed the collection's total or sections"
        case .tooLong(let id): return "The field \(id) takes at most \(CollectionsContract.maximumMultilineTextBytes) bytes"
        }
    }
}
