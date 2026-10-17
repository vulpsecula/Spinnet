import Foundation
import XCTest
@testable import SpinnetCore

final class ActivitySourceDeliveryTests: XCTestCase {
    func testLevelFourOptInIsPublishedAndOlderHostsRefuseIt() throws {
        let command = CommandDeclaration(id: .init("tasks"), title: "Tasks", execution: .javascript, script: "tasks.js")
        let manifest = try PluginManifest(apiLevel: 4, id: .init("com.example.live-tasks"), name: "Tasks", version: "1", commands: [command])
        XCTAssertEqual(PluginInterfaceContracts.host.highestStableLevel, 5)
        XCTAssertTrue(PluginInterfaceContracts.host.permitting(manifest)(LiveActivityDelivery.member))
        let older = PluginInterfaceContracts(levels: PluginInterfaceContracts.host.levels.filter { $0.key <= 3 })
        XCTAssertThrowsError(try older.check(manifest, origin: .bundled)) {
            XCTAssertEqual(($0 as? UnsupportedPluginAPILevel)?.supportedLevel, 3)
        }
        let schema = try JSONSchemaSubsetValidator(schemaAt: PagesContractTests.pluginAPI.appendingPathComponent("schemas/manifest-level-4.schema.json"))
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(schema.errors(for: value), [])
    }

    func testLevelFourTaskLogsDeliverEverySecondWhileEarlierLevelsKeepTheirFloor() throws {
        let record = try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: PagesContractTests.pluginAPI.appendingPathComponent("candidates/live_activity_delivery/r1/candidate.json")))
        let candidate = CandidateContract(name: record.name, revision: record.revision, baseLevel: record.baseLevel,
            members: record.members, tag: record.tag)
        let candidateHost = PluginInterfaceContracts(levels: PluginInterfaceContracts.host.levels.filter { $0.key <= 3 },
            candidates: [candidate])
        let promoted = try candidateHost.promoting(candidate.name, toLevel: 4)
        XCTAssertEqual(promoted.levels, PluginInterfaceContracts.host.levels.filter { $0.key <= 4 })
        XCTAssertEqual(record.status, .retired(promotedToLevel: 4))
        for (level, declaresCandidate) in [(2, false), (3, false), (4, false), (3, true)] {
            var clock = 0.0
            var timers: [(Double, () -> Void)] = []
            let owner = PluginID("com.example.live-tasks")
            let command = CommandDeclaration(id: .init("tasks"), title: "Tasks", execution: .javascript, script: "tasks.js")
            let manifest = try PluginManifest(apiLevel: level, candidateContracts: declaresCandidate ? [candidate.declaration] : [], id: owner, name: "Tasks", version: "1", commands: [command])
            let grants = PluginCapabilityGrantStore()
            let registry = PluginRegistry(contracts: declaresCandidate ? candidateHost : .host, grantStore: grants)
            try registry.register(.init(rootURL: FileManager.default.temporaryDirectory, manifest: manifest, origin: .installed))
            let action = try ActionConfiguration(id: .init("tasks"), pluginID: owner, command: command, input: .null)
            let activities = HostActivities()
            let task = try activities.register(owner: owner, pluginName: "Tasks", kind: "task", status: "Running", stop: {})
            func publish(_ line: String) {
                activities.updateTask(task.id, status: "Running", detail: .object([
                    "id": .string(task.id), "kind": .string("task"), "status": .string("running"),
                    "log": .array([.string(line)])
                ]), detached: false)
            }
            publish("first chunk")
            let broker = CapabilityCheckedHostServiceBroker(grantStore: grants, systemPermissionCheck: { _ in true },
                selectedTextProvider: { _ in "" }, clipboardWriter: { _ in }, activities: activities)
            let page = try PluginPage(parsing: .object([
                "id": .string("tasks"), "title": .string("Tasks"),
                "sources": .array([.object(["id": .string("activities"), "perform": .string("activities.list"),
                    "input": .null, "every": .number(1), "deliver": .object([:])])]),
                "content": .array([.object(["kind": .string("text"), "id": .string("log"), "text": .string("Waiting")])])
            ]), permits: { _ in true })
            let engine = HostRunSources(adapters: ["activities.list": broker.activitySourceAdapter(using: registry)],
                now: { clock }, schedule: { timers.append((clock + $0, $1)) }, background: { $0() }, executor: { $0() })
            var delivered: [JSONValue] = []
            engine.onDelivery = { _, event, current in
                if current(), case .sourceDelivered(_, _, _, let result?, nil) = event { delivered.append(result) }
            }
            try engine.present(page, for: action)
            engine.setVisible(true, pluginID: owner)
            XCTAssertEqual(delivered.count, 1)
            publish("second chunk before the task ends")
            while let next = timers.enumerated().min(by: { $0.element.0 < $1.element.0 }), next.element.0 <= 1 {
                let timer = timers.remove(at: next.offset); clock = timer.0; timer.1()
            }
            XCTAssertEqual(delivered.count, (level == 4 || declaresCandidate) ? 2 : 1, "Level \(level) delivery cadence")
            if level == 4 || declaresCandidate {
                XCTAssertEqual(delivered.last?.value(atPointer: "/0/log/0"), .string("second chunk before the task ends"))
            }
            engine.setVisible(false, pluginID: owner)
            let count = delivered.count
            for timer in timers { clock = timer.0; timer.1() }
            XCTAssertEqual(delivered.count, count, "Hidden pages must not keep invoking the Plugin")
        }
    }
}
