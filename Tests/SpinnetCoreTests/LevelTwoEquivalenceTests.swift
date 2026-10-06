import Foundation
import XCTest
@testable import SpinnetCore
import SpinnetPluginTestKit

/// Promotion is verified by running each Plugin's candidate revision on the
/// candidate Host and its Level 2 revision on the promoted Host, with the
/// same result (#68, ADR 0013). The Host's probes declare Level 2; their
/// candidate variants declare the revisions they were written against.
/// Each scenario runs through the public test kit and the real helper, and
/// everything the kit observed is compared: every answer, every event the
/// Host delivered, every operation it performed and its outcome, the toasts,
/// what ran after the view closed, and what the session kept.
final class LevelTwoEquivalenceTests: XCTestCase {
    private var helpers: [PluginTestHelper] = []
    private var directories: [URL] = []

    override func tearDown() {
        helpers.forEach { $0.shutdown() }
        helpers = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func helper(_ contracts: PluginInterfaceContracts) throws -> PluginTestHelper {
        let helper = try PluginTestHelper(contracts: contracts)
        helpers.append(helper)
        return helper
    }

    private func storage() -> PluginStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return PluginStorage(directory: directory)
    }

    /// What one session showed the kit, comparable across Hosts.
    private struct Transcript: Equatable {
        var answers: [String] = []
        var events: [PluginViewEvent] = []
        var performed: [RequestedHostOperation] = []
        var outcomes: [HostOperationOutcome] = []
        var toasts: [String] = []
        var afterClose: [PluginViewEvent] = []
        var state: JSONValue = .null
        var page: JSONValue?
        var isClosed = false

        mutating func append(_ session: PluginTestPage) {
            answers += session.runs.map { run in
                switch run.result {
                case .success(let value):
                    return String(decoding: (try? JSONEncoder.sorted.encode(value)) ?? Data(), as: UTF8.self)
                case .failure(let error): return "failed: \(error.localizedDescription)"
                }
            }
            events += session.events
            performed += session.performed
            outcomes += session.outcomes
            toasts += session.toasts
            afterClose += session.afterClose
            state = session.state
            page = session.pageJSON
            isClosed = session.isClosed
        }
    }

    /// Runs `scenario` on the package's candidate variant, declaring
    /// `declarations`, on the candidate Host, and on the package itself on
    /// this Host, each with its own Plugin Storage, and returns both
    /// transcripts.
    private func both(_ package: URL, declaring declarations: [CandidateContractRevision], command: String,
                      _ scenario: (() throws -> PluginTestPage, inout Transcript) throws -> Void)
        throws -> (candidate: Transcript, levelTwo: Transcript) {
        let candidatePackage = try CandidateVariant.write(package, CandidateVariant.declaring(declarations))
        directories.append(candidatePackage.deletingLastPathComponent())
        var results: [Transcript] = []
        for (source, contracts) in [(candidatePackage, PluginInterfaceContracts.candidateHost), (package, .host)] {
            let plugin = try PluginUnderTest(packageAt: source)
            let helper = try helper(contracts)
            let services = RecordedHostServices(storage: storage())
            var transcript = Transcript()
            try scenario({ PluginTestPage(command, of: plugin, helper: helper, answering: services) }, &transcript)
            results.append(transcript)
        }
        return (results[0], results[1])
    }

    // MARK: Pages

    /// Emoji: open, move, type, choose a category, copy with ⌘C, toggle a
    /// favourite, insert with Return (the unpinned view closes and the
    /// outcome reaches a viewless run); then a second session that reads
    /// Recent and Favourites, goes to the end and back through ranges, is
    /// pinned and inserts by double-click, has an insertion refused, and is
    /// called again.
    func testEmojiGivesTheSameResultAtLevelTwo() throws {
        let (candidate, levelTwo) = try both(CollectionsFixtures.emoji, declaring: CandidateVariant.pages(),
                                             command: "emoji.search") { session, transcript in
            let first = try session()
            try first.open()
            try first.press(.down)
            try first.type("cat", into: "query")
            try first.choose("animals-nature", in: "category")
            try first.copySelection()
            let selected = try XCTUnwrap(first.selectedItem)
            try first.choose(itemAction: "favourite", on: selected.id)
            try first.pressReturn(in: "query")
            XCTAssertTrue(first.isClosed)
            transcript.append(first)

            let second = try session()
            try second.open()
            try second.press(.end)
            try second.scroll(to: 1000)
            try second.press(.home)
            second.isPinned = true
            let other = try XCTUnwrap(second.item(at: 5))
            try second.doubleClick(other.id)
            second.operationOutcomes["selection.replace"] = .refused(.targetChanged)
            try second.pressReturn()
            try second.call()
            transcript.append(second)
        }
        XCTAssertFalse(candidate.performed.isEmpty)
        XCTAssertFalse(candidate.afterClose.isEmpty, "The scenario reaches an outcome after the view closed")
        XCTAssertTrue(candidate.events.contains { if case .loadRange = $0 { return true }; return false })
        XCTAssertEqual(levelTwo, candidate)
    }

