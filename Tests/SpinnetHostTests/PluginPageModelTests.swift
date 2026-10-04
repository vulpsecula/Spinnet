import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Pages of a Plugin declaring Candidate Contract `collections`, drawn by
/// the Host's renderer: immediate state across answers, keyboard roles,
/// pointer gestures, the Host's chrome, and the windows the renderer opens.
final class PluginPageModelTests: XCTestCase {
    private var harness: PageHarness!

    override func setUp() {
        harness = try! PageHarness()
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }

    // MARK: Opening

    func testAPageOpensInItsOwnWindowFocusedOnTheSearchField() throws {
        try harness.open(PageHarness.search())
        XCTAssertEqual(harness.pageWindows.count, 1)
        XCTAssertNil(harness.windows.model(for: PageHarness.pluginID), "No Level 1 view")
        XCTAssertEqual(model.focusRequest?.component, "query")
        XCTAssertEqual(model.focused, "query")
        XCTAssertEqual(model.selectedItem, "A", "Return works on the first result at once (C7)")
        XCTAssertEqual(model.focusStops, ["query", "category", "results"])
        XCTAssertEqual(model.insertionTargetLine, "Inserts into TextEdit")
        XCTAssertEqual(harness.pageWindows.first?.title, "Emoji")
    }

    // MARK: Immediate state

    /// Typing never republishes the page; the answer to it keeps the text,
    /// and only a reset writes into the field.
    func testTypingIsKeptAcrossAnswersUntilAReset() throws {
        try harness.open(PageHarness.search())
        let revision = model.textRevisions["query"]
        model.textChanged("query", to: "cat", caret: PluginPageCaret(location: 3))
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(harness.events.last?.event, .pageFieldChanged(page: "search", field: "query", values: .object([
            "query": .string("cat"), "category": .string("all")
        ])))
        try harness.answer(PageHarness.search(query: "", items: ["C", "D"], reset: ["results"]))
        XCTAssertEqual(model.text(of: "query"), "cat")
        XCTAssertEqual(model.textRevisions["query"], revision, "The field is not written")
        XCTAssertEqual(model.selectedItem, "C")
        model.textChanged("query", to: "cats", caret: nil)
        harness.clock.advance(by: 0.2)
        try harness.answer(PageHarness.search(query: "", items: ["C"], reset: ["query"]))
        XCTAssertEqual(model.text(of: "query"), "")
        XCTAssertNotEqual(model.textRevisions["query"], revision, "A reset writes the field")
    }

    /// No answer interrupts a composition: composing text is not sent, and
    /// a reset of the composing field is dropped.
    func testACompositionIsNeitherSentNorReset() throws {
        try harness.open(PageHarness.search())
        model.textChanged("query", to: "cat ", caret: nil)
        harness.clock.advance(by: 0.2)
        let sent = harness.events.count
        model.compositionChanged("query", isComposing: true)
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(harness.events.count, sent, "Marked text sends nothing")
        let revision = model.textRevisions["query"]
        try harness.answer(PageHarness.search(query: "", items: [], reset: ["query", "results"]))
        XCTAssertEqual(model.textRevisions["query"], revision, "The composing field's reset is dropped")
        XCTAssertNil(model.selectedItem, "The rest of the reset applies")
        model.textChanged("query", to: "cat 猫", caret: nil)
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(harness.events.last?.event, .pageFieldChanged(page: "search", field: "query", values: .object([
            "query": .string("cat 猫"), "category": .string("all")
        ])), "The committed text is sent")
    }

