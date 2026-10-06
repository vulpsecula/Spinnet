import Foundation
import XCTest
@testable import SpinnetCore

/// `Tests/Fixtures/EmojiPages.spinnetplugin` and `BrewPages.spinnetplugin`
/// are external Plugins declaring Plugin API Level 2, written against
/// Candidate Contract `collections` r3 and the `host_operations` r2 and
/// `namespaces` r1 it required before Level 2 promoted them: an Emoji-shaped
/// grid and a Brew-shaped list with a detail page.
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

    /// What a Plugin declaring `collections` r1, which has no repeated
    /// calls, and the candidates it requires could use on the candidate Host.
    static var revisionOne: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.candidateHost.permitting(try! manifest(declaringCollections: 1))
    }

    /// What a Plugin declaring `collections` r2, whose collections are whole
    /// and append with `load_more`, and the candidates it requires could use
    /// on the candidate Host.
    static var revisionTwo: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.candidateHost.permitting(try! manifest(declaringCollections: 2))
    }

    /// The Emoji fixture's manifest declaring `collections` at `revision`
    /// and what it requires, at Level 1, as before promotion.
    static func manifest(declaringCollections revision: Int, of package: URL = emoji) throws -> PluginManifest {
        try CandidateVariant.manifest(of: package, CandidateVariant.declaring(CandidateVariant.pages(collections: revision)))
    }

    /// What a Plugin declaring `host_operations` and `namespaces` but not
    /// `collections` could use on the candidate Host.
    static var withoutCollections: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.candidateHost.permitting(try! CandidateVariant.manifest(
            of: OperationsProbeFixture.package, CandidateVariant.declaring(CandidateVariant.operations(revision: 1))))
    }
}

/// Candidate Contract `collections` r1 as published under
/// `PluginAPI/candidates/collections/r1/` and as the Host reads it: the
/// answers and events its fixtures hold, the page rules beyond the schema,
/// the candidate's members, its SDK and types, and Level 1 left as it was.
/// `CollectionsRevisionTwoContractTests` runs the same checks on r2.
class CollectionsContractTests: XCTestCase {
    static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    /// The revision these tests check.
    class var revision: Int { 1 }
    /// The Host's record of that revision.
    class var candidate: CandidateContract { CollectionsContract.revisionOne }
    static var published: URL { pluginAPI.appendingPathComponent("candidates/collections/r\(revision)") }
    static var schema: URL { published.appendingPathComponent("collections.schema.json") }

    struct Fixture: Decodable {
        let file: String
        let definition: String
        let valid: Bool
        let note: String
        let level1: Bool?
    }

