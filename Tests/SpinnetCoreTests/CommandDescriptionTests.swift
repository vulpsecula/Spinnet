import XCTest
@testable import SpinnetCore

/// A Command may carry an optional one-sentence `description` that the Host
/// shows wherever the user chooses between Commands.
final class CommandDescriptionTests: XCTestCase {

    private func manifest(description: String?) -> Data {
        let field = description.map { ", \"description\": \(String(reflecting: $0))" } ?? ""
        return Data("""
        {
          "protocol_version": "1.0", "id": "com.example.described", "name": "Described", "version": "1.0.0",
          "commands": [{"id": "run", "title": "Run", "execution": "javascript",
                        "is_configurable": false, "script": "run.js"\(field)}]
        }
        """.utf8)
    }

    func testADescriptionIsOptionalAndRoundTrips() throws {
        let described = try PluginManifestLoader.decode(manifest(description: "Runs the example."))
        XCTAssertEqual(described.commands[0].explanation, "Runs the example.")
        let encoded = try JSONEncoder().encode(described.commands[0])
        XCTAssertEqual(try JSONDecoder().decode(CommandDeclaration.self, from: encoded).explanation, "Runs the example.")
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["description"] as? String,
            "Runs the example."
        )

        XCTAssertNil(try PluginManifestLoader.decode(manifest(description: nil)).commands[0].explanation)
    }

    func testABlankOrOverlongDescriptionIsRejected() {
        for description in ["", "   ", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try PluginManifestLoader.decode(manifest(description: description)),
                                 "accepted \(description.count) characters")
        }
        XCTAssertNoThrow(try PluginManifestLoader.decode(manifest(description: String(repeating: "a", count: 256))))
    }

    /// A description is shown to the user, not executed, so rewording it must
    /// not turn a configured Action into a changed Command.
    func testRewordingADescriptionKeepsConfiguredActionsExecutable() {
        let before = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                        isConfigurable: false, script: "run.js", explanation: "Runs it.")
        let after = CommandDeclaration(id: CommandID("run"), title: "Run", execution: .javascript,
                                       isConfigurable: false, script: "run.js", explanation: "Runs the example.")
        XCTAssertTrue(before.matchesExecutableDefinition(after))
    }

    func testEveryWindowPositionCommandExplainsItself() throws {
        for command in try WindowPositionFixture.load().manifest.commands {
            let explanation = try XCTUnwrap(command.explanation, "\(command.id.rawValue) has no description")
            XCTAssertTrue(explanation.hasSuffix("."), "\(command.id.rawValue): \(explanation)")
        }
    }

    func testEveryTranslatorCommandExplainsItself() throws {
        for command in try TranslatorFixture.load().manifest.commands {
            let explanation = try XCTUnwrap(command.explanation, "\(command.id.rawValue) has no description")
            XCTAssertTrue(explanation.hasSuffix("."), "\(command.id.rawValue): \(explanation)")
        }
    }
}
