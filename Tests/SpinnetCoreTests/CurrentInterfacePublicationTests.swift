import SpinnetTestSupport
import Foundation
import XCTest
@testable import SpinnetCore

/// One current catalogue describes the same operation entry points and value
/// shapes the Host admits; version ranges never choose an older vocabulary.
final class CurrentInterfacePublicationTests: XCTestCase {
    private static let api = TestRepository.root.appendingPathComponent("PluginAPI")
    private func json(_ path: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.api.appendingPathComponent(path)))
    }
    func testCurrentCatalogueAndHostOfferTheSameOperationsAtEveryEntryPoint() throws {
        let catalogue = try json("catalogue.json")
        XCTAssertEqual(catalogue.value(atPointer: "/host_version"), .string(HostVersion.currentString))
        guard case .array(let values)? = catalogue.value(atPointer: "/operations") else { return XCTFail("Missing operations") }
        let published = try values.map { value -> String in
            guard case .string(let id)? = value.value(atPointer: "/id") else { throw CocoaError(.coderInvalidValue) }
            let operation = try XCTUnwrap(HostServiceCatalogue.operation(id), id)
            for point in HostServiceEntryPoint.allCases {
                let status = value.value(atPointer: "/entry_points/\(point.rawValue)/status")
                let offered = status == .string("offered")
                XCTAssertEqual(operation.isOffered(at: point), offered, "\(id) at \(point.rawValue): \(String(describing: status))")
            }
            return id
        }
        XCTAssertEqual(Set(published), Set(HostServiceCatalogue.operations.map(\.id)))
        XCTAssertEqual(published.count, Set(published).count, "Catalogue IDs remain unique")
        let schema = try JSONSchemaSubsetValidator(schemaAt: Self.api.appendingPathComponent("schemas/catalogue.schema.json"))
        XCTAssertEqual(schema.errors(for: catalogue), [])
    }
    func testPublishedFormDetailActionsAndEventsAreCurrentMembers() throws {
        let views = try json("schemas/plugin-view.schema.json")
        let session = try json("schemas/view-session.schema.json")
        for (document, pointer, kind) in [
            (views, "/$defs/action/properties/perform/enum", PluginInterfaceMember.Kind.standardAction),
            (session, "/$defs/event/properties/type/enum", .viewEvent)
        ] {
            guard case .array(let values)? = document.value(atPointer: pointer) else { return XCTFail(pointer) }
            for value in values {
                guard case .string(let name) = value else { return XCTFail(pointer) }
                XCTAssertTrue(PluginInterfaceContracts.host.members.contains(.init(kind: kind, name: name)), name)
            }
        }
        guard case .object(let fields)? = views.value(atPointer: "/$defs/view/properties") else { return XCTFail("Missing view") }
        for name in fields.keys where name != "title" && name != "subtitle" {
            XCTAssertTrue(PluginInterfaceContracts.host.members.contains(.viewComponent(name)), name)
        }
    }
    func testMemberKindsRoundTripAndUnknownKindsAreRefused() throws {
        for member in [PluginInterfaceMember.hostCommand("clipboard.write"), .request("clipboard.write"),
                       .hostService("clipboard.write"), .behaviour("catalogue_ids_only")] {
            XCTAssertEqual(try JSONDecoder().decode(PluginInterfaceMember.self, from: JSONEncoder().encode(member)), member)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PluginInterfaceMember.self,
            from: Data(#"{"kind":"command","name":"clipboard.write"}"#.utf8)))
    }
    func testCurrentManifestSchemaAndLoaderBothRefuseRetiredDeclarations() throws {
        let schema = try JSONSchemaSubsetValidator(schemaAt: Self.api.appendingPathComponent("schemas/manifest.schema.json"))
        let source = try CandidateProbeFixture.write()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        XCTAssertEqual(schema.errors(for: value), [])
        guard case .object(let original) = value else { return XCTFail("Expected manifest") }
        for key in ["api_level", "candidate_contracts"] {
            for retiredValue in [JSONValue.null, .array([]), .number(1)] {
                var fields = original; fields[key] = retiredValue; value = .object(fields)
                XCTAssertFalse(schema.errors(for: value).isEmpty, key)
                XCTAssertThrowsError(try PluginManifestLoader.decode(JSONEncoder().encode(value)), key)
            }
        }
    }
}
