import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Bundled packages declare stable Level 3 and receive only the proved additions.
final class PluginAPILevelThreeTests: XCTestCase {
    private func manifest(level: Int, candidate: CandidateContractRevision? = nil) throws -> PluginManifest {
        var value: [String: JSONValue] = ["protocol_version": .string("1.0"), "api_level": .number(Double(level)),
            "id": .string("com.example.stable-proof"), "name": .string("Stable proof"), "version": .string("1.0"),
            "commands": .array([.object(["id": .string("show"), "title": .string("Show"),
                "execution": .string("javascript"), "script": .string("show.js")])])]
        if let candidate { value["candidate_contracts"] = .array([.object(["name": .string(candidate.name), "revision": .number(Double(candidate.revision))])]) }
        return try PluginManifestLoader.decode(JSONEncoder().encode(value))
    }

    func testBundledStablePackageCanPresentTheProvedAdaptiveViewport() throws {
        let manifest = try manifest(level: 3)
        try PluginInterfaceContracts.host.check(manifest, origin: .bundled)
        let page = try PluginPage(parsing: AdaptiveViewportContractTests.page(), permits: PluginInterfaceContracts.host.permitting(manifest))
        XCTAssertEqual(page.inputs.map(\.id), ["note"])
        XCTAssertThrowsError(try PluginPage(parsing: AdaptiveViewportContractTests.page(),
            permits: PluginInterfaceContracts.host.permitting(self.manifest(level: 2))))
    }
    func testRetiredDeclarationsNameTheStableMigrationAndGrantNoMembers() throws {
        for declaration in [CandidateContractRevision(name: "adaptive_layout", revision: 1),
            .init(name: "adaptive_layout", revision: 2), .init(name: "spotify_controls", revision: 1),
            .init(name: "external_app_connections", revision: 1), .init(name: "homebrew_autoremove", revision: 1)] {
            let retired = try manifest(level: 2, candidate: declaration)
            XCTAssertThrowsError(try PluginInterfaceContracts.host.check(retired, origin: .installed)) {
                XCTAssertEqual($0 as? CandidateContractRefusal,
                    .retired(plugin: "Stable proof", declared: declaration, promotedToLevel: 3))
                XCTAssertTrue($0.localizedDescription.contains("declares Level 3 instead"))
            }
            XCTAssertFalse(PluginInterfaceContracts.host.permits(.viewComponent("adaptive"), declaredBy: retired))
            XCTAssertFalse(PluginInterfaceContracts.host.permits(.behaviour("spotify_controls"), declaredBy: retired))
        }
    }

    func testPublishedStableAdaptiveFixturesAgreeWithThePublicAnswerParser() throws {
        let api = PagesContractTests.pluginAPI
        let fixtures = api.appendingPathComponent("fixtures/level-3/adaptive-layout")
        let schemas = try ["pages-level-3", "adaptive-layout"].map {
            try JSONSchemaSubsetValidator(definition: "answer",
                inSchemaAt: api.appendingPathComponent("schemas/\($0).schema.json"))
        }
        struct Entry: Decodable { let file: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: fixtures.appendingPathComponent("index.json")))
        let permits = PluginInterfaceContracts.host.permitting(try manifest(level: 3))
        for entry in index.fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtures.appendingPathComponent(entry.file)))
            for schema in schemas {
                XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, "\(entry.file): \(schema.errors(for: value))")
            }
            do { _ = try PluginScriptAnswer(parsing: value, permits: permits); XCTAssertTrue(entry.valid, entry.file) }
            catch { XCTAssertFalse(entry.valid, "\(entry.file): \(error)") }
        }
    }

    func testStableAdaptivePagesComposeWithLevelThreeSourcesAndOperations() throws {
        guard case .object(var page) = AdaptiveViewportContractTests.page() else { return XCTFail("No page fixture") }
        page["sources"] = .array([.object(["id": .string("preview"), "perform": .string("tools.read"),
            "input": .object(["tool": .string("homebrew"), "operation": .string("previewAutoremove")])])])
        let answer = JSONValue.object(["page": .object(page), "operation": .object([
            "perform": .string("tools.startTask"), "input": .object(["tool": .string("homebrew"), "operation": .string("autoremove")])])])
        _ = try PluginScriptAnswer(parsing: answer, permits: PluginInterfaceContracts.host.permitting(manifest(level: 3)))
        for name in ["pages-level-3", "adaptive-layout"] {
            let schema = try JSONSchemaSubsetValidator(definition: "answer",
                inSchemaAt: PagesContractTests.pluginAPI.appendingPathComponent("schemas/\(name).schema.json"))
            XCTAssertEqual(schema.errors(for: answer), [], name)
        }
    }

    func testStableManifestSchemaAcceptsMigratedPackagesAndRefusesCandidateDeclarations() throws {
        let schema = try JSONSchemaSubsetValidator(schemaAt: PagesContractTests.pluginAPI.appendingPathComponent("schemas/manifest-level-3.schema.json"))
        for package in [AdaptivePageContractTests.fixture, AdaptiveViewportContractTests.fixture] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
            XCTAssertEqual(schema.errors(for: value), [])
        }
        let stale = try manifest(level: 3, candidate: .init(name: "spotify_controls", revision: 1))
        XCTAssertFalse(schema.errors(for: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stale))).isEmpty)
    }

    func testPublishedStableToolAndSpotifyFixturesRetainTheirTypedBounds() throws {
        let api = PagesContractTests.pluginAPI
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        for name in ["homebrew-autoremove", "spotify-controls"] {
            let folder = api.appendingPathComponent("fixtures/level-3/\(name)")
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
            for entry in index.fixtures {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(entry.file)))
                let schema = try JSONSchemaSubsetValidator(definition: entry.definition,
                    inSchemaAt: api.appendingPathComponent("schemas/\(name).schema.json"))
                XCTAssertEqual(schema.errors(for: value).isEmpty, entry.valid, "\(name)/\(entry.file): \(schema.errors(for: value))")
            }
        }
    }

    func testStableSDKBuildersAreAvailableOnlyAtTheDeclaredLevel() throws {
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
        for level in [1, 2, 3] {
            try JSONEncoder().encode(manifest(level: level)).write(to: root.appendingPathComponent("manifest.json"))
            let run = helper.run(.init("show"), of: try PluginUnderTest(packageAt: root), answering: RecordedHostServices([:]))
            let value = try run.result.get()
            guard case .object(let answer) = value, case .object(let state)? = answer["state"] else {
                return XCTFail("Missing SDK state for Level \(level): \(value)")
            }
            XCTAssertEqual(state["adaptive"], JSONValue.bool(level == 3))
        }
    }
}
