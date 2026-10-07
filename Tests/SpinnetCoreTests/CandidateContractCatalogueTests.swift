import Foundation
import XCTest
@testable import SpinnetCore

/// The Host's contracts are what it checks Plugins against: the members of
/// each stable Plugin API Level and the Candidate Contract revisions it
/// provides. They must agree with what `PluginAPI/` publishes, stable and
/// candidate material apart, so a Plugin author's reading of the interface
/// is the Host's.
final class CandidateContractCatalogueTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    private static let candidates = pluginAPI.appendingPathComponent("candidates")

    private func json(_ url: URL) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func strings(in value: JSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { if case .string(let text) = $0 { return text }; return nil }
    }

    private func definition(_ name: String, in schema: String, member: String) throws -> JSONValue? {
        guard case .object(let document) = try json(Self.pluginAPI.appendingPathComponent("schemas/\(schema)")),
              case .object(let definitions)? = document["$defs"], case .object(let definition)? = definitions[name],
              case .object(let properties)? = definition["properties"] else { return nil }
        return properties[member]
    }

    /// Every candidate revision `PluginAPI/candidates/<name>/r<revision>/`
    /// publishes.
    private func publishedCandidates() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.candidates, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "schemas" && $0.hasDirectoryPath }
            .flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .map { $0.appendingPathComponent("candidate.json") }
    }

    func testLevelOneIsWhatTheLevelOneCatalogueAndSchemasPublish() throws {
        let members = PluginInterfaceContracts.levelOneMembers
        func names(_ kind: PluginInterfaceMember.Kind) -> [String] {
            members.filter { $0.kind == kind }.map(\.name).sorted()
        }
        guard case .object(let viewSchema) = try json(Self.pluginAPI.appendingPathComponent("schemas/plugin-view.schema.json")),
              case .object(let viewDefinitions)? = viewSchema["$defs"], case .object(let view)? = viewDefinitions["view"],
              case .object(let viewMembers)? = view["properties"],
              case .object(let perform)? = try definition("action", in: "plugin-view.schema.json", member: "perform"),
              case .object(let type)? = try definition("event", in: "view-session.schema.json", member: "type"),
              case .object(let manifestSchema) = try json(Self.pluginAPI.appendingPathComponent("schemas/manifest.schema.json")),
              case .object(let manifestDefinitions)? = manifestSchema["$defs"],
              case .object(let hostCommand)? = manifestDefinitions["hostCommand"] else {
            return XCTFail("The view schemas do not describe their components")
        }

        XCTAssertEqual(names(.hostService), PluginHostService.levelOne.map(\.rawValue).sorted())
        XCTAssertEqual(names(.hostCommand), strings(in: hostCommand["enum"]).sorted())
        XCTAssertEqual(names(.request), [], "Level 1 has no Requested Host Operations")
        XCTAssertEqual(names(.viewComponent), viewMembers.keys.filter { $0 != "title" && $0 != "subtitle" }.sorted())
        XCTAssertEqual(names(.standardAction), strings(in: perform["enum"]).sorted())
        XCTAssertEqual(names(.viewEvent), strings(in: type["enum"]).sorted())
        XCTAssertEqual(names(.behaviour), [], "Level 1 behaviour is the published pages, not a declared member")
        XCTAssertEqual(PluginInterfaceContracts.host.levels[1], members)
        XCTAssertEqual(PluginInterfaceContracts.host.highestStableLevel, PluginAPILevel.highestSupported)
    }

    /// What the Host has retired is exactly what the candidate pages
    /// publish, revision by revision, each with the Level it became.
    func testTheHostsCandidatesAreThePublishedOnes() throws {
        let published = try publishedCandidates().map {
            try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: $0))
        }
        XCTAssertEqual(Set(published.map { "\($0.name) r\($0.revision)" }),
                       Set(PluginInterfaceContracts.host.candidates.map { "\($0.name) r\($0.revision)" }))
        for candidate in PluginInterfaceContracts.host.candidates {
            let page = try XCTUnwrap(published.first { $0.declaration == candidate.declaration })
            XCTAssertEqual(page.status, candidate.status, "\(candidate.name) r\(candidate.revision)")
            XCTAssertEqual(page.tag, candidate.tag)
        }
        for promoted in [HostServiceCatalogue.promoted, HostOperationsContract.promoted, CollectionsContract.promoted] {
            let page = try XCTUnwrap(published.first { $0.declaration == promoted.declaration })
            XCTAssertEqual(Set(page.members), Set(promoted.members), "Level 2 holds \(promoted.name)'s published members")
        }
        let provided = try PublishedTable.column(0, under: "## Candidate Contracts this Host provides",
                                                 in: "candidates/README.md")
        XCTAssertEqual(provided.sorted(), PluginInterfaceContracts.host.candidates
            .filter { $0.status == .supported }.map(\.name).sorted())
        let retired = try PublishedTable.column(0, under: "## Retired candidate declarations", in: "candidates/README.md")
        XCTAssertEqual(retired.sorted(), PluginInterfaceContracts.host.candidates
            .filter { $0.status != .supported }.map(\.name).sorted())
    }

    func testCandidateMetadataFollowsItsSchemaAndPinsItsTag() throws {
        let validator = try JSONSchemaSubsetValidator(
            schemaAt: Self.candidates.appendingPathComponent("schemas/candidate-metadata.schema.json")
        )
        for url in try publishedCandidates() + [CandidateProbeFixture.metadata] {
            XCTAssertEqual(validator.errors(for: try json(url)), [], url.path)
            let candidate = try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: url))
            XCTAssertEqual(candidate.tag, "plugin-api-candidate/\(candidate.name)/r\(candidate.revision)")
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "r\(candidate.revision)")
            XCTAssertEqual(try json(url), try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(candidate)
            ), "The Host reads and writes the metadata as published")
        }
        XCTAssertFalse(validator.errors(for: .object(["name": .string("language_probe"), "revision": .number(1)])).isEmpty)
    }

    /// A candidate may add a Command that runs a Host Service directly and a
    /// Requested Host Operation, each a member of its own kind, which the
    /// schema and the Host read alike; any other kind is refused by both.
    func testCandidateMetadataNamesCommandAndRequestMembers() throws {
        let validator = try JSONSchemaSubsetValidator(
            schemaAt: Self.candidates.appendingPathComponent("schemas/candidate-metadata.schema.json")
        )
        func metadata(_ kind: String) -> JSONValue {
            .object(["name": .string("operations_probe"), "revision": .number(1), "base_level": .number(1),
                     "requires": .array([]), "conflicts": .array([]),
                     "members": .array([.object(["kind": .string(kind), "name": .string("clipboard.write")])]),
                     "tag": .string("plugin-api-candidate/operations_probe/r1"), "status": .string("supported")])
        }
        for (kind, member) in [("host_command", PluginInterfaceMember.hostCommand("clipboard.write")),
                               ("request", PluginInterfaceMember.request("clipboard.write"))] {
            XCTAssertEqual(validator.errors(for: metadata(kind)), [], kind)
            let decoded = try JSONDecoder().decode(CandidateContract.self, from: JSONEncoder().encode(metadata(kind)))
            XCTAssertEqual(decoded.members, [member])
        }
        XCTAssertFalse(validator.errors(for: metadata("command")).isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(CandidateContract.self, from: JSONEncoder().encode(metadata("command"))))
    }

    /// The stable manifest schema is unchanged and refuses a candidate
    /// declaration; the candidate schema describes that one member, and the
    /// rest of the manifest is the stable one.
    func testACandidateManifestIsAStableManifestPlusItsDeclaration() throws {
        guard case .object(var manifest) = try json(
            CandidateProbeFixture.package.appendingPathComponent("manifest.json")
        ) else { return XCTFail("The probe's manifest is not an object") }
        let stable = try JSONSchemaSubsetValidator(schemaAt: Self.pluginAPI.appendingPathComponent("schemas/manifest.schema.json"))
        let candidate = try JSONSchemaSubsetValidator(
            schemaAt: Self.candidates.appendingPathComponent("schemas/candidate-contracts.schema.json")
        )

        XCTAssertEqual(stable.errors(for: .object(manifest)).map { $0.components(separatedBy: ":")[0] },
                       ["/candidate_contracts"])
        XCTAssertEqual(candidate.errors(for: .object(manifest)), [])
        for invalid: JSONValue in [
            .array([.object(["name": .string("language_probe"), "revision": .number(0)])]),
            .array([.object(["name": .string("Language Probe"), "revision": .number(1)])]),
            .array([.object(["name": .string("language_probe")])]),
            .array([])
        ] {
            manifest["candidate_contracts"] = invalid
            XCTAssertFalse(candidate.errors(for: .object(manifest)).isEmpty, "\(invalid)")
        }
        manifest["candidate_contracts"] = nil
        XCTAssertEqual(stable.errors(for: .object(manifest)), [])
    }

    /// The candidate pages are linked from the stable README, which keeps
    /// them apart from the Level 1 catalogue, and their links resolve.
    func testTheCandidatePagesAreLinkedAndTheirLinksResolve() throws {
        let readme = try String(contentsOf: Self.pluginAPI.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("(candidates/README.md)"))
        let page = Self.candidates.appendingPathComponent("README.md")
        let text = try String(contentsOf: page, encoding: .utf8)
        for file in try FileManager.default.contentsOfDirectory(
            at: Self.candidates.appendingPathComponent("schemas"), includingPropertiesForKeys: nil
        ).map(\.lastPathComponent) {
            XCTAssertTrue(text.contains("(schemas/\(file))"), "The candidate page does not link schemas/\(file)")
        }
        let link = try NSRegularExpression(pattern: #"\]\(([^)#:]+)(#[^)]*)?\)"#)
        for match in link.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let target = page.deletingLastPathComponent().appendingPathComponent(String(text[range])).standardizedFileURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "candidates/README.md links \(text[range])")
        }
    }

    /// Promotion is a Host change the tooling makes in one step: the
    /// candidate's members become the next Level and its revision is
    /// retired, remembered with the Level it became.
    func testPromotionRetiresTheRevisionIntoTheNextLevel() throws {
        let candidateHost = try CandidateProbeFixture.matchingHost()

        let stableHost = try candidateHost.promoting("language_probe", toLevel: 2)

        XCTAssertEqual(stableHost.levels[2], [CandidateProbeFixture.member])
        XCTAssertEqual(stableHost.levels[1], candidateHost.levels[1])
        XCTAssertEqual(stableHost.candidates.map(\.status), [.retired(promotedToLevel: 2)])
        XCTAssertThrowsError(try candidateHost.promoting("language_probe", toLevel: 3), "Levels are not skipped") {
            XCTAssertEqual($0 as? CandidateContractPromotionError, .notTheNextLevel(3, next: 2))
        }
        XCTAssertThrowsError(try candidateHost.promoting("unknown_probe", toLevel: 2)) {
            XCTAssertEqual($0 as? CandidateContractPromotionError, .notProvided(candidate: "unknown_probe"))
        }
        XCTAssertThrowsError(try stableHost.promoting("language_probe", toLevel: 3),
                             "A retired revision is not promoted again") {
            XCTAssertEqual($0 as? CandidateContractPromotionError, .notProvided(candidate: "language_probe"))
        }
    }

    /// A Host may provide several revisions of one candidate: a Plugin
    /// declaring any of them runs; one declaring another is refused with
    /// the latest named; and promotion gives the latest revision's members
    /// the next Level and retires every one.
    func testAHostMayProvideSeveralRevisionsOfOneCandidate() throws {
        let host = CandidateProbeFixture.host(offering: [try CandidateProbeFixture.contract(),
                                                         try CandidateProbeFixture.contract(revision: 2)])
        func probe(declaring revision: Int) throws -> PluginManifest {
            try ManifestVariant.manifest(of: CandidateProbeFixture.package,
                                         CandidateProbeFixture.declaring([("language_probe", revision)]))
        }
        for revision in [1, 2] {
            XCTAssertNoThrow(try host.check(probe(declaring: revision), origin: .installed))
        }
        let three = try probe(declaring: 3)
        XCTAssertThrowsError(try host.check(three, origin: .installed)) {
            XCTAssertEqual($0 as? CandidateContractRefusal,
                           .revisionMismatch(plugin: three.name, declared: three.candidateContracts[0], provided: 2))
        }

        let promoted = try host.promoting("language_probe", toLevel: 2)
        XCTAssertEqual(promoted.levels[2], [CandidateProbeFixture.member])
        XCTAssertEqual(promoted.candidates.map(\.status), [.retired(promotedToLevel: 2), .retired(promotedToLevel: 2)])
        let one = try probe(declaring: 1)
        XCTAssertThrowsError(try promoted.check(one, origin: .installed)) {
            XCTAssertEqual($0 as? CandidateContractRefusal,
                           .retired(plugin: one.name, declared: one.candidateContracts[0], promotedToLevel: 2))
        }
    }
}
