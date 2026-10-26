import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Current feature composition agrees across Host parser, schemas and SDK.
final class CurrentFeatureCompositionTests: XCTestCase {
    private func manifest() throws -> PluginManifest {
        try PluginManifest(id: .init("com.example.current-proof"), name: "Current proof", version: "1.0.0", commands: [
            .init(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")])
    }
    func testBundledPackageCanPresentTheCurrentAdaptiveViewport() throws {
        let manifest = try manifest()
        try PluginInterfaceContracts.host.check(manifest, origin: .bundled)
        let page = try PluginPage(parsing: AdaptiveViewportContractTests.page(), permits: PluginInterfaceContracts.host.permitting(manifest))
        XCTAssertEqual(page.inputs.map(\.id), ["note"])
        XCTAssertThrowsError(try PluginPage(parsing: AdaptiveViewportContractTests.page(), permits: { _ in false }),
            "An unavailable Host feature is still refused independently of compatibility")
    }

    func testPublishedStableAdaptiveFixturesAgreeWithThePublicAnswerParser() throws {
        let api = PagesContractTests.pluginAPI
        let fixtures = api.appendingPathComponent("fixtures/adaptive-layout")
        let schemas = try ["pages", "adaptive-layout"].map {
            try JSONSchemaSubsetValidator(definition: "answer",
                inSchemaAt: api.appendingPathComponent("schemas/\($0).schema.json"))
        }
        struct Entry: Decodable { let file: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: fixtures.appendingPathComponent("index.json")))
        let permits = PluginInterfaceContracts.host.permitting(try manifest())
        for entry in index.fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtures.appendingPathComponent(entry.file)))
            for schema in schemas {
                XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, "\(entry.file): \(schema.errors(for: value))")
            }
            do { _ = try PluginScriptAnswer(parsing: value, permits: permits); XCTAssertTrue(entry.valid, entry.file) }
            catch { XCTAssertFalse(entry.valid, "\(entry.file): \(error)") }
        }
    }

    func testAdaptivePagesComposeWithCurrentSourcesAndOperations() throws {
        guard case .object(var page) = AdaptiveViewportContractTests.page() else { return XCTFail("No page fixture") }
        page["sources"] = .array([.object(["id": .string("preview"), "perform": .string("tools.read"),
            "input": .object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")])])])
        let answer = JSONValue.object(["page": .object(page), "operation": .object([
            "perform": .string("tools.startTask"), "input": .object(["tool": .string("homebrew"), "operation": .string("autoremove")])])])
        _ = try PluginScriptAnswer(parsing: answer, permits: PluginInterfaceContracts.host.permitting(manifest()))
        for name in ["pages", "adaptive-layout"] {
            let schema = try JSONSchemaSubsetValidator(definition: "answer",
                inSchemaAt: PagesContractTests.pluginAPI.appendingPathComponent("schemas/\(name).schema.json"))
            XCTAssertEqual(schema.errors(for: answer), [], name)
        }
    }

    func testStableManifestSchemaAcceptsMigratedPackagesAndRefusesCandidateDeclarations() throws {
        let schema = try JSONSchemaSubsetValidator(schemaAt: PagesContractTests.pluginAPI.appendingPathComponent("schemas/manifest.schema.json"))
        for package in [AdaptivePageContractTests.fixture, AdaptiveViewportContractTests.fixture] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
            XCTAssertEqual(schema.errors(for: value), [])
        }
        var stale = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(manifest()))
        guard case .object(var fields) = stale else { return XCTFail("Expected manifest") }
        fields["candidate_contracts"] = .array([]); stale = .object(fields)
        XCTAssertFalse(schema.errors(for: stale).isEmpty)
        XCTAssertThrowsError(try PluginManifestLoader.decode(JSONEncoder().encode(stale)))
    }

    func testPublishedStableToolAndSpotifyFixturesRetainTheirTypedBounds() throws {
        let api = PagesContractTests.pluginAPI
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        for name in ["homebrew-autoremove", "spotify-controls"] {
            let folder = api.appendingPathComponent("fixtures/\(name)")
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
            for entry in index.fixtures {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(entry.file)))
                let schema = try JSONSchemaSubsetValidator(definition: entry.definition,
                    inSchemaAt: api.appendingPathComponent("schemas/\(name).schema.json"))
                XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, "\(name)/\(entry.file): \(schema.errors(for: value))")
            }
        }
    }

    func testCurrentSDKBuildersAreAvailableToEveryCompatiblePlugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("SDK.spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        try """
        (function () {
          var adaptive = typeof spinnet.ui.components === 'object' && typeof spinnet.ui.components.adaptive === 'function';
          return {toast: String(adaptive), state: {adaptive: adaptive}};
        })()
        """.write(to: root.appendingPathComponent("show.js"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(manifest()).write(to: root.appendingPathComponent("manifest.json"))
        let run = helper.run(.init("show"), of: try PluginUnderTest(packageAt: root), answering: RecordedHostServices([:]))
        let value = try run.result.get()
        XCTAssertEqual(value.value(atPointer: "/state/adaptive"), .bool(true))
    }
}
