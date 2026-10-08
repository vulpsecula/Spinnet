import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Pages of a Level 2 Plugin, drawn by
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

    // MARK: Windows

    /// A session may go from a page to a Level 1 view and back: each gets its
    /// own window, and the pin is kept.
    func testPagesAndLevelOneViewsSwapWindowsKeepingThePin() throws {
        try harness.open(PageHarness.search())
        model.isPinned = true
        let placed = PluginPanelGeometry(frame: NSRect(x: 30, y: 40, width: 640, height: 480), isUserSized: true)
        harness.pageWindows.first?.userChangedGeometry(to: placed)
        model.returnPressedInCollection()
        harness.finish(.object(["view": .object(["title": .string("Level 1"),
                                                  "actions": .array([.object(["id": .string("a"), "title": .string("A")])])])]))
        XCTAssertNil(harness.windows.pageModel(for: PageHarness.pluginID))
        let level1 = try XCTUnwrap(harness.windows.model(for: PageHarness.pluginID))
        XCTAssertTrue(level1.isPinned)
        XCTAssertEqual(harness.pageWindows.first?.closes, 1)
        XCTAssertEqual(harness.levelOneWindows.first?.restored, [placed], "The pinned panel keeps its place and size")
        level1.choose(try XCTUnwrap(level1.description.actions.first))
        try harness.answer(PageHarness.search())
        XCTAssertTrue(model.isPinned)
        XCTAssertEqual(harness.pageWindows.count, 2)
        XCTAssertEqual(harness.levelOneWindows.first?.closes, 1)
    }

    /// Pin means the user keeps the panel beside their App: an item
    /// action's `closes_view` and a requested operation's leave a pinned
    /// page open, and close it once it is unpinned.
    func testClosesViewLeavesAPinnedPageOpen() throws {
        try harness.open(PageHarness.search(insertsItself: true, closesView: true))
        model.isPinned = true
        model.returnPressedInCollection()
        XCTAssertEqual(harness.performer.performed.last?.operation.perform, "selection.replace")
        XCTAssertNotNil(harness.windows.pageModel(for: PageHarness.pluginID), "The pinned page stays after inserting")
        XCTAssertEqual(harness.pageWindows.last?.closes, 0)
        _ = model.copySelection()
        XCTAssertEqual(harness.performer.performed.last?.operation.perform, "clipboard.write")
        XCTAssertNotNil(harness.sessions.session(for: PageHarness.pluginID))

        model.isPinned = false
        _ = model.copySelection()
        XCTAssertNil(harness.sessions.session(for: PageHarness.pluginID), "Unpinned, closes_view closes it")
        XCTAssertEqual(harness.pageWindows.last?.closes, 1)
    }

    func testARequestedOperationThatClosesTheViewLeavesAPinnedPageOpen() throws {
        try harness.open(PageHarness.search())
        model.isPinned = true
        model.returnPressedInCollection()
        harness.finish(.object(["operation": RequestedHostOperation(perform: "selection.replace", input: .string("★"),
                                                                   closesView: true).json]))
        XCTAssertEqual(harness.performer.performed.map(\.operation.perform), ["selection.replace"])
        XCTAssertNotNil(harness.sessions.session(for: PageHarness.pluginID))
        XCTAssertEqual(harness.pageWindows.last?.closes, 0)
    }

    /// The Plugin's `{close: true}` and the user's own close still close a
    /// pinned page.
    func testAnExplicitCloseOrTheUsersCloseClosesAPinnedPage() throws {
        try harness.open(PageHarness.search())
        model.isPinned = true
        model.returnPressedInCollection()
        harness.finish(.object(["close": .bool(true)]))
        XCTAssertNil(harness.sessions.session(for: PageHarness.pluginID), "The Plugin closed it")

        try harness.open(PageHarness.search())
        model.isPinned = true
        harness.pageWindows.last?.onUserClose?()
        XCTAssertNil(harness.sessions.session(for: PageHarness.pluginID), "The user closed it")
    }

    func testAnUnpinnedPageClosesWhenItLosesFocus() throws {
        try harness.open(PageHarness.search())
        harness.pageWindows.last?.onResignKey?()
        XCTAssertNil(harness.windows.pageModel(for: PageHarness.pluginID))
        XCTAssertTrue(harness.sessions.session(for: PageHarness.pluginID) == nil)
    }
}

// MARK: - Windows, toggles and outcomes (collections r3)

final class PluginPageWindowModelTests: XCTestCase {
    private var harness: PageHarness!

    override func setUp() {
        harness = try! PageHarness()
    }

    private var model: PluginPageModel { harness.windows.pageModel(for: PageHarness.pluginID)! }

