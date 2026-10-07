import Foundation
import XCTest
@testable import SpinnetCore

/// Plugin API Level 2 as `PluginAPI/` publishes it (#79): the manifest
/// schema, the types, the SDK, the README and the reference, held to the
/// Host. The catalogue, pages and Requested Host Operations have their own
/// tests: `HostServiceCatalogueTests`, `PagesContractTests` and
/// `HostOperationsContractTests`.
final class LevelTwoPublishedContractTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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

    /// The manifest schema holds a Level 2 manifest's Commands to catalogue
    /// IDs and a Level 1 manifest's to Level 1's Host Commands, and refuses
    /// `candidate_contracts`.
    func testTheManifestSchemaReadsEachLevelsCommands() throws {
        let validator = try JSONSchemaSubsetValidator(schemaAt: Self.pluginAPI.appendingPathComponent("schemas/manifest.schema.json"))
        for package in [CollectionsFixtures.emoji, CollectionsFixtures.brew, OperationsProbeFixture.package,
                        NamespacesProbeFixture.package] {
            let manifest = try JSONDecoder().decode(JSONValue.self,
                                                    from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
            XCTAssertEqual(validator.errors(for: manifest), [], package.lastPathComponent)
        }
        func manifest(level: Int, hostCommand: String, candidates: Bool = false) -> JSONValue {
            var members: [String: JSONValue] = [
                "protocol_version": .string("1.0"), "api_level": .number(Double(level)), "id": .string("com.example.m"),
                "name": .string("M"), "version": .string("1.0.0"),
                "commands": .array([.object(["id": .string("m.open"), "title": .string("Open"), "execution": .string("host"),
                                             "host_command": .string(hostCommand)])])
            ]
            if candidates {
                members["candidate_contracts"] = .array([.object(["name": .string("namespaces"), "revision": .number(1)])])
            }
            return .object(members)
        }
        XCTAssertEqual(validator.errors(for: manifest(level: 1, hostCommand: "url.open")), [])
        XCTAssertEqual(validator.errors(for: manifest(level: 2, hostCommand: "open.url")), [])
        XCTAssertNotEqual(validator.errors(for: manifest(level: 2, hostCommand: "url.open")), [])
        XCTAssertNotEqual(validator.errors(for: manifest(level: 1, hostCommand: "open.url")), [])
        XCTAssertNotEqual(validator.errors(for: manifest(level: 1, hostCommand: "url.open", candidates: true)), [])
    }

    // MARK: Types, SDK and pages

    /// The types tag every function with the ID it reaches and the entry
    /// points it offers, and their ID unions are the catalogue's.
    func testTheTypesNameEveryIDAtItsEntryPoints() throws {
        let types = try text("spinnet-level-2.d.ts")
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
        let sdk = try text("spinnet-level-2.js")
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

    /// The README's Level 2 table lists every operation offered somewhere,
    /// and the reference names every ID.
    func testTheReadmeAndReferenceListEveryOperation() throws {
        let offered = HostServiceCatalogue.operations.filter { !$0.isReserved }.map(\.id)
        XCTAssertEqual(try PublishedTable.column(1, under: "### Host Services, by ID", in: "README.md"), offered)
        let reference = try text("reference/namespaces.md")
        for operation in HostServiceCatalogue.operations {
            XCTAssertTrue(reference.contains("`\(operation.id)`"), "reference/namespaces.md does not name \(operation.id)")
        }
        let pages = try PublishedTable.column(0, under: "### Pages, in `spinnet.ui.components`", in: "README.md")
        XCTAssertEqual(Set(pages), Set(PluginPageComponent.Kind.allCases.map(\.rawValue)))
    }

    /// The Level 2 pages link what exists, and every Level 2 file is linked
    /// from the README.
    func testTheLevelTwoFilesAreLinked() throws {
        let readme = try text("README.md")
        for file in ["catalogue.json", "spinnet-level-2.js", "spinnet-level-2.d.ts", "fixtures/pages/index.json",
                     "fixtures/host-operations/index.json"] {
            XCTAssertTrue(readme.contains("(\(file))"), "The README does not link \(file)")
        }
        let link = try NSRegularExpression(pattern: #"\]\(([^)#:]+)(#[^)]*)?\)"#)
        for page in ["reference/namespaces.md", "reference/host-operations.md", "reference/pages.md",
                     "reference/level-1-names.md", "candidates/README.md"] {
            let url = Self.pluginAPI.appendingPathComponent(page)
            let content = try text(page)
            for match in link.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                guard let range = Range(match.range(at: 1), in: content) else { continue }
                let target = url.deletingLastPathComponent().appendingPathComponent(String(content[range])).standardizedFileURL
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "\(page) links \(content[range])")
            }
        }
    }
}
