import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class AdaptivePageRuntimeTests: XCTestCase {
    func testRealHelperInjectsTheLevelThreeBuilderAndKeepsFieldState() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt: AdaptivePageContractTests.fixture)
        let view = PluginTestPage("cards", of: plugin, helper: helper)
        try view.open()
        guard case .adaptive(let cards)? = view.page?.component("cards") else { return XCTFail("No stable adaptive layout from the real SDK") }
        XCTAssertEqual(cards.minimumCardWidth, 280); XCTAssertEqual(cards.maximumColumns, 2)
        let schema = PagesContractTests.pluginAPI.appendingPathComponent("schemas/adaptive-layout.schema.json")
        XCTAssertEqual(try JSONSchemaSubsetValidator(definition: "page", inSchemaAt: schema).errors(for: try XCTUnwrap(view.pageJSON)), [])
        try view.type("retained note", into: "note")
        try view.click("refresh")
        XCTAssertEqual(view.text(of: "note"), "retained note")

        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("spinnetplugin")
        try FileManager.default.copyItem(at: AdaptivePageContractTests.fixture, to: stable)
        defer { try? FileManager.default.removeItem(at: stable) }
        let manifestURL = stable.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["api_level"] = 2
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let probe = PluginTestPage("cards", of: try PluginUnderTest(packageAt: stable), helper: helper, input: .object(["sdkProbe": .bool(true)]))
        try probe.open()
        guard case .text(let available)? = probe.page?.component("available") else { return XCTFail("No SDK probe") }
        XCTAssertEqual(available.text, "undefined", "Level 2 Plugins do not receive the Level 3 adaptive builder")
    }
}
