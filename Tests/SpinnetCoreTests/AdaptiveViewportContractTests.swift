import Foundation
import XCTest
import SpinnetCore

final class AdaptiveViewportContractTests: XCTestCase {
    static let fixture = AdaptivePageContractTests.fixture.deletingLastPathComponent().appendingPathComponent("AdaptiveViewport.spinnetplugin")
    static var permits: (PluginInterfaceMember) -> Bool {
        get throws { PluginInterfaceContracts.host.permitting(try PluginManifestLoader.load(packageAt: fixture).manifest) }
    }
    static func page(fit: JSONValue? = nil) -> JSONValue {
        var adaptive: [String: JSONValue] = ["kind": .string("adaptive"), "id": .string("cards"), "max_columns": .number(2),
            "content": .array([.object(["kind": .string("column"), "id": .string("cpu"), "content": .array([
                .object(["kind": .string("text"), "id": .string("value"), "text": .string("CPU")]),
                .object(["kind": .string("text_field"), "id": .string("note"), "title": .string("Note")])])])])]
        adaptive["fit"] = fit ?? .object(["profiles": .array([.object(["id": .string("compact"), "min_card_width": .number(180),
            "min_card_height": .number(80), "overrides": .array([.object(["id": .string("value"), "text": .string("Processor"),
                "style": .object(["font_size": .number(20)])])])])])])
        return .object(["id": .string("metrics"), "title": .string("Metrics"), "resizable": .bool(true), "content": .array([.object(adaptive)])])
    }
    func testCurrentViewportProfilesPreserveCanonicalComponents() throws {
        let manifest = try PluginManifestLoader.load(packageAt: Self.fixture).manifest
        try PluginInterfaceContracts.host.check(manifest)
        let page = try PluginPage(parsing: Self.page(), permits: Self.permits)
        XCTAssertEqual(page.components.map(\.id), ["cards", "cpu", "value", "note"])
        XCTAssertEqual(page.inputs.map(\.id), ["note"])
        XCTAssertThrowsError(try PluginPage(parsing: Self.page(), permits: { $0 != AdaptiveViewportLayout.viewportFit && AdaptivePageContractTests.permits($0) }), "A Host without viewport fit must refuse it")
        XCTAssertNoThrow(try PluginPage(parsing: Self.page(), permits: CollectionsFixtures.permits))
    }
    func testProfilesOnlyOverrideBoundedPassiveTextAndNeverIntroduceTrees() throws {
        func fit(_ overrides: [JSONValue], profiles: Int = 1) -> JSONValue {
            .object(["profiles":.array((0..<profiles).map { .object(["id":.string("p\($0)"),"min_card_width":.number(180),"min_card_height":.number(80),"overrides":.array(overrides)]) })])
        }
        for target in ["note","cpu","unknown"] {
            XCTAssertThrowsError(try PluginPage(parsing:Self.page(fit:fit([.object(["id":.string(target),"hidden":.bool(true)])])),permits:Self.permits))
        }
        XCTAssertThrowsError(try PluginPage(parsing:Self.page(fit:fit([.object(["id":.string("value"),"content":.array([])])])),permits:Self.permits))
        XCTAssertThrowsError(try PluginPage(parsing:Self.page(fit:fit([],profiles:4)),permits:Self.permits))
        XCTAssertThrowsError(try PluginPage(parsing:Self.page(fit:fit([.object(["id":.string("value")]),.object(["id":.string("value")])])),permits:Self.permits))
        guard case .object(var page) = Self.page(),case .array(var content)? = page["content"] else { return XCTFail("No fixture") }
        content.append(.object(["kind":.string("text"),"id":.string("sibling"),"text":.string("Outside")]))
        page["content"] = .array(content)
        XCTAssertThrowsError(try PluginPage(parsing:.object(page),permits:Self.permits),"Only one fit region can own the remaining height")
    }

    func testPublishedStableViewportFixturesMatchSchemaAndPublicParser() throws {
        let root = PagesContractTests.pluginAPI.appendingPathComponent("fixtures/adaptive-layout")
        let validator = try JSONSchemaSubsetValidator(definition:"answer",inSchemaAt:PagesContractTests.pluginAPI.appendingPathComponent("schemas/adaptive-layout.schema.json"))
        struct Index: Decodable { struct Fixture: Decodable { let file:String; let valid:Bool }; let fixtures:[Fixture] }
        let index = try JSONDecoder().decode(Index.self,from:Data(contentsOf:root.appendingPathComponent("index.json")))
        for fixture in index.fixtures {
            let value = try JSONDecoder().decode(JSONValue.self,from:Data(contentsOf:root.appendingPathComponent(fixture.file)))
            XCTAssertEqual(validator.errors(for:value).isEmpty,fixture.valid,"\(fixture.file): \(validator.errors(for:value))")
            do { _ = try PluginScriptAnswer(parsing:value,permits:Self.permits); XCTAssertTrue(fixture.valid,fixture.file) }
            catch { XCTAssertFalse(fixture.valid,"\(fixture.file): \(error)") }
        }
        XCTAssertTrue(PluginInterfaceContracts.currentMembers.contains(AdaptiveViewportLayout.viewportFit))
        let manifest = try PluginManifestLoader.load(packageAt: Self.fixture).manifest
        XCTAssertThrowsError(try PluginInterfaceContracts(hostVersion: HostVersion("0.9.0")).check(manifest))
    }

}