    /// Scenario 05: another page and back restores text, selection and focus.
    func testPageMemoryRestoresTheListAsTheUserLeftIt() throws {
        try harness.open(PageHarness.search())
        model.textChanged("query", to: "py", caret: PluginPageCaret(location: 2))
        model.click("C")
        XCTAssertEqual(model.focused, "results")
        model.returnPressedInCollection()
        try harness.answer(PageHarness.page("detail:C", [PageHarness.buttons(["back"])]))
        XCTAssertNil(model.collection)
        XCTAssertEqual(model.focusStops, [])
        model.choose(try XCTUnwrap(model.page.components.compactMap { component -> PluginPageAction? in
            if case .actions(_, let actions) = component { return actions.first } else { return nil }
        }.first))
        try harness.answer(PageHarness.search())
        XCTAssertEqual(model.text(of: "query"), "py")
        XCTAssertEqual(model.caret(of: "query"), PluginPageCaret(location: 2))
        XCTAssertEqual(model.selectedItem, "C")
        XCTAssertEqual(model.focusRequest?.component, "results", "Focus comes back where it was")
    }

    // MARK: Keyboard roles

    /// Up and Down in the search field move the selection by a grid row;
    /// Return performs the default item action with the item's snapshot and
    /// the target shown when it was pressed.
    func testTheSearchFieldDrivesTheGrid() throws {
        try harness.open(PageHarness.search(items: (0..<20).map { "i\($0)" }))
        XCTAssertTrue(model.searchesCollection("query"))
        XCTAssertTrue(model.moveSelection(.down))
        XCTAssertEqual(model.selectedItem, "i8")
        XCTAssertEqual(model.scrollRequest?.item, "i8", "The selection is kept in view")
        XCTAssertEqual(model.focused, "query", "Focus stays in the field (C2)")
        model.returnPressed(in: "query")
        let event = try XCTUnwrap(harness.events.last)
        XCTAssertEqual(event.event, .itemAction(page: "search", collection: "results", action: "insert",
                                                 item: PluginPageItemSnapshot(id: "i8", section: nil, text: "★"),
                                                 values: .object(["query": .string(""), "category": .string("all")])))
        XCTAssertEqual(event.delivery.insertionTarget, harness.tracker.capture(), "The target shown at the key press")
    }

    /// C1: Return before the answer to the latest typing sends that typing
    /// at once and acts on the selection its answer produced.
    func testReturnWaitsForTheTypingBeforeIt() throws {
        try harness.open(PageHarness.search(items: ["A", "B"]))
        model.textChanged("query", to: "cat", caret: nil)
        model.returnPressed(in: "query")
        XCTAssertEqual(harness.events.count, 1, "The typing is sent without waiting for its pause")
        XCTAssertEqual(harness.events.last?.event?.typeName, "field_changed")
        try harness.answer(PageHarness.search(items: ["CAT", "B"], reset: ["results"]))
        XCTAssertEqual(harness.events.count, 2)
        guard case .itemAction(_, _, _, let item, let values)? = harness.events.last?.event else {
            return XCTFail("Return performed nothing")
        }
        XCTAssertEqual(item.id, "CAT")
        XCTAssertEqual(values, .object(["query": .string("cat"), "category": .string("all")]))

        model.textChanged("query", to: "dog", caret: nil)
        model.returnPressed(in: "query")
        harness.fail(.scriptedActionFailed)
        XCTAssertEqual(harness.events.count, 3, "A failed search gives Return nothing to act on")
    }

    func testTabMovesBetweenTheFieldsAndTheCollection() throws {
        try harness.open(PageHarness.search())
        model.moveFocus(from: "query", forward: true)
        XCTAssertEqual(model.focused, "category")
        model.moveFocus(from: "category", forward: true)
        XCTAssertEqual(model.focused, "results")
        model.moveFocus(from: "results", forward: true)
        XCTAssertEqual(model.focused, "query", "The target line is no stop; Tab wraps")
        model.moveFocus(from: "query", forward: false)
        XCTAssertEqual(model.focused, "results")
    }

    /// C3: a key typed in the collection goes to the search field with a
    /// keyboard layout, and is ignored with an input method.
    func testATypedKeyGoesToTheSearchFieldOnlyWithAKeyboardLayout() throws {
        try harness.open(PageHarness.search())
        model.click("B")
        model.inputMethodIsSelected = { true }
        XCTAssertNil(model.fieldForTypedKey())
        XCTAssertEqual(model.focused, "results")
        model.inputMethodIsSelected = { false }
        XCTAssertEqual(model.fieldForTypedKey(), "query")
        XCTAssertEqual(model.focused, "query")
    }