    /// The Host holds the first screens of a window and draws placeholders
    /// for the rest; End selects the last position, asks for its range,
    /// and selects the item that comes, which Return then acts on.
    func testEndAsksForItsRangeAndSelectsItsItemWhenItComes() throws {
        try harness.open(PageHarness.windowed())
        XCTAssertEqual(model.window?.total, 1906)
        XCTAssertEqual(model.window?.heldCount, 144)
        XCTAssertNotNil(model.item(at: 143))
        XCTAssertNil(model.item(at: 144), "A placeholder")
        XCTAssertTrue(harness.events.isEmpty)

        XCTAssertTrue(model.moveSelection(.end))
        XCTAssertEqual(model.selectedPosition, 1905)
        XCTAssertNil(model.selectedItem)
        XCTAssertEqual(model.scrollRequest?.position, 1905)
        guard case .loadRange("search", "results", let start, let count)? = harness.events.last?.event else {
            return XCTFail("End asked for nothing: \(harness.events.map(\.event))")
        }
        XCTAssertEqual(start + count, 1906)
        model.returnPressedInCollection()
        XCTAssertEqual(harness.events.count, 1, "Return waits for nothing and does nothing on a placeholder")

        try harness.answerRanges()
        XCTAssertEqual(model.selectedItem, "i1905")
        XCTAssertNil(model.item(at: 0), "The first screens were let go")
        model.returnPressedInCollection()
        guard case .itemAction(_, _, "insert", let item, _)? = harness.events.last?.event else { return XCTFail("No insert") }
        XCTAssertEqual(item.id, "i1905")
    }

    /// At most one `load_range` runs per collection: a newer screen waits
    /// for its answer, and is asked for when it comes.
    func testOneRangeAtATime() throws {
        try harness.open(PageHarness.windowed())
        model.viewportChanged(1000..<1048)
        XCTAssertEqual(harness.events.count, 1)
        model.viewportChanged(1500..<1548)
        model.viewportChanged(1600..<1648)
        XCTAssertEqual(harness.events.count, 1, "The first is still running")
        try harness.answer(PageHarness.windowed(start: 904, count: 240))
        XCTAssertEqual(harness.events.count, 2, "The screen the user is on now is asked for")
        guard case .loadRange(_, _, let start, let count)? = harness.events.last?.event else { return XCTFail("No range") }
        XCTAssertTrue((start..<start + count).contains(1600))
        try harness.answerRanges()
        XCTAssertNotNil(model.item(at: 1600))
        XCTAssertLessThanOrEqual(model.window?.heldCount ?? 0, CollectionsContract.maximumWindowItems)
    }

    /// A range that does not come is not asked for again until the user
    /// moves onto it; a failed one shows inline.
    func testARangeThatFailsIsNotAskedForAgainByScrolling() throws {
        try harness.open(PageHarness.windowed())
        model.viewportChanged(1000..<1048)
        harness.fail(.scriptedActionFailed)
        XCTAssertEqual(model.error?.category, .scriptedActionFailed)
        model.viewportChanged(1008..<1056)
        XCTAssertEqual(harness.events.count, 1)
        model.click(at: 1010)
        XCTAssertEqual(harness.events.count, 2, "Moving onto it asks again")
    }

    /// A toggle item action is checked in the menu of an item carrying its
    /// mark, and VoiceOver says so; choosing it sends the marks as shown.
    func testAToggleIsCheckedForAMarkedItem() throws {
        try harness.open(PageHarness.windowed(marked: [1]))
        XCTAssertEqual(model.menu(of: "i1").map(\.isChecked), [false, false, true])
        XCTAssertEqual(model.menu(of: "i0").map(\.isChecked), [false, false, false])
        XCTAssertEqual(model.accessibilityActions(of: "i1"), ["Insert", "Copy", "Favourite, checked"])
        XCTAssertEqual(model.accessibilityActions(of: "i0"), ["Insert", "Copy", "Favourite, not checked"])
        model.choose(try XCTUnwrap(model.menu(of: "i1").last).action, on: "i1")
        guard case .itemAction(_, _, "favourite", let item, _)? = harness.events.last?.event else { return XCTFail("No toggle") }
        XCTAssertEqual(item.marks, ["favourite"])
        XCTAssertEqual(model.selectedItem, "i1", "The menu's item is selected")
    }

    /// ⌘C performs Copy, which asked to notify: its outcome reaches the
    /// Plugin with the item, in the view.
    func testCopyWithNotifyIsHeard() throws {
        try harness.open(PageHarness.windowed())
        XCTAssertTrue(model.copySelection())
        let copy = try XCTUnwrap(harness.performer.performed.last?.operation)
        XCTAssertEqual(copy.item, PluginPageItemSnapshot(id: "i0", section: nil, text: "★"))
        XCTAssertEqual(harness.events.last?.event, .operationFinished(id: "copy", perform: "clipboard.write",
                                                                      outcome: .succeeded, item: copy.item))
    }

