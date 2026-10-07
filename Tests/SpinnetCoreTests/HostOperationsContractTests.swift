import Foundation
import XCTest
@testable import SpinnetCore

/// Requested Host Operations as Plugin API Level 2 publishes them, in
/// `schemas/host-operations.schema.json`, `fixtures/host-operations/`,
/// `spinnet-level-2.d.ts` and `reference/host-operations.md`, and as the Host
/// reads them: the answers and events the fixtures hold, the request IDs,
/// the outcomes and reasons the Host reports, after the view closed too, and
/// Level 1 left as it was.
final class HostOperationsContractTests: XCTestCase {
    private static let pluginAPI = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PluginAPI")
    private static let published = pluginAPI.appendingPathComponent("fixtures/host-operations")
    private static let schema = pluginAPI.appendingPathComponent("schemas/host-operations.schema.json")

    private struct Fixture: Decodable {
        let file: String
        let definition: String
        let valid: Bool
        let note: String
    }

    private func fixtures() throws -> [Fixture] {
        struct Index: Decodable { let fixtures: [Fixture] }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: Self.published.appendingPathComponent("index.json")))
            .fixtures
    }

    private func value(_ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.published.appendingPathComponent(file)))
    }

    /// What the Operations Probe, a Level 2 Plugin, may use.
    static var permits: (PluginInterfaceMember) -> Bool {
        PluginInterfaceContracts.host.permitting(try! PluginManifestLoader.load(packageAt: OperationsProbeFixture.package).manifest)
    }

    func testThePublishedFixturesFollowTheSchema() throws {
        let all = try fixtures()
        XCTAssertFalse(all.isEmpty)
        for fixture in all {
            let validator = try JSONSchemaSubsetValidator(definition: fixture.definition, inSchemaAt: Self.schema)
            let errors = validator.errors(for: try value(fixture.file))
            XCTAssertEqual(errors.isEmpty, fixture.valid, "\(fixture.file): \(fixture.note) \(errors)")
        }
    }

    /// The Host accepts exactly the answers the schema accepts, reading each
    /// as it reads a Level 2 Plugin's answer, its view included.
    func testTheHostReadsThePublishedAnswersAsTheSchemaDoes() throws {
        for fixture in try fixtures() where fixture.definition == "answer" {
            let answer = try value(fixture.file)
            do {
                let read = try PluginScriptAnswer(parsing: answer, permits: Self.permits)
                if let view = read.view {
                    _ = try PluginViewDescription(parsing: view, settingsFields: [], permits: Self.permits)
                }
                XCTAssertTrue(fixture.valid, "\(fixture.file) was accepted: \(fixture.note)")
            } catch {
                XCTAssertFalse(fixture.valid, "\(fixture.file) was refused: \(error)")
                XCTAssertEqual((error as? PluginRuntimeError)?.failureCategory, .runtimeProtocolFailed, fixture.file)
            }
        }
    }

    func testAnAnswersOperationIsReadAsTheScriptWroteIt() throws {
        let answer = try PluginScriptAnswer(parsing: try value("answers/insert-with-view.json"), permits: Self.permits)
        XCTAssertEqual(answer.operation, RequestedHostOperation(perform: "selection.replace", input: .object(["text": .string("😀")]),
                                                                id: "insert", closesView: true))
        XCTAssertEqual(answer.operation?.insertedText, "😀")
        XCTAssertEqual(answer.state, .object(["recent": .array([.string("😀")])]))
        let view = try PluginViewDescription(parsing: XCTUnwrap(answer.view), settingsFields: [], permits: Self.permits)
        XCTAssertTrue(view.showsInsertionTarget)

        let bare = try PluginScriptAnswer(parsing: try value("answers/copy-bare-string.json"), permits: Self.permits)
        XCTAssertEqual(try bare.operation?.implementation()?.service, .writeClipboard)
        XCTAssertEqual(try bare.operation?.implementation()?.input, .string("😀"))
        XCTAssertNil(bare.view)
        XCTAssertEqual(bare.toast, "Copied")
    }

    /// The pre-checks that need no target refuse the answer before it
    /// commits, as a protocol violation naming what is wrong.
    func testWhatNeedsNoTargetIsCheckedBeforeTheAnswerCommits() {
        let violations: [(JSONValue, String)] = [
            (.object(["perform": .string("selection.replace"), "input": .string(String(repeating: "a", count: 128 * 1024 + 1))]),
             "The script's operation inserts more than 128 KiB"),
            (.object(["perform": .string("selection.replace"), "input": .string("a\u{8}")]),
             "The script's operation inserts a control character other than a tab or a line break"),
            (.object(["perform": .string("open.url"), "input": .string("file:///etc/hosts")]),
             "The script's operation gives open.url input it refuses: Only http and https links can be opened"),
            (.object(["perform": .string("open.path"), "input": .string("relative")]),
             "The script's operation gives open.path input it refuses: Use an absolute local path or ~/path, up to 4096 bytes"),
            (.object(["perform": .string("clipboardHistory.show"), "input": .string("x")]),
             "The script's operation gives clipboardHistory.show input, which it takes none of"),
            (.object(["perform": .string("apps.perform"), "input": .object(["bundle_id": .string("com.example")])]),
             "The script's operation gives apps.perform no operation"),
            (.object(["perform": .string("insert_text"), "input": .string("x")]),
             "The script's operation names insert_text, a Plugin API Level 1 name; a request names selection.replace"),
            (.object(["perform": .string("apps.quit")]),
             "The script's operation names apps.quit, which is reserved: no Plugin API Level requests it yet"),
            (.object(["perform": .string("storage.get"), "input": .string("k")]),
             "The script's operation names storage.get, which cannot be requested in an answer"),
            (.object(["perform": .string("clipboard.write"), "input": .string("x"), "notify": .string("yes")]),
             "The script's operation has a notify that is not true or false")
        ]
        for (operation, message) in violations {
            XCTAssertThrowsError(try PluginScriptAnswer(parsing: .object(["operation": operation]), permits: Self.permits)) {
                XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation(message))
            }
        }
        XCTAssertNoThrow(try PluginScriptAnswer(parsing: .object(["operation": .object([
            "perform": .string("selection.replace"), "input": .string("line one\nline two\ttabbed")
        ])]), permits: Self.permits), "Tabs and line breaks are keys the Host types")
    }

    /// Level 1 is unchanged: to a Level 1 Plugin, `operation` and
    /// `shows_insertion_target` are unknown members.
    func testALevelOnePluginCannotUseRequestedOperations() {
        let levelOne = CollectionsFixtures.levelOne
        let answer = JSONValue.object(["operation": .object(["perform": .string("selection.replace"), "input": .string("x")])])
        for parse in [{ try PluginScriptAnswer(parsing: answer) }, { try PluginScriptAnswer(parsing: answer, permits: levelOne) }] {
            XCTAssertThrowsError(try parse()) {
                XCTAssertEqual($0 as? PluginRuntimeError,
                               .protocolViolation("The script's answer has unknown member operation"))
            }
        }
        let view = JSONValue.object(["title": .string("T"), "shows_insertion_target": .bool(true),
                                     "actions": .array([.object(["id": .string("a"), "title": .string("A")])])])
        XCTAssertThrowsError(try PluginViewDescription(parsing: view, settingsFields: [], permits: levelOne)) {
            XCTAssertEqual($0 as? PluginRuntimeError, .protocolViolation("The view has unknown member shows_insertion_target"))
        }
        XCTAssertTrue(try PluginViewDescription(parsing: view, settingsFields: [], permits: Self.permits).showsInsertionTarget)
    }

    /// The IDs an answer may request are the catalogue's request IDs, which
    /// the schema lists and Level 2 offers as request members.
    func testTheRequestIDsAreTheCataloguesAndLevelTwosMembers() throws {
        let catalogue = HostServiceCatalogue.operations.filter { $0.isOffered(at: .request) }.map(\.id)
        XCTAssertEqual(HostOperationsContract.requestIDs, catalogue)
        XCTAssertEqual(Set(PluginInterfaceContracts.levelTwoMembers.filter { $0.kind == .request }.map(\.name)), Set(catalogue))
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
                Self.pluginAPI.appendingPathComponent("schemas/namespaces.schema.json"))),
              case .object(let definitions)? = schema["$defs"], case .object(let requests)? = definitions["request_id"],
              case .array(let ids)? = requests["enum"] else { return XCTFail("namespaces.schema.json lists no request IDs") }
        XCTAssertEqual(ids, catalogue.map(JSONValue.string))
    }

    /// Every `operation_finished` the Host can deliver is one the schema
    /// accepts, after the view closed too, where a cancelled operation never
    /// is; and its reasons are exactly the published ones.
    func testEveryResultTheHostDeliversFollowsTheSchema() throws {
        let validator = try JSONSchemaSubsetValidator(definition: "event", inSchemaAt: Self.schema)
        let reasons = HostOperationReason.allCases.flatMap { [HostOperationOutcome.refused($0), .failed($0)] }
        for outcome in [.succeeded, .declined, .expired, .cancelled] + reasons {
            for id in [nil, "insert"] {
                let event = PluginViewEvent.operationFinished(id: id, perform: "selection.replace", outcome: outcome)
                XCTAssertEqual(validator.errors(for: event.json), [], "\(outcome)")
                XCTAssertFalse(event.isGesture)
            }
        }
        for outcome in [.succeeded] + reasons {
            let event = PluginViewEvent.operationFinished(id: "insert", perform: "selection.replace", outcome: outcome,
                                                          viewClosed: true)
            XCTAssertEqual(validator.errors(for: event.json), [], "\(outcome) after close")
        }
        XCTAssertFalse(validator.errors(for: PluginViewEvent.operationFinished(
            id: nil, perform: "clipboard.write", outcome: .cancelled, viewClosed: true).json).isEmpty)
        guard case .object(let schema) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.schema)),
              case .object(let definitions)? = schema["$defs"], case .object(let reason)? = definitions["reason"],
              case .array(let reasons)? = reason["enum"] else { return XCTFail("No reasons") }
        XCTAssertEqual(reasons, HostOperationReason.allCases.map { .string($0.rawValue) })
    }

    /// The types tag the builder of every ID an answer may request, list
    /// them and the reasons, and the reference names each one.
    func testTheTypesReferenceAndSDKNameEveryRequestID() throws {
        let ids = HostOperationsContract.requestIDs
        let types = try String(contentsOf: Self.pluginAPI.appendingPathComponent("spinnet-level-2.d.ts"), encoding: .utf8)
        func matches(_ pattern: String, in text: String) throws -> [String] {
            let expression = try NSRegularExpression(pattern: pattern)
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        func union(_ name: String) throws -> [String] {
            let start = try XCTUnwrap(types.range(of: "export type \(name) =")).upperBound
            let end = try XCTUnwrap(types[start...].range(of: ";")).lowerBound
            return try matches(#""([\w.]+)""#, in: String(types[start..<end]))
        }
        XCTAssertEqual(Set(try matches(#"@id ([\w.]+) @entry [\w ]*\brequest\b"#, in: types)), Set(ids))
        XCTAssertEqual(try union("RequestID"), ids)
        XCTAssertEqual(try union("OperationReason"), HostOperationReason.allCases.map(\.rawValue))

        let reference = try String(contentsOf: Self.pluginAPI.appendingPathComponent("reference/host-operations.md"),
                                   encoding: .utf8)
        for id in ids {
            XCTAssertTrue(reference.contains("`\(id)`"), "host-operations.md does not name \(id)")
        }
        for reason in HostOperationReason.allCases {
            XCTAssertTrue(reference.contains("`\(reason.rawValue)`"), "host-operations.md does not name \(reason.rawValue)")
        }
        XCTAssertTrue(reference.contains("`outcome_after_close`"))
        XCTAssertTrue(types.contains("view_closed?: true"))
    }

    func testOnlySubmittingAndChoosingAreGestures() {
        XCTAssertTrue(PluginViewEvent.submitted(values: .null).isGesture)
        XCTAssertTrue(PluginViewEvent.actionChosen("go").isGesture)
        XCTAssertTrue(ViewEventDelivery.actionStart.answersGesture, "The Action's start is a gesture")
        for event: PluginViewEvent in [.fieldChanged(field: "q", values: .null), .settingChanged(key: "k", value: .null),
                                       .settingsSwapped(first: "a", second: "b"),
                                       .sectionDelivered(section: "s", response: .null)] {
            XCTAssertFalse(event.isGesture, "\(event)")
        }
    }
}