    /// Brew: a list in pages of 150, its scope and search, a detail page
    /// with a Host-performed copy and a link, Back through page memory, a
    /// secondary item action answering with a toast, and a call with
    /// another override.
    func testBrewGivesTheSameResultAtLevelTwo() throws {
        let (candidate, levelTwo) = try both(CollectionsFixtures.brew, declaring: CandidateVariant.pages(),
                                             command: "brew.packages") { session, transcript in
            let brew = try session()
            try brew.open()
            try brew.choose("all", in: "scope")
            try brew.scrollToEnd()
            try brew.type("py", into: "query")
            let python = try XCTUnwrap(brew.collection?.items.first { $0.title == "py@3.13" })
            try brew.scroll(to: try XCTUnwrap(brew.collection?.positions[python.id]))
            try brew.select(python.id)
            try brew.pressReturn(in: "query")
            try brew.click("Copy Name")
            try brew.click("Homepage")
            try brew.click("back")
            try brew.choose("outdated", in: "scope")
            let outdated = try XCTUnwrap(brew.selectedItem)
            try brew.choose(itemAction: "upgrade", on: outdated.id)
            try brew.call(input: .object(["scope": .string("installed")]))
            transcript.append(brew)
        }
        XCTAssertEqual(candidate.performed.map(\.perform), ["clipboard.write", "open.url"])
        XCTAssertEqual(levelTwo, candidate)
    }

    // MARK: Requested operations and catalogue IDs

    /// The Operations Probe's Level 1 view with requested operations, on
    /// `host_operations` r2: Return requests an insertion that commits with
    /// the answer, its outcome comes back as `operation_finished`, and a
    /// request without a view is refused, the same at Level 2.
    func testRequestedOperationsGiveTheSameResultAtLevelTwo() throws {
        let candidatePackage = try CandidateVariant.write(OperationsProbeFixture.package,
                                                          CandidateVariant.declaring(CandidateVariant.operations()))
        directories.append(candidatePackage.deletingLastPathComponent())
        struct Step: Equatable {
            var state: JSONValue?
            var view: JSONValue?
            var operation: RequestedHostOperation?
            var performed: RecordedHostOperations.Performed?
        }
        func transcript(_ source: URL, _ contracts: PluginInterfaceContracts) throws -> [Step] {
            let plugin = try PluginUnderTest(packageAt: source)
            let helper = try helper(contracts)
            let operations = RecordedHostOperations(["selection.replace": .refused(.targetChanged)], contracts: contracts)
            var steps: [Step] = []
            let opened = try helper.run(PluginTestInvocation("probe.pick"), of: plugin, answering: RecordedHostServices())
                .answer()
            steps.append(Step(state: opened.state, view: opened.view))
            for query in ["star", "heart"] {
                let invocation = PluginTestInvocation("probe.pick", event: .submitted(values: .object(["query": .string(query)])),
                                                      state: opened.state, view: opened.view)
                let run = helper.run(invocation, of: plugin, answering: RecordedHostServices())
                let answer = try run.answer()
                let performed = try operations.perform(run, of: plugin, for: invocation)
                steps.append(Step(state: answer.state, view: answer.view, operation: answer.operation, performed: performed))
                if let delivery = performed?.delivery {
                    let finished = try helper.run(PluginTestInvocation("probe.pick", event: delivery, state: answer.state),
                                                  of: plugin, answering: RecordedHostServices()).answer()
                    steps.append(Step(state: finished.state, view: finished.view, operation: finished.operation))
                }
            }
            let stampInvocation = PluginTestInvocation("probe.stamp")
            let stamp = helper.run(stampInvocation, of: plugin, answering: RecordedHostServices())
            let stamped = try stamp.answer()
            steps.append(Step(state: stamped.state, view: stamped.view, operation: stamped.operation,
                              performed: try operations.perform(stamp, of: plugin, for: stampInvocation)))
            return steps
        }
        let candidate = try transcript(candidatePackage, .candidateHost)
        let levelTwo = try transcript(OperationsProbeFixture.package, .host)
        XCTAssertEqual(levelTwo, candidate)
        XCTAssertTrue(candidate.contains { $0.performed?.outcome == .refused(.targetChanged) })
        XCTAssertTrue(candidate.contains { $0.performed?.outcome == .refused(.targetNotShown) },
                      "The stamp, without a view, is refused")
    }

    /// The Namespaces Probe names Host Services by catalogue ID in a script
    /// and in a scriptless Command, as on `namespaces` r1.
    func testCatalogueIDsGiveTheSameResultAtLevelTwo() throws {
        let candidatePackage = try CandidateVariant.write(NamespacesProbeFixture.package,
                                                          CandidateVariant.declaring([CandidateVariant.namespaces]))
        directories.append(candidatePackage.deletingLastPathComponent())
        let services = RecordedHostServices(operations: [
            "selection.readText": .value(.string("hello")), "clipboard.write": .value(.null)
        ])
        struct Ran: Equatable {
            let result: JSONValue
            let performed: [PluginTestOperation]
            let requests: [PluginTestRequest]
        }
        var results: [[Ran]] = []
        for (source, contracts) in [(candidatePackage, PluginInterfaceContracts.candidateHost),
                                    (NamespacesProbeFixture.package, .host)] {
            let plugin = try PluginUnderTest(packageAt: source)
            let helper = try helper(contracts)
            results.append(try ["probe.shout", "probe.copy_greeting"].map { command in
                let run = helper.run(PluginTestInvocation(command), of: plugin, answering: services)
                return Ran(result: try run.result.get(), performed: run.performed, requests: run.requests)
            })
        }
        XCTAssertEqual(results[1], results[0])
        XCTAssertEqual(results[0].flatMap { $0.performed.map(\.id) },
                       ["selection.readText", "clipboard.write", "clipboard.write"])
    }
}

private extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
