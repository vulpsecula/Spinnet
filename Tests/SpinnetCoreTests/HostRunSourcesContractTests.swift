import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class HostRunSourcesContractTests: XCTestCase {
    private let api = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PluginAPI")
    private var fixture: URL { api.deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/SourcesProbe.spinnetplugin") }

    func testExternalPackageBuildsAOnceReviewedToolSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".spinnetplugin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let brew = api.deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/ReviewedToolsProbe.spinnetplugin")
        try FileManager.default.copyItem(at: brew, to: directory)
        try """
        spinnet.ui.showPage(spinnet.ui.page({id: "brew", title: "Packages",
          sources: [spinnet.tools.read.source("local", {tool: "homebrew", operation: "installed", kind: "formula"}, {deliver: true})],
          content: [spinnet.ui.components.text({id: "name", text: "Waiting", bind: spinnet.ui.components.bind("local", "/packages/0/name")})]
        }))
        """.write(to: directory.appendingPathComponent("read.js"), atomically: true, encoding: .utf8)
        let plugin = try PluginUnderTest(packageAt: directory)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let invocation = PluginTestInvocation("probe.read")
        let answer = try helper.run(invocation, of: plugin, answering: RecordedHostServices()).answer()
        let page = try XCTUnwrap(answer.description)
        XCTAssertEqual(page.value(atPointer: "/sources/0/perform"), .string("tools.read"))
        let packages: JSONValue = .object(["tool": .string("homebrew"), "operation": .string("installed"), "packages": .array([.object(["kind": .string("formula"), "name": .string("wget")])])])
        var reads = 0
        let recording = try RecordedHostSources(of: plugin, for: invocation, operations: ["tools.read": .answer { _ in reads += 1; return packages }])
        try recording.present(page)
        recording.setVisible(true)
        XCTAssertEqual(recording.shown("name")?.text, "wget")
        XCTAssertEqual(recording.deliveries.count, 1)
        recording.setVisible(false); recording.setVisible(true); recording.advance(by: 60)
        XCTAssertEqual(reads, 1, "A successful Homebrew source is once only")
        XCTAssertEqual(helper.launchCount, 1, "The Host reads without holding the helper alive")
        recording.close()
        let missing = try RecordedHostSources(of: plugin, for: invocation, operations: ["tools.read": .failure(.tool(.missing))])
        try missing.present(page); missing.setVisible(true)
        guard case .sourceDelivered(_, _, _, nil, let failure)? = missing.deliveries.first else { return XCTFail("Expected bounded tool failure delivery") }
        XCTAssertEqual(failure?.category, .toolMissing)
        let validator = try JSONSchemaSubsetValidator(definition: "source_delivered", inSchemaAt: api.appendingPathComponent("schemas/host-run-sources.schema.json"))
        XCTAssertEqual(validator.errors(for: try XCTUnwrap(missing.deliveries.first).json), [])
        missing.close()
        let denied = try RecordedHostSources(of: plugin, for: invocation, deniedCapabilities: [.readReviewedTools],
            operations: ["tools.read": .answer { _ in XCTFail("A denied source must not read tool data"); return packages }])
        try denied.present(page); denied.setVisible(true)
        XCTAssertEqual(denied.shown("name")?.text, "Capability read_reviewed_tools is not granted")
        guard case .sourceDelivered(_, _, _, nil, let refusal)? = denied.deliveries.first else { return XCTFail("Expected tool authority failure") }
        XCTAssertEqual(refusal?.category, .capabilityDenied)
        XCTAssertEqual(refusal?.message, "Capability read_reviewed_tools is not granted")
        denied.close()
        var periodic = try XCTUnwrap(page.value(atPointer: "/sources/0"))
        guard case .object(var fields) = periodic else { return XCTFail("Expected source definition") }
        fields["every"] = .number(1); periodic = .object(fields)
        XCTAssertThrowsError(try PluginPageSource(parsing: periodic, permits: CollectionsFixtures.permits))
    }
    func testExternalPackageBuildsBoundPageAndShowsRecordedAnswerWithoutHelperRun() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let invocation = PluginTestInvocation("sources.show", input: .object(["deliver": .bool(false)]))
        let opened = helper.run(invocation, of: plugin, answering: RecordedHostServices())
        _ = try opened.answer()
        XCTAssertTrue(opened.requests.isEmpty, "A declaration performs no helper-side HTTP call")
        let page = try XCTUnwrap(try opened.result.get().value(atPointer: "/page"))
        let recording = try RecordedHostSources(of: plugin, for: invocation, responses: ["example.com": RecordedHostFetchedSections.json(#"{"temperature":24.5}"#)])
        try recording.present(page)
        XCTAssertEqual(recording.requests.count, 0, "An ordered-out page does not sample")
        recording.setVisible(true)
        XCTAssertEqual(recording.requests.count, 1)
        XCTAssertEqual(recording.shown("temperature", locale: Locale(identifier: "en_US"))?.text, "24.5")
        XCTAssertTrue(recording.deliveries.isEmpty)
        helper.retireHelper(of: plugin)
        recording.advance(by: 60)
        XCTAssertEqual(helper.launchCount, 1, "Binding updates never invoke a helper")
        XCTAssertEqual(recording.shown("temperature")?.text, "24.5")
        recording.close()
    }
    func testRecordedDeliveryColdStartsRetiredHelperWithMatchingProvenance() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let invocation = PluginTestInvocation("sources.show", input: .object(["deliver": .bool(true)]))
        let opened = try helper.run(invocation, of: plugin, answering: RecordedHostServices()).answer()
        let page = try XCTUnwrap(opened.description)
        let recording = try RecordedHostSources(of: plugin, for: invocation, responses: ["example.com": RecordedHostFetchedSections.json(#"{"temperature":24.5}"#)])
        try recording.present(page); recording.setVisible(true)
        let event = try XCTUnwrap(recording.deliveries.first)
        helper.retireHelper(of: plugin)
        let delivered = PluginTestInvocation("sources.show", input: invocation.input, event: event, state: opened.state)
        let answer = try helper.run(delivered, of: plugin, answering: RecordedHostServices()).answer()
        XCTAssertEqual(answer.state, .number(1))
        XCTAssertEqual(helper.launchCount, 2)
        XCTAssertEqual(recording.requests.count, 1)
    }
    func testPublishedRecordsAndLevelOneIsolation() throws {
        struct Entry: Decodable { let file: String; let definition: String; let valid: Bool }
        struct Index: Decodable { let fixtures: [Entry] }
        let folder = api.appendingPathComponent("fixtures/sources")
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
        for record in index.fixtures {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(record.file)))
            let schema = try JSONSchemaSubsetValidator(definition: record.definition, inSchemaAt: api.appendingPathComponent("schemas/pages.schema.json"))
            if record.valid { XCTAssertEqual(schema.errors(for: value), [], record.file) }
            if record.definition == "answer" {
                if record.valid { XCTAssertNoThrow(try PluginScriptAnswer(parsing: value, permits: CollectionsFixtures.permits)) }
                else { XCTAssertThrowsError(try PluginScriptAnswer(parsing: value, permits: CollectionsFixtures.permits)) }
                XCTAssertThrowsError(try PluginScriptAnswer(parsing: value, permits: CollectionsFixtures.levelOne))
            }
        }
        for member in HostRunSourceAddition.members {
            XCTAssertTrue(CollectionsFixtures.permits(member)); XCTAssertFalse(CollectionsFixtures.levelOne(member))
        }
    }
    func testSessionKeepsOnlyLatestQueuedSourceAndDropsInvalidProvenance() throws {
        final class Renderer: PluginViewRenderer {
            func present(_ presentation: PluginViewPresentation, of session: PluginViewSession) {}
            func close(_ session: PluginViewSession, because reason: PluginViewSessionEnd) {}
            func showToast(_ toast: String, in session: PluginViewSession) {}
        }
        let renderer = Renderer()
        let plugin = try PluginUnderTest(packageAt: fixture)
        let action = try plugin.action(for: PluginTestInvocation("sources.show"))
        var events: [PluginViewEvent] = []
        var finishers: [(ActionOutcome) -> Void] = []
        let sessions = PluginViewSessions(renderer: renderer, runEvent: { _, delivery, _, started, finish in
            events.append(delivery.event!); finishers.append(finish); started()
        }, schedule: { _, _ in }, showFeedback: { _ in }, permitting: { _ in PluginInterfaceContracts.host.permitting(plugin.manifest) })
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: api.appendingPathComponent("fixtures/sources/bound-https.json")))
        try sessions.actionAnswered(action, with: answer)
        let session = try XCTUnwrap(sessions.session(for: plugin.manifest.id))
        func event(_ number: Int) -> PluginViewEvent { .sourceDelivered(page: "weather", source: "remote", sequence: number, result: .number(Double(number)), failure: nil) }
        session.deliverSource(event(1), stillCurrent: { true })
        session.deliverSource(event(2), stillCurrent: { true })
        session.deliverSource(event(3), stillCurrent: { true })
        XCTAssertEqual(events, [event(1)])
        let succeeded = ActionOutcome(actionID: action.id, pluginID: action.pluginID, title: action.title, terminal: .succeeded(.null))
        finishers.removeFirst()(succeeded)
        XCTAssertEqual(events, [event(1), event(3)], "Newer source results replace queued ones in place")
        session.deliverSource(event(4), stillCurrent: { false })
        finishers.removeFirst()(succeeded)
        XCTAssertEqual(events.count, 2, "A changed page/source generation drops its queued event")
        session.close()
    }

    func testAuthorityFailureCanRetryOnGrantAndCloseStopsAllReads() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let invocation = PluginTestInvocation("sources.show")
        let recording = try RecordedHostSources(of: plugin, for: invocation,
            responses: ["example.com": RecordedHostFetchedSections.json(#"{"temperature":24.5}"#)], deniedCapabilities: [.contactHTTPS])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: api.appendingPathComponent("fixtures/sources/bound-https.json")))
        try recording.present(try XCTUnwrap(value.value(atPointer: "/page"))); recording.setVisible(true)
        XCTAssertEqual(recording.requests.count, 0)
        recording.grants.setDecision(.granted, for: plugin.manifest.id, pluginVersion: plugin.manifest.version,
            capability: .contactHTTPS, scope: plugin.manifest.scope(for: .contactHTTPS))
        recording.authorityChanged(); recording.advance(by: 60)
        XCTAssertEqual(recording.requests.count, 1)
        recording.close(); recording.advance(by: 600)
        XCTAssertEqual(recording.requests.count, 1)
        XCTAssertNil(recording.shown("temperature"))
    }

    func testSourceDeliveryWarmAndColdLatencyAndAutomaticIdleRetirement() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let helper = try PluginTestHelper(); defer { helper.shutdown() }
        let initial = PluginTestInvocation("sources.show", input: .object(["deliver": .bool(true)]))
        let opened = try helper.run(initial, of: plugin, answering: RecordedHostServices()).answer()
        let recording = try RecordedHostSources(of: plugin, for: initial,
            responses: ["example.com": RecordedHostFetchedSections.json(#"{"temperature":24.5}"#)])
        try recording.present(try XCTUnwrap(opened.description)); recording.setVisible(true)
        let delivered = try XCTUnwrap(recording.deliveries.first)
        let invocation = PluginTestInvocation("sources.show", input: initial.input, event: delivered, state: opened.state)
        func measure(cold: Bool) throws -> [Double] {
            var samples: [Double] = []
            for _ in 0..<20 {
                if cold { helper.retireHelper(of: plugin) }
                let start = ProcessInfo.processInfo.systemUptime
                _ = try helper.run(invocation, of: plugin, answering: RecordedHostServices()).answer()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            return samples.sorted()
        }
        let warm = try measure(cold: false), cold = try measure(cold: true)
        print(String(format: "SOURCE LATENCY ms warm p50 %.3f p95 %.3f max %.3f; cold p50 %.3f p95 %.3f max %.3f", warm[9], warm[18], warm[19], cold[9], cold[18], cold[19]))
        XCTAssertLessThan(warm[18], 150)
        XCTAssertLessThan(cold[18], 300)
        let launches = helper.launchCount
        let idleStart = ProcessInfo.processInfo.systemUptime
        let idle = expectation(description: "Production helper idle retirement")
        DispatchQueue.global().asyncAfter(deadline: .now() + 31.5) { idle.fulfill() }
        wait(for: [idle], timeout: 35)
        XCTAssertEqual(recording.shown("temperature", locale: Locale(identifier: "en_US"))?.text, "24.5")
        XCTAssertEqual(recording.requests.count, 1)
        _ = try helper.run(invocation, of: plugin, answering: RecordedHostServices()).answer()
        XCTAssertEqual(helper.launchCount, launches + 1, "An automatically retired helper cold-starts while source value survives")
        print(String(format: "SOURCE HELPER automatic retirement verified after %.3fs; launch count %d to %d", ProcessInfo.processInfo.systemUptime - idleStart, launches, helper.launchCount))
    }

    func testDeclaredDeliveryReportsFailureWithoutReadingRefusedData() throws {
        let plugin = try PluginUnderTest(packageAt: fixture)
        let value: JSONValue = .object(["id": .string("denied"), "title": .string("Denied"), "sources": .array([
            .object(["id": .string("remote"), "perform": .string("http.request"), "input": .object(["method": .string("GET"), "url": .string("https://example.com/weather")]), "deliver": .object([:])])]),
            "content": .array([.object(["kind": .string("text"), "id": .string("t"), "text": .string("Waiting")])])])
        let recording = try RecordedHostSources(of: plugin, for: PluginTestInvocation("sources.show"), deniedCapabilities: [.contactHTTPS])
        try recording.present(value); recording.setVisible(true)
        XCTAssertTrue(recording.requests.isEmpty)
        guard case .sourceDelivered(_, _, _, let result, let failure)? = recording.deliveries.first else {
            return XCTFail("A source's authority failure must reach its declared delivery")
        }
        XCTAssertNil(result); XCTAssertEqual(failure?.category, .capabilityDenied)
    }

}