    // MARK: Pointer and item actions

    /// Double-click selects and performs the default; the context menu
    /// lists the default first; Copy and ⌘C are performed by the Host.
    func testDoubleClickContextMenuAndCopy() throws {
        try harness.open(PageHarness.search())
        model.doubleClick("B")
        XCTAssertEqual(model.selectedItem, "B")
        XCTAssertEqual(model.focused, "results")
        guard case .itemAction(_, _, "insert", let item, _)? = harness.events.last?.event else {
            return XCTFail("No default action")
        }
        XCTAssertEqual(item.id, "B")
        try harness.answer(nil)

        XCTAssertEqual(model.menu(of: "C").map(\.title), ["Insert", "Copy"])
        XCTAssertEqual(model.accessibilityActions(of: "C"), ["Insert", "Copy"])
        let events = harness.events.count
        model.choose(try XCTUnwrap(model.menu(of: "C").last).action, on: "C")
        XCTAssertTrue(model.copySelection())
        XCTAssertEqual(harness.events.count, events, "Copy runs no script")
        XCTAssertEqual(harness.performer.performed.map(\.operation.perform), ["clipboard.write", "clipboard.write"])
        XCTAssertEqual(harness.performer.performed.first?.operation.input, .object(["text": .string("★")]))
    }

    /// A `selection.replace` item action names the App in the menu and
    /// draws the target line even if the page does not ask for it.
    func testAnInsertItemActionNamesTheApp() throws {
        try harness.open(PageHarness.search(insertsItself: true, showsTarget: false))
        XCTAssertEqual(model.menu(of: "A").map(\.title), ["Insert into TextEdit", "Copy"])
        XCTAssertEqual(model.insertionTargetLine, "Inserts into TextEdit")
        model.returnPressedInCollection()
        XCTAssertEqual(harness.performer.performed.first?.operation.perform, "selection.replace")
        XCTAssertEqual(harness.performer.performed.first?.target, harness.tracker.capture())
    }

    func testAPageThatCannotInsertShowsNoTargetLine() throws {
        try harness.open(PageHarness.search(showsTarget: false, copyOnly: true))
        XCTAssertNil(model.insertionTargetLine)
    }

    // MARK: More items

    /// Scenario 09: the Host asks once per loaded count, shows loading,
    /// keeps the selection on append, and offers Retry after a failure.
    func testLoadMoreLoadingRetryAndAppend() throws {
        let ten = (0..<10).map { "i\($0)" }
        try harness.open(PageHarness.search(items: ten, hasMore: true))
        model.click("i1")
        XCTAssertEqual(harness.events.last?.event, .loadMore(page: "search", collection: "results", loaded: 10))
        XCTAssertEqual(model.loadingMore, .loading)
        model.itemAppeared(at: 9)
        XCTAssertEqual(harness.events.count, 1, "One outstanding per collection")
        harness.fail(.helperCrashed)
        XCTAssertEqual(model.loadingMore, .failed)
        XCTAssertNil(model.error, "The collection's own row shows it, with Retry")
        model.retryLoadingMore()
        XCTAssertEqual(harness.events.count, 2)
        try harness.answer(PageHarness.search(items: ten + (10..<26).map { "i\($0)" }))
        XCTAssertEqual(model.loadingMore, .idle)
        XCTAssertEqual(model.selectedItem, "i1")
        XCTAssertEqual(model.collection?.items.count, 26)
        model.itemAppeared(at: 25)
        XCTAssertEqual(harness.events.count, 2, "No has_more, no asking")
    }

    // MARK: Windows

