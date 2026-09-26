import Foundation
import XCTest
@testable import SpinnetCore

/// `PluginAPI/schemas/plugin-storage.schema.json` publishes the shapes of the
/// Plugin Storage Host Services. The Host must accept exactly the inputs the
/// schema accepts, and answer only with results the schema describes.
final class PluginStorageSchemaTests: XCTestCase {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI/schemas/plugin-storage.schema.json")

    private let pluginID = PluginID("com.example.schema")

    private func validator(for definition: String) throws -> JSONSchemaSubsetValidator {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.schemaURL))
        guard case .object(let document) = schema, case .object(let definitions)? = document["$defs"] else {
            throw XCTSkip("The schema has no $defs")
        }
        XCTAssertNotNil(definitions[definition], "The schema defines \(definition)")
        return JSONSchemaSubsetValidator(schema: .object([
            "$ref": .string("#/$defs/\(definition)"), "$defs": .object(definitions)
        ]))
    }

    private func makeStorage() -> PluginStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginStorageSchema-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PluginStorage(directory: directory)
    }

    func testTheHostAcceptsExactlyTheInputsTheSchemaAccepts() throws {
        let storage = makeStorage()
        let longest = String(repeating: "k", count: 128)
        let tooLong = String(repeating: "k", count: 129)
        let inputs: [PluginHostService: [JSONValue]] = [
            .getStorageValue: [.string("a"), .string(longest), .string(""), .string(tooLong), .null,
                               .object(["key": .string("a")]), .number(1)],
            .setStorageValue: [
                .object(["key": .string("a"), "value": .number(1)]),
                .object(["key": .string(longest), "value": .object(["nested": .array([.bool(true)])])]),
                .object(["key": .string("a"), "value": .null]),
                .object(["key": .string("a")]),
                .object(["value": .number(1)]),
                .object(["key": .string(""), "value": .number(1)]),
                .object(["key": .string(tooLong), "value": .number(1)]),
                .object(["key": .number(1), "value": .number(1)]),
                .object(["key": .string("a"), "value": .number(1), "extra": .null]),
                .string("a"), .null
            ],
            .removeStorageValue: [.string("a"), .string(""), .string(tooLong), .null],
            .listStorageKeys: [.null, .string("a"), .object([:])],
            .clearStorage: [.null, .string("a"), .object([:])]
        ]

        for (service, candidates) in inputs {
            let schema = try validator(for: "\(service.rawValue).input")
            for input in candidates {
                let schemaAccepts = schema.errors(for: input).isEmpty
                var hostAccepts = true
                do {
                    _ = try storage.answer(service, input: input, for: pluginID)
                } catch PluginHostServiceError.invalidInput {
                    hostAccepts = false
                }
                XCTAssertEqual(hostAccepts, schemaAccepts, "\(service.rawValue) with \(input)")
            }
        }
    }

    func testTheHostsResultsMatchTheSchema() throws {
        let storage = makeStorage()
        func answer(_ service: PluginHostService, _ input: JSONValue = .null) throws {
            let result = try storage.answer(service, input: input, for: pluginID)
            XCTAssertEqual(try validator(for: "\(service.rawValue).result").errors(for: result), [],
                           "\(service.rawValue) answered \(result)")
        }

        try answer(.getStorageValue, .string("missing"))
        try answer(.setStorageValue, .object(["key": .string("Count"), "value": .number(1)]))
        try answer(.setStorageValue, .object(["key": .string("count"), "value": .string("x")]))
        try answer(.getStorageValue, .string("count"))
        try answer(.listStorageKeys)
        try answer(.removeStorageValue, .string("count"))
        try answer(.clearStorage)
        try answer(.listStorageKeys)
    }

    /// The published key limit is the one the Host enforces.
    func testTheSchemasKeyLengthIsTheHostsLimit() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.schemaURL))
        guard case .object(let document) = schema, case .object(let definitions)? = document["$defs"],
              case .object(let key)? = definitions["key"] else {
            return XCTFail("The schema defines no key")
        }
        XCTAssertEqual(key["maxLength"], .number(Double(PluginStorageBudgets.maximumKeyLength)))
        XCTAssertEqual(key["minLength"], .number(1))
    }
}
