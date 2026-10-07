import Foundation
import XCTest
@testable import SpinnetCore

/// `Tests/Fixtures/EmojiPages.spinnetplugin` and `BrewPages.spinnetplugin`
/// are external Plugins declaring Plugin API Level 2: an Emoji-shaped grid
/// and a Brew-shaped list with a detail page.
enum CollectionsFixtures {
    static let emoji = NamespacesProbeFixture.fixtures.appendingPathComponent("EmojiPages.spinnetplugin", isDirectory: true)
    static let brew = NamespacesProbeFixture.fixtures.appendingPathComponent("BrewPages.spinnetplugin", isDirectory: true)

    static let emojiID = PluginID("com.example.emoji-pages")

    static func manifest(_ package: URL = emoji) throws -> PluginManifest {
        try PluginManifestLoader.load(packageAt: package).manifest
    }

    /// What a Level 2 Plugin may use.
    static var permits: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.host.permitting(try! manifest())
    }

    /// What a Level 1 Plugin may use.
    static var levelOne: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.host.permitting(try! PluginManifestLoader.load(
            packageAt: OperationsProbeFixture.write(OperationsProbeFixture.levelOne)
        ).manifest)
    }
}

/// Pages and collections as Plugin API Level 2 publishes them, in
/// `schemas/pages.schema.json`, `fixtures/pages/`, `spinnet-level-2.d.ts`
/// and `reference/pages.md`, and as the Host reads them: the answers and
/// events the fixtures hold, the page rules beyond the schema, windows,
/// toggles and outcomes, and Level 1 left as it was.
final class PagesContractTests: XCTestCase {
    static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    private static let schema = pluginAPI.appendingPathComponent("schemas/pages.schema.json")
    private static let published = pluginAPI.appendingPathComponent("fixtures/pages")

    private struct Fixture: Decodable {
        let file: String
        let definition: String
        let valid: Bool
        let note: String
        let level1: Bool?
    }