    /// A session may go from a page to a Level 1 view and back: each gets its
    /// own window, and the pin is kept.
    func testPagesAndLevelOneViewsSwapWindowsKeepingThePin() throws {
        try harness.open(PageHarness.search())
        model.isPinned = true
        model.returnPressedInCollection()
        harness.finish(.object(["view": .object(["title": .string("Level 1"),
                                                  "actions": .array([.object(["id": .string("a"), "title": .string("A")])])])]))
        XCTAssertNil(harness.windows.pageModel(for: PageHarness.pluginID))
        let level1 = try XCTUnwrap(harness.windows.model(for: PageHarness.pluginID))
        XCTAssertTrue(level1.isPinned)
        XCTAssertEqual(harness.pageWindows.first?.closes, 1)
        level1.choose(try XCTUnwrap(level1.description.actions.first))
        try harness.answer(PageHarness.search())
        XCTAssertTrue(model.isPinned)
        XCTAssertEqual(harness.pageWindows.count, 2)
        XCTAssertEqual(harness.levelOneWindows.first?.closes, 1)
    }

    func testAnUnpinnedPageClosesWhenItLosesFocus() throws {
        try harness.open(PageHarness.search())
        harness.pageWindows.last?.onResignKey?()
        XCTAssertNil(harness.windows.pageModel(for: PageHarness.pluginID))
        XCTAssertTrue(harness.sessions.session(for: PageHarness.pluginID) == nil)
    }
}

// MARK: - Harness

/// The Host's renderer over View Sessions of a Plugin declaring
/// `collections`, with fake windows, events the test answers by hand, a
/// clock it advances and a performer that records operations.
final class PageHarness {
    static let pluginID = PluginID("com.example.emoji-pages")
    let clock = PageClock()
    let performer = RecordingPerformer()
    let tracker: InsertionTargetTracker
    private let apps: FakeApps
    private(set) var events: [HeldEvent] = []
    private(set) var pageWindows: [FakePluginViewWindow] = []
    private(set) var levelOneWindows: [FakePluginViewWindow] = []
    private(set) var windows: PluginViewWindows!
    private(set) var sessions: PluginViewSessions!

    init() throws {
        let desktop = FakeDesktop()
        desktop.frontmost = 42
        apps = FakeApps(desktop: desktop)
        tracker = InsertionTargetTracker(environment: apps.environment)
        let hostActions = PluginViewHostActions(
            authorize: { _, _ in }, manifest: { _ in nil }, copyText: { _ in }, openURL: { _ in },
            insertText: { _, _, finished in finished(nil) }, openPluginSettings: { _ in },
            readSettings: { _ in [:] }, writeSettings: { _, _ in }
        )
        let environment = PluginViewEnvironment(
            hostActions: hostActions, sections: RecordingSectionProvider(), settingsFields: { _ in [] },
            pluginName: { _ in "Emoji Pages" }, repair: { _, _ in }, copy: { _ in },
            schedule: { _, _ in }, report: { _ in }, insertionTargets: tracker
        )
        windows = PluginViewWindows(
            environment: environment,
            makeWindow: { [unowned self] _ in
                let window = FakePluginViewWindow()
                levelOneWindows.append(window)
                return window
            },
            makePageWindow: { [unowned self] _ in
                let window = FakePluginViewWindow()
                pageWindows.append(window)
                return window
            },
            pointer: { NSPoint(x: 200, y: 200) }, frontmostApplication: { nil }, report: { _ in }
        )
        let permits: (PluginInterfaceMember) -> Bool = { member in
            PluginInterfaceContracts.host.candidates.contains { $0.members.contains(member) }
        }
        sessions = PluginViewSessions(
            renderer: windows,
            runEvent: { [unowned self] action, delivery, _, started, finish in
                events.append(HeldEvent(event: delivery.event, finish: finish, action: action, delivery: delivery))
                started()
            },
            schedule: { [unowned self] delay, operation in clock.schedule(delay, operation) },
            showFeedback: { _ in },
            permitting: { _ in permits },
            operations: performer
        )
    }

