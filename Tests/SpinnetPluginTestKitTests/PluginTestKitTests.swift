import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The kit runs a Plugin's script in the real helper, answers its Host
/// Service requests from what the test recorded, and hands back what the
/// script asked for.
final class PluginTestKitTests: XCTestCase {
    private var helper: PluginTestHelper!

    override func setUpWithError() throws {
        helper = try PluginTestHelper()
    }

    override func tearDown() {
        helper?.shutdown()
        helper = nil
    }

    func testARunAnswersFromRecordingsAndReturnsTheRequestsTheScriptMade() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text", "write_clipboard"], script: """
            (() => {
              const text = requestHostService("read_selected_text");
              requestHostService("write_clipboard", text.toUpperCase());
              return { copied: text.length };
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .value(.string("hello")),
            .writeClipboard: .value(.null)
        ]))

        XCTAssertEqual(try run.result.get(), .object(["copied": .number(5)]))
        XCTAssertEqual(run.requests, [
            PluginTestRequest(service: .readSelectedText, input: .null),
            PluginTestRequest(service: .writeClipboard, input: .string("HELLO"))
        ])
    }

    /// Recorded answers stand in for the Host, not for the manifest: a
    /// service whose Capability the Command does not declare is refused as
    /// the Host would refuse it, however the test answered it.
    func testAServiceTheManifestDoesNotDeclareIsRefusedLikeTheHostRefusesIt() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            requestHostService("write_clipboard", "copied")
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .writeClipboard: .value(.null)
        ]))

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .capabilityDenied)
        }
        XCTAssertEqual(run.requests, [PluginTestRequest(service: .writeClipboard, input: .string("copied"))])
    }

    /// A recorded failure reaches the script as the Host's would: it ends
    /// the run with the Host's failure category, even if the script catches it.
    func testARecordedFailureEndsTheRunAsTheHostsWould() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            (() => {
              try { return requestHostService("read_selected_text"); } catch (error) { return "fallback"; }
            })()
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .failure(.unavailable("No readable selection"))
        ]))

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .hostServiceFailed)
        }
    }

    /// An answer can depend on what was asked, and a value the Host would
    /// encode, such as a focused window, can be recorded as that value.
    func testAnswersCanDependOnTheRequestOrEncodeAHostValue() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text", "write_clipboard", "position_focused_window"],
                                     script: """
            (() => {
              const window = requestHostService("read_focused_window");
              return [requestHostService("write_clipboard", "a"), requestHostService("write_clipboard", "b"), window.frame.width];
            })()
            """)
        let window = FocusedWindow(frame: WindowRect(x: 0, y: 0, width: 300, height: 200),
                                   visibleFrame: WindowRect(x: 0, y: 25, width: 1440, height: 875))

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices([
            .readFocusedWindow: try .encoding(window),
            .writeClipboard: .answer { input in input }
        ]))

        XCTAssertEqual(try run.result.get(), .array([.string("a"), .string("b"), .number(300)]))
    }

    /// A request the test did not expect fails the run and says which
    /// service went unanswered.
    func testAnUnansweredServiceFailsTheRunNamingTheService() throws {
        let plugin = try writePlugin(capabilities: ["read_selected_text"], script: """
            requestHostService("read_selected_text")
            """)

        let run = helper.run(PluginTestInvocation("example.run"), of: plugin, answering: RecordedHostServices())

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual(($0 as? PluginRuntimeError)?.failureCategory, .hostServiceFailed)
            XCTAssertTrue("\($0)".contains("read_selected_text"), "\($0)")
        }
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText])
    }

    func testRunningACommandThePluginDoesNotDeclareFailsBeforeTheHelper() throws {
        let plugin = try writePlugin(capabilities: [], script: "null")
        let run = helper.run(PluginTestInvocation("example.missing"), of: plugin, answering: RecordedHostServices())
        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual($0 as? PluginTestKitError, .unknownCommand("example.missing"))
        }
    }

    /// A test finds its Plugin by package name in a parent directory of the
    /// test file, either beside it or in a `Plugins` directory, so the same
    /// test works in the Host repository and in a repository of Plugins.
    func testAPluginIsFoundByNameFromTheTestFile() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetTestKitRepository-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repository) }
        let testFile = repository.appendingPathComponent("Tests/ExampleTests/ExampleTests.swift").path
        try writePackage(at: repository.appendingPathComponent("Plugins/Nested.spinnetplugin"), id: "com.example.nested")
        try writePackage(at: repository.appendingPathComponent("Beside.spinnetplugin"), id: "com.example.beside")

        let nested = try PluginUnderTest(named: "Nested.spinnetplugin", origin: .bundled, searchingFrom: testFile)
        XCTAssertEqual(nested.manifest.id.rawValue, "com.example.nested")
        XCTAssertEqual(nested.package.origin, .bundled)
        XCTAssertEqual(try PluginUnderTest(named: "Beside.spinnetplugin", searchingFrom: testFile).manifest.id.rawValue,
                       "com.example.beside")
        XCTAssertThrowsError(try PluginUnderTest(named: "Missing.spinnetplugin", searchingFrom: testFile)) {
            XCTAssertEqual($0 as? PluginTestKitError, .packageNotFound("Missing.spinnetplugin"))
        }
    }

    // MARK: - Support

    /// A one-Command package in a temporary directory, removed after the test.
    private func writePlugin(capabilities: [String], script: String) throws -> PluginUnderTest {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetTestKit-\(UUID().uuidString).spinnetplugin", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try writePackage(at: root, capabilities: capabilities, script: script)
        return try PluginUnderTest(packageAt: root)
    }

    private func writePackage(at root: URL, id: String = "com.example.kit", capabilities: [String] = [],
                              script: String = "null") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        {
          "protocol_version": "1.0", "id": "\(id)", "name": "Kit Example", "version": "1.0.0",
          "capabilities": [\(list)],
          "commands": [
            {"id": "example.run", "title": "Run", "execution": "javascript", "is_configurable": false, "script": "run.js"}
          ]
        }
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: root.appendingPathComponent("run.js"), atomically: true, encoding: .utf8)
    }
}
