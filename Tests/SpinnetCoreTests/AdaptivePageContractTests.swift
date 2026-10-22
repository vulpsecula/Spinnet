import Foundation
import XCTest
import SpinnetCore

/// Public Level 3 answer parsing: cards are identified components, not
/// Collection items, so their fields and source bindings remain ordinary.
final class AdaptivePageContractTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/AdaptiveCards.spinnetplugin")
    static var manifest: PluginManifest { try! PluginManifestLoader.load(packageAt: fixture).manifest }
    static var permits: (PluginInterfaceMember) -> Bool { PluginInterfaceContracts.host.permitting(manifest) }
    static let answer: JSONValue = .object(["page": .object([
        "id": .string("metrics"), "title": .string("Metrics"), "resizable": .bool(true),
        "content": .array([.object(["kind": .string("adaptive"), "id": .string("cards"),
            "min_card_width": .number(240), "spacing": .number(12), "max_columns": .number(2),
            "content": .array([
                .object(["kind": .string("column"), "id": .string("cpu"), "content": .array([
                    .object(["kind": .string("text"), "id": .string("cpu-value"), "text": .string("CPU")]),
                    .object(["kind": .string("text_field"), "id": .string("note"), "title": .string("Note"), "value": .string("initial")])])]),
                .object(["kind": .string("column"), "id": .string("memory"), "content": .array([
                    .object(["kind": .string("text"), "id": .string("memory-value"), "text": .string("Memory")])])])])])])])])

    func testADeclarativeAdaptiveContainerKeepsEveryIdentifiedChildInThePublicPage() throws {
        let page = try XCTUnwrap(try PluginScriptAnswer(parsing: Self.answer, permits: Self.permits).page)
        XCTAssertEqual(page.components.map(\.id), ["cards", "cpu", "cpu-value", "note", "memory", "memory-value"])
        XCTAssertEqual(page.content.first?.children.map(\.id), ["cpu", "memory"])
        XCTAssertNil(page.collection, "Cards never create Collection selection or load_range")
        guard case .textField(let field)? = page.component("note") else { return XCTFail("Missing identified field") }
        XCTAssertEqual(field.value, "initial")
    }
    func testLevelThreeAdmissionKeepsEarlierVocabularySeparate() throws {
        try PluginInterfaceContracts.host.check(Self.manifest, origin: .installed)
        XCTAssertFalse(PluginInterfaceContracts.levelTwoMembers.contains(.viewComponent("adaptive")))
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: Self.answer, permits: CollectionsFixtures.permits))
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: Self.answer, permits: CollectionsFixtures.levelOne))
        XCTAssertNoThrow(try PluginInterfaceContracts.host.check(Self.manifest, origin: .bundled))
        let oldHost = PluginInterfaceContracts(levels: [1: PluginInterfaceContracts.levelOneMembers, 2: PluginInterfaceContracts.levelTwoMembers])
        XCTAssertThrowsError(try oldHost.check(Self.manifest, origin: .installed))
        let wrongRevision = CandidateContract(name: "adaptive_layout", revision: 2, baseLevel: 2,
            members: [.viewComponent("adaptive")], tag: "plugin-api-candidate/adaptive_layout/r2")
        XCTAssertThrowsError(try PluginInterfaceContracts(levels: oldHost.levels, candidates: [wrongRevision]).check(Self.manifest, origin: .installed))
    }

    func testAdaptiveChildrenCannotBypassSharedIdentityAndDepthBudgets() throws {
        let leaf: (String) -> JSONValue = { .object(["kind": .string("text"), "id": .string($0), "text": .string("Value")]) }
        func answer(_ children: [JSONValue]) -> JSONValue {
            .object(["page": .object(["id": .string("p"), "title": .string("P"), "content": .array([
                .object(["kind": .string("adaptive"), "id": .string("cards"), "content": .array(children)])])])])
        }
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer([leaf("same"), leaf("same")]), permits: Self.permits))
        let deep: JSONValue = .object(["kind": .string("column"), "id": .string("c"), "content": .array([
            .object(["kind": .string("row"), "id": .string("r"), "content": .array([
                .object(["kind": .string("column"), "id": .string("too-deep"), "content": .array([leaf("v")])])])])])])
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer([deep]), permits: Self.permits))
        let tooMany: [JSONValue] = (0..<8).map { card in .object(["kind": .string("column"), "id": .string("card\(card)"),
            "content": .array((0..<5).map { leaf("v\(card)-\($0)") })]) }
        XCTAssertThrowsError(try PluginScriptAnswer(parsing: answer(tooMany), permits: Self.permits), "Forty page components includes adaptive descendants")
    }

    func testPublishedStableCardFixturesFollowSchemaAndHostBounds() throws {
        let root = PagesContractTests.pluginAPI.appendingPathComponent("fixtures/level-3/adaptive-cards")
        let validator = try JSONSchemaSubsetValidator(definition: "answer", inSchemaAt: PagesContractTests.pluginAPI.appendingPathComponent("schemas/adaptive-layout.schema.json"))
        struct Index: Decodable { struct Fixture: Decodable { let file: String; let valid: Bool }; let fixtures: [Fixture] }
        let fixtures = try JSONDecoder().decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("index.json"))).fixtures
        for fixture in fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(fixture.file)))
            XCTAssertEqual(validator.errors(for: value).isEmpty, fixture.valid, "\(fixture.file): \(validator.errors(for: value))")
            do { _ = try PluginScriptAnswer(parsing: value, permits: Self.permits); XCTAssertTrue(fixture.valid, fixture.file) }
            catch { XCTAssertFalse(fixture.valid, "\(fixture.file): \(error)") }
        }
    }
}