    /// An answer to another event with the same layout keeps what it does
    /// not give on screen and asks for it again; one with another total
    /// keeps the item the user looks at in place.
    func testAnswersToOtherEventsRefreshTheScreen() throws {
        try harness.open(PageHarness.windowed())
        model.viewportChanged(1000..<1048)
        try harness.answerRanges()
        model.click(at: 1001)
        model.choose(try XCTUnwrap(model.menu(of: "i1001").last).action, on: "i1001")
        try harness.answer(PageHarness.windowed(marked: [1001]))
        XCTAssertEqual(model.item(at: 1001)?.marks, [], "Still shown until it comes again")
        guard case .loadRange(_, _, let start, let count)? = harness.events.last?.event else {
            return XCTFail("The screen was not asked for again")
        }
        XCTAssertTrue((start..<start + count).contains(1001))
        try harness.answerRanges(marked: [1001])
        XCTAssertEqual(model.item(at: 1001)?.marks, ["favourite"])
        XCTAssertEqual(model.selectedItem, "i1001")
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
    /// The events `answerRanges` answered, by index.
    private var answeredEvents: Set<Int> = []
    private(set) var pageWindows: [FakePluginViewWindow] = []
    private(set) var levelOneWindows: [FakePluginViewWindow] = []
    private(set) var windows: PluginViewWindows!
    private(set) var sessions: PluginViewSessions!

    init(images: PluginPageImageProvider? = nil) throws {
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
            schedule: { _, _ in }, report: { _ in }, insertionTargets: tracker, images: images
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
        let permits: (PluginInterfaceMember) -> Bool = { PluginInterfaceContracts.levelTwoMembers.contains($0) }
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
                       insertsItself: Bool = false, showsTarget: Bool = true,
                       copyOnly: Bool = false, closesView: Bool = false) -> JSONValue {
        let closes: [String: JSONValue] = closesView ? ["closes_view": .bool(true)] : [:]
        var actions: [JSONValue] = [
            .object(["id": .string("insert"), "title": .string("Insert"), "default": .bool(true)]
                .merging(insertsItself ? ["perform": .string("selection.replace")].merging(closes) { $1 } : [:]) { $1 }),
            .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write")]
                .merging(closes) { $1 })
        ]
        if copyOnly { actions.removeFirst() }
        let grid: [String: JSONValue] = ["kind": .string("grid"), "id": .string("results"), "columns": .number(8),
                                         "items": .array(items.map(item)), "actions": .array(actions)]
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

    /// The Emoji search page under `collections` r3: a grid of `total`
    /// items `i0`… of which the answer gives `start..<start + count`, with
    /// Insert, Copy (which asks to hear its outcome) and a Favourite toggle,
    /// the items in `marked` carrying its mark.
    static func windowed(total: Int = 1906, start: Int = 0, count: Int = 200, marked: Set<Int> = [],
                         sections: [(String, Int)]? = nil, reset: [String]? = nil) -> JSONValue {
        guard case .object(var page) = search(reset: reset), case .array(var content) = page["content"],
              case .object(var grid) = content[1] else { return .null }
        let end = min(start + count, total)
        grid["items"] = .array((start..<end).map { index in
            var item: [String: JSONValue] = ["id": .string("i\(index)"), "title": .string("item \(index)"),
                                             "symbol": .string("★")]
            if marked.contains(index) { item["marks"] = .array([.string("favourite")]) }
            return .object(item)
        })
        grid["total"] = .number(Double(total))
        grid["start"] = .number(Double(start))
        if let sections {
            grid["sections"] = .array(sections.map { .object(["id": .string($0.0), "title": .string($0.0),
                                                              "count": .number(Double($0.1))]) })
        }
        grid["actions"] = .array([
            .object(["id": .string("insert"), "title": .string("Insert"), "default": .bool(true)]),
            .object(["id": .string("copy"), "title": .string("Copy"), "perform": .string("clipboard.write"),
                     "notify": .bool(true)]),
            .object(["id": .string("favourite"), "title": .string("Favourite"), "toggle": .string("favourite")])
        ])
        content[1] = .object(grid)
        page["content"] = .array(content)
        return .object(page)
    }

    /// Answers every `load_range` waiting, as a Plugin with `total` items
    /// would, until none is left; returns how many it answered.
    @discardableResult
    func answerRanges(total: Int = 1906, marked: Set<Int> = [], sections: [(String, Int)]? = nil,
                      page: (Int, Int) -> JSONValue? = { _, _ in nil }) throws -> Int {
        var answered = 0
        while let last = events.last, !answeredEvents.contains(events.count - 1),
              case .loadRange(_, _, let start, let count)? = last.event {
            answeredEvents.insert(events.count - 1)
            try answer(page(start, count) ?? Self.windowed(total: total, start: start, count: count, marked: marked,
                                                           sections: sections))
            answered += 1
        }
        return answered
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
                 accepted: AcceptedHostOperationTarget, completion: @escaping (HostOperationResult) -> Void) {
        performed.append((operation, target))
        completion(HostOperationResult(.succeeded))
    }
}
