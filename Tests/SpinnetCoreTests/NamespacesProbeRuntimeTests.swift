import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Namespaces Probe run the way its author runs it: through the public
/// test kit and the real helper, against the Host this repository builds.
/// Its script calls Host Services by catalogue ID through the namespaced SDK,
/// its scriptless Command runs one directly, and internal adapter names and
/// reserved IDs a declaring Plugin may not use are refused with the ID the
/// Host expects.
final class NamespacesProbeRuntimeTests: XCTestCase {
    private var helpers: [PluginTestHelper] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
    }

    private func run(_ commandID: String, of source: URL = NamespacesProbeFixture.package,
                     answering services: PluginHostServiceBroker = RecordedHostServices(),
                     contracts: PluginInterfaceContracts = NamespacesProbeFixture.host) throws -> PluginTestRun {
        let helper = try PluginTestHelper(contracts: contracts)
        helpers.append(helper)
        return helper.run(PluginTestInvocation(commandID), of: try PluginUnderTest(packageAt: source), answering: services)
    }

    /// A variant of the probe whose script is `source`, with every
    /// Capability its tests need.
    private func probe(running source: String, capabilities: [String] = ["read_selected_text", "write_clipboard"], scopes: [JSONValue]? = nil) throws -> URL {
        try NamespacesProbeFixture.write(scripts: ["shout.js": source]) {
            $0["capabilities"] = .array(capabilities.map(JSONValue.string))
            if let scopes { $0["capability_scopes"] = .array(scopes) }
        }
    }

    private func assertFailure(_ run: PluginTestRun, _ expected: PluginRuntimeError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try run.result.get(), file: file, line: line) {
            XCTAssertEqual($0 as? PluginRuntimeError, expected, file: file, line: line)
        }
    }

    // MARK: Calls

    func testTheProbeCallsHostServicesByTheirCatalogueIDs() throws {
        let run = try run("probe.shout", answering: RecordedHostServices(operations: [
            "selection.readText": .value(.string("hello")),
            "clipboard.write": .value(.null)
        ]))

        XCTAssertEqual(try run.answer().toast, "Copied in capitals")
        XCTAssertEqual(run.performed.map(\.id), ["selection.readText", "clipboard.write"])
        XCTAssertEqual(run.inputs(to: "selection.readText"), [.object(["best_effort": .bool(true)])])
        XCTAssertEqual(run.inputs(to: "clipboard.write"), [.string("HELLO")])
        XCTAssertEqual(run.requests.map(\.service), [.readSelectedText, .writeClipboard],
                       "Catalogue IDs retain their internal Host Service adapters")
    }

    /// Decision N5: a Plugin declaring the candidate calls by ID only; the
    /// refusal ends the run as a Host Service failure naming the ID.
    func testRawServiceNamesAreRefusedWithCurrentIDs() throws {
        let run = try run("probe.shout", of: probe(running: #"requestHostService("write_clipboard", "x")"#))

        assertFailure(run, .hostServiceFailed("Host Service is unavailable: write_clipboard is an internal adapter name; call clipboard.write"))
        XCTAssertEqual(run.requests, [], "The refusal never reached the Host's services")
    }

    /// Decision N8: keystrokes, Shortcuts and Services chosen by a script
    /// stay reserved, while the Commands that run them remain; an ID the
    /// catalogue reserves for a later ticket is refused too.
    func testReservedAndCommandOnlyIDsAreRefusedToAScript() throws {
        for (script, message) in [
            (#"spinnet.environment && requestHostService("system.runShortcut", "Focus")"#,
             "system.runShortcut is reserved: scripts cannot call it"),
            (#"requestHostService("selection.paste")"#, "selection.paste cannot be called from a script; a Command can run it"),
            (#"requestHostService("host.toast", "Hi")"#, "host.toast cannot be called from a script; a Command can run it"),
            (#"requestHostService("clipboard.copyAll")"#, "clipboard.copyAll is not a Host Service of the Plugin API catalogue")
        ] {
            let run = try run("probe.shout", of: probe(running: script))
            assertFailure(run, .hostServiceFailed("Host Service is unavailable: " + message))
            XCTAssertEqual(run.requests, [], script)
        }
    }

    /// A bare string stands for an operation's one required string member,
    /// so both spellings are the same call.
    func testABareStringStandsForThePrimaryMember() throws {
        let run = try run("probe.shout", of: probe(running: """
            spinnet.clipboard.write("a"); spinnet.clipboard.write({ text: "b" }); null
            """), answering: RecordedHostServices([.writeClipboard: .value(.null)]))

        XCTAssertEqual(try run.result.get(), .null)
        XCTAssertEqual(run.inputs(to: "clipboard.write"), [.string("a"), .string("b")])
    }

    /// `open.application` is new as a call and needs `open_local_path`,
    /// which already lets a script launch an application by its path.
    func testOpeningAnApplicationNeedsOpenLocalPath() throws {
        let script = #"spinnet.open.application({ application: "com.apple.TextEdit" })"#
        let granted = try run("probe.shout", of: probe(running: script, capabilities: ["open_local_path", "write_clipboard"]),
                              answering: RecordedHostServices(operations: ["open.application": .value(.null)]))
        let refused = try run("probe.shout", of: probe(running: script))

        XCTAssertEqual(try granted.result.get(), .null)
        XCTAssertEqual(granted.inputs(to: "open.application"), [.string("com.apple.TextEdit")])
        assertFailure(refused, .capabilityDenied("Capability open_local_path is not granted"))
    }

    // MARK: The scriptless Command

    /// The probe's Command runs `clipboard.write` with its fixed input as
    /// the Host runs it: no helper starts.
    func testTheProbesCommandRunsWithoutAScript() throws {
        let run = try run("probe.copy_greeting", answering: RecordedHostServices(operations: [
            "clipboard.write": .value(.null)
        ]))

        XCTAssertEqual(try run.result.get(), .null)
        XCTAssertEqual(run.performed, [PluginTestOperation(id: "clipboard.write",
                                                           input: .string("Hello from a Host Command"))])
        XCTAssertEqual(run.requests, [])
        XCTAssertEqual(helpers.last?.launchCount, 0)
    }

    /// The Command fails with its operation's category, as a call does.
    func testTheProbesCommandFailsWithItsOperationsCategory() throws {
        let run = try run("probe.copy_greeting", answering: RecordedHostServices(operations: [
            "clipboard.write": .failure(.unavailable("The clipboard is busy"))
        ]))

        XCTAssertThrowsError(try run.result.get()) {
            XCTAssertEqual(($0 as? ActionFailure)?.category, .hostServiceFailed)
            XCTAssertEqual(($0 as? ActionFailure)?.message, "Host Service is unavailable: The clipboard is busy")
        }
    }

    /// The kit refuses a Command the Host would refuse, before it runs.
    func testARefusedCommandDoesNotRun() throws {
        let run = try run("probe.copy_greeting", of: NamespacesProbeFixture.write(NamespacesProbeFixture.naming("url.open")),
                          answering: RecordedHostServices(operations: ["open.url": .value(.null)]))

        assertFailure(run, .invalidAction("Command probe.copy_greeting of Namespaces Probe names internal adapter url.open; use open.url."))
        XCTAssertEqual(run.performed, [])
    }

    // MARK: The SDK

    /// Level 2's SDK holds the same call at every ID, and `host` for the
    /// operation only an answer or a page action reaches. Under Level 2 a
    /// synchronous `selection.replace` needs a target the Host showed, as
    /// `host_operations` ruled, so the probe calls every other ID.
    func testCurrentSDKCallsEveryOfferedID() throws {
        let ids = HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id)
        let toolResult: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("installed"), "packages": .array([])])
        let run = try run("probe.shout", of: probe(running: """
            const reached = [];
            let toolResult = null;
            for (const area of Object.keys(spinnet).sort()) {
              if (area === "ui" || area === "environment") continue;
              for (const verb of Object.keys(spinnet[area]).sort()) {
                const member = spinnet[area][verb];
                if (typeof member !== "function") continue;
                if (area + "." + verb === "tools.read") {
                  toolResult = member({tool: "homebrew", operation: "installed", kind: "formula"});
                } else if (area + "." + verb !== "selection.replace") member(area + "." + verb);
                reached.push(area + "." + verb);
              }
            }
            [reached, Object.keys(spinnet).sort(), Object.keys(spinnet.host.showPluginSettings).sort(),
             typeof spinnet.ui.view, typeof spinnet.ui.showPage, Object.isFrozen(spinnet.clipboard), toolResult]
            """, capabilities: ["read_selected_text", "write_clipboard", "read_reviewed_tools"], scopes: [
                .object(["capability": .string("read_reviewed_tools"), "command_ids": .array([.string("probe.shout")]),
                    "data_types": .array([]), "includes_existing_host_data": .bool(false), "https_hosts": .array([]), "external_apps": .array([]),
                    "reviewed_tools": .array([.object(["tool": .string("homebrew"), "operations": .array([.string("installed")]), "kinds": .array([.string("formula")])])])])
            ]), answering: AnsweringEverything(reviewedTools: RecordedHostServices(operations: ["tools.read": .value(toolResult)])))

        guard case .array(let values) = try run.result.get(), values.count == 7 else {
            return XCTFail("The probe did not report the SDK")
        }
        XCTAssertEqual(values[0], .array(ids.sorted().map(JSONValue.string)))
        XCTAssertEqual(values[1], .array(["activities", "apps", "clipboard", "clipboardHistory", "environment", "host", "http", "open",
                                          "screen", "selection", "storage", "system", "text", "tools", "ui", "window"].map(JSONValue.string)))
        XCTAssertEqual(values[2], .array([.string("action"), .string("operation")]))
        XCTAssertEqual(values[3], .string("function"), "Form/detail View builders remain available")
        XCTAssertEqual(values[4], .string("function"))
        XCTAssertEqual(values[5], .bool(true))
        XCTAssertEqual(values[6], toolResult)
        XCTAssertEqual(run.performed.map(\.id), ids.sorted().filter { $0 != "selection.replace" })
        XCTAssertEqual(run.inputs(to: "tools.read"), [.object(["tool": .string("homebrew"), "operation": .string("installed"), "kind": .string("formula")])])
        XCTAssertEqual(run.requests.filter { $0.service == .reviewedToolRead }.count, 1)
    }


}

/// Records a typed tools.read result through its public scope checks; other
/// calls return null so this coverage probe sees each SDK member's Host Service.
private struct AnsweringEverything: PluginHostServiceBroker {
    let reviewedTools: RecordedHostServices
    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue {
        if request.service == .reviewedToolRead { return try reviewedTools.execute(request: request, for: package, action: action) }
        return .null
    }
}
