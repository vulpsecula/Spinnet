import Foundation
import SpinnetCore

/// One View Session of a Plugin declaring Candidate Contract `collections`,
/// driven by recorded gestures the way the Host drives it: answers are read
/// and applied as the Host applies them, through the same page memory, so
/// typed text, choices, selection and focus survive refreshes and come back
/// with a remembered page; gestures produce the events, with their
/// snapshots, the Host would deliver; and page and item actions that name a
/// Host Service are performed by the Host without running the script.
///
/// Every event runs the Command once in the real helper, in order. Nothing is
/// debounced: each `type` stands for a pause in typing.
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
    /// Every event delivered to the script, in order.
    public private(set) var events: [PluginViewEvent] = []
    /// Every run, in order, the Action's start first.
    public private(set) var runs: [PluginTestRun] = []
    /// What the Host performed: page and item actions naming a Host
    /// Service, and operations the script's answers requested, in order.
    public private(set) var performed: [RequestedHostOperation] = []
    /// The toasts the answers carried.
    public private(set) var toasts: [String] = []
    public private(set) var isClosed = false
    /// Text fields in which the test says an input-method composition is
    /// open: a reset of one of them is dropped, as the Host drops it.
    public var composing: Set<String> = []

    /// The Command and input of the Action handling the session: the one
    /// that opened it, or the last call whose answer committed a page or
    /// view (Candidate Contract `collections` r2).
    public private(set) var handler: (commandID: String, input: JSONValue)

    private let helper: PluginTestHelper
    private let plugin: PluginUnderTest
    private let services: PluginHostServiceBroker
    /// The loaded count the Host last asked for more at, per collection.
    private var askedAt: [String: Int] = [:]

    public init(_ commandID: String, of plugin: PluginUnderTest, helper: PluginTestHelper,
                answering services: PluginHostServiceBroker = RecordedHostServices(), input: JSONValue = .null) {
        handler = (commandID, input)
        self.plugin = plugin
        self.helper = helper
        self.services = services
    }

    // MARK: What the Host shows

    public var page: PluginPage? { memory.page }
    public var collection: PluginPageCollection? { page?.collection }
    public var values: JSONValue { memory.values }
    public var selectedItem: PluginPageItem? { memory.selectedItem }
    public var focus: String? { memory.state.focus }

    public func text(of field: String) -> String? { memory.state.texts[field] }
    public func choice(of field: String) -> String? { memory.state.choices[field] }

    /// The script's last answer, as the Host read it.
    public func lastAnswer() throws -> PluginScriptAnswer {
        guard let run = runs.last else { throw PluginTestKitError.unknownCommand(handler.commandID) }
        return try run.answer()
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
    /// For a Plugin declaring `collections` r2 the call runs in the session
    /// as `called`, from the last good state, as a gesture with no insertion
    /// target shown; only an answer with a page or view makes it the handler,
    /// and a failure throws and keeps the handler, page and state. For any
    /// other Plugin, Level 1's rule: the Action starts again with no event
    /// and no state, and an answer with a view replaces the session's.
    @discardableResult
    public func call(_ commandID: String? = nil, input: JSONValue? = nil) throws -> PluginScriptAnswer {
        let called = (commandID ?? handler.commandID, input ?? handler.input)
        let intoSession = PluginInterfaceContracts.host.permitting(plugin.manifest)(CollectionsContract.repeatedCallsIntoSession)
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

    /// The user clicked `item`, which selects it.
    public func select(_ item: String) throws {
        guard collection?.positions[item] != nil else { throw PluginTestPageError.noItem(item) }
        memory.select(item)
        if let collection { memory.state.focus = collection.id }
        try askForMoreIfNeeded()
    }

    /// An arrow, Page or Home/End key that moves the selection, in the
    /// search field (Up and Down) or the collection. Reaching within a
    /// screenful of the end asks for more, as the Host does.
    public func press(_ move: PluginPageCollection.Move) throws {
        memory.moveSelection(move)
        try askForMoreIfNeeded()
    }

    /// The user scrolled to the end of what is loaded.
    public func scrollToEnd() throws {
        guard let collection else { return }
        try askForMore(collection, nearEnd: collection.hasMore)
    }

    /// Return: in a search field or the collection, the default item action
    /// on the selection; in a text field that searches nothing, `submitted`.
    @discardableResult
    public func pressReturn(in field: String? = nil) throws -> PluginScriptAnswer? {
        guard let page else { return nil }
        if let field, case .textField(let declared)? = page.component(field), declared.collection == nil {
            return try run(.pageSubmitted(page: page.id, field: field, values: memory.values, selection: memory.selection))
        }
        guard let item = memory.selectedItem, let action = collection?.defaultAction else { return nil }
        return try perform(action, on: item)
    }

    /// A double-click on `item`: it is selected and its default item action runs.
    @discardableResult
    public func doubleClick(_ item: String) throws -> PluginScriptAnswer? {
        try select(item)
        guard let found = collection?.item(item), let action = collection?.defaultAction else { return nil }
        return try perform(action, on: found)
    }

    /// The titles `item`'s context menu offers, the default first.
    public func menu(of item: String) throws -> [String] {
        guard let collection, let found = collection.item(item) else { throw PluginTestPageError.noItem(item) }
        return collection.actions(of: found).map(\.title)
    }

    /// The user chose the item action `action` from `item`'s context menu.
    @discardableResult
    public func choose(itemAction action: String, on item: String) throws -> PluginScriptAnswer? {
        guard let collection, let found = collection.item(item) else { throw PluginTestPageError.noItem(item) }
        guard let chosen = collection.actions(of: found).first(where: { $0.id == action }) else {
            throw PluginTestPageError.noAction(action)
        }
        return try perform(chosen, on: found)
    }

    /// ⌘C with the collection focused: the selected item's `clipboard.write`
    /// item action, when the collection has exactly one; else nothing.
    public func copySelection() throws {
        guard let item = memory.selectedItem, let copy = collection?.copyAction else { return }
        try perform(copy, on: item)
    }

    /// The user clicked the button whose event ID or title is `button`.
    @discardableResult
    public func click(_ button: String) throws -> PluginScriptAnswer? {
        guard let page else { return nil }
        for case .actions(_, let actions) in page.components {
            for action in actions {
                switch action.kind {
                case .event(let id, _) where id == button || action.title == button:
                    return try run(.pageActionChosen(page: page.id, action: id, values: memory.values,
                                                     selection: memory.selection))
                case .perform(let operation) where action.title == button || operation.id == button:
                    hostPerforms(operation)
                    return nil
                default:
                    continue
                }
            }
        }
        throw PluginTestPageError.noAction(button)
    }

    // MARK: Running

    private func perform(_ action: PluginPageItemAction, on item: PluginPageItem) throws -> PluginScriptAnswer? {
        if let operation = action.operation(on: item) {
            hostPerforms(operation)
            return nil
        }
        guard let page, let collection else { return nil }
        return try run(.itemAction(page: page.id, collection: collection.id, action: action.id,
                                   item: collection.snapshot(of: item), values: memory.values))
    }

    private func hostPerforms(_ operation: RequestedHostOperation) {
        performed.append(operation)
        if operation.closesView { isClosed = true }
    }

    private func askForMoreIfNeeded() throws {
        guard let collection else { return }
        try askForMore(collection, nearEnd: collection.isNearEnd(memory.selectedPosition))
    }

    private func askForMore(_ collection: PluginPageCollection, nearEnd: Bool) throws {
        guard nearEnd, collection.hasMore, let page, askedAt[collection.id] != collection.items.count else { return }
        askedAt[collection.id] = collection.items.count
        try run(.loadMore(page: page.id, collection: collection.id, loaded: collection.items.count))
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
        apply(answer)
        return answer
    }

    private func apply(_ answer: PluginScriptAnswer) {
        if let toast = answer.toast { toasts.append(toast) }
        if answer.close {
            isClosed = true
            return
        }
        if let page = answer.page {
            let applied = memory.show(page, composing: composing)
            if let id = page.collection?.id, applied.pageChanged || applied.renewed.contains(id) { askedAt[id] = nil }
            pageJSON = answer.pageJSON
            levelOneView = nil
            state = answer.state
        } else if let view = answer.view {
            memory.showLevelOneView()
            levelOneView = view
            pageJSON = nil
            state = answer.state
        }
        if let operation = answer.operation { hostPerforms(operation) }
    }
}

public enum PluginTestPageError: Error, Equatable, CustomStringConvertible {
    case noComponent(String)
    case noItem(String)
    case noAction(String)
    case closed

    public var description: String {
        switch self {
        case .noComponent(let id): return "The page has no input \(id)"
        case .noItem(let id): return "The collection has no item \(id)"
        case .noAction(let id): return "There is no action \(id) to choose"
        case .closed: return "The view is closed"
        }
    }
}
