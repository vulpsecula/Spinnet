import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// The Namespaces Probe run the way its author runs it: through the public
/// test kit and the real helper, against the Host this repository builds.
/// Its script calls Host Services by catalogue ID through the namespaced SDK,
/// its scriptless Command runs one directly, and the Level 1 names and
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
    private func probe(running source: String, capabilities: [String] = ["read_selected_text", "write_clipboard"]) throws -> URL {
        try NamespacesProbeFixture.write(scripts: ["shout.js": source]) {
            $0["capabilities"] = .array(capabilities.map(JSONValue.string))
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
                       "Each ID is performed by the Host Service Level 1 performs it with")
    }

    /// Decision N5: a Plugin declaring the candidate calls by ID only; the
    /// refusal ends the run as a Host Service failure naming the ID.
    func testALevelOneNameIsRefusedWithTheIDToCallInstead() throws {
        let run = try run("probe.shout", of: probe(running: #"requestHostService("write_clipboard", "x")"#))

        assertFailure(run, .hostServiceFailed("Host Service is unavailable: write_clipboard is a Plugin API Level 1 "
            + "name; a Plugin API Level 2 Plugin calls clipboard.write"))
        XCTAssertEqual(run.requests, [], "The refusal never reached the Host's services")
    }

    /// Decision N8: keystrokes, Shortcuts and Services chosen by a script
    /// stay reserved, while the Commands that run them remain; an ID the
    /// catalogue reserves for a later ticket is refused too.
    func testReservedAndCommandOnlyIDsAreRefusedToAScript() throws {
        for (script, message) in [
            (#"spinnet.environment && requestHostService("system.runShortcut", "Focus")"#,
             "system.runShortcut is reserved: no Plugin API Level lets a script call it yet"),
            (#"requestHostService("apps.frontmost")"#,
             "apps.frontmost is reserved: no Plugin API Level lets a script call it yet"),
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

        assertFailure(run, .invalidAction("Command probe.copy_greeting of Namespaces Probe names url.open, a Plugin API "
            + "Level 1 Host Command; a Plugin API Level 2 Plugin names it open.url."))
        XCTAssertEqual(run.performed, [])
    }

    // MARK: The SDK

    /// Every operation a script can call is a function at `spinnet.<id>`
    /// that calls exactly that ID; the namespaces without one, and Level 1's
    /// wrappers, are absent. This is retired revision 1 of `namespaces`
    /// alone, on the candidate Host: an insertion needed no shown target.
    func testTheNamespacedSDKCallsEachIDItHolds() throws {
        let ids = HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id)
        let source = try probe(running: """
            const reached = [];
            for (const area of Object.keys(spinnet).sort()) {
              if (area === "ui" || area === "environment") continue;
              for (const verb of Object.keys(spinnet[area]).sort()) {
                try { spinnet[area][verb](area + "." + verb); } catch (e) {}
                reached.push(area + "." + verb);
              }
            }
            [reached, Object.keys(spinnet).sort(), typeof spinnet.ui.view, Object.isFrozen(spinnet.clipboard)]
            """)
        let candidate = try CandidateVariant.write(source, CandidateVariant.declaring([CandidateVariant.namespaces]))
        let run = try run("probe.shout", of: candidate, answering: AnsweringEverything(),
                          contracts: .candidateHost)

        guard case .array(let values) = try run.result.get(), values.count == 4 else {
            return XCTFail("The probe did not report the SDK")
        }
        XCTAssertEqual(values[0], .array(ids.sorted().map(JSONValue.string)))
        XCTAssertEqual(values[1], .array(["apps", "clipboard", "clipboardHistory", "environment", "http", "open", "screen",
                                          "selection", "storage", "text", "ui", "window"].map(JSONValue.string)))
        XCTAssertEqual(values[2], .string("function"), "Level 1's view builders stay for Level 1 views")
        XCTAssertEqual(values[3], .bool(true))
        for performed in run.performed {
            XCTAssertTrue(ids.contains(performed.id), performed.id)
        }
    }

    /// Level 2's SDK holds the same call at every ID, and `host` for the
    /// operation only an answer or a page action reaches. Under Level 2 a
    /// synchronous `selection.replace` needs a target the Host showed, as
    /// `host_operations` ruled, so the probe calls every other ID.
    func testTheLevelTwoSDKCallsEachIDItHolds() throws {
        let ids = HostServiceCatalogue.operations.filter { $0.isOffered(at: .call) }.map(\.id)
        let run = try run("probe.shout", of: probe(running: """
            const reached = [];
            for (const area of Object.keys(spinnet).sort()) {
              if (area === "ui" || area === "environment") continue;
              for (const verb of Object.keys(spinnet[area]).sort()) {
                const member = spinnet[area][verb];
                if (typeof member !== "function") continue;
                if (area + "." + verb !== "selection.replace") member(area + "." + verb);
                reached.push(area + "." + verb);
              }
            }
            [reached, Object.keys(spinnet).sort(), Object.keys(spinnet.host.showPluginSettings).sort(),
             typeof spinnet.ui.view, typeof spinnet.ui.showPage, Object.isFrozen(spinnet.clipboard)]
            """), answering: AnsweringEverything())

        guard case .array(let values) = try run.result.get(), values.count == 6 else {
            return XCTFail("The probe did not report the SDK")
        }
        XCTAssertEqual(values[0], .array(ids.sorted().map(JSONValue.string)))
        XCTAssertEqual(values[1], .array(["apps", "clipboard", "clipboardHistory", "environment", "host", "http", "open",
                                          "screen", "selection", "storage", "text", "ui", "window"].map(JSONValue.string)))
        XCTAssertEqual(values[2], .array([.string("action"), .string("operation")]))
        XCTAssertEqual(values[3], .string("function"), "Level 1's view builders stay for Level 1 views")
        XCTAssertEqual(values[4], .string("function"))
        XCTAssertEqual(values[5], .bool(true))
        XCTAssertEqual(run.performed.map(\.id), ids.sorted().filter { $0 != "selection.replace" })
    }

    // MARK: Level 1 is unchanged

    /// A Plugin that declares no candidate keeps Level 1's SDK and names,
    /// and a catalogue ID stays as unknown to its helper as before.
    func testALevelOnePluginKeepsLevelOnesSDKAndNames() throws {
        let source = try NamespacesProbeFixture.write(scripts: ["shout.js": """
            [typeof spinnet.clipboard.history, typeof spinnet.clipboardHistory, spinnet.clipboard.write("x")]
            """]) { manifest in
            NamespacesProbeFixture.levelOne(&manifest)
            NamespacesProbeFixture.hostCommand { $0["host_command"] = .string("clipboard.copy"); $0["input"] = nil }(&manifest)
        }
        let level1 = try run("probe.shout", of: source, answering: RecordedHostServices([.writeClipboard: .value(.null)]))
        XCTAssertEqual(try level1.result.get(), .array([.string("function"), .string("undefined"), .null]))
        XCTAssertEqual(level1.requests, [PluginTestRequest(service: .writeClipboard, input: .string("x"))])
        XCTAssertEqual(level1.performed, [], "A Level 1 Plugin performs no catalogue ID")

        let unknown = try run("probe.shout", of: NamespacesProbeFixture.write(scripts: [
            "shout.js": #"requestHostService("clipboard.write", "x")"#
        ]) { manifest in
            NamespacesProbeFixture.levelOne(&manifest)
            NamespacesProbeFixture.hostCommand { $0["host_command"] = .string("clipboard.copy"); $0["input"] = nil }(&manifest)
        })
        assertFailure(unknown, .protocolViolation("Unsupported Host Service"))
    }
}

/// Answers every request with null, whatever Capability it needs, so a
/// test sees which Host Service each SDK member asks for.
private struct AnsweringEverything: PluginHostServiceBroker {
    func execute(request: PluginRuntimeHostServiceRequest, for package: PluginPackage,
                 action: ActionConfiguration) throws -> JSONValue { .null }
}
