import SpinnetTestSupport
import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Public examples pass through the same SDK composition and helper used by
/// Plugins. The shared matrix then checks their actual wire shapes and parser.
final class SDKCompositionTests: XCTestCase {
    private static let api = TestRepository.root
        .appendingPathComponent("PluginAPI")
    private struct Check: Decodable { let schema: String; let definition: String?; let valid: Bool }
    private struct Fixture: Decodable {
        let name: String; let value: JSONValue; let checks: [Check]
        let sdk_script: String?
    }
    private struct Index: Decodable { let cases: [Fixture] }

    private func plugin(at root: URL, script: String) throws -> PluginUnderTest {
        let manifest = try PluginManifest(id: .init("com.example.sdk-composition"), name: "SDK composition", version: "1.0", commands: [
                .init(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")
            ])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try script.write(to: root.appendingPathComponent("show.js"), atomically: true, encoding: .utf8)
        return try PluginUnderTest(packageAt: root)
    }

    func testCurrentFeatureExamplesMatchSharedSchemaMatrixThroughTheRealSDK() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.api.appendingPathComponent("fixtures/conformance/index.json")))
        let examples = index.cases.filter { $0.sdk_script != nil }
        XCTAssertEqual(Set(examples.compactMap(\.sdk_script)), Set(["sdk/activity-source.js", "sdk/terminal-homebrew.js", "sdk/command-output.js", "sdk/catalog-refresh.js"]))
        for fixture in examples {
            let script = try String(contentsOf: Self.api.appendingPathComponent("fixtures/" + XCTUnwrap(fixture.sdk_script)), encoding: .utf8)
            for check in fixture.checks where check.valid {
                let probe = try plugin(at: root, script: script)
                let run = helper.run(.init("show", event: .pageActionChosen(page: "p", action: "run", values: .object([:]), selection: .null)),
                    of: probe, answering: RecordedHostServices([:]))
                let output = try run.result.get()
                XCTAssertEqual(output, fixture.value, "\(fixture.name)")
                XCTAssertTrue(run.requests.isEmpty, "Building an answer must not perform an operation")
                _ = try run.answer()
                let schema = Self.api.appendingPathComponent("schemas/" + check.schema)
                let validator = try check.definition.map { try JSONSchemaSubsetValidator(definition: $0, inSchemaAt: schema) }
                    ?? JSONSchemaSubsetValidator(schemaAt: schema)
                XCTAssertEqual(validator.errors(for: output), [], fixture.name)
            }
        }
    }

    func testEveryRetiredDeclarationIsRefusedBeforeTheHelperOrHostServicesRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        _ = try plugin(at: root, script: "requestHostService('storage.get', {key:'should-not-run'})")
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
        for (key, value) in [("api_level", 1 as Any), ("api_level", NSNull()),
                             ("candidate_contracts", [] as Any), ("candidate_contracts", NSNull())] {
            var fields = original; fields[key] = value
            try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent("manifest.json"))
            XCTAssertThrowsError(try PluginUnderTest(packageAt: root), key)
        }
        XCTAssertEqual(helper.launchCount, 0, "Retired declarations are refused before launching a helper")
    }
}
