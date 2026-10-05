import Foundation
import XCTest
@testable import SpinnetCore

/// Candidate Contract `host_operations` r2 as published under
/// `PluginAPI/candidates/host_operations/r2/` and as the Host reads it:
/// revision 1 with `operation_finished` delivered after the view closed.
final class HostOperationsRevisionTwoContractTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    private static let published = pluginAPI.appendingPathComponent("candidates/host_operations/r2")
    private static let first = pluginAPI.appendingPathComponent("candidates/host_operations/r1")
    private static let schema = published.appendingPathComponent("host-operations.schema.json")

    private struct Fixture: Decodable {
        let file: String
        let definition: String
        let valid: Bool
        let note: String
    }

    private func fixtures() throws -> [Fixture] {
        struct Index: Decodable { let fixtures: [Fixture] }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.published.appendingPathComponent("fixtures/index.json")))
            .fixtures
    }

    private func value(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.published.appendingPathComponent("fixtures/\(file)")))
    }

    /// What a Plugin declaring `host_operations` r2 and `namespaces` r1 may use.
    private static var permits: (PluginInterfaceMember) -> Bool {
        let data = try! Data(contentsOf: OperationsProbeFixture.package.appendingPathComponent("manifest.json"))
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"{"name": "host_operations", "revision": 1}"#,
                                  with: #"{"name": "host_operations", "revision": 2}"#)
        let manifest = try! PluginManifestLoader.decode(Data(text.utf8))
        precondition(manifest.candidateContracts.contains(HostOperationsContract.revisionTwoDeclaration))
        return PluginInterfaceContracts.host.permitting(manifest)
    }

    func testThePublishedRevisionIsTheHosts() throws {
        let published = try JSONDecoder().decode(CandidateContract.self,
                                                 from: Data(contentsOf: Self.published.appendingPathComponent("candidate.json")))
        XCTAssertEqual(published, HostOperationsContract.revisionTwo)
        XCTAssertEqual(Set(published.members).subtracting(HostOperationsContract.candidate.members),
                       [HostOperationsContract.outcomeAfterClose])
        XCTAssertTrue(Set(HostOperationsContract.candidate.members).isSubset(of: published.members))
        XCTAssertTrue(PluginInterfaceContracts.host.candidates.contains(HostOperationsContract.candidate),
                      "Revision 1 is still provided")
        XCTAssertTrue(Self.permits(HostOperationsContract.outcomeAfterClose))
        XCTAssertFalse(HostOperationsContractTests.permits(HostOperationsContract.outcomeAfterClose))
    }

    func testThePublishedFixturesFollowTheSchema() throws {
        for fixture in try fixtures() {
            let validator = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: Self.schema)
            let errors = validator.errors(for: try value(fixture.file))
            XCTAssertEqual(errors.isEmpty, fixture.valid, "\(fixture.file): \(fixture.note) \(errors)")
        }
    }

    /// Revision 1's fixtures stay, unchanged, beside the new ones.
    func testRevisionOnesFixturesStay() throws {
        for folder in ["answers", "events"] {
            let one = Set(try FileManager.default.contentsOfDirectory(atPath: Self.first.appendingPathComponent("fixtures/\(folder)").path))
            let two = Set(try FileManager.default.contentsOfDirectory(atPath: Self.published.appendingPathComponent("fixtures/\(folder)").path))
            XCTAssertTrue(one.isSubset(of: two), folder)
            for file in one {
                XCTAssertEqual(try Data(contentsOf: Self.first.appendingPathComponent("fixtures/\(folder)/\(file)")),
                               try Data(contentsOf: Self.published.appendingPathComponent("fixtures/\(folder)/\(file)")), file)
            }
        }
    }

    func testTheHostReadsThePublishedAnswersAsTheSchemaDoes() throws {
        for fixture in try fixtures() where fixture.definition == "answer" {
            do {
                let read = try PluginScriptAnswer(parsing: value(fixture.file), permits: Self.permits)
                if let view = read.view { _ = try PluginViewDescription(parsing: view, settingsFields: [], permits: Self.permits) }
                XCTAssertTrue(fixture.valid, "\(fixture.file) was accepted: \(fixture.note)")
            } catch {
                XCTAssertFalse(fixture.valid, "\(fixture.file) was refused: \(error)")
            }
        }
    }

    /// Every outcome the Host can deliver after a view closed follows the
    /// schema; a cancelled operation never is, and the schema says so.
    func testEveryOutcomeAfterCloseFollowsTheSchema() throws {
        let validator = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        var outcomes: [HostOperationOutcome] = [.succeeded]
        outcomes += HostOperationReason.allCases.flatMap { [HostOperationOutcome.refused($0), .failed($0)] }
        for outcome in outcomes {
            let event = PluginViewEvent.operationFinished(id: "insert", perform: "selection.replace", outcome: outcome,
                                                          viewClosed: true)
            XCTAssertEqual(validator.errors(for: event.json), [], "\(outcome)")
            XCTAssertFalse(event.isGesture)
        }
        XCTAssertFalse(validator.errors(for: PluginViewEvent.operationFinished(
            id: nil, perform: "clipboard.write", outcome: .cancelled, viewClosed: true).json).isEmpty)
    }

    /// The reference, types and README name what revision 2 adds; its SDK
    /// is revision 1's.
    func testTheReferenceAndTypesNameTheAddition() throws {
        let reference = try String(contentsOf: Self.published.appendingPathComponent("reference.md"), encoding: .utf8)
        let types = try String(contentsOf: Self.published.appendingPathComponent("host-operations.d.ts"), encoding: .utf8)
        XCTAssertTrue(reference.contains("`outcome_after_close`"))
        XCTAssertTrue(reference.contains("\"view_closed\": true"))
        XCTAssertTrue(types.contains("view_closed?: true"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.published.appendingPathComponent("host_operations.js").path),
                       "Revision 2 adds no builder")
        for id in HostOperationsContract.requestIDs { XCTAssertTrue(reference.contains("`\(id)`"), id) }
        let readme = try String(contentsOf: Self.pluginAPI.appendingPathComponent("candidates/README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("host_operations/r2/"))
    }
}
