import Foundation
import XCTest
@testable import SpinnetCore

/// Plugin API Level 2 as `PluginAPI/` publishes it (#79): the catalogue, the
/// schemas, the fixtures, the types and the README, held to the Host, and
/// each held to the candidate revision it was promoted from, so that moving
/// the material into stable pages changed names and nothing else.
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

    // MARK: The catalogue

    func testTheHostsOperationsAreTheLevelTwoCatalogue() throws {
        let catalogue = object(try json("catalogue.json"))
        XCTAssertEqual(catalogue["level"], .number(2))
        let published = array(catalogue["operations"]).map(object)
        XCTAssertEqual(HostServiceCatalogue.operations.map(\.id), published.compactMap { string($0["id"]) })

        for (definition, operation) in zip(HostServiceCatalogue.operations, published) {
            let id = definition.id
            XCTAssertEqual(definition.isReserved, string(operation["status"]) == "reserved", id)
            XCTAssertEqual(definition.capabilities.map(\.rawValue), strings(operation["capabilities"]), id)
            XCTAssertEqual(definition.systemPermission?.rawValue, string(operation["system_permission"]), id)
            XCTAssertEqual(definition.failures.map(\.rawValue), strings(operation["failures"]), id)
            XCTAssertEqual(definition.primaryMember, string(operation["primary_member"]), id)
            let entryPoints = object(operation["entry_points"])
            XCTAssertEqual(Set(definition.entryPoints.keys.map(\.rawValue)), Set(entryPoints.keys), id)
            for (name, value) in entryPoints {
                let entryPoint = try XCTUnwrap(HostServiceEntryPoint(rawValue: name))
                let offering = definition.offering(at: entryPoint)
                switch string(object(value)["status"]) {
                case "level1":
                    guard case .offered(_, level1: true) = offering else { XCTFail("\(id) at \(name)"); continue }
                case "level2":
                    guard case .offered(_, level1: false) = offering else { XCTFail("\(id) at \(name)"); continue }
                case "reserved": XCTAssertEqual(offering, .reserved, "\(id) at \(name)")
                default: XCTAssertEqual(offering, .notOffered, "\(id) at \(name)")
                }
                XCTAssertNil(object(value)["candidate"], "Level 2 names no candidate: \(id) at \(name)")
            }
            if let input = string(operation["input"]) {
                XCTAssertTrue(input.hasPrefix("schemas/namespaces.schema.json#/$defs/"), id)
            }
        }
    }

    func testTheCatalogueFollowsItsSchema() throws {
        let validator = try JSONSchemaSubsetValidator(schemaAt: Self.pluginAPI.appendingPathComponent("schemas/catalogue.schema.json"))
        XCTAssertEqual(validator.errors(for: try json("catalogue.json")), [])
    }

    /// Level 2's catalogue is `namespaces` r1's with Level 2 in place of the
    /// candidates: every operation has the same authority, failures, targets,
    /// entry points and Level 1 names.
    func testTheCatalogueIsTheCandidatesCatalogueRenamed() throws {
        func normalized(_ operation: [String: JSONValue]) -> [String: JSONValue] {
            var kept = operation.filter { ["id", "namespace", "status", "capabilities", "system_permission", "failures",
                                           "primary_member", "targets", "level1", "default_title", "item_action",
                                           "closes_view"].contains($0.key) }
            if kept["status"] == .string("candidate") { kept["status"] = .string("level2") }
            kept["entry_points"] = .object(object(operation["entry_points"]).mapValues { entry in
                var members = object(entry).filter { ["status", "capabilities"].contains($0.key) }
                if members["status"] == .string("candidate") { members["status"] = .string("level2") }
                return .object(members)
            })
            for key in ["input", "result"] {
                kept[key] = operation[key].map { value in
                    string(value).map { .string($0.replacingOccurrences(of: "schemas/", with: "")) } ?? value
                }
            }
            return kept
        }
        let stable = array(object(try json("catalogue.json"))["operations"]).map { normalized(object($0)) }
        let candidate = array(object(try json("candidates/namespaces/r1/catalogue.json"))["operations"])
            .map { normalized(object($0)) }
        XCTAssertEqual(stable, candidate)
        XCTAssertEqual(object(try json("catalogue.json"))["capabilities"],
                       object(try json("candidates/namespaces/r1/catalogue.json"))["capabilities"])
    }

    // MARK: Schemas and fixtures

    /// Each Level 2 schema defines exactly what the candidate revision it was
    /// promoted from defined: only titles, descriptions and the paths of
    /// references changed.
    func testTheSchemasAreTheCandidatesSchemas() throws {
        func shape(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let members):
                var kept: [String: JSONValue] = [:]
                for (key, member) in members where !["description", "title"].contains(key) {
                    if key == "$ref", let reference = string(member) {
                        // A file beside it, or a candidate's in its own
                        // directory, by its name; Level 2 renamed one.
                        let parts = reference.components(separatedBy: "#")
                        let file = (parts[0].components(separatedBy: "/").last ?? "")
                            .replacingOccurrences(of: "collections.schema.json", with: "pages.schema.json")
                        kept[key] = .string(file + "#" + parts.dropFirst().joined(separator: "#"))
                        continue
                    }
                    kept[key] = shape(member)
                }
                return .object(kept)
            case .array(let values): return .array(values.map(shape))
            default: return value
            }
        }
        for (stable, candidate) in [("schemas/namespaces.schema.json", "candidates/namespaces/r1/namespaces.schema.json"),
                                    ("schemas/host-operations.schema.json",
                                     "candidates/host_operations/r2/host-operations.schema.json"),
                                    ("schemas/pages.schema.json", "candidates/collections/r3/collections.schema.json")] {
            XCTAssertEqual(shape(try json(stable)), shape(try json(candidate)), stable)
        }
        let catalogueSchema = object(try json("schemas/catalogue.schema.json"))
        XCTAssertEqual(object(catalogueSchema["properties"])["level"], .object([
            "description": .string("The stable Plugin API Level this catalogue describes."), "const": .number(2)
        ]))
    }

    private struct Fixture: Decodable {
        let file: String
        let definition: String
        let valid: Bool
        let note: String
    }

    /// The published fixtures are the promoted revisions' fixtures, file for
    /// file; each valid one follows its Level 2 schema, and the Host reads
    /// every answer as a Level 2 Plugin's exactly as the fixture says.
    func testTheFixturesAreTheCandidatesAndTheHostReadsThemAtLevelTwo() throws {
        let permits = CollectionsFixtures.permits
        for (stable, candidate, schema) in [("fixtures/pages", "candidates/collections/r3/fixtures", "pages.schema.json"),
                                            ("fixtures/host-operations", "candidates/host_operations/r2/fixtures",
                                             "host-operations.schema.json")] {
            struct Index: Decodable { let fixtures: [Fixture] }
            let fixtures = try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.pluginAPI
                .appendingPathComponent("\(stable)/index.json"))).fixtures
            let candidateFixtures = try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.pluginAPI
                .appendingPathComponent("\(candidate)/index.json"))).fixtures
            XCTAssertEqual(fixtures.map(\.file), candidateFixtures.map(\.file), stable)
            XCTAssertEqual(fixtures.map(\.valid), candidateFixtures.map(\.valid), stable)
            XCTAssertGreaterThan(fixtures.count, 20, stable)
            for fixture in fixtures {
                XCTAssertEqual(try Data(contentsOf: Self.pluginAPI.appendingPathComponent("\(stable)/\(fixture.file)")),
                               try Data(contentsOf: Self.pluginAPI.appendingPathComponent("\(candidate)/\(fixture.file)")),
                               fixture.file)
                let value = try json("\(stable)/\(fixture.file)")
                let validator = try JSONSchemaSubsetValidator(
                    definition: fixture.definition, inSchemaAt: Self.pluginAPI.appendingPathComponent("schemas/\(schema)"))
                if fixture.valid { XCTAssertEqual(validator.errors(for: value), [], "\(stable)/\(fixture.file)") }
                guard fixture.definition == "answer" else { continue }
                do {
                    let read = try PluginScriptAnswer(parsing: value, permits: permits)
                    if let view = read.view { _ = try PluginViewDescription(parsing: view, settingsFields: [], permits: permits) }
                    XCTAssertTrue(fixture.valid, "\(stable)/\(fixture.file) was accepted: \(fixture.note)")
                } catch {
                    XCTAssertFalse(fixture.valid, "\(stable)/\(fixture.file) was refused: \(error)")
                }
            }
        }
    }

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