    func action() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("emoji.search"), pluginID: Self.pluginID,
                                command: CommandDeclaration(id: CommandID("emoji.search"), title: "Search Emoji",
                                                            execution: .javascript, script: "emoji.js"),
                                input: .null)
    }

    func open(_ page: JSONValue) throws {
        try sessions.actionAnswered(action(), with: .object(["page": page, "state": .null]))
    }

    /// Answers the event running with `page`, or with nothing.
    func answer(_ page: JSONValue?) throws {
        if let page { finish(.object(["page": page, "state": .null])) } else { finish(.null) }
    }

    func finish(_ value: JSONValue) {
        guard let run = events.last else { return XCTFail("No event is running") }
        run.finish(ActionOutcome(actionID: run.action.id, pluginID: run.action.pluginID, title: run.action.title,
                                 terminal: .succeeded(value)))
    }

    func fail(_ category: ActionFailureCategory) {
        guard let run = events.last else { return XCTFail("No event is running") }
        run.finish(ActionOutcome(actionID: run.action.id, pluginID: run.action.pluginID, title: run.action.title,
                                 terminal: .failed(ActionFailure(pluginID: run.action.pluginID, actionID: run.action.id,
                                                                 category: category, message: category.rawValue))))
    }

    // MARK: Pages

    static func item(_ id: String) -> JSONValue {
        .object(["id": .string(id), "title": .string("item \(id)"), "symbol": .string("★")])
    }

    static func search(query: String = "", items: [String] = ["A", "B", "C", "D"], reset: [String]? = nil,
                       hasMore: Bool = false, insertsItself: Bool = false, showsTarget: Bool = true,
                       copyOnly: Bool = false) -> JSONValue {
        var actions: [JSONValue] = [
            .object(["id": .string("insert"), "title": .string("Insert"), "default": .bool(true)]
                .merging(insertsItself ? ["perform": .string("selection.replace")] : [:]) { $1 }),
            .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write")])
        ]
        if copyOnly { actions.removeFirst() }
        var grid: [String: JSONValue] = ["kind": .string("grid"), "id": .string("results"), "columns": .number(8),
                                         "items": .array(items.map(item)), "actions": .array(actions)]
        if hasMore { grid["has_more"] = .bool(true) }
        var page: [String: JSONValue] = [
            "id": .string("search"), "title": .string("Emoji"),
            "content": .array([
                .object(["kind": .string("row"), "id": .string("bar"), "content": .array([
                    .object(["kind": .string("text_field"), "id": .string("query"), "title": .string("Search"),
                             "value": .string(query), "collection": .string("results")]),
                    .object(["kind": .string("choice_field"), "id": .string("category"), "title": .string("Category"),
                             "choices": .array([.string("all"), .string("animals")]), "value": .string("all")])
                ])]),
                .object(grid)
            ])
        ]
        if showsTarget { page["shows_insertion_target"] = .bool(true) }
        if let reset { page["reset"] = .array(reset.map(JSONValue.string)) }
        return .object(page)
    }

    static func page(_ id: String, _ content: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "title": .string(id), "content": .array(content)])
    }

    static func buttons(_ ids: [String]) -> JSONValue {
        .object(["kind": .string("actions"), "id": .string("buttons"),
                 "actions": .array(ids.map { .object(["id": .string($0), "title": .string($0.capitalized)]) })])
    }
}

/// A clock the test advances by hand.
final class PageClock {
    private var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, operation: () -> Void)] = []
    private var order = 0

    func schedule(_ delay: TimeInterval, _ operation: @escaping () -> Void) {
        order += 1
        pending.append((now + delay, order, operation))
    }

    func advance(by interval: TimeInterval) {
        let end = now + interval
        while let next = pending.filter({ $0.at <= end + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = max(now, next.at)
            next.operation()
        }
        now = end
    }
}

/// Records what the sessions asked to perform and succeeds at once.
final class RecordingPerformer: HostOperationPerformer {
    private(set) var performed: [(operation: RequestedHostOperation, target: InsertionTargetCapture)] = []

    func authorize(_ operation: RequestedHostOperation, for action: ActionConfiguration) throws {}

    func perform(_ operation: RequestedHostOperation, for action: ActionConfiguration, target: InsertionTargetCapture,
                 completion: @escaping (HostOperationResult) -> Void) {
        performed.append((operation, target))
        completion(HostOperationResult(.succeeded))
    }
}