    func fixtures() throws -> [Fixture] {
        struct Index: Decodable { let fixtures: [Fixture] }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.published.appendingPathComponent("fixtures/index.json")))
            .fixtures
    }

    func value(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.published.appendingPathComponent("fixtures/\(file)")))
    }

    /// What a Plugin declaring this revision, and the candidates it
    /// requires, could use on the candidate Host.
    var permits: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.candidateHost.permitting(try! CollectionsFixtures.manifest(declaringCollections: Self.revision))
    }

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
    /// one as a protocol violation, reading each as it reads an answer of a
    /// Plugin declaring the candidate: its page, page rules included, or its
    /// Level 1 view.
    func testTheHostReadsThePublishedAnswersAsTheFixturesSay() throws {
        for fixture in try fixtures() where fixture.definition == "answer" {
            let answer = try value(fixture.file)
            do {
                let read = try PluginScriptAnswer(parsing: answer, permits: permits)
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

    /// Every valid event fixture is one the Host could send: it reads back
    /// into an event whose JSON is the fixture.
    func testEveryEventTheHostSendsFollowsTheSchema() throws {
        let validator = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        let item = PluginPageItemSnapshot(id: "1F408", section: "animals-nature", text: "🐈")
        let events: [PluginViewEvent] = [
            .pageFieldChanged(page: "search", field: "query", values: .object(["query": .string("cat")])),
            .pageSubmitted(page: "p", field: "q", values: .object([:]), selection: .object(["results": .null])),
            .pageActionChosen(page: "p", action: "back", values: .object([:]), selection: .object([:])),
            .itemAction(page: "search", collection: "results", action: "insert", item: item,
                        values: .object(["query": .string("cat")])),
            .itemAction(page: "search", collection: "results", action: "insert",
                        item: PluginPageItemSnapshot(id: "x", section: nil, text: "x"), values: .object([:])),
            .loadMore(page: "search", collection: "results", loaded: 200)
        ]
        for event in events { XCTAssertEqual(validator.errors(for: event.json), [], "\(event)") }
        // An explicit call is revision 2's.
        XCTAssertEqual(validator.errors(for: PluginViewEvent.called.json).isEmpty, Self.revision >= 2)
        XCTAssertTrue(PluginViewEvent.called.isGesture)
        XCTAssertFalse(PluginViewEvent.called.coalesces)
        XCTAssertNil(PluginViewEvent.called.pageOrigin, "No page change drops a call")
        XCTAssertEqual(PluginPageItemSnapshot(id: "x", section: nil, text: "x").json, .object(["id": .string("x")]),
                       "The text travels only where it differs from the ID")
        XCTAssertEqual(events.map(\.isGesture), [false, true, true, true, true, false])
        XCTAssertEqual(events.map(\.coalesces), [true, false, false, false, false, false])
    }

    /// Level 1 is unchanged: its published schemas refuse what the candidate
    /// adds, and to a Plugin that does not declare it `page` is unknown.
    func testLevelOneRefusesWhatTheCandidateAdds() throws {
        let session = Self.pluginAPI.appendingPathComponent("schemas/view-session.schema.json")
        for fixture in try fixtures() {
            guard let level1 = fixture.level1 else { continue }
            let errors = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: session)
                .errors(for: try value(fixture.file))
            XCTAssertEqual(errors.isEmpty, level1, "\(fixture.file): Level 1 \(level1 ? "accepts" : "refuses") it")
        }
        let page = try value("answers/emoji-search-cat.json")
        for permits in [CollectionsFixtures.withoutCollections, { _ in false }] {
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
            "answers/unknown-kind.json": "kind must be one of"
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
        XCTAssertEqual(grid.copyAction?.operation(on: first),
                       RequestedHostOperation(perform: "clipboard.write", input: .object(["text": .string(first.resolvedText)]),
                                              id: "copy"))

        let brew = try XCTUnwrap(try PluginScriptAnswer(parsing: value("answers/brew-list.json"), permits: permits).page)
        let list = try XCTUnwrap(brew.collection)
        XCTAssertEqual(list.style, .list)
        XCTAssertFalse(brew.drawsInsertionTarget, "A page that cannot insert shows no target line")
        for item in list.items {
            XCTAssertEqual(list.actions(of: item).first?.isDefault, true, "The default comes first in \(item.id)'s menu")
        }
    }

    /// A page action takes what a request of its ID takes and is held to the
    /// IDs the candidate offers as page actions.
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
        let refused: [(JSONValue, String)] = [
            (.object(["perform": .string("copy_text"), "input": .string("x")]),
             "A page action names copy_text, a Plugin API Level 1 name; a request names clipboard.write"),
            (.object(["perform": .string("storage.get"), "input": .string("k")]),
             "A page action names storage.get, which is not a page action"),
            (.object(["perform": .string("open.url"), "input": .string("file:///etc")]),
             "A page action gives open.url input it refuses: Only http and https links can be opened"),
            (.object(["perform": .string("clipboard.write"), "input": .string("x"), "notify": .bool(true)]),
             "A page action has unknown member notify")
        ]
        for (action, message) in refused {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: page(action), permits: permits)) {
                XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation(message))
            }
        }
    }

    /// The published metadata is the Host's record: behaviours, the IDs a
    /// page action may perform (the catalogue's view-action IDs, which the
    /// namespaces schema lists), the components and the events.
    func testTheCandidatesMembersAreTheCataloguesAndThePublishedOnes() throws {
        let published = try JSONDecoder().decode(CandidateContract.self,
                                                 from: Data(contentsOf: Self.published.appendingPathComponent("candidate.json")))
        XCTAssertEqual(published, CandidateVariant.retired(Self.candidate))
        XCTAssertTrue(PluginInterfaceContracts.candidateHost.candidates.contains(Self.candidate))
        XCTAssertEqual(published.members.contains(CollectionsContract.repeatedCallsIntoSession), Self.revision >= 2)
        XCTAssertEqual(published.members.contains(.viewEvent("called")), Self.revision >= 2)
        XCTAssertEqual(published.requires, [Self.revision >= 3 ? HostOperationsContract.revisionTwoDeclaration
                                                                : HostOperationsContract.declaration,
                                            HostServiceCatalogue.declaration])
        let viewActions = HostServiceCatalogue.operations.filter { $0.isOffered(at: .viewAction) }.map(\.id)
        XCTAssertEqual(published.members.filter { $0.kind == .standardAction }.map(\.name), viewActions)
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
                HostServiceCatalogueTests.published.appendingPathComponent("namespaces.schema.json"))),
              case .object(let definitions)? = schema["$defs"],
              case .object(let ids)? = definitions["view_action_id"], case .array(let listed)? = ids["enum"],
              case .object(let items)? = definitions["item_action_id"], case .array(let itemIDs)? = items["enum"] else {
            return XCTFail("namespaces.schema.json lists no view or item action IDs")
        }
        XCTAssertEqual(listed, viewActions.map(JSONValue.string))
        XCTAssertEqual(itemIDs, CollectionsContract.itemActionIDs.map(JSONValue.string))
        // The catalogue's default titles are the ones a page action shows.
        let catalogue = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
            HostServiceCatalogueTests.published.appendingPathComponent("catalogue.json")))
        guard case .object(let root) = catalogue, case .array(let operations)? = root["operations"] else {
            return XCTFail("catalogue.json has no operations")
        }
        for case .object(let operation) in operations {
            guard case .string(let id)? = operation["id"], viewActions.contains(id),
                  case .string(let title)? = operation["default_title"] else { continue }
            XCTAssertEqual(CollectionsContract.defaultTitle(of: id), title, id)
        }
    }

    /// The types, reference and SDK name every page action ID and component.
    func testTheTypesReferenceAndSDKNameEveryMember() throws {
        let types = try String(contentsOf: Self.published.appendingPathComponent("collections.d.ts"), encoding: .utf8)
        let reference = try String(contentsOf: Self.published.appendingPathComponent("reference.md"), encoding: .utf8)
        // Revision 2 adds no builder: the helper adds revision 1's SDK for it.
        let sdk = try String(contentsOf: Self.pluginAPI.appendingPathComponent("candidates/collections/r1/collections.js"),
                             encoding: .utf8)
        XCTAssertEqual(FileManager.default.fileExists(atPath: Self.published.appendingPathComponent("collections.js").path),
                       Self.revision == 1)
        for id in CollectionsContract.viewActionIDs {
            XCTAssertTrue(types.contains("\"\(id)\""), "collections.d.ts does not list \(id)")
            XCTAssertTrue(reference.contains("`\(id)`"), "reference.md does not name \(id)")
            let parts = id.split(separator: ".")
            XCTAssertTrue(sdk.contains("\(parts[0]): [") && sdk.contains("\"\(parts[1])\""), "collections.js has no \(id)")
        }
        for kind in CollectionsContract.componentKinds {
            XCTAssertTrue(types.contains("kind: \"\(kind)\""), "collections.d.ts has no \(kind)")
            XCTAssertTrue(reference.contains("`\(kind)`"), "reference.md does not name \(kind)")
        }
        for event in CollectionsContract.events {
            XCTAssertTrue(types.contains("type: \"\(event)\""), "collections.d.ts has no \(event)")
        }
        if Self.revision == 1 {
            XCTAssertFalse(types.contains("\"called\""), "Repeated calls are not part of revision 1")
        } else {
            XCTAssertTrue(types.contains("type: \"called\""), "collections.d.ts has no called")
            XCTAssertTrue(reference.contains("`called`"), "reference.md does not name called")
            XCTAssertTrue(reference.contains("`repeated_calls_into_session`"))
        }
    }
}

