import Foundation
import XCTest
@testable import SpinnetCore

/// Candidate Contract `collections` r3, published under
/// `PluginAPI/candidates/collections/r3/`: revision 1's checks where they
/// still hold, and what revision 3 changes: `load_range` and windows in place
/// of `load_more`, toggle item actions and marks, and outcomes of the page
/// and item actions the Host performs.
final class CollectionsRevisionThreeContractTests: CollectionsContractTests {
    override class var revision: Int { 3 }
    override class var candidate: CandidateContract { CollectionsContract.candidate }

    /// Revision 3 is revision 2 without `load_more`, with `load_range` and
    /// three behaviours, requiring `host_operations` r2; the Host still
    /// provides revisions 1 and 2.
    func testRevisionThreeIsRevisionTwoWithWindowsTogglesAndOutcomes() throws {
        let two = CollectionsContract.revisionTwo, three = CollectionsContract.candidate
        XCTAssertEqual(three.revision, 3)
        XCTAssertEqual(Set(three.members).subtracting(two.members), [
            CollectionsContract.collectionWindow, CollectionsContract.toggleItemActions,
            CollectionsContract.performedActionOutcomes, CollectionsContract.loadRange
        ])
        XCTAssertEqual(Set(two.members).subtracting(three.members), [CollectionsContract.loadMore])
        XCTAssertEqual(three.requires, [HostOperationsContract.revisionTwoDeclaration, HostServiceCatalogue.declaration])
        let host = PluginInterfaceContracts.host
        XCTAssertTrue([CollectionsContract.revisionOne, two, three].allSatisfy(host.candidates.contains))
    }

    /// Every event revision 3's Host sends follows its schema: `load_range`
    /// instead of `load_more`, snapshots with marks, and `operation_finished`
    /// naming an item, after the view closed too.
    override func testEveryEventTheHostSendsFollowsTheSchema() throws {
        let validator = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        let item = PluginPageItemSnapshot(id: "1F408", section: "animals-nature", text: "🐈", marks: ["favourite"])
        let events: [PluginViewEvent] = [
            .pageFieldChanged(page: "search", field: "query", values: .object(["query": .string("cat")])),
            .itemAction(page: "search", collection: "results", action: "favourite", item: item, values: .object([:])),
            .loadRange(page: "search", collection: "results", start: 400, count: 240),
            .called,
            .operationFinished(id: "copy", perform: "clipboard.write", outcome: .succeeded, item: item),
            .operationFinished(id: "insert", perform: "selection.replace", outcome: .refused(.targetChanged),
                               viewClosed: true, item: item),
            .operationFinished(id: nil, perform: "open.url", outcome: .failed(.hostServiceFailed))
        ]
        for event in events { XCTAssertEqual(validator.errors(for: event.json), [], "\(event)") }
        XCTAssertFalse(validator.errors(for: PluginViewEvent.loadMore(page: "p", collection: "c", loaded: 3).json).isEmpty,
                       "Revision 3 asks for ranges, never for more")
        let range = PluginViewEvent.loadRange(page: "p", collection: "c", start: 0, count: 10)
        XCTAssertFalse(range.isGesture)
        XCTAssertFalse(range.coalesces)
        XCTAssertEqual(range.pageOrigin?.component, "c")
        XCTAssertEqual(item.json, .object(["id": .string("1F408"), "section": .string("animals-nature"),
                                           "text": .string("🐈"), "marks": .array([.string("favourite")])]))
    }

