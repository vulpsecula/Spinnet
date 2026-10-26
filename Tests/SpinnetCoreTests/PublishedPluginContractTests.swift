import SpinnetTestSupport
import Foundation
import XCTest
@testable import SpinnetCore

/// Published manifest, types, SDK and navigation stay aligned with the Host.
final class PublishedPluginContractTests: XCTestCase {
    private static let pluginAPI = TestRepository.root
        .appendingPathComponent("PluginAPI")

    private func json(_ path: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.pluginAPI.appendingPathComponent(path)))
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let members)? = value { return members }
        return [:]
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let values)? = value { return values }
        return []
    }

    private func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private func strings(_ value: JSONValue?) -> [String] { array(value).compactMap(string) }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.pluginAPI.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Manifests

    /// Only current declarations and catalogue command IDs are admitted.
    func testTheManifestSchemaAdmitsCurrentCommandsAndRefusesRetiredDeclarations() throws {
        let validator = try JSONSchemaSubsetValidator(schemaAt: Self.pluginAPI.appendingPathComponent("schemas/manifest.schema.json"))
        for package in [CollectionsFixtures.emoji, CollectionsFixtures.brew, OperationsProbeFixture.package, NamespacesProbeFixture.package] {
            let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
            XCTAssertEqual(validator.errors(for: manifest), [], package.lastPathComponent)
        }
        let fields: [String: JSONValue] = [
            "protocol_version": .string("1.0"), "engines": .object(["spinnet": .string("^1.0.0")]),
            "id": .string("com.example.m"), "name": .string("M"), "version": .string("1.0.0"),
            "commands": .array([.object(["id": .string("m.open"), "title": .string("Open"), "execution": .string("host"), "host_command": .string("open.url")])])
        ]
        XCTAssertEqual(validator.errors(for: .object(fields)), [])
        for key in ["api_level", "candidate_contracts"] {
            var retired = fields; retired[key] = .null
            XCTAssertFalse(validator.errors(for: .object(retired)).isEmpty, key)
        }
        var missing = fields; missing["engines"] = nil
        XCTAssertFalse(validator.errors(for: .object(missing)).isEmpty)
        var internalCommand = fields
        internalCommand["commands"] = .array([.object(["id": .string("m.open"), "title": .string("Open"), "execution": .string("host"), "host_command": .string("url.open")])])
        XCTAssertFalse(validator.errors(for: .object(internalCommand)).isEmpty)
    }

    // MARK: Types, SDK and pages

    /// The types tag every function with the ID it reaches and the entry
    /// points it offers, and their ID unions are the catalogue's.
    func testTheTypesNameEveryIDAtItsEntryPoints() throws {
        let types = try text("sdk/spinnet.d.ts")
        func ids(at entryPoint: HostServiceEntryPoint) -> [String] {
            HostServiceCatalogue.operations.filter { $0.isOffered(at: entryPoint) }.map(\.id)
        }
        func matches(_ pattern: String) throws -> [String] {
            let expression = try NSRegularExpression(pattern: pattern)
            return expression.matches(in: types, range: NSRange(types.startIndex..., in: types)).compactMap {
                Range($0.range(at: 1), in: types).map { String(types[$0]) }
            }
        }
        func union(_ name: String) throws -> [String] {
            let start = try XCTUnwrap(types.range(of: "export type \(name) =")).upperBound
            let end = try XCTUnwrap(types[start...].range(of: ";")).lowerBound
            let expression = try NSRegularExpression(pattern: #""([\w.]+)""#)
            let text = String(types[start..<end])
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        XCTAssertEqual(try matches(#"@id ([\w.]+) @entry call\b"#), ids(at: .call))
        XCTAssertEqual(try union("CallID"), ids(at: .call))
        XCTAssertEqual(try union("HostCommandID"), ids(at: .command))
        XCTAssertEqual(try union("RequestID"), ids(at: .request))
        XCTAssertEqual(ids(at: .viewAction), ids(at: .request), "ViewActionID is RequestID")
        XCTAssertEqual(Set(try matches(#"@id ([\w.]+) @entry [\w ]*\brequest\b"#)), Set(ids(at: .request)))
        XCTAssertEqual(Set(try matches(#"@id ([\w.]+) @entry [\w ]*\bview_action\b"#)), Set(ids(at: .viewAction)))
    }

    /// The SDK's lists of IDs are the catalogue's.
    func testTheSDKHoldsTheCataloguesIDs() throws {
        let sdk = try text("sdk/spinnet.js")
        func listed(_ name: String) throws -> [String] {
            let start = try XCTUnwrap(sdk.range(of: "const \(name) = {")).upperBound
            let end = try XCTUnwrap(sdk[start...].range(of: "};")).lowerBound
            var ids: [String] = []
            for line in sdk[start..<end].split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let namespace = parts[0].trimmingCharacters(in: .whitespaces)
                let expression = try NSRegularExpression(pattern: #""(\w+)""#)
                let verbs = String(parts[1])
                ids += expression.matches(in: verbs, range: NSRange(verbs.startIndex..., in: verbs)).compactMap {
                    Range($0.range(at: 1), in: verbs).map { "\(namespace).\(verbs[$0])" }
                }
            }
            return ids
        }
        XCTAssertEqual(try listed("calls"), HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id))
        XCTAssertEqual(try listed("performed"), HostOperationsContract.requestIDs)
        XCTAssertEqual(try listed("performed"), CollectionsContract.viewActionIDs)
    }

    /// The interface overview table lists every operation offered somewhere,
    /// and the reference names every ID.
    func testTheReadmeAndReferenceListEveryOperation() throws {
        let offered = HostServiceCatalogue.operations.filter { !$0.isReserved }.map(\.id)
        XCTAssertEqual(try PublishedTable.column(1, under: "### Host Services, by ID", in: "reference/overview.md"), offered)
        let reference = try text("reference/namespaces.md")
        for operation in HostServiceCatalogue.operations {
            XCTAssertTrue(reference.contains("`\(operation.id)`"), "reference/namespaces.md does not name \(operation.id)")
        }
        let pages = try PublishedTable.column(0, under: "### Pages, in `spinnet.ui.components`", in: "reference/overview.md")
        XCTAssertEqual(Set(pages), Set(PluginPageComponent.Kind.allCases.filter { PluginInterfaceContracts.currentMembers.contains(.viewComponent($0.rawValue)) }.map(\.rawValue)))
    }

    /// Public files stay reachable through the published navigation; the
    /// entry page can link a topic index instead of every individual file.
    func testTheCurrentFilesAreLinked() throws {
        let reachable = try PublishedPluginDocumentation.reachableFiles()
        for file in ["catalogue.json", "sdk/spinnet.js", "sdk/spinnet.d.ts", "fixtures/pages/index.json",
                     "fixtures/host-operations/index.json", "reference/namespaces.md", "reference/host-operations.md",
                     "reference/pages.md", "reference/compatibility.md", "reference/compatibility.md"] {
            XCTAssertTrue(reachable.contains(file), "No navigation path reaches \(file)")
        }
    }
}
