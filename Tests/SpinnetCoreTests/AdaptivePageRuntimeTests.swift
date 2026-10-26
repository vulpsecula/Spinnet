import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class AdaptivePageRuntimeTests: XCTestCase {
    func testRealHelperInjectsTheAdaptiveBuilderAndKeepsFieldState() throws {
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


    }
}