    /// A performed page action may ask to notify in revision 3.
    override func testPageActionsNameTheirHostServiceByCatalogueID() throws {
        let answer = try PluginScriptAnswer(parsing: value("answers/page-action-notify.json"), permits: permits)
        guard case .actions(_, let actions)? = answer.page?.components.first,
              case .perform(let operation)? = actions.first?.kind else { return XCTFail("No page action") }
        XCTAssertEqual(operation, RequestedHostOperation(perform: "clipboard.write", input: .string("🐈"), id: "copy",
                                                         notify: true))
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: value("answers/page-action-notify.json"),
                                                    permits: CollectionsFixtures.revisionTwo)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("A page action has unknown member notify"))
        }
    }

    /// What revision 3's page rules refuse, by the message the author reads.
    func testRevisionThreesRulesNameWhatIsWrong() throws {
        let expected: [String: String] = [
            "answers/has-more-gone.json": "unknown member has_more",
            "answers/start-without-total.json": "gives a start without a total",
            "answers/items-past-total.json": "gives items past its total of 3",
            "answers/total-over-2000.json": "total is not a whole number from 0 to 2000",
            "answers/section-counts-not-total.json": "sections count 2 items, not its total of 5",
            "answers/windowed-section-with-items.json": "unknown member items",
            "answers/section-header-without-total.json": "unknown member count",
            "answers/mark-without-toggle.json": "which no toggle item action of its collection names",
            "answers/toggle-with-perform.json": "toggles a mark, which only the Plugin can do",
            "answers/notify-on-event-item-action.json": "delivers an event, so it has no notify",
            "answers/two-toggles-same-mark.json": "two item actions toggling the mark favourite"
        ]
        for (file, words) in expected {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: value(file), permits: permits), file) {
                guard case .protocolViolation(let message)? = $0 as? PluginRuntimeError else {
                    return XCTFail("\(file): \($0)")
                }
                XCTAssertTrue(message.contains(words), "\(file): \(message)")
            }
        }
        // `has_more` has its meaning only where `load_more` exists.
        XCTAssertNoThrow(try PluginScriptAnswer(parsing: value("answers/has-more-gone.json"),
                                                permits: CollectionsFixtures.revisionTwo))
    }

    /// The Host reads a window as positions: the total, the slice from
    /// `start`, and sections as headers; toggles and marks; notify on a
    /// performed item action, whose operation carries the item.
    func testAWindowIsReadAsPositions() throws {
        let open = try XCTUnwrap(try PluginScriptAnswer(parsing: value("answers/emoji-open.json"), permits: permits).page)
        let grid = try XCTUnwrap(open.collection)
        XCTAssertTrue(grid.isWindowed)
        XCTAssertEqual(grid.total, grid.sections.map(\.count).reduce(0, +))
        XCTAssertEqual(grid.start, 0)
        XCTAssertEqual(grid.sections.first?.start, 0)
        let range = try XCTUnwrap(try PluginScriptAnswer(parsing: value("answers/emoji-smile-load-range.json"),
                                                         permits: permits).page?.collection)
        XCTAssertEqual(range.slice, 10..<range.total)
        XCTAssertEqual(range.item(at: 10)?.id, range.items.first?.id)
        XCTAssertNil(range.item(at: 9))

        let favourites = try XCTUnwrap(try PluginScriptAnswer(parsing: value("answers/emoji-favourites-toggle.json"),
                                                              permits: permits).page?.collection)
        let cat = try XCTUnwrap(favourites.items.first)
        let toggle = try XCTUnwrap(favourites.actions.first { $0.toggle == "favourite" })
        XCTAssertTrue(toggle.isChecked(for: cat))
        XCTAssertFalse(toggle.isChecked(for: try XCTUnwrap(favourites.items.last)))
        XCTAssertNil(toggle.perform)
        let copy = try XCTUnwrap(favourites.copyAction)
        XCTAssertTrue(copy.notify)
        let snapshot = favourites.snapshot(of: cat)
        XCTAssertEqual(snapshot.marks, ["favourite"])
        XCTAssertEqual(copy.operation(on: cat, snapshot: snapshot)?.item, snapshot)
        XCTAssertEqual(copy.operation(on: cat, snapshot: snapshot)?.json, .object([
            "perform": .string("clipboard.write"), "input": .object(["text": .string("🐈")]), "id": .string("copy"),
            "notify": .bool(true)
        ]), "The item never travels in the request")
    }

    /// The types, reference and revision 3's own SDK name every member.
    override func testTheTypesReferenceAndSDKNameEveryMember() throws {
        let types = try String(contentsOf: Self.published.appendingPathComponent("collections.d.ts"), encoding: .utf8)
        let reference = try String(contentsOf: Self.published.appendingPathComponent("reference.md"), encoding: .utf8)
        let sdk = try String(contentsOf: Self.published.appendingPathComponent("collections-r3.js"), encoding: .utf8)
        for id in CollectionsContract.viewActionIDs {
            XCTAssertTrue(types.contains("\"\(id)\""), "collections.d.ts does not list \(id)")
            XCTAssertTrue(reference.contains("`\(id)`"), "reference.md does not name \(id)")
            let parts = id.split(separator: ".")
            XCTAssertTrue(sdk.contains("\(parts[0]): [") && sdk.contains("\"\(parts[1])\""), "collections-r3.js has no \(id)")
        }
        for kind in CollectionsContract.componentKinds {
            XCTAssertTrue(types.contains("kind: \"\(kind)\""), "collections.d.ts has no \(kind)")
            XCTAssertTrue(reference.contains("`\(kind)`"), "reference.md does not name \(kind)")
        }
        for event in ["item_action", "load_range", "called"] {
            XCTAssertTrue(types.contains("type: \"\(event)\""), "collections.d.ts has no \(event)")
            XCTAssertTrue(reference.contains("`\(event)`"), "reference.md does not name \(event)")
        }
        XCTAssertFalse(types.contains("load_more\";"), "No load_more event")
        for member in ["collection_window", "toggle_item_actions", "performed_action_outcomes", "repeated_calls_into_session"] {
            XCTAssertTrue(try String(contentsOf: Self.published.appendingPathComponent("candidate.json"), encoding: .utf8)
                .contains("\"\(member)\""), member)
        }
        for word in ["total", "start", "marks", "toggle", "notify", "count"] {
            XCTAssertTrue(sdk.contains("\(word): o.\(word)"), "collections-r3.js does not build \(word)")
            XCTAssertTrue(types.contains("\(word)?:") || types.contains("\(word):"), "collections.d.ts has no \(word)")
            XCTAssertTrue(reference.contains("`\(word)"), "reference.md does not name \(word)")
        }
        XCTAssertFalse(sdk.contains("has_more"), "The builders drop hasMore")
        // Revisions 1 and 2 keep revision 1's SDK, unchanged.
        let one = try String(contentsOf: Self.pluginAPI.appendingPathComponent("candidates/collections/r1/collections.js"),
                             encoding: .utf8)
        XCTAssertTrue(one.contains("has_more: o.hasMore"))
        XCTAssertFalse(one.contains("notify"))
    }
}
