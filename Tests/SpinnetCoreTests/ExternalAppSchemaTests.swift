import Foundation
import XCTest
@testable import SpinnetCore

/// `PluginAPI/schemas/external-apps.schema.json` publishes the inputs of
/// `perform_app_operation` and `open_deep_link` (ADR 0012), and every
/// Reviewed App Interface the Host ships. A Reviewed App Interface must accept
/// exactly the operations the schema publishes for it.
final class ExternalAppSchemaTests: XCTestCase {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/external-apps.schema.json")

    private func definitions() throws -> [String: JSONValue] {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.schemaURL))
        guard case .object(let document) = schema, case .object(let definitions)? = document["$defs"] else {
            throw ConfigurationError.malformedValue("The schema has no $defs")
        }
        return definitions
    }

    /// Adding a Reviewed App Interface is a Host release, and it is not
    /// published until the schema names it.
    func testTheSchemaPublishesEveryReviewedAppInterface() throws {
        guard case .object(let listing)? = try definitions()["reviewed_app_interfaces"],
              case .object(let interfaces)? = listing["$defs"] else {
            return XCTFail("The schema lists no Reviewed App Interfaces")
        }
        XCTAssertEqual(Set(interfaces.keys), Set(ReviewedAppInterface.reviewed.map(\.bundleID)))
    }

    func testEachReviewedAppInterfaceAcceptsExactlyThePublishedOperations() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "perform_app_operation.input", inSchemaAt: Self.schemaURL)
        for interface in ReviewedAppInterface.reviewed {
            var candidates: [(String, [String: JSONValue]?)] = [("reviewCode", nil), ("", nil)]
            for operation in interface.operations {
                let arguments = Dictionary(uniqueKeysWithValues: operation.parameters.map {
                    ($0.key, JSONValue.string("Hello"))
                })
                candidates += [
                    (operation.name, nil), (operation.name, arguments),
                    (operation.name, arguments.merging(["extra": .string("x")]) { _, new in new }),
                    (operation.name, arguments.mapValues { _ in .string("  ") }),
                    (operation.name, arguments.mapValues { _ in .number(1) })
                ]
            }
            for (operation, arguments) in candidates {
                var input: [String: JSONValue] = ["bundle_id": .string(interface.bundleID), "operation": .string(operation)]
                input["arguments"] = arguments.map(JSONValue.object)
                let schemaAccepts = schema.errors(for: .object(input)).isEmpty
                let hostAccepts = (try? interface.request(operation: operation, arguments: arguments ?? [:])) != nil
                XCTAssertEqual(hostAccepts, schemaAccepts, "\(interface.name) \(operation) with \(String(describing: arguments))")
            }
        }
    }

    func testOperationInputsOfTheWrongShapeAreNotPublished() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "perform_app_operation.input", inSchemaAt: Self.schemaURL)
        let refused: [JSONValue] = [
            .object(["operation": .string("translateText")]),
            .object(["bundle_id": .string("com.example.app")]),
            .object(["bundle_id": .string("com.example.app"), "operation": .string("run"), "script": .string("x")]),
            .object(["bundle_id": .string("com.example.app"), "operation": .string("run"), "arguments": .array([])]),
            .string("translateText")
        ]
        for input in refused {
            XCTAssertFalse(schema.errors(for: input).isEmpty, "\(input)")
        }
    }

    func testEveryDeepLinkTheHostOpensIsOfThePublishedShape() throws {
        let schema = try JSONSchemaSubsetValidator(definition: "open_deep_link.input", inSchemaAt: Self.schemaURL)
        let scope = try XCTUnwrap(DeepLinkTemplateTests.manifest().scope(for: .controlExternalApp))
        let candidates: [(String, [String: JSONValue])] = [
            ("new", [:]), ("search", ["query": .string("groceries")]), ("open", ["folder": .string("archive")]),
            // Refused:
            ("search", ["query": .number(1)]), ("open", ["folder": .bool(true)])
        ]
        for (template, parameters) in candidates {
            let input = JSONValue.object(["template": .string(template), "parameters": .object(parameters)])
            let hostAccepts = (try? scope.deepLink(template: template, parameters: parameters)) != nil
            if hostAccepts {
                XCTAssertEqual(schema.errors(for: input), [], "\(input)")
            } else {
                XCTAssertFalse(schema.errors(for: input).isEmpty, "\(input)")
            }
        }
        for input: JSONValue in [
            .object(["parameters": .object([:])]),
            .object(["template": .string("new"), "url": .string("notes-example://note/new")]),
            .object(["template": .string("note new")]),
            .string("new")
        ] {
            XCTAssertFalse(schema.errors(for: input).isEmpty, "\(input)")
        }
    }

    func testBothServicesAnswerNull() throws {
        let definitions = try definitions()
        XCTAssertEqual(definitions["perform_app_operation.result"], .object(["type": .string("null")]))
        XCTAssertEqual(definitions["open_deep_link.result"], .object(["type": .string("null")]))
    }
}
