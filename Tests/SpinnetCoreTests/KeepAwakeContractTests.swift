import Foundation
import XCTest
import SpinnetCore

final class KeepAwakeContractTests: XCTestCase {
    func testPublishedFixtureShapesAndHostInputReadingAgree() throws {
        let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PluginAPI")
        struct Fixture: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Fixture] }
        let root = api.appendingPathComponent("fixtures/keep-awake")
        let fixtures = try JSONDecoder().decode(Index.self, from: Data(contentsOf: root.appendingPathComponent("index.json"))).fixtures
        for fixture in fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(fixture.file)))
            let schema = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: api.appendingPathComponent("schemas/namespaces.schema.json"))
            XCTAssertEqual(schema.errors(for: value).isEmpty, fixture.valid, fixture.file)
            if fixture.definition == "system.keepAwake.input" {
                XCTAssertEqual((try? KeepAwakeRequest(input: value)) != nil, fixture.valid, fixture.file)
            }
            if fixture.definition == "activities.stop.input" {
                XCTAssertEqual((try? KeepAwakeRequest.stopID(input: value)) != nil, fixture.valid, fixture.file)
            }
        }
    }
}
