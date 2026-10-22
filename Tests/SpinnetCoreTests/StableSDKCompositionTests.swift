import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// Public examples pass through the same SDK composition and helper used by
/// Plugins. The shared matrix then checks their actual wire shapes and parser.
final class StableSDKCompositionTests: XCTestCase {
    private static let api = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    private struct Check: Decodable { let schema: String; let definition: String?; let level: Int; let valid: Bool }
    private struct Fixture: Decodable {
        let name: String; let value: JSONValue; let checks: [Check]
        let sdk_script: String?; let sdk_level: Int?
    }
    private struct Index: Decodable { let cases: [Fixture] }

    private func plugin(at root: URL, level: Int, candidates: [CandidateContractRevision] = [], script: String) throws -> PluginUnderTest {
        let manifest = try PluginManifest(apiLevel: level, candidateContracts: candidates,
            id: .init("com.example.sdk-composition"), name: "SDK composition", version: "1.0", commands: [
                .init(id: .init("show"), title: "Show", execution: .javascript, script: "show.js")
            ])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try script.write(to: root.appendingPathComponent("show.js"), atomically: true, encoding: .utf8)
        return try PluginUnderTest(packageAt: root)
    }

    func testLevelFourThroughSevenExamplesMatchSharedSchemaMatrixThroughTheRealSDK() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.api.appendingPathComponent("fixtures/stable-levels/index.json")))
        let examples = index.cases.filter { $0.sdk_script != nil }
        XCTAssertEqual(Set(examples.compactMap(\.sdk_level)), Set(4...7))
        for fixture in examples {
            let script = try String(contentsOf: Self.api.appendingPathComponent("fixtures/" + XCTUnwrap(fixture.sdk_script)), encoding: .utf8)
            for check in fixture.checks where check.valid {
                let probe = try plugin(at: root, level: check.level, script: script)
                let run = helper.run(.init("show", event: .pageActionChosen(page: "p", action: "run", values: .object([:]), selection: .null)),
                    of: probe, answering: RecordedHostServices([:]))
                let output = try run.result.get()
                XCTAssertEqual(output, fixture.value, "\(fixture.name), Level \(check.level)")
                XCTAssertTrue(run.requests.isEmpty, "Building an answer must not perform an operation")
                _ = try run.answer()
                let schema = Self.api.appendingPathComponent("schemas/" + check.schema)
                let validator = try check.definition.map { try JSONSchemaSubsetValidator(definition: $0, inSchemaAt: schema) }
                    ?? JSONSchemaSubsetValidator(schemaAt: schema)
                XCTAssertEqual(validator.errors(for: output), [], fixture.name)
            }
        }
    }

    func testEveryRetiredDeclarationIsRefusedBeforeTheHelperOrHostServicesRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("spinnetplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let records = PluginInterfaceContracts.host.candidates
        XCTAssertEqual(records.count, 15)
        for record in records {
            let probe = try plugin(at: root, level: record.baseLevel, candidates: [record.declaration],
                script: "requestHostService('storage.get', {key:'should-not-run'})")
            let run = helper.run(.init("show"), of: probe, answering: RecordedHostServices([:]))
            XCTAssertThrowsError(try run.result.get()) { error in
                guard case .invalidAction(let message)? = error as? PluginRuntimeError else {
                    return XCTFail("Unexpected refusal category for \(record.declaration): \(error)")
                }
                guard case .retired(let promotedLevel) = record.status, let level = promotedLevel else {
                    return XCTFail("Expected a retirement record: \(record.declaration)")
                }
                XCTAssertTrue(message.contains(record.name), message)
                XCTAssertTrue(message.contains("revision \(record.revision)"), message)
                XCTAssertTrue(message.contains("became Plugin API Level \(level)"), message)
            }
            XCTAssertTrue(run.requests.isEmpty, "\(record.declaration) reached a Host Service")
        }
        XCTAssertEqual(helper.launchCount, 0, "No retired SDK should need to be embedded or injected")
    }
}
