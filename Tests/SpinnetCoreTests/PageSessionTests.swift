import Foundation
import XCTest
@testable import SpinnetCore

/// View Sessions showing pages (Candidate Contract `collections` r1), driven
/// through the sessions' seams: page answers commit as views do, page events
/// are dispatched only while the page and component they came from are
/// unchanged (scenario 06), Return waits for the typing it follows (C1),
/// and page and item actions naming a Host Service run in the Plugin's
/// operation slot.
final class PageSessionTests: XCTestCase {
    private typealias B = PageBuilder
    private var clock: ManualClock!
    private var renderer: RecordingRenderer!
    private var runner: HeldEventRunner!
    private var performer: HeldPerformer!
    private var sessions: PluginViewSessions!
    private static let pluginID = PluginID("com.example.emoji-pages")

    override func setUp() {
        clock = ManualClock()
        renderer = RecordingRenderer()
        runner = HeldEventRunner()
        performer = HeldPerformer()
        let permits = CollectionsFixtures.permits
        sessions = PluginViewSessions(renderer: renderer, runEvent: runner.run, schedule: clock.schedule,
                                      showFeedback: { _ in }, permitting: { _ in permits }, operations: performer)
    }

    private static func action() throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("emoji.search"), pluginID: pluginID,
                                command: CommandDeclaration(id: CommandID("emoji.search"), title: "Search",
                                                            execution: .javascript, script: "emoji.js"),
                                input: .null)
    }

    private func start(_ page: JSONValue) throws -> PluginViewSession {
        try sessions.actionAnswered(Self.action(), with: .object(["page": page, "state": .number(0)]))
        return try XCTUnwrap(sessions.session(for: Self.pluginID))
    }

    private static func searchPage(items: [String] = ["A", "B", "C"], reset: JSONValue? = nil) -> JSONValue {
        B.pageJSON("search", [B.row([B.field(), B.choice()]), B.grid(items: items)], reset: reset)
    }

    private func answer(_ index: Int, page: JSONValue?, state: JSONValue = .number(1), operation: RequestedHostOperation? = nil) {
        var members: [String: JSONValue] = [:]
        if let page { members["page"] = page; members["state"] = state }
        if let operation { members["operation"] = operation.json }
        runner.runs[index].finish(.succeeded(.object(members)))
    }

    private func typed(_ text: String) -> PluginViewEvent {
        .pageFieldChanged(page: "search", field: "query", values: .object(["query": .string(text), "category": .string("all")]))
    }

    private func itemAction(_ id: String) -> PluginViewEvent {
        .itemAction(page: "search", collection: "results", action: "insert",
                    item: PluginPageItemSnapshot(id: id, section: nil, text: "★"), values: .object([:]))
    }

    func testAPageAnswerStartsASessionThatShowsThePage() throws {
        let session = try start(Self.searchPage())
        XCTAssertEqual(session.page?.id, "search")
        XCTAssertEqual(session.state, .number(0))
        XCTAssertEqual(renderer.presentations.last?.page?.collection?.items.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(renderer.presentations.last?.view, Self.searchPage())

        session.send(itemAction("B"))
        XCTAssertEqual(runner.runs[0].delivery.event?.typeName, "item_action")
        answer(0, page: Self.searchPage(items: ["B"]), state: .number(2))
        XCTAssertEqual(session.page?.collection?.items.map(\.id), ["B"])
        XCTAssertEqual(session.state, .number(2))
        XCTAssertEqual(session.answeredEvent, itemAction("B"))

        session.send(itemAction("B"))
        answer(1, page: B.pageJSON("detail", [B.buttons(["back"])]))
        XCTAssertEqual(session.page?.id, "detail")
        session.send(.pageActionChosen(page: "detail", action: "back", values: .object([:]), selection: .object([:])))
        XCTAssertEqual(runner.runs.count, 3)
        answer(2, page: .null)
        XCTAssertTrue(session.isEnded, "An answer that is no page or view is a protocol violation")
    }

    /// Scenario 06: an event from a page that was replaced is dropped.
    func testAnEventFromAReplacedPageIsDropped() throws {
        let session = try start(Self.searchPage())
        session.send(itemAction("A"))
        session.send(typed("pyt"))
        clock.advance(by: 0.2)
        answer(0, page: B.pageJSON("detail", [B.buttons(["back"])]))
        XCTAssertEqual(runner.runs.count, 1, "The queued typing belonged to the search page")
        session.send(typed("late"))
        clock.advance(by: 0.2)
        XCTAssertEqual(runner.runs.count, 1, "An event naming a page not on screen is dropped at once")
    }

    /// Scenario 06: an event from a component reset since is dropped; an
    /// event from a kept component is not.
    func testAnEventFromAComponentResetSinceIsDropped() throws {
        let session = try start(Self.searchPage())
        session.send(.loadMore(page: "search", collection: "results", loaded: 3))
        session.send(typed("dog"))
        clock.advance(by: 0.2)
        answer(0, page: Self.searchPage(reset: .array([.string("query")])))
        XCTAssertEqual(runner.runs.count, 1, "query was reset after the typing was made")

        session.send(.loadMore(page: "search", collection: "results", loaded: 3))
        session.send(typed("dog"))
        clock.advance(by: 0.2)
        answer(1, page: Self.searchPage(reset: .array([.string("results")])))
        XCTAssertEqual(runner.runs.count, 3, "query was kept, so its typing runs")
        XCTAssertEqual(runner.runs[2].delivery.event, typed("dog"))
    }

    /// Scenario 06: an item action is delivered after its item left the
    /// collection, because it carries its snapshot.
    func testAnItemActionOutlivesItsItem() throws {
        let session = try start(Self.searchPage())
        session.send(typed("cat"))
        clock.advance(by: 0.2)
        session.send(itemAction("C"))
        answer(0, page: Self.searchPage(items: ["A"]))
        XCTAssertEqual(runner.runs.count, 2)
        XCTAssertEqual(runner.runs[1].delivery.event, itemAction("C"))
    }

    /// A kind change under the same ID is a new component.
    func testAnEventFromAComponentOfAnotherKindIsDropped() throws {
        let session = try start(Self.searchPage())
        session.send(typed("x"))
        session.send(.loadMore(page: "search", collection: "results", loaded: 3))
        answer(0, page: B.pageJSON("search", [B.row([B.field(), B.choice()]), B.grid(items: ["A"], kind: "list")]))
        XCTAssertEqual(runner.runs.count, 1, "results is now a list")
    }

    /// C1: Return in the search field sends the typing waiting out its pause
    /// at once, so the default action can follow its answer.
    func testTypingCanBeSentAtOnce() throws {
        let session = try start(Self.searchPage())
        session.send(typed("cat"))
        XCTAssertTrue(session.hasPendingFieldChange)
        XCTAssertEqual(runner.runs.count, 0)
        session.flushFieldChanges()
        XCTAssertEqual(runner.runs.count, 1, "Sent without waiting for the pause")
        XCTAssertTrue(session.hasPendingFieldChange, "Its answer is still to come")
        answer(0, page: Self.searchPage())
        XCTAssertFalse(session.hasPendingFieldChange)
    }

    /// A failed `load_more` is told apart, so the Host can offer Retry.
    func testAFailedEventNamesItself() throws {
        let session = try start(Self.searchPage())
        let more = PluginViewEvent.loadMore(page: "search", collection: "results", loaded: 3)
        session.send(more)
        XCTAssertTrue(session.isPending { $0 == more })
        runner.runs[0].finish(.failed(ActionFailure(pluginID: Self.pluginID, actionID: ActionID("e"),
                                                    category: .scriptedActionFailed, message: "boom")))
        XCTAssertFalse(session.isPending { $0 == more })
        XCTAssertEqual(session.errorEvent, more)
        XCTAssertEqual(renderer.presentations.last?.error?.message, "boom")
        XCTAssertEqual(session.page?.id, "search", "A failure keeps the page")
    }

    /// Only a gesture's answer may request an operation: `item_action` is
    /// one, `load_more` and typing are not.
    func testItemActionsAreGesturesAndLoadMoreIsNot() throws {
        let insert = RequestedHostOperation(perform: "selection.replace", input: .string("★"), closesView: true)
        let session = try start(Self.searchPage())
        session.send(itemAction("A"), insertionTarget: .shown(app: nil, focus: nil))
        answer(0, page: nil, operation: insert)
        XCTAssertEqual(performer.performed.map(\.operation), [insert])
        XCTAssertEqual(performer.performed.first?.target, .shown(app: nil, focus: nil))

        setUp()
        let other = try start(Self.searchPage())
        other.send(.loadMore(page: "search", collection: "results", loaded: 3))
        answer(0, page: nil, operation: insert)
        XCTAssertTrue(other.isEnded)
    }

    /// Page and item actions naming a Host Service run without a View Event
    /// in the operation slot, with the target shown when the user acted; a
    /// refusal shows in the page.
    func testHostPerformedActionsRunInTheOperationSlot() throws {
        let session = try start(Self.searchPage())
        let copy = RequestedHostOperation(perform: "clipboard.write", input: .object(["text": .string("★")]), id: "copy")
        session.perform(copy, insertionTarget: .notShown)
        XCTAssertEqual(runner.runs.count, 0, "No View Event")
        XCTAssertEqual(performer.performed.map(\.operation), [copy])
        session.send(itemAction("A"))
        XCTAssertEqual(runner.runs.count, 0, "A gesture waits behind the outstanding operation")
        performer.finish(0, .succeeded)
        XCTAssertEqual(runner.runs.count, 1)
        XCTAssertFalse(session.isEnded)

        performer.refusal = .capabilityDenied(.writeClipboard)
        session.perform(copy, insertionTarget: .notShown)
        XCTAssertEqual(renderer.presentations.last?.error?.category, .capabilityDenied)
        XCTAssertNil(session.errorEvent)
    }

    /// A Level 1 view answer replaces a page, and back: the session tells
    /// the renderer which it shows.
    func testALevelOneViewAndAPageMayFollowEachOther() throws {
        let session = try start(Self.searchPage())
        session.send(itemAction("A"))
        let view = JSONValue.object(["title": .string("Level 1"), "actions": .array([.object(["id": .string("a"), "title": .string("A")])])])
        runner.runs[0].finish(.succeeded(.object(["view": view])))
        XCTAssertNil(session.page)
        XCTAssertNil(renderer.presentations.last?.page)
        XCTAssertEqual(renderer.presentations.last?.view, view)
        session.send(.actionChosen("a"))
        answer(1, page: Self.searchPage())
        XCTAssertEqual(session.page?.id, "search")
    }
}
