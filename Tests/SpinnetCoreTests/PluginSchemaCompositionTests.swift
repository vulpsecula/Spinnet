import SpinnetTestSupport
import Foundation
import XCTest
@testable import SpinnetCore

/// Public schemas and the Host read the same current payloads. Composition
/// matters inside nested containers and at each operation/source seam,
/// beyond an isolated component or input definition.
final class PluginSchemaCompositionTests: XCTestCase {
    private static let api = TestRepository.root
        .appendingPathComponent("PluginAPI")
    private static let fixtures = api.appendingPathComponent("fixtures/conformance")

    private struct Entry: Decodable {
        let schema: String
        let definition: String?
        let valid: Bool
    }
    private struct Fixture: Decodable {
        let name: String
        let value: JSONValue
        let checks: [Entry]
        let host_versions: [Admission]?
    }
    private struct Admission: Decodable { let version: String; let compatible: Bool }
    private struct Index: Decodable { let cases: [Fixture] }

    func testCurrentFixturesAgreeWithBothSchemaAndHostParser() throws {
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("index.json")))
        XCTAssertGreaterThanOrEqual(index.cases.count, 45)
        XCTAssertTrue(index.cases.allSatisfy { !$0.name.isEmpty && !$0.checks.isEmpty })
        for fixture in index.cases {
            for entry in fixture.checks {
                let context = "\(fixture.name), \(entry.schema)"
                let value = fixture.value
                let url = Self.api.appendingPathComponent("schemas/" + entry.schema)
                let validator = try entry.definition.map { try JSONSchemaSubsetValidator(definition: $0, inSchemaAt: url) }
                    ?? JSONSchemaSubsetValidator(schemaAt: url)
                let errors = validator.errors(for: value)
                XCTAssertEqual(errors.isEmpty, entry.valid, "\(context): \(errors)")

                do {
                    if entry.definition == nil {
                        let manifest = try PluginManifestLoader.decode(JSONEncoder().encode(value))
                        if let admissions = fixture.host_versions {
                            for admission in admissions {
                                let contracts = PluginInterfaceContracts(hostVersion: try HostVersion(admission.version))
                                if admission.compatible { XCTAssertNoThrow(try contracts.check(manifest), context) }
                                else { XCTAssertThrowsError(try contracts.check(manifest), context) }
                            }
                        } else { try PluginInterfaceContracts.host.check(manifest) }
                    } else {
                        let manifest = try PluginManifest(id: .init("com.example.schema-composition"),
                            name: "Schema composition", version: "1.0", commands: [
                                .init(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")
                            ])
                        _ = try PluginScriptAnswer(parsing: value,
                            answering: .pageActionChosen(page: "p", action: "run", values: .object([:]), selection: .null),
                            permits: PluginInterfaceContracts.host.permitting(manifest))
                    }
                    XCTAssertTrue(entry.valid, "Host unexpectedly accepted \(context)")
                } catch {
                    XCTAssertFalse(entry.valid, "Host unexpectedly refused \(context): \(error)")
                }
            }
        }
    }
}

final class JSONSchemaLogicTests: XCTestCase {
    func testNegationAlsoHandlesBooleanSchemas() {
        XCTAssertFalse(JSONSchemaSubsetValidator(schema: .object(["not": .bool(true)])).errors(for: .null).isEmpty)
        XCTAssertEqual(JSONSchemaSubsetValidator(schema: .object(["not": .bool(false)])).errors(for: .null), [])
        let noStrings = JSONSchemaSubsetValidator(schema: .object(["not": .object(["type": .string("string")])]))
        XCTAssertFalse(noStrings.errors(for: .string("forbidden")).isEmpty)
        XCTAssertEqual(noStrings.errors(for: .number(1)), [])
    }

    func testOnlyTheSelectedConditionalBranchApplies() {
        let validator = JSONSchemaSubsetValidator(schema: .object([
            "if": .object(["type": .string("string")]),
            "then": .object(["const": .string("accepted")]),
            "else": .object(["const": .number(7)])
        ]))
        XCTAssertEqual(validator.errors(for: .string("accepted")), [])
        XCTAssertEqual(validator.errors(for: .number(7)), [])
        XCTAssertFalse(validator.errors(for: .string("other")).isEmpty)
        XCTAssertFalse(validator.errors(for: .number(8)).isEmpty)
        let noCondition = JSONSchemaSubsetValidator(schema: .object(["then": .bool(false), "else": .bool(false)]))
        XCTAssertEqual(noCondition.errors(for: .null), [], "then and else have no effect without if")
    }

    func testExistingServiceCommandSchemasEnforceConditionalPackageSelectors() throws {
        let schemas = TestRepository.root.appendingPathComponent("PluginAPI/schemas")
        let terminal = try JSONSchemaSubsetValidator(schemaAt: schemas.appendingPathComponent("terminal-homebrew.schema.json"))
        XCTAssertEqual(terminal.errors(for: .object(["command": .string("services")])), [])
        XCTAssertFalse(terminal.errors(for: .object(["command": .string("services"), "package": .string("redis")])).isEmpty)
        XCTAssertEqual(terminal.errors(for: .object(["command": .string("services"), "action": .string("info"), "package": .string("redis")])), [])
        let output = try JSONSchemaSubsetValidator(definition: "input", inSchemaAt: schemas.appendingPathComponent("command-output.schema.json"))
        let base: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string("services")]
        XCTAssertEqual(output.errors(for: .object(base)), [])
        XCTAssertFalse(output.errors(for: .object(base.merging(["package": .string("redis")]) { _, new in new })).isEmpty)
        XCTAssertEqual(output.errors(for: .object(base.merging(["action": .string("info"), "package": .string("redis")]) { _, new in new })), [])
    }
}
