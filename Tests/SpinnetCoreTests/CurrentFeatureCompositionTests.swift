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
    func testAPackageCanPresentTheCurrentAdaptiveViewport() throws {
        let manifest = try manifest()
        try PluginInterfaceContracts.host.check(manifest)
        let page = try PluginPage(parsing: AdaptiveViewportContractTests.page(), permits: PluginInterfaceContracts.host.permitting(manifest))
        XCTAssertEqual(page.inputs.map(\.id), ["note"])
        XCTAssertThrowsError(try PluginPage(parsing: AdaptiveViewportContractTests.page(), permits: { _ in false }),
            "An unavailable Host feature is still refused independently of compatibility")
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
