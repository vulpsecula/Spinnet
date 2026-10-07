import Foundation
import XCTest
@testable import SpinnetCore

/// The Host is held to the Plugin API catalogue (ADR 0020), Level 2's
/// `PluginAPI/catalogue.json`: its own table of operations has every
/// published ID with the same Capabilities, System Permission, failure
/// categories and entry points, the Level 1 names each replaces, and the
/// input members the schema gives it; and Level 2 offers exactly the
/// catalogue's calls and Commands.
final class HostServiceCatalogueTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    static let schemas = pluginAPI.appendingPathComponent("schemas")

    private func json(_ path: String) throws -> [String: JSONValue] {
        guard case .object(let document) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: Self.pluginAPI.appendingPathComponent(path))
        ) else { throw ConfigurationError.malformedValue("\(path) is not an object") }
        return document
    }

    private func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { if case .string(let text) = $0 { return text }; return nil }
    }

    private func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private func catalogueOperations() throws -> [[String: JSONValue]] {
        guard case .array(let operations)? = try json("catalogue.json")["operations"] else {
            throw ConfigurationError.malformedValue("catalogue.json lists no operations")
        }
        return operations.compactMap { if case .object(let operation) = $0 { return operation }; return nil }
    }

    /// The published IDs offered at `entryPoint`.
    private func ids(offeredAt entryPoint: String) throws -> [String] {
        try catalogueOperations().compactMap { operation in
            guard case .object(let entryPoints)? = operation["entry_points"],
                  case .object(let entry)? = entryPoints[entryPoint],
                  ["level1", "level2"].contains(string(entry["status"])) else { return nil }
            return string(operation["id"])
        }
    }

    func testTheHostsOperationsAreThePublishedCatalogue() throws {
        XCTAssertEqual(try json("catalogue.json")["level"], .number(2))
        let published = try catalogueOperations()
        XCTAssertEqual(HostServiceCatalogue.operations.map(\.id), published.compactMap { string($0["id"]) })

        for (definition, operation) in zip(HostServiceCatalogue.operations, published) {
            let id = definition.id
            XCTAssertEqual(definition.isReserved, string(operation["status"]) == "reserved", id)
            XCTAssertEqual(definition.namespace, string(operation["namespace"]), id)
            XCTAssertEqual(definition.capabilities.map(\.rawValue), strings(operation["capabilities"]), id)
            XCTAssertEqual(definition.systemPermission?.rawValue, string(operation["system_permission"]), id)
            XCTAssertEqual(definition.failures.map(\.rawValue), strings(operation["failures"]), id)
            XCTAssertEqual(definition.primaryMember, string(operation["primary_member"]), id)
            guard case .object(let entryPoints)? = operation["entry_points"] else { return XCTFail(id) }
            XCTAssertEqual(Set(definition.entryPoints.keys.map(\.rawValue)), Set(entryPoints.keys), id)
            for (name, value) in entryPoints {
                guard case .object(let entry) = value, let entryPoint = HostServiceEntryPoint(rawValue: name) else {
                    XCTFail("\(id) has an unknown entry point \(name)"); continue
                }
                let offering = definition.offering(at: entryPoint)
                switch string(entry["status"]) {
                case "level1":
                    guard case .offered(_, level1: true) = offering else { XCTFail("\(id) at \(name)"); continue }
                case "level2":
                    guard case .offered(_, level1: false) = offering else { XCTFail("\(id) at \(name)"); continue }
                case "reserved": XCTAssertEqual(offering, .reserved, "\(id) at \(name)")
                default: XCTAssertEqual(offering, .notOffered, "\(id) at \(name)")
                }
                if entryPoint == .command, entry["capabilities"] != nil {
                    XCTAssertEqual(definition.commandCapabilityOverride?.map(\.rawValue), strings(entry["capabilities"]), id)
                }
            }
            if case .object(let command)? = entryPoints["command"], command["capabilities"] == nil {
                XCTAssertNil(definition.commandCapabilityOverride, id)
            }
            let levelOne = (try? JSONDecoder().decode([[String: String]].self,
                                                      from: JSONEncoder().encode(operation["level1"] ?? .array([])))) ?? []
            XCTAssertEqual(definition.levelOneHostServices.map(\.rawValue),
                           levelOne.filter { $0["kind"] == "host_service" }.compactMap { $0["name"] }, id)
            XCTAssertEqual(definition.levelOneHostCommands.map(\.rawValue),
                           levelOne.filter { $0["kind"] == "host_command" }.compactMap { $0["name"] }, id)
        }
    }

    func testTheCatalogueFollowsItsSchema() throws {
        let validator = try JSONSchemaSubsetValidator(schemaAt: Self.schemas.appendingPathComponent("catalogue.schema.json"))
        XCTAssertEqual(validator.errors(for: .object(try json("catalogue.json"))), [])
    }

    /// Every Level 1 Host Service and Host Command has an ID, so a refusal
    /// can always name the one to use instead.
    func testEveryLevelOneNameHasAnID() {
        for service in PluginHostService.levelOne {
            XCTAssertEqual(HostServiceCatalogue.ids(replacing: service).count, 1, service.rawValue)
        }
        for command in HostCommand.allCases {
            XCTAssertFalse(HostServiceCatalogue.ids(replacing: command).isEmpty, command.rawValue)
        }
    }

    /// The members a Command's input may have are the ones the operation's
    /// schema definition declares, so a Command fixing or configuring one is
    /// checked against the published shape.
    func testCommandInputMembersAreTheSchemas() throws {
        let schemaURL = Self.schemas.appendingPathComponent("namespaces.schema.json")
        for definition in HostServiceCatalogue.operations where definition.isOffered(at: .command) {
            XCTAssertEqual(Set(definition.inputMembers),
                           try declaredMembers(of: .string("#/$defs/\(definition.id).input"), in: schemaURL),
                           definition.id)
            if let primary = definition.primaryMember {
                XCTAssertTrue(definition.inputMembers.contains(primary), definition.id)
            }
        }
    }

    /// The property names a schema reference allows, through `$ref`,
    /// `oneOf` and `allOf`, in this file or one beside it.
    private func declaredMembers(of reference: JSONValue, in file: URL) throws -> Set<String> {
        guard case .string(let target) = reference else { return [] }
        let parts = target.components(separatedBy: "#")
        let url = parts[0].isEmpty ? file : file.deletingLastPathComponent().appendingPathComponent(parts[0]).standardizedFileURL
        var node = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        for key in parts[1].split(separator: "/") {
            guard case .object(let members) = node, let next = members[String(key)] else { return [] }
            node = next
        }
        return try declaredMembers(in: node, of: url)
    }

    private func declaredMembers(in schema: JSONValue, of file: URL) throws -> Set<String> {
        guard case .object(let keywords) = schema else { return [] }
        var members = Set<String>()
        if case .object(let properties)? = keywords["properties"] { members.formUnion(properties.keys) }
        if let reference = keywords["$ref"] { members.formUnion(try declaredMembers(of: reference, in: file)) }
        for combinator in ["oneOf", "allOf"] {
            guard case .array(let schemas)? = keywords[combinator] else { continue }
            for nested in schemas { members.formUnion(try declaredMembers(in: nested, of: file)) }
        }
        return members
    }

    /// Level 2 lets a Plugin call exactly the catalogue's call IDs and run
    /// exactly its Command IDs, which the schema lists.
    func testLevelTwoOffersTheCataloguesCallsAndCommands() throws {
        let members = PluginInterfaceContracts.levelTwoMembers
        XCTAssertEqual(Set(members.filter { $0.kind == .hostService }.map(\.name)), Set(try ids(offeredAt: "call")))
        XCTAssertEqual(Set(members.filter { $0.kind == .hostCommand }.map(\.name)), Set(try ids(offeredAt: "command")))
        XCTAssertTrue(members.contains(HostServiceCatalogue.catalogueIDsOnly))
        let schema = try json("schemas/namespaces.schema.json")
        guard case .object(let definitions)? = schema["$defs"], case .object(let calls)? = definitions["call_id"],
              case .object(let commands)? = definitions["host_command_id"] else { return XCTFail("No ID lists") }
        XCTAssertEqual(strings(calls["enum"]), try ids(offeredAt: "call"))
        XCTAssertEqual(strings(commands["enum"]), try ids(offeredAt: "command"))
    }
}