/// Candidate Contract `collections` r2, published under
/// `PluginAPI/candidates/collections/r2/`: revision 1's checks, and the
/// `called` event and `repeated_calls_into_session` behaviour it adds.
final class CollectionsRevisionTwoContractTests: CollectionsContractTests {
    override class var revision: Int { 2 }
    override class var candidate: CandidateContract { CollectionsContract.revisionTwo }

    /// Revision 2 is revision 1 with repeated calls, and nothing else: the
    /// same schema apart from `called`, the same fixtures and two more.
    func testRevisionTwoIsRevisionOneWithRepeatedCalls() throws {
        let one = CollectionsContract.revisionOne, two = CollectionsContract.revisionTwo
        XCTAssertEqual(two.revision, 2)
        XCTAssertEqual(Set(two.members).subtracting(one.members),
                       [CollectionsContract.repeatedCallsIntoSession, .viewEvent("called")])
        XCTAssertTrue(Set(one.members).isSubset(of: two.members))
        XCTAssertEqual(two.requires, one.requires)
        let host = PluginInterfaceContracts.candidateHost
        XCTAssertTrue(host.candidates.contains(one) && host.candidates.contains(two),
                      "The candidate Host provided revision 1 beside it")

        let r1 = Self.pluginAPI.appendingPathComponent("candidates/collections/r1/fixtures")
        let r2 = Self.published.appendingPathComponent("fixtures")
        for folder in ["answers", "events"] {
            let first = Set(try FileManager.default.contentsOfDirectory(atPath: r1.appendingPathComponent(folder).path))
            let second = Set(try FileManager.default.contentsOfDirectory(atPath: r2.appendingPathComponent(folder).path))
            XCTAssertEqual(second.subtracting(first), folder == "events" ? ["called.json", "called-with-input.json"] : [])
            XCTAssertEqual(first.subtracting(second), [])
            for file in first {
                XCTAssertEqual(try Data(contentsOf: r1.appendingPathComponent("\(folder)/\(file)")),
                               try Data(contentsOf: r2.appendingPathComponent("\(folder)/\(file)")), file)
            }
        }
    }
}