    private func fixtures() throws -> [Fixture] {
        struct Index: Decodable { let fixtures: [Fixture] }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.published.appendingPathComponent("index.json")))
            .fixtures
    }

    private func value(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.published.appendingPathComponent(file)))
    }

    private var permits: (PluginInterfaceMember) -> Bool { CollectionsFixtures.permits }

    /// The fixtures the schema alone can judge follow it; the ones it cannot
    /// (the page rules) are left to the Host, below.
    func testThePublishedFixturesFollowTheSchemaWhereItCanTell() throws {
        let all = try fixtures()
        XCTAssertGreaterThan(all.count, 40)
        for fixture in all {
            let validator = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: Self.schema)
            let errors = validator.errors(for: try value(fixture.file))
            if fixture.valid { XCTAssertEqual(errors, [], "\(fixture.file): \(fixture.note)") }
        }
    }

    /// The Host accepts exactly the valid answers and refuses every invalid
    /// one as a protocol violation, reading each as it reads a Level 2
    /// Plugin's answer: its page, page rules included, or its Level 1 view.
    func testTheHostReadsThePublishedAnswersAsTheFixturesSay() throws {
        for fixture in try fixtures() where fixture.definition == "answer" {
            do {
                let read = try PluginScriptAnswer(parsing: value(fixture.file), permits: permits)
                if let view = read.view {
                    _ = try PluginViewDescription(parsing: view, settingsFields: [], permits: permits)
                }
                XCTAssertTrue(fixture.valid, "\(fixture.file) was accepted: \(fixture.note)")
            } catch {
                XCTAssertFalse(fixture.valid, "\(fixture.file) was refused: \(error)")
                XCTAssertEqual((error as? PluginRuntimeError)?.failureCategory, .runtimeProtocolFailed, fixture.file)
            }
        }
    }

    /// Every event the Host sends a page follows the schema: snapshots with
    /// marks, `load_range`, `called`, and `operation_finished` naming an
    /// item, after the view closed too.
    func testEveryEventTheHostSendsFollowsTheSchema() throws {
        let validator = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        let item = PluginPageItemSnapshot(id: "1F408", section: "animals-nature", text: "🐈", marks: ["favourite"])
        let events: [PluginViewEvent] = [
            .pageFieldChanged(page: "search", field: "query", values: .object(["query": .string("cat")])),
            .pageSubmitted(page: "p", field: "q", values: .object([:]), selection: .object(["results": .null])),
            .pageActionChosen(page: "p", action: "back", values: .object([:]), selection: .object([:])),
            .itemAction(page: "search", collection: "results", action: "favourite", item: item, values: .object([:])),
            .itemAction(page: "search", collection: "results", action: "insert",
                        item: PluginPageItemSnapshot(id: "x", section: nil, text: "x"), values: .object([:])),
            .loadRange(page: "search", collection: "results", start: 400, count: 240),
            .called,
            .operationFinished(id: "copy", perform: "clipboard.write", outcome: .succeeded, item: item),
            .operationFinished(id: "insert", perform: "selection.replace", outcome: .refused(.targetChanged),
                               viewClosed: true, item: item),
            .operationFinished(id: nil, perform: "open.url", outcome: .failed(.hostServiceFailed))
        ]
        for event in events { XCTAssertEqual(validator.errors(for: event.json), [], "\(event)") }
        XCTAssertEqual(events.map(\.isGesture), [false, true, true, true, true, false, true, false, false, false])
        XCTAssertEqual(events.map(\.coalesces), [true, false, false, false, false, false, false, false, false, false])
        XCTAssertNil(PluginViewEvent.called.pageOrigin, "No page change drops a call")
        XCTAssertEqual(PluginViewEvent.loadRange(page: "p", collection: "c", start: 0, count: 10).pageOrigin?.component, "c")
        XCTAssertEqual(PluginPageItemSnapshot(id: "x", section: nil, text: "x").json, .object(["id": .string("x")]),
                       "The text travels only where it differs from the ID")
        XCTAssertEqual(item.json, .object(["id": .string("1F408"), "section": .string("animals-nature"),
                                           "text": .string("🐈"), "marks": .array([.string("favourite")])]))
    }

    /// Level 1 is unchanged: its published schemas refuse what pages add,
    /// and to a Level 1 Plugin `page` is unknown.
    func testLevelOneRefusesWhatPagesAdd() throws {
        let session = Self.pluginAPI.appendingPathComponent("schemas/view-session.schema.json")
        for fixture in try fixtures() {
            guard let level1 = fixture.level1 else { continue }
            let errors = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: session)
                .errors(for: try value(fixture.file))
            XCTAssertEqual(errors.isEmpty, level1, "\(fixture.file): Level 1 \(level1 ? "accepts" : "refuses") it")
        }
        let page = try value("answers/emoji-search-cat.json")
        for permits in [CollectionsFixtures.levelOne, { _ in false }] {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: page, permits: permits)) {
                XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("The script's answer has unknown member page"))
            }
        }
    }

    /// What the page rules refuse, by the message the Plugin's author reads.
    func testThePageRulesNameWhatIsWrong() throws {
        let expected: [String: String] = [
            "answers/two-collections.json": "has more than one collection",
            "answers/duplicate-component-id.json": "has two components with the ID",
            "answers/duplicate-item-id.json": "has two items with the ID",
            "answers/two-default-actions.json": "has more than one default item action",
            "answers/field-searches-missing-collection.json": "which is not the page's collection",
            "answers/item-offers-undeclared-action.json": "which its collection does not declare",
            "answers/reset-unknown-id.json": "reset names",
            "answers/focus-unknown-id.json": "focus names",
            "answers/selected-unknown-item.json": "which is not one of its items",
            "answers/item-action-shortcut.json": "unknown member shortcut",
            "answers/page-action-shortcut.json": "unknown member shortcut",
            "answers/page-and-view.json": "describes both a view and a page",
            "answers/row-holds-grid.json": "A row holds no grid",
            "answers/unknown-kind.json": "kind must be one of",
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
    }

    func testAPageIsReadAsTheHostDrawsIt() throws {
        let answer = try PluginScriptAnswer(parsing: value("answers/emoji-open.json"), permits: permits)
        let page = try XCTUnwrap(answer.page)
        XCTAssertNil(answer.view)
        XCTAssertEqual(answer.description, answer.pageJSON)
        XCTAssertEqual(page.id, "search")
        XCTAssertTrue(page.drawsInsertionTarget)
        XCTAssertEqual(page.components.map(\.kind), [.row, .textField, .choiceField, .grid])
        let grid = try XCTUnwrap(page.collection)
        XCTAssertEqual(grid.style, .grid)
        XCTAssertEqual(grid.columns, 8)
        XCTAssertEqual(grid.defaultAction?.id, "insert")
        XCTAssertEqual(grid.copyAction?.id, "copy")
        let first = try XCTUnwrap(grid.items.first)
        XCTAssertEqual(grid.actions(of: first).map(\.title), ["Insert", "Copy"])

        let brew = try XCTUnwrap(try PluginScriptAnswer(parsing: value("answers/brew-list.json"), permits: permits).page)
        let list = try XCTUnwrap(brew.collection)
        XCTAssertEqual(list.style, .list)
        XCTAssertFalse(brew.drawsInsertionTarget, "A page that cannot insert shows no target line")
        for item in list.items {
            XCTAssertEqual(list.actions(of: item).first?.isDefault, true, "The default comes first in \(item.id)'s menu")
        }
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

    /// A page action takes what a request of its ID takes, may ask to
    /// notify, and is held to the IDs offered as page actions.
    func testPageActionsNameTheirHostServiceByCatalogueID() throws {
        func page(_ action: JSONValue) -> JSONValue {
            .object(["page": .object(["id": .string("p"), "title": .string("P"), "content": .array([
                .object(["kind": .string("actions"), "id": .string("buttons"), "actions": .array([action])])
            ])])])
        }
        let open = try PluginScriptAnswer(parsing: page(.object(["perform": .string("open.url"),
                                                                 "input": .string("https://brew.sh")])), permits: permits)
        guard case .actions(_, let actions)? = open.page?.components.first else { return XCTFail("No actions") }
        XCTAssertEqual(actions.first?.title, "Open in Browser", "The catalogue's default title")
        XCTAssertEqual(actions.first?.kind, .perform(RequestedHostOperation(perform: "open.url", input: .string("https://brew.sh"))))

        let notify = try PluginScriptAnswer(parsing: value("answers/page-action-notify.json"), permits: permits)
        guard case .actions(_, let notifying)? = notify.page?.components.first,
              case .perform(let operation)? = notifying.first?.kind else { return XCTFail("No page action") }
        XCTAssertEqual(operation, RequestedHostOperation(perform: "clipboard.write", input: .string("🐈"), id: "copy",
                                                         notify: true))

        let refused: [(JSONValue, String)] = [
            (.object(["perform": .string("copy_text"), "input": .string("x")]),
             "A page action names copy_text, a Plugin API Level 1 name; a request names clipboard.write"),
            (.object(["perform": .string("storage.get"), "input": .string("k")]),
             "A page action names storage.get, which is not a page action"),
            (.object(["perform": .string("open.url"), "input": .string("file:///etc")]),
             "A page action gives open.url input it refuses: Only http and https links can be opened")
        ]
        for (action, message) in refused {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: page(action), permits: permits)) {
                XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation(message))
            }
        }
    }

    /// The IDs a page or item action may perform are the catalogue's and the
    /// published schema's, and the catalogue's default titles are the ones a
    /// page action shows.
    func testTheActionIDsAndTitlesAreTheCatalogues() throws {
        let viewActions = HostServiceCatalogue.operations.filter { $0.isOffered(at: .viewAction) }.map(\.id)
        XCTAssertEqual(CollectionsContract.viewActionIDs, viewActions)
        XCTAssertEqual(PluginInterfaceContracts.levelTwoMembers.filter { $0.kind == .standardAction }.map(\.name).sorted(),
                       viewActions.sorted())
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
                Self.pluginAPI.appendingPathComponent("schemas/namespaces.schema.json"))),
              case .object(let definitions)? = schema["$defs"],
              case .object(let ids)? = definitions["view_action_id"], case .array(let listed)? = ids["enum"],
              case .object(let items)? = definitions["item_action_id"], case .array(let itemIDs)? = items["enum"] else {
            return XCTFail("namespaces.schema.json lists no view or item action IDs")
        }
        XCTAssertEqual(listed, viewActions.map(JSONValue.string))
        XCTAssertEqual(itemIDs, CollectionsContract.itemActionIDs.map(JSONValue.string))
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
                Self.pluginAPI.appendingPathComponent("catalogue.json"))),
              case .array(let operations)? = root["operations"] else { return XCTFail("catalogue.json has no operations") }
        for case .object(let operation) in operations {
            guard case .string(let id)? = operation["id"], viewActions.contains(id),
                  case .string(let title)? = operation["default_title"] else { continue }
            XCTAssertEqual(CollectionsContract.defaultTitle(of: id), title, id)
        }
    }

    /// The types, reference and SDK name every page action ID, component,
    /// event and windowed member.
    func testTheTypesReferenceAndSDKNameEveryMember() throws {
        let types = try String(contentsOf: Self.pluginAPI.appendingPathComponent("spinnet-level-2.d.ts"), encoding: .utf8)
        let reference = try String(contentsOf: Self.pluginAPI.appendingPathComponent("reference/pages.md"), encoding: .utf8)
        let sdk = try String(contentsOf: Self.pluginAPI.appendingPathComponent("spinnet-level-2.js"), encoding: .utf8)
        for id in CollectionsContract.viewActionIDs {
            XCTAssertTrue(types.contains("\"\(id)\""), "spinnet-level-2.d.ts does not list \(id)")
        }
        for kind in CollectionsContract.componentKinds {
            XCTAssertTrue(types.contains("kind: \"\(kind)\""), "spinnet-level-2.d.ts has no \(kind)")
            XCTAssertTrue(reference.contains("`\(kind)`"), "pages.md does not name \(kind)")
        }
        for event in CollectionsContract.events {
            XCTAssertTrue(types.contains("type: \"\(event)\""), "spinnet-level-2.d.ts has no \(event)")
            XCTAssertTrue(reference.contains("`\(event)`"), "pages.md does not name \(event)")
        }
        XCTAssertFalse(types.contains("load_more\";"), "No load_more event")
        for word in ["total", "start", "marks", "toggle", "notify", "count"] {
            XCTAssertTrue(sdk.contains("\(word): o.\(word)"), "spinnet-level-2.js does not build \(word)")
            XCTAssertTrue(types.contains("\(word)?:") || types.contains("\(word):"), "spinnet-level-2.d.ts has no \(word)")
            XCTAssertTrue(reference.contains("`\(word)"), "pages.md does not name \(word)")
        }
        XCTAssertFalse(sdk.contains("has_more"), "The builders have no hasMore")
    }
}
