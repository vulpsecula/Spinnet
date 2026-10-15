import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class AdaptiveViewportRuntimeTests: XCTestCase {
    func testActualRevisionTwoSDKAndHelperKeepCanonicalBindingsAndPublicProfiles() throws {
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let plugin = try PluginUnderTest(packageAt:AdaptiveViewportContractTests.fixture)
        let view = PluginTestPage("cards",of:plugin,helper:helper,input:.object(["probe":.bool(true)]))
        try view.open()
        let page = try XCTUnwrap(view.page)
        guard case .adaptive(let adaptive)? = page.component("metric-cards") else { return XCTFail("Missing actual candidate SDK output") }
        XCTAssertEqual(adaptive.fit?.profiles.map(\.id),["compact","standard","spacious"])
        XCTAssertEqual(adaptive.fit?.profiles.first?.overrides.first?.style?.fontSize,11)
        XCTAssertEqual(adaptive.fit?.profiles.last?.overrides.first(where:{$0.id == "cpu-value"})?.style?.fontSize,32)
        XCTAssertEqual(page.components.filter { if case .text(let text) = $0 { return text.binding != nil }; return false }.count,7)
        XCTAssertEqual(page.inputs.map(\.id),["note"])
        let schema = PagesContractTests.pluginAPI.appendingPathComponent("candidates/adaptive_layout/r2/adaptive-layout.schema.json")
        XCTAssertEqual(try JSONSchemaSubsetValidator(definition:"page",inSchemaAt:schema).errors(for:try XCTUnwrap(view.pageJSON)),[])
        try view.type("kept note",into:"note")
        XCTAssertEqual(view.text(of:"note"),"kept note")
        XCTAssertEqual(view.page?.components.map(\.id),page.components.map(\.id))
    }
}
